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

/// Starts an internal timer that calls -renderFrame on its own, independent of Music.app's Vpls
/// (pulse) messages. Music only sends those while a track is actually playing, so without this,
/// renderFrame was never called at all while paused/stopped or before the first Play - the layer
/// just sat on whatever NSView draws by default (a blank/grey view), even after loading the idle
/// preset onto the engine, since nothing ever asked it to actually draw a frame. Idempotent - a
/// second call while already running is a no-op. See PrismVisualizerPlugin.mm's Activate/
/// Deactivate.
- (void)startRendering;

/// Stops the timer started by -startRendering. Safe to call even if it was never started.
- (void)stopRendering;

@end

NS_ASSUME_NONNULL_END
