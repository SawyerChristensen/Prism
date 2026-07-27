#pragma once

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

/// A single persistent projectM instance for the lifetime of the visualizer.
///
/// Unlike the previous hand-rolled Swift renderer (which constructed a whole new
/// renderer object per preset load and cross-faded between two of them), real
/// projectM performs preset transitions internally on one instance - "loading a
/// preset" is just a call on this same object, not a reconstruction.
@interface ProjectMEngine : NSObject

/// Creates the engine (EGL/ANGLE context + projectm_handle). Returns nil if the
/// underlying GL context or projectM instance couldn't be created - check the
/// system log for the specific reason (both ANGLE and projectM log via NSLog/stderr).
- (nullable instancetype)init NS_DESIGNATED_INITIALIZER;

/// Loads a preset from a local file URL. Fire-and-forget: if loading fails, the
/// currently displayed preset keeps rendering (this matches projectm_load_preset_file's
/// own behavior). Failures are reported asynchronously via -presetLoadFailureHandler.
- (void)loadPresetAtURL:(NSURL *)url smoothTransition:(BOOL)smoothTransition;

/// Called when projectM reports a preset failed to load. Runs on whatever thread
/// projectM's callback fires on (in practice, the same thread that calls
/// -renderFrameWithWidth:height:, since callbacks are invoked synchronously from
/// inside projectM's own calls) - hop to the main thread yourself if needed.
@property(nonatomic, copy, nullable) void (^presetLoadFailureHandler)(NSString *filename, NSString *message);

/// Feeds interleaved stereo PCM samples (LRLRLR..., each in [-1, 1]) into projectM's
/// internal audio buffer. Safe to call every frame with a small chunk of samples.
- (void)addInterleavedStereoPCM:(const float *)samples frameCount:(NSUInteger)frameCount;

/// Renders one frame at the given pixel size into an internal IOSurface-backed
/// target, and returns that IOSurface. The caller (Metal side) wraps it as an
/// MTLTexture via MTLDevice.makeTexture(descriptor:iosurface:plane:) - the IOSurface
/// identity is stable across frames of the same size, only its contents change, so
/// the Metal-side wrap only needs to happen once per size, not every frame.
/// Returns NULL on failure (e.g. width/height is 0).
- (nullable IOSurfaceRef)renderFrameWithWidth:(size_t)width height:(size_t)height CF_RETURNS_NOT_RETAINED;

@end

NS_ASSUME_NONNULL_END
