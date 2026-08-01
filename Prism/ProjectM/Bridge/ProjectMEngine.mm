#import "ProjectMEngine.h"
#import "ProjectMEGLContext.h"

#include "projectM-4/projectM.h"

@interface ProjectMEngine ()
- (void)handlePresetSwitchFailedWithFilename:(const char*)filename message:(const char*)message;
@end

namespace {

void PresetSwitchFailedTrampoline(const char* presetFilename, const char* message, void* userData)
{
    ProjectMEngine* engine = (__bridge ProjectMEngine*)userData;
    [engine handlePresetSwitchFailedWithFilename:presetFilename message:message];
}

} // namespace

@implementation ProjectMEngine {
    ProjectMEGLContext* _eglContext;
    projectm_handle _instance;
}

- (nullable instancetype)init
{
    self = [super init];
    if (self == nil)
    {
        return nil;
    }

    _eglContext = [[ProjectMEGLContext alloc] init];
    if (_eglContext == nil)
    {
        return nil;
    }
    if (![_eglContext makeCurrent])
    {
        return nil;
    }

    _instance = projectm_create_with_opengl_load_proc(
        reinterpret_cast<projectm_load_proc>([_eglContext loadProcFunctionPointer]), nullptr);
    if (_instance == nullptr)
    {
        return nil;
    }

    projectm_set_preset_switch_failed_event_callback(_instance, &PresetSwitchFailedTrampoline,
                                                      (__bridge void*)self);

    return self;
}

- (void)dealloc
{
    if (_instance != nullptr)
    {
        [_eglContext makeCurrent];
        projectm_destroy(_instance);
        _instance = nullptr;
    }
}

- (void)handlePresetSwitchFailedWithFilename:(const char*)filename message:(const char*)message
{
    if (self.presetLoadFailureHandler == nil)
    {
        return;
    }
    NSString* filenameString = filename != nullptr ? [NSString stringWithUTF8String:filename] : @"";
    NSString* messageString = message != nullptr ? [NSString stringWithUTF8String:message] : @"";
    self.presetLoadFailureHandler(filenameString, messageString);
}

- (void)loadPresetAtURL:(NSURL*)url smoothTransition:(BOOL)smoothTransition
{
    if (![_eglContext makeCurrent])
    {
        return;
    }
    projectm_load_preset_file(_instance, url.fileSystemRepresentation, smoothTransition);
}

- (void)addInterleavedStereoPCM:(const float*)samples frameCount:(NSUInteger)frameCount
{
    if (![_eglContext makeCurrent])
    {
        return;
    }
    projectm_pcm_add_float(_instance, samples, (unsigned int)frameCount, PROJECTM_STEREO);
}

- (nullable IOSurfaceRef)renderFrameWithWidth:(size_t)width height:(size_t)height
{
    if (![_eglContext makeCurrent])
    {
        return NULL;
    }

    uint32_t fbo = [_eglContext framebufferForWidth:width height:height];
    if (fbo == 0)
    {
        return NULL;
    }

    projectm_set_window_size(_instance, width, height);
    projectm_opengl_render_frame_fbo(_instance, fbo);
    [_eglContext finish];

    return _eglContext.currentIOSurface;
}

- (void)setTargetFPS:(int32_t)fps
{
    projectm_set_fps(_instance, fps);
}

- (void)setWarpAnimSpeedMultiplier:(float)multiplier
{
    projectm_set_warp_anim_speed_multiplier(_instance, multiplier);
}

@end
