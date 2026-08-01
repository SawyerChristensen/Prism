#pragma once

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

#include <EGL/egl.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns an ANGLE (Metal-backed) EGL display/config/context and knows how to bind
/// IOSurface-backed render targets to GL textures for interop with Metal.
///
/// One instance is expected to live for the lifetime of the visualizer. All methods
/// (other than -init) must be called with this context current on the calling thread
/// (see -makeCurrent).
@interface ProjectMEGLContext : NSObject

/// Creates the EGL display/config/context. Returns nil if ANGLE's Metal backend
/// can't be initialized or doesn't meet the minimum GLES/GLSL version this build
/// requires (see Vendor/projectm-VERSION.md for why the requirement is GLES 3.0,
/// not upstream projectM's default 3.2).
- (nullable instancetype)init NS_DESIGNATED_INITIALIZER;

/// Makes this context (and its internal dummy pbuffer surface) current on the calling thread.
/// Must be called before any other GL/projectM calls on a given thread.
- (BOOL)makeCurrent;

/// Function pointer suitable for projectm_create_with_opengl_load_proc(). Resolves GL
/// entry points via eglGetProcAddress; ignores the user_data parameter.
- (void *)loadProcFunctionPointer;

/// Creates (or resizes) the IOSurface-backed color render target used as projectM's
/// render destination, and binds it to an FBO. Safe to call every frame; only
/// recreates the underlying objects when the size actually changes.
/// Returns the FBO id to pass to projectm_opengl_render_frame_fbo(), or 0 on failure.
- (uint32_t)framebufferForWidth:(size_t)width height:(size_t)height;

/// The IOSurface backing the current render target (matches the most recent
/// -framebufferForWidth:height: call). nil until the first successful call.
/// The Metal side wraps this same IOSurface as an MTLTexture - see
/// MTLDevice.makeTexture(descriptor:iosurface:plane:).
@property(nonatomic, readonly, nullable) IOSurfaceRef currentIOSurface;

/// Blocks until all GL work submitted so far has completed. Called after rendering
/// a frame so the IOSurface's contents are guaranteed complete before Metal samples
/// it. Correctness-first; revisit with a proper fence once rendering is verified.
- (void)finish;

@end

NS_ASSUME_NONNULL_END
