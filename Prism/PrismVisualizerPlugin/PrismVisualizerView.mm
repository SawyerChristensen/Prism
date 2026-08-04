//
//  PrismVisualizerView.mm
//  PrismVisualizerPlugin
//

#import "PrismVisualizerView.h"
#import "ProjectMEngine.h"
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>

// See PrismVisualizerPlugin.mm's matching PrismLog macro/comment - plain NSLog's dynamic
// arguments get privacy-redacted to "<private>" in the unified log by default.
#define PrismLog(fmt, ...) os_log(OS_LOG_DEFAULT, "[Prism Visualizer] " fmt, ##__VA_ARGS__)

@implementation PrismVisualizerView {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    CAMetalLayer *_metalLayer;
    // Diagnostic-only: renderFrame fires up to 60x/sec, so state is logged at most once every
    // ~2s (see renderFrame) rather than every call, to stay legible while still surfacing a
    // persistently-broken pipeline (blank/grey output) within a couple seconds of it starting.
    CFTimeInterval _lastDiagnosticLogTime;
    // See -startRendering's doc comment - drives renderFrame independent of Music.app's own Vpls
    // cadence, which only arrives during actual playback.
    NSTimer *_renderTimer;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self == nil) {
        return nil;
    }

    self.wantsLayer = YES;

    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];

    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = NO;

    self.layer = _metalLayer;

    // -initWithFrame: never triggers -setFrameSize: (that only fires on a *later* resize), so
    // without this the layer's drawableSize sits at {0,0} until Music happens to resize the
    // visualizer view - renderFrame silently no-ops on every pulse until then, which reads as a
    // permanently blank/grey visualizer even though everything else is working.
    [self prism_updateDrawableSizeForFrame:frameRect];

    return self;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)dealloc {
    [self stopRendering];
}

- (void)startRendering {
    if (_renderTimer != nil) {
        return;
    }
    // matches the 60Hz pulseRateInHz Music.app is asked for at registration - see
    // PrismRegisterVisualPlugin. Scheduled in the common run loop modes so it keeps firing while
    // Music.app's own UI is tracking a mouse/menu, not just the default mode.
    _renderTimer = [NSTimer timerWithTimeInterval:(1.0 / 60.0)
                                            target:self
                                          selector:@selector(renderFrame)
                                          userInfo:nil
                                           repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_renderTimer forMode:NSRunLoopCommonModes];
}

- (void)stopRendering {
    [_renderTimer invalidate];
    _renderTimer = nil;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self prism_updateDrawableSizeForFrame:NSMakeRect(0, 0, newSize.width, newSize.height)];
}

- (void)prism_updateDrawableSizeForFrame:(NSRect)frame {
    CGFloat scale = self.window.backingScaleFactor;
    if (scale <= 0) {
        scale = 2.0;
    }
    _metalLayer.contentsScale = scale;
    _metalLayer.drawableSize = CGSizeMake(frame.size.width * scale, frame.size.height * scale);
}

- (void)renderFrame {
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
        if (shouldLog) PrismLog("renderFrame: no engine set on view yet");
        return;
    }

    CGSize drawableSize = _metalLayer.drawableSize;
    size_t width = (size_t)drawableSize.width;
    size_t height = (size_t)drawableSize.height;
    if (width == 0 || height == 0) {
        if (shouldLog) {
            PrismLog("renderFrame: drawableSize is zero (%{public}g x %{public}g) - layer.bounds=%{public}@ contentsScale=%{public}g",
                      drawableSize.width, drawableSize.height, NSStringFromRect(self.bounds), _metalLayer.contentsScale);
        }
        return;
    }

    IOSurfaceRef ioSurface = [self.engine renderFrameWithWidth:width height:height];
    if (ioSurface == NULL) {
        if (shouldLog) PrismLog("renderFrame: engine returned NULL IOSurface for %{public}zux%{public}zu", width, height);
        return;
    }

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                            width:width
                                                                                           height:height
                                                                                        mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;

    id<MTLTexture> sourceTexture = [_device newTextureWithDescriptor:descriptor iosurface:ioSurface plane:0];
    if (sourceTexture == nil) {
        if (shouldLog) PrismLog("renderFrame: newTextureWithDescriptor:iosurface: returned nil");
        return;
    }

    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (drawable == nil) {
        if (shouldLog) PrismLog("renderFrame: nextDrawable returned nil (layer possibly not in a live window)");
        return;
    }

    if (shouldLog) {
        PrismLog("renderFrame: OK, presenting %{public}zux%{public}zu", width, height);
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
