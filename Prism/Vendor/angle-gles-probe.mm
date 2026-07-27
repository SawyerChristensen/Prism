// Standalone go/no-go spike: does this ANGLE build report GLES 3.2 / ESSL 3.20
// via the Metal backend? projectM's GladLoader::CheckGLRequirements() hard-requires
// this; if it's not satisfied, projectm_create_with_opengl_load_proc() always
// returns nullptr. Build and run directly with clang++, not through Xcode:
//
//   clang++ -std=c++17 -fobjc-arc -framework Metal -framework Foundation \
//     -I Prism/Vendor/angle/include \
//     -L Prism/Vendor/angle/lib -Wl,-rpath,Prism/Vendor/angle/lib \
//     -lEGL -lGLESv2 \
//     Prism/Vendor/angle-gles-probe.mm -o /tmp/angle-gles-probe
//   /tmp/angle-gles-probe

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES2/gl2.h>
#include <cstdio>
#include <cstdlib>

#include "projectm-4/projectM.h"

namespace {
void* ProjectMLoadProc(const char* name, void*)
{
    return reinterpret_cast<void*>(eglGetProcAddress(name));
}
} // namespace

int main()
{
    const EGLAttrib displayAttribs[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_PLATFORM_ANGLE_MAX_VERSION_MAJOR_ANGLE, 3,
        EGL_PLATFORM_ANGLE_MAX_VERSION_MINOR_ANGLE, 2,
        EGL_NONE,
    };

    EGLDisplay display = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE,
                                                (void*)EGL_DEFAULT_DISPLAY, displayAttribs);
    if (display == EGL_NO_DISPLAY)
    {
        fprintf(stderr, "FAIL: eglGetPlatformDisplay returned EGL_NO_DISPLAY\n");
        return 1;
    }

    EGLint major = 0, minor = 0;
    if (!eglInitialize(display, &major, &minor))
    {
        fprintf(stderr, "FAIL: eglInitialize failed, error 0x%x\n", eglGetError());
        return 1;
    }
    printf("EGL version: %d.%d\n", major, minor);

    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLConfig config;
    EGLint numConfigs = 0;
    if (!eglChooseConfig(display, configAttribs, &config, 1, &numConfigs) || numConfigs == 0)
    {
        fprintf(stderr, "FAIL: eglChooseConfig failed, error 0x%x\n", eglGetError());
        return 1;
    }

    const EGLint pbufferAttribs[] = {
        EGL_WIDTH, 16,
        EGL_HEIGHT, 16,
        EGL_NONE,
    };
    EGLSurface surface = eglCreatePbufferSurface(display, config, pbufferAttribs);
    if (surface == EGL_NO_SURFACE)
    {
        fprintf(stderr, "FAIL: eglCreatePbufferSurface failed, error 0x%x\n", eglGetError());
        return 1;
    }

    EGLContext context = EGL_NO_CONTEXT;
    struct { EGLint major, minor; } attempts[] = {{3, 2}, {3, 1}, {3, 0}};
    for (auto& a : attempts)
    {
        const EGLint contextAttribs[] = {
            EGL_CONTEXT_MAJOR_VERSION, a.major,
            EGL_CONTEXT_MINOR_VERSION, a.minor,
            EGL_NONE,
        };
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs);
        if (context != EGL_NO_CONTEXT)
        {
            printf("eglCreateContext succeeded requesting ES %d.%d\n", a.major, a.minor);
            break;
        }
        fprintf(stderr, "eglCreateContext(%d.%d) failed, error 0x%x\n", a.major, a.minor, eglGetError());
    }
    if (context == EGL_NO_CONTEXT)
    {
        fprintf(stderr, "FAIL: all context version attempts failed\n");
        return 1;
    }

    if (!eglMakeCurrent(display, surface, surface, context))
    {
        fprintf(stderr, "FAIL: eglMakeCurrent failed, error 0x%x\n", eglGetError());
        return 1;
    }

    const char* version = (const char*)glGetString(GL_VERSION);
    const char* shadingLang = (const char*)glGetString(GL_SHADING_LANGUAGE_VERSION);
    const char* renderer = (const char*)glGetString(GL_RENDERER);
    printf("GL_VERSION: %s\n", version ? version : "(null)");
    printf("GL_SHADING_LANGUAGE_VERSION: %s\n", shadingLang ? shadingLang : "(null)");
    printf("GL_RENDERER: %s\n", renderer ? renderer : "(null)");

    bool ok = version && shadingLang;
    printf(ok ? "RESULT: GO (EGL/GLES probe)\n" : "RESULT: NO-GO (EGL/GLES probe)\n");
    if (!ok)
    {
        return 1;
    }

    projectm_handle instance = projectm_create_with_opengl_load_proc(ProjectMLoadProc, nullptr);
    if (instance == nullptr)
    {
        printf("RESULT: NO-GO (projectm_create_with_opengl_load_proc returned NULL)\n");
        return 1;
    }

    int pmMajor = 0, pmMinor = 0, pmPatch = 0;
    projectm_get_version_components(&pmMajor, &pmMinor, &pmPatch);
    printf("projectM version: %d.%d.%d\n", pmMajor, pmMinor, pmPatch);
    printf("RESULT: GO (projectm_create_with_opengl_load_proc succeeded)\n");

    projectm_destroy(instance);
    return 0;
}
