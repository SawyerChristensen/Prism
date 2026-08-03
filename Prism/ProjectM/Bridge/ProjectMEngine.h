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
- (void)loadPresetAtURL:(NSURL *)url smoothTransition:(BOOL)smoothTransition NS_SWIFT_NAME(loadPreset(at:smoothTransition:));

/// Called when projectM reports a preset failed to load. Runs on whatever thread
/// projectM's callback fires on (in practice, the same thread that calls
/// -renderFrameWithWidth:height:, since callbacks are invoked synchronously from
/// inside projectM's own calls) - hop to the main thread yourself if needed.
@property(nonatomic, copy, nullable) void (^presetLoadFailureHandler)(NSString *filename, NSString *message);

/// Feeds interleaved stereo PCM samples (LRLRLR..., each in [-1, 1]) into projectM's
/// internal audio buffer. Safe to call every frame with a small chunk of samples.
- (void)addInterleavedStereoPCM:(const float *)samples frameCount:(NSUInteger)frameCount NS_SWIFT_NAME(addInterleavedStereoPCM(_:frameCount:));

/// Renders one frame at the given pixel size into an internal IOSurface-backed
/// target, and returns that IOSurface. The caller (Metal side) wraps it as an
/// MTLTexture via MTLDevice.makeTexture(descriptor:iosurface:plane:) - the IOSurface
/// identity is stable across frames of the same size, only its contents change, so
/// the Metal-side wrap only needs to happen once per size, not every frame.
/// Returns NULL on failure (e.g. width/height is 0).
- (nullable IOSurfaceRef)renderFrameWithWidth:(size_t)width height:(size_t)height CF_RETURNS_NOT_RETAINED NS_SWIFT_NAME(renderFrame(width:height:));

/// Tells projectM the real current output frame rate, so presets whose per-frame code
/// normalizes against the `fps` builtin (e.g. `x = x + rate/fps`) animate at their
/// authored speed instead of speeding up on high-refresh displays. Safe to call every
/// frame; projectM just stores the value. See MilkdropPreset per-frame `fps`/`frame`
/// builtins (PerFrameContext.cpp) - this only corrects presets that use `fps`, not ones
/// that key off the raw `frame` counter.
- (void)setTargetFPS:(int32_t)fps NS_SWIFT_NAME(setTargetFPS(_:));

/// Multiplies the built-in warp-noise animation's time source (on top of whatever the
/// preset's own `fWarpAnimSpeed` already is) - see PRISM_LOCAL_PATCH in
/// PerPixelMesh.cpp. 1.0 = unmodified. Safe to call every frame.
- (void)setWarpAnimSpeedMultiplier:(float)multiplier NS_SWIFT_NAME(setWarpAnimSpeedMultiplier(_:));

/// Whether projectM is currently blending the previous preset's render into the new one
/// (PRISM_LOCAL_PATCH - see Prism/Vendor/projectm-VERSION.md's "exposed preset-transition state"
/// entry). That blend happens entirely inside projectM's own render pass, so this - and the four
/// properties below - are the only way to observe it from outside: ProjectMCoordinator polls these
/// every frame to drive its own album-art overlay through the *exact same* transition (not just
/// the same kind of transition) in lockstep with whatever's actually happening to the preset.
@property(nonatomic, readonly) BOOL presetTransitionActive;

/// The current transition's linear progress, 0...1. 0 (not `presetTransitionActive`) when no
/// transition is running.
@property(nonatomic, readonly) double presetTransitionProgress;

/// Which of projectM's 6 built-in transition shaders this transition is using - see
/// Renderer::TransitionShaderManager's construction order (Vendor/projectm/src/libprojectM/
/// Renderer/TransitionShaderManager.cpp): 0 Circle, 1 Plasma, 2 SimpleBlend, 3 Sweep, 4 Warp,
/// 5 ZoomBlur. -1 when no transition is running.
@property(nonatomic, readonly) int32_t presetTransitionShaderIndex;

/// The current transition's four per-transition random seed values (each built-in transition
/// shader reads these as `iRandStatic` to pick e.g. a random wipe angle or blend width - see
/// Renderer/TransitionShaders/TransitionShaderHeaderGlsl330.frag), held fixed for its whole
/// duration. All 0 when no transition is running.
@property(nonatomic, readonly) int32_t presetTransitionRandomSeedA;
@property(nonatomic, readonly) int32_t presetTransitionRandomSeedB;
@property(nonatomic, readonly) int32_t presetTransitionRandomSeedC;
@property(nonatomic, readonly) int32_t presetTransitionRandomSeedD;

@end

NS_ASSUME_NONNULL_END
