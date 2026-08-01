//
//  PrismVisualizerView.mm
//  PrismVisualizerPlugin
//

#import "PrismVisualizerView.h"
#import "ProjectMEngine.h"
#import <QuartzCore/QuartzCore.h>

@implementation PrismVisualizerView {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    CAMetalLayer *_metalLayer;
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
    if (self.engine == nil) {
        return;
    }

    CGSize drawableSize = _metalLayer.drawableSize;
    size_t width = (size_t)drawableSize.width;
    size_t height = (size_t)drawableSize.height;
    if (width == 0 || height == 0) {
        return;
    }

    IOSurfaceRef ioSurface = [self.engine renderFrameWithWidth:width height:height];
    if (ioSurface == NULL) {
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
        return;
    }

    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (drawable == nil) {
        return;
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
