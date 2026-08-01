//
//  PrismVisualizerView.h
//  PrismVisualizerPlugin
//
//  A CAMetalLayer-backed NSView that Music.app hosts directly (added as a subview of the
//  view it hands us in Vact, same technique the reference projectM iTunes/Music plugin uses
//  for its NSOpenGLView subview — Music.app's own view isn't guaranteed to be drawable into
//  directly). Blits the IOSurface-backed texture ProjectMEngine renders into straight to the
//  layer's current drawable; no render pipeline/shader needed since both are bgra8Unorm.
//

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@class ProjectMEngine;

@interface PrismVisualizerView : NSView

@property(nonatomic, strong, nullable) ProjectMEngine *engine;

/// Feeds the engine's current frame into the layer's next drawable via a blit. Call once per
/// Vpls (pulse) message — see PrismVisualizerPlugin.mm's VisualPluginHandler.
- (void)renderFrame;

@end

NS_ASSUME_NONNULL_END
