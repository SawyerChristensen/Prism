//
//  PrismItunesVisualizer.mm
//  PrismVisualizerPlugin
//

#import "PrismItunesVisualizer.h"
#import "ProjectMEngine.h"
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>

// See PrismVisualizerPlugin.mm's matching PrismLog macro/comment - plain NSLog's dynamic
// arguments get privacy-redacted to "<private>" in the unified log by default.
#define PrismLog(fmt, ...) os_log(OS_LOG_DEFAULT, "[Prism Visualizer] " fmt, ##__VA_ARGS__)

/// The real screen's max refresh rate, so ProMotion/high-refresh displays draw fully smoothly
/// instead of being capped at some arbitrary constant - same reasoning as
/// ProjectMMetalView.refreshMatchedFramesPerSecond in the main app. Falls back to NSScreen.main
/// (view has no window yet) or 60 (no screens at all) since MTKView requires a positive value.
static NSInteger PrismRefreshMatchedFramesPerSecond(NSView *view) {
    NSScreen *screen = view.window.screen ?: NSScreen.mainScreen;
    NSInteger hz = screen.maximumFramesPerSecond;
    return hz > 0 ? hz : 60;
}

@interface PrismItunesVisualizer () <MTKViewDelegate>
@end

@implementation PrismItunesVisualizer {
    id<MTLCommandQueue> _commandQueue;
    // Diagnostic-only: drawInMTKView fires once per display refresh, so state is logged at most
    // once every ~2s (see drawInMTKView) rather than every call, to stay legible while still
    // surfacing a persistently-broken pipeline (blank/grey output) within a couple seconds of it
    // starting.
    CFTimeInterval _lastDiagnosticLogTime;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect device:MTLCreateSystemDefaultDevice()];
    if (self == nil) {
        return nil;
    }

    _commandQueue = [self.device newCommandQueue];

    self.delegate = self;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = NO;
    self.enableSetNeedsDisplay = NO;
    self.paused = YES; // -startRendering flips this once there's an engine/preset to show.
    self.preferredFramesPerSecond = PrismRefreshMatchedFramesPerSecond(self);

    return self;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    // Picks up the real screen's refresh rate once the view actually has a window (it has none
    // yet at -initWithFrame: time) - and again if it's ever moved to a different-refresh screen.
    self.preferredFramesPerSecond = PrismRefreshMatchedFramesPerSecond(self);
}

- (void)dealloc {
    [self stopRendering];
}

- (void)startRendering {
    self.preferredFramesPerSecond = PrismRefreshMatchedFramesPerSecond(self);
    self.paused = NO;
}

- (void)stopRendering {
    self.paused = YES;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // No-op: drawInMTKView: reads view.drawableSize fresh every frame.
}

- (void)drawInMTKView:(MTKView *)view {
    // Diagnostic-only throttle (see _lastDiagnosticLogTime's doc comment) - decided once per call
    // so every early-return branch below can log its own specific reason without re-checking the
    // clock itself, and the final success path can log a heartbeat confirming frames are actually
    // reaching nextDrawable/commit.
    CFTimeInterval now = CACurrentMediaTime();
    BOOL shouldLog = (now - _lastDiagnosticLogTime) >= 2.0;
    if (shouldLog) {
        _lastDiagnosticLogTime = now;
    }

    if (self.engine == nil) {
        if (shouldLog) PrismLog("drawInMTKView: no engine set on view yet");
        return;
    }

    CGSize drawableSize = view.drawableSize;
    size_t width = (size_t)drawableSize.width;
    size_t height = (size_t)drawableSize.height;
    if (width == 0 || height == 0) {
        if (shouldLog) {
            PrismLog("drawInMTKView: drawableSize is zero (%{public}g x %{public}g)",
                      drawableSize.width, drawableSize.height);
        }
        return;
    }

    IOSurfaceRef ioSurface = [self.engine renderFrameWithWidth:width height:height];
    if (ioSurface == NULL) {
        if (shouldLog) PrismLog("drawInMTKView: engine returned NULL IOSurface for %{public}zux%{public}zu", width, height);
        return;
    }

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                            width:width
                                                                                           height:height
                                                                                        mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;

    id<MTLTexture> sourceTexture = [self.device newTextureWithDescriptor:descriptor iosurface:ioSurface plane:0];
    if (sourceTexture == nil) {
        if (shouldLog) PrismLog("drawInMTKView: newTextureWithDescriptor:iosurface: returned nil");
        return;
    }

    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (drawable == nil) {
        if (shouldLog) PrismLog("drawInMTKView: currentDrawable returned nil (view possibly not in a live window)");
        return;
    }

    if (shouldLog) {
        PrismLog("drawInMTKView: OK, presenting %{public}zux%{public}zu", width, height);
    }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:sourceTexture
               sourceSlice:0
               sourceLevel:0
              sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(width, height, 1)
                 toTexture:drawable.texture
          destinationSlice:0
          destinationLevel:0
         destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end
