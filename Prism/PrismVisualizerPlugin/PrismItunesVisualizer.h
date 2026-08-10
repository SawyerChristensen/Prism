//
//  PrismItunesVisualizer.h
//  PrismVisualizerPlugin
//
//  An MTKView that Music.app hosts directly (added as a subview of the view it hands us in
//  Vact, same technique the reference projectM iTunes/Music plugin uses for its NSOpenGLView
//  subview — Music.app's own view isn't guaranteed to be drawable into directly). Blits the
//  IOSurface-backed texture ProjectMEngine renders into straight to the view's current drawable;
//  no render pipeline/shader needed since both are bgra8Unorm. Driven by MTKView's own
//  display-link-backed draw loop (matched to the real screen's refresh rate via
//  -startRendering), exactly like ProjectMCoordinator/ProjectMMetalView drive the main app's
//  Metal view - not a hand-rolled NSTimer capped at an arbitrary rate.
//

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ProjectMEngine;

@interface PrismItunesVisualizer : MTKView

@property(nonatomic, strong, nullable) ProjectMEngine *engine;

/// Starts the display-link-driven draw loop, matched to the real screen's refresh rate. Music
/// only sends Vpls pulses while a track is actually playing, so without this, nothing would ever
/// draw a frame while paused/stopped or before the first Play - the view would just sit blank
/// even after loading the idle preset onto the engine. Idempotent - a second call while already
/// running is a no-op. See PrismVisualizerPlugin.mm's Activate/Deactivate.
- (void)startRendering;

/// Stops the draw loop started by -startRendering. Safe to call even if it was never started.
- (void)stopRendering;

@end

NS_ASSUME_NONNULL_END
