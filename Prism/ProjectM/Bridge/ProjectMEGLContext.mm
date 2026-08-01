#import "ProjectMEGLContext.h"

#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <GLES2/gl2ext_angle.h>

#import <CoreFoundation/CoreFoundation.h>

#include <utility>

namespace {

void* ProjectMEGLLoadProc(const char* name, void*)
{
    return reinterpret_cast<void*>(eglGetProcAddress(name));
}

// Matches the fallback order verified working in Vendor/angle-gles-probe.mm: this
// ANGLE build's Metal backend currently only negotiates GLES 3.0, not 3.1/3.2, but
// requesting higher first means we transparently pick up improvements in future
// ANGLE builds without code changes here.
EGLContext CreateContextWithBestAvailableVersion(EGLDisplay display, EGLConfig config)
{
    const std::pair<EGLint, EGLint> attempts[] = {{3, 2}, {3, 1}, {3, 0}};
    for (const auto& version : attempts)
    {
        const EGLint contextAttribs[] = {
            EGL_CONTEXT_MAJOR_VERSION, version.first,
            EGL_CONTEXT_MINOR_VERSION, version.second,
            EGL_NONE,
        };
        EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs);
        if (context != EGL_NO_CONTEXT)
        {
            return context;
        }
    }
    return EGL_NO_CONTEXT;
}

} // namespace

@implementation ProjectMEGLContext {
    EGLDisplay _display;
    EGLConfig _config;
    EGLContext _context;
    EGLSurface _dummySurface; // 1x1 pbuffer, exists only so the context has something to bind to.

    // Current IOSurface-backed render target.
    size_t _targetWidth;
    size_t _targetHeight;
    IOSurfaceRef _ioSurface;
    EGLSurface _targetPbuffer;
    GLuint _targetTexture;
    GLuint _targetFramebuffer;
    GLenum _targetTextureGLTarget;
}

- (nullable instancetype)init
{
    self = [super init];
    if (self == nil)
    {
        return nil;
    }

    _display = EGL_NO_DISPLAY;
    _context = EGL_NO_CONTEXT;
    _dummySurface = EGL_NO_SURFACE;
    _targetPbuffer = EGL_NO_SURFACE;

    const EGLAttrib displayAttribs[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_PLATFORM_ANGLE_MAX_VERSION_MAJOR_ANGLE, 3,
        EGL_PLATFORM_ANGLE_MAX_VERSION_MINOR_ANGLE, 2,
        EGL_NONE,
    };
    _display = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, (void*)EGL_DEFAULT_DISPLAY,
                                      displayAttribs);
    if (_display == EGL_NO_DISPLAY)
    {
        return nil;
    }

    EGLint major = 0, minor = 0;
    if (!eglInitialize(_display, &major, &minor))
    {
        return nil;
    }

    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE,
        EGL_NONE,
    };
    EGLint numConfigs = 0;
    if (!eglChooseConfig(_display, configAttribs, &_config, 1, &numConfigs) || numConfigs == 0)
    {
        return nil;
    }

    const EGLint dummyAttribs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    _dummySurface = eglCreatePbufferSurface(_display, _config, dummyAttribs);
    if (_dummySurface == EGL_NO_SURFACE)
    {
        return nil;
    }

    _context = CreateContextWithBestAvailableVersion(_display, _config);
    if (_context == EGL_NO_CONTEXT)
    {
        return nil;
    }

    if (![self makeCurrent])
    {
        return nil;
    }

    // Resolve the GL target this config binds IOSurface textures to (2D vs. rectangle)
    // once, matching ANGLE's own EGLIOSurfaceClientBufferTest.cpp getGLTextureTarget().
    EGLint textureTargetEGL = 0;
    eglGetConfigAttrib(_display, _config, EGL_BIND_TO_TEXTURE_TARGET_ANGLE, &textureTargetEGL);
    switch (textureTargetEGL)
    {
        case EGL_TEXTURE_2D:
            _targetTextureGLTarget = GL_TEXTURE_2D;
            break;
        case EGL_TEXTURE_RECTANGLE_ANGLE:
            _targetTextureGLTarget = GL_TEXTURE_RECTANGLE_ANGLE;
            break;
        default:
            _targetTextureGLTarget = GL_TEXTURE_RECTANGLE_ANGLE;
            break;
    }

    return self;
}

- (void)dealloc
{
    [self destroyRenderTarget];
    if (_context != EGL_NO_CONTEXT)
    {
        eglDestroyContext(_display, _context);
    }
    if (_dummySurface != EGL_NO_SURFACE)
    {
        eglDestroySurface(_display, _dummySurface);
    }
    if (_display != EGL_NO_DISPLAY)
    {
        eglTerminate(_display);
    }
}

- (BOOL)makeCurrent
{
    return eglMakeCurrent(_display, _dummySurface, _dummySurface, _context) == EGL_TRUE;
}

- (void*)loadProcFunctionPointer
{
    return reinterpret_cast<void*>(&ProjectMEGLLoadProc);
}

- (void)destroyRenderTarget
{
    if (_targetFramebuffer != 0)
    {
        glDeleteFramebuffers(1, &_targetFramebuffer);
        _targetFramebuffer = 0;
    }
    if (_targetTexture != 0)
    {
        glDeleteTextures(1, &_targetTexture);
        _targetTexture = 0;
    }
    if (_targetPbuffer != EGL_NO_SURFACE)
    {
        eglDestroySurface(_display, _targetPbuffer);
        _targetPbuffer = EGL_NO_SURFACE;
    }
    if (_ioSurface != nullptr)
    {
        CFRelease(_ioSurface);
        _ioSurface = nullptr;
    }
    _targetWidth = 0;
    _targetHeight = 0;
}

- (uint32_t)framebufferForWidth:(size_t)width height:(size_t)height
{
    if (width == 0 || height == 0)
    {
        return 0;
    }
    if (width == _targetWidth && height == _targetHeight && _targetFramebuffer != 0)
    {
        return _targetFramebuffer;
    }

    [self destroyRenderTarget];

    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    auto addInt = [&](CFStringRef key, int32_t value) {
        CFNumberRef number = CFNumberCreate(nullptr, kCFNumberSInt32Type, &value);
        CFDictionaryAddValue(props, key, number);
        CFRelease(number);
    };
    addInt(kIOSurfaceWidth, (int32_t)width);
    addInt(kIOSurfaceHeight, (int32_t)height);
    addInt(kIOSurfacePixelFormat, 'BGRA');
    addInt(kIOSurfaceBytesPerElement, 4);

    _ioSurface = IOSurfaceCreate(props);
    CFRelease(props);
    if (_ioSurface == nullptr)
    {
        return 0;
    }

    const EGLint pbufferAttribs[] = {
        EGL_WIDTH, (EGLint)width,
        EGL_HEIGHT, (EGLint)height,
        EGL_IOSURFACE_PLANE_ANGLE, 0,
        EGL_TEXTURE_TARGET, (_targetTextureGLTarget == GL_TEXTURE_2D) ? EGL_TEXTURE_2D
                                                                       : EGL_TEXTURE_RECTANGLE_ANGLE,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
        EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
        EGL_NONE,
    };
    _targetPbuffer =
        eglCreatePbufferFromClientBuffer(_display, EGL_IOSURFACE_ANGLE, _ioSurface, _config, pbufferAttribs);
    if (_targetPbuffer == EGL_NO_SURFACE)
    {
        [self destroyRenderTarget];
        return 0;
    }

    glGenTextures(1, &_targetTexture);
    glBindTexture(_targetTextureGLTarget, _targetTexture);
    if (!eglBindTexImage(_display, _targetPbuffer, EGL_BACK_BUFFER))
    {
        [self destroyRenderTarget];
        return 0;
    }

    glGenFramebuffers(1, &_targetFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _targetFramebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, _targetTextureGLTarget,
                           _targetTexture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
    {
        [self destroyRenderTarget];
        return 0;
    }

    _targetWidth = width;
    _targetHeight = height;
    return _targetFramebuffer;
}

- (IOSurfaceRef)currentIOSurface
{
    return _ioSurface;
}

- (void)finish
{
    glFinish();
}

@end
