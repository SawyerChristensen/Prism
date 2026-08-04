#import "ProjectMEngine.h"
#import "ProjectMEGLContext.h"

#include "projectM-4/projectM.h"

@interface ProjectMEngine ()
- (void)handlePresetSwitchFailedWithFilename:(const char*)filename message:(const char*)message;
- (void)provideTextureOverrideForName:(const char*)textureName intoData:(projectm_texture_load_data*)data;
@end

namespace {

void PresetSwitchFailedTrampoline(const char* presetFilename, const char* message, void* userData)
{
    ProjectMEngine* engine = (__bridge ProjectMEngine*)userData;
    [engine handlePresetSwitchFailedWithFilename:presetFilename message:message];
}

void TextureLoadTrampoline(const char* textureName, projectm_texture_load_data* data, void* userData)
{
    ProjectMEngine* engine = (__bridge ProjectMEngine*)userData;
    [engine provideTextureOverrideForName:textureName intoData:data];
}

} // namespace

/// Holds one -setTextureOverrideImage:forName:'s decoded pixels, bottom-row-first (see
/// PrismRGBADataFromImage) so they're ready to hand straight to projectm_texture_load_data as-is.
@interface PrismTextureOverride : NSObject
@property(nonatomic, strong) NSData* rgbaData;
@property(nonatomic) unsigned int width;
@property(nonatomic) unsigned int height;
@end

@implementation PrismTextureOverride
@end

namespace {

/// Decodes `image` into top-down RGBA8, then flips it to bottom-row-first - the "standard OpenGL
/// format" projectm_texture_load_data.data documents itself as expecting (callbacks.h) - since
/// CGContext (like every other 2D drawing API here) fills a buffer top-down. Returns nil if the
/// image has no CGImage representation.
NSData* PrismBottomUpRGBADataFromImage(NSImage* image, unsigned int* outWidth, unsigned int* outHeight)
{
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (cgImage == NULL)
    {
        return nil;
    }

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0)
    {
        return nil;
    }

    size_t bytesPerRow = width * 4;
    NSMutableData* topDown = [NSMutableData dataWithLength:bytesPerRow * height];

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(topDown.mutableBytes, width, height, 8, bytesPerRow,
                                                  colorSpace, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL)
    {
        return nil;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    NSMutableData* bottomUp = [NSMutableData dataWithLength:bytesPerRow * height];
    const uint8_t* src = static_cast<const uint8_t*>(topDown.bytes);
    uint8_t* dst = static_cast<uint8_t*>(bottomUp.mutableBytes);
    for (size_t row = 0; row < height; row++)
    {
        memcpy(dst + row * bytesPerRow, src + (height - 1 - row) * bytesPerRow, bytesPerRow);
    }

    *outWidth = static_cast<unsigned int>(width);
    *outHeight = static_cast<unsigned int>(height);
    return bottomUp;
}

} // namespace

@implementation ProjectMEngine {
    ProjectMEGLContext* _eglContext;
    projectm_handle _instance;
    NSMutableDictionary<NSString*, PrismTextureOverride*>* _textureOverrides;
    BOOL _textureLoadCallbackInstalled;
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

- (void)loadIdlePresetWithSmoothTransition:(BOOL)smoothTransition
{
    if (![_eglContext makeCurrent])
    {
        return;
    }
    projectm_load_preset_file(_instance, "idle://Geiss & Sperl - Feedback (projectM idle HDR mix).milk", smoothTransition);
}

- (void)loadPresetFromData:(NSString*)presetText smoothTransition:(BOOL)smoothTransition
{
    if (![_eglContext makeCurrent])
    {
        return;
    }
    projectm_load_preset_data(_instance, presetText.UTF8String, smoothTransition);
}

- (void)setTextureOverrideImage:(nullable NSImage*)image forName:(NSString*)name
{
    NSString* key = name.lowercaseString;

    if (image == nil)
    {
        [_textureOverrides removeObjectForKey:key];
        return;
    }

    unsigned int width = 0;
    unsigned int height = 0;
    NSData* rgba = PrismBottomUpRGBADataFromImage(image, &width, &height);
    if (rgba == nil)
    {
        return;
    }

    PrismTextureOverride* override = [[PrismTextureOverride alloc] init];
    override.rgbaData = rgba;
    override.width = width;
    override.height = height;

    if (_textureOverrides == nil)
    {
        _textureOverrides = [NSMutableDictionary dictionary];
    }
    _textureOverrides[key] = override;

    if (!_textureLoadCallbackInstalled)
    {
        _textureLoadCallbackInstalled = YES;
        projectm_set_texture_load_event_callback(_instance, &TextureLoadTrampoline, (__bridge void*)self);
    }
}

- (void)provideTextureOverrideForName:(const char*)textureName intoData:(projectm_texture_load_data*)data
{
    if (textureName == nullptr)
    {
        return;
    }
    NSString* key = [NSString stringWithUTF8String:textureName].lowercaseString;
    PrismTextureOverride* override = _textureOverrides[key];
    if (override == nil)
    {
        return;
    }
    data->data = static_cast<const unsigned char*>(override.rgbaData.bytes);
    data->width = override.width;
    data->height = override.height;
    data->channels = 4;
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

- (BOOL)presetTransitionActive
{
    return projectm_get_preset_transition_active(_instance);
}

- (double)presetTransitionProgress
{
    return projectm_get_preset_transition_progress(_instance);
}

- (int32_t)presetTransitionShaderIndex
{
    return projectm_get_preset_transition_shader_index(_instance);
}

- (int32_t)presetTransitionRandomSeedA
{
    int32_t values[4];
    projectm_get_preset_transition_random_values(_instance, values);
    return values[0];
}

- (int32_t)presetTransitionRandomSeedB
{
    int32_t values[4];
    projectm_get_preset_transition_random_values(_instance, values);
    return values[1];
}

- (int32_t)presetTransitionRandomSeedC
{
    int32_t values[4];
    projectm_get_preset_transition_random_values(_instance, values);
    return values[2];
}

- (int32_t)presetTransitionRandomSeedD
{
    int32_t values[4];
    projectm_get_preset_transition_random_values(_instance, values);
    return values[3];
}

@end
