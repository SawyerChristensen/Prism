//
//  PrismVisualizerPlugin.mm
//  PrismVisualizerPlugin
//
//  The Music.app-facing half of the visualizer: implements the legacy iTunes/Music Visual
//  Plug-in protocol (macOS/PrismVisualizerPlugin/iTunesSDK — Apple's own SDK headers, vendored
//  verbatim, see their license header) and drives a ProjectMEngine + PrismVisualizerView with
//  it. Deliberately does NOT use AudioCaptureEngine/CoreAudioTapEngine or any of Prism.app's
//  own capture machinery: Music.app pushes waveform/spectrum data to us directly via the
//  kVisualPluginPulseMessage ('Vpls') message, so this plugin needs no Screen Recording or
//  audio-capture permission of its own — it only ever sees audio Music.app is already playing.
//
//  Entry point symbol name (iTunesPluginMainMachO) and the message-dispatch shape follow
//  Apple's original iTunes Visual SDK sample/Tech Note 2016, also mirrored by the open-source
//  projectM Music plugin (github.com/projectM-visualizer/frontend-music-plug-in), which is the
//  reference this file's structure is modeled on.
//

#import "iTunesSDK/iTunesAPI.h"
#import "iTunesSDK/iTunesVisualAPI.h"

#import "PrismVisualizerView.h"
#import "ProjectMEngine.h"

#import <Cocoa/Cocoa.h>

#define kPrismVisualPluginName CFSTR("Prism")
#define kPrismVisualPluginCreator 'prsm'

typedef struct {
    void *appCookie;
    ITAppProcPtr appProc;

    void *enginePtr; // CFBridgingRetain'd ProjectMEngine *
    void *viewPtr;   // CFBridgingRetain'd PrismVisualizerView *

    __unsafe_unretained NSView *destView; // owned by Music.app; only valid while active

    Boolean playing;
} PrismPluginData;

extern "C" OSStatus iTunesPluginMainMachO(OSType inMessage, PluginMessageInfo *inMessageInfoPtr, void *refCon)
    __attribute__((visibility("default")));

#pragma mark - projectM setup

/// The same real, plain (non-sandbox-container) folder Prism.app's own build-time bundling
/// script (Scripts/copy_bundled_presets.sh) stages its default preset pack from. Not a
/// security-scoped bookmark, not inside any app's sandbox container — the plugin can only reuse
/// Prism.app's own *configured* library folder (an arbitrary user pick, persisted via a bookmark
/// stored in Prism.app's own sandbox container) if the user re-picks it independently from
/// inside Music itself, which isn't wired up (yet) - see the "Load First Available Preset"
/// comment below for why. This path is a reasonable stand-in: it's what Prism.app itself falls
/// back to whenever no custom library has been configured.
static NSString *const kPrismDefaultPresetPackPath = @"~/Documents/PrismCollection/BestMilkdropPresetsPack/Presets";

static NSArray<NSURL *> *PrismScanForMilkPresets(NSString *directoryPath) {
    NSURL *directoryURL = [NSURL fileURLWithPath:directoryPath.stringByExpandingTildeInPath isDirectory:YES];
    NSDirectoryEnumerator<NSURL *> *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:directoryURL
                                                                       includingPropertiesForKeys:nil
                                                                                          options:0
                                                                                     errorHandler:nil];
    NSMutableArray<NSURL *> *presets = [NSMutableArray array];
    for (NSURL *url in enumerator) {
        if ([url.pathExtension.lowercaseString isEqualToString:@"milk"]) {
            [presets addObject:url];
        }
    }
    return presets;
}

/// Scanned once per plugin load (~9,800 files — not worth re-walking on every track change) and
/// cached here. `nil` means "not scanned yet"; an empty (non-nil) array means "scanned, found
/// nothing" so repeated failed lookups don't keep re-hitting the filesystem either.
static NSArray<NSURL *> *PrismCachedPresetCandidates = nil;

/// Presets aren't bundled inside the plugin itself by default — drop `.milk` files directly into
/// this plugin bundle's own Contents/Resources/Presets/ folder (readable regardless of Music
/// app's sandbox, since Music already needs read+execute access to this same bundle tree to load
/// the plugin at all) to have that take priority. Failing that, falls back to scanning
/// `kPrismDefaultPresetPackPath` on disk directly — the same real folder Prism.app's own bundled
/// pack is staged from at build time, so this is "the same presets Prism ships with," even
/// though it isn't literally reading Prism.app's own configured/bookmarked library folder (see
/// that constant's comment for why not).
static NSArray<NSURL *> *PrismPresetCandidates(void) {
    if (PrismCachedPresetCandidates != nil) {
        return PrismCachedPresetCandidates;
    }

    NSBundle *pluginBundle = [NSBundle bundleForClass:[PrismVisualizerView class]];
    NSString *bundledPresetsDir = [pluginBundle.resourcePath stringByAppendingPathComponent:@"Presets"];

    NSArray<NSURL *> *candidates = PrismScanForMilkPresets(bundledPresetsDir);
    if (candidates.count == 0) {
        candidates = PrismScanForMilkPresets(kPrismDefaultPresetPackPath);
    }
    if (candidates.count == 0) {
        NSLog(@"[Prism Visualizer] No .milk presets found in %@ or %@ — rendering blank until presets are available.",
              bundledPresetsDir, kPrismDefaultPresetPackPath);
    }

    PrismCachedPresetCandidates = candidates;
    return candidates;
}

/// Picks and loads a random preset. Called on activate (hard cut - nothing to crossfade *from*
/// yet) and again on every track change (smooth crossfade). Without any presets found, projectM
/// just renders its built-in blank/default state — no crash, just nothing interesting to look at.
static void PrismLoadRandomPreset(ProjectMEngine *engine, BOOL smoothTransition) {
    NSArray<NSURL *> *candidates = PrismPresetCandidates();
    if (candidates.count == 0) {
        return;
    }

    NSURL *presetURL = candidates[arc4random_uniform((uint32_t)candidates.count)];
    NSLog(@"[Prism Visualizer] Loading preset: %@", presetURL.path);
    [engine loadPresetAtURL:presetURL smoothTransition:smoothTransition];
}

#pragma mark - Visual lifecycle

static OSStatus PrismActivateVisual(PrismPluginData *data, VISUAL_PLATFORM_VIEW destView, OptionBits options) {
    (void)options;

    data->destView = destView;

    if (data->enginePtr == NULL) {
        ProjectMEngine *engine = [[ProjectMEngine alloc] init];
        if (engine == nil) {
            NSLog(@"[Prism Visualizer] Failed to create ProjectMEngine (EGL/projectM init failed) — see log above.");
            return memFullErr;
        }
        data->enginePtr = (void *)CFBridgingRetain(engine);
        PrismLoadRandomPreset(engine, /*smoothTransition=*/NO);
    }

    if (data->viewPtr == NULL) {
        PrismVisualizerView *view = [[PrismVisualizerView alloc] initWithFrame:destView.bounds];
        view.autoresizingMask = (NSViewWidthSizable | NSViewHeightSizable);
        view.engine = (__bridge ProjectMEngine *)data->enginePtr;
        [destView addSubview:view];
        data->viewPtr = (void *)CFBridgingRetain(view);
    }

    return noErr;
}

static OSStatus PrismDeactivateVisual(PrismPluginData *data) {
    if (data->viewPtr != NULL) {
        PrismVisualizerView *view = (__bridge PrismVisualizerView *)data->viewPtr;
        [view removeFromSuperview];
        CFBridgingRelease(data->viewPtr);
        data->viewPtr = NULL;
    }

    if (data->enginePtr != NULL) {
        CFBridgingRelease(data->enginePtr);
        data->enginePtr = NULL;
    }

    data->destView = nil;

    return noErr;
}

static OSStatus PrismResizeVisual(PrismPluginData *data) {
    if (data->viewPtr != NULL && data->destView != nil) {
        PrismVisualizerView *view = (__bridge PrismVisualizerView *)data->viewPtr;
        view.frame = data->destView.bounds;
    }
    return noErr;
}

/// Converts Music.app's 8-bit unsigned waveform samples (RenderVisualData.waveformData,
/// 0-255, centered on 128 - the same encoding the reference projectM plugin's
/// ProcessRenderData assumes) to interleaved stereo float PCM in [-1, 1] and feeds it straight
/// to ProjectMEngine. This is Music.app's own live audio, pushed to us once per pulse - no
/// capture engine, no permission prompt.
static void PrismProcessRenderData(PrismPluginData *data, const RenderVisualData *renderData) {
    if (data->enginePtr == NULL || renderData == NULL || renderData->numWaveformChannels == 0) {
        return;
    }

    ProjectMEngine *engine = (__bridge ProjectMEngine *)data->enginePtr;

    uint8_t channels = MIN(renderData->numWaveformChannels, (UInt8)kVisualMaxDataChannels);
    float interleaved[kVisualNumWaveformEntries * 2];

    for (int sample = 0; sample < kVisualNumWaveformEntries; sample++) {
        float left = (float)renderData->waveformData[0][sample] - 128.0f;
        float right = (channels > 1) ? (float)renderData->waveformData[1][sample] - 128.0f : left;
        interleaved[sample * 2] = left / 128.0f;
        interleaved[sample * 2 + 1] = right / 128.0f;
    }

    [engine addInterleavedStereoPCM:interleaved frameCount:kVisualNumWaveformEntries];
}

#pragma mark - Plugin registration

static void PrismGetVisualName(ITUniStr255 name) {
    CFIndex length = CFStringGetLength(kPrismVisualPluginName);
    name[0] = (UniChar)length;
    CFStringGetCharacters(kPrismVisualPluginName, CFRangeMake(0, length), &name[1]);
}

static OSStatus PrismVisualPluginHandler(OSType message, VisualPluginMessageInfo *messageInfo, void *refCon);

static OSStatus PrismRegisterVisualPlugin(PluginMessageInfo *initMessageInfo) {
    PlayerMessageInfo playerMessageInfo;
    memset(&playerMessageInfo.u.registerVisualPluginMessage, 0, sizeof(playerMessageInfo.u.registerVisualPluginMessage));

    PrismGetVisualName(playerMessageInfo.u.registerVisualPluginMessage.name);
    SetNumVersion(&playerMessageInfo.u.registerVisualPluginMessage.pluginVersion, 1, 0, finalStage, 0);

    playerMessageInfo.u.registerVisualPluginMessage.options = kVisualUsesOnly3D;
    playerMessageInfo.u.registerVisualPluginMessage.handler = (VisualPluginProcPtr)PrismVisualPluginHandler;
    playerMessageInfo.u.registerVisualPluginMessage.registerRefCon = 0;
    playerMessageInfo.u.registerVisualPluginMessage.creator = kPrismVisualPluginCreator;

    // Pulse rate matches Prism.app's own preference for high-refresh-rate redraw; Music.app
    // caps this around ~120Hz regardless.
    playerMessageInfo.u.registerVisualPluginMessage.pulseRateInHz = 60;
    playerMessageInfo.u.registerVisualPluginMessage.numWaveformChannels = 2;
    playerMessageInfo.u.registerVisualPluginMessage.numSpectrumChannels = 0;

    playerMessageInfo.u.registerVisualPluginMessage.minWidth = 64;
    playerMessageInfo.u.registerVisualPluginMessage.minHeight = 64;
    playerMessageInfo.u.registerVisualPluginMessage.maxWidth = 0;
    playerMessageInfo.u.registerVisualPluginMessage.maxHeight = 0;

    return PlayerRegisterVisualPlugin(initMessageInfo->u.initMessage.appCookie,
                                       initMessageInfo->u.initMessage.appProc,
                                       &playerMessageInfo);
}

#pragma mark - Message dispatch

static OSStatus PrismVisualPluginHandler(OSType message, VisualPluginMessageInfo *messageInfo, void *refCon) {
    PrismPluginData *data = (PrismPluginData *)refCon;
    OSStatus status = noErr;

    switch (message) {
        case kVisualPluginInitMessage: {
            data = (PrismPluginData *)calloc(1, sizeof(PrismPluginData));
            if (data == NULL) {
                return memFullErr;
            }
            data->appCookie = messageInfo->u.initMessage.appCookie;
            data->appProc = messageInfo->u.initMessage.appProc;
            messageInfo->u.initMessage.refCon = (void *)data;
            break;
        }

        case kVisualPluginCleanupMessage: {
            if (data != NULL) {
                PrismDeactivateVisual(data);
                free(data);
            }
            break;
        }

        case kVisualPluginEnableMessage:
        case kVisualPluginDisableMessage:
        case kVisualPluginIdleMessage:
        case kVisualPluginConfigureMessage:
        case kVisualPluginPlayMessage:
        case kVisualPluginCoverArtMessage:
        case kVisualPluginSetPositionMessage: {
            // Not used: Prism doesn't overlay track metadata/artwork in the visualizer itself.
            break;
        }

        case kVisualPluginChangeTrackMessage: {
            // Fires on every track change (including the very first track, right after Activate
            // already picked one - a second pick this soon just means song #1 sometimes gets two
            // presets back to back, harmless). Deliberately not wired to kVisualPluginPlayMessage
            // too, which also fires on resume-after-pause with no track change - that would pick
            // a new preset on every pause/resume, not just real song changes.
            if (data->enginePtr != NULL) {
                PrismLoadRandomPreset((__bridge ProjectMEngine *)data->enginePtr, /*smoothTransition=*/YES);
            }
            break;
        }

        case kVisualPluginActivateMessage: {
            status = PrismActivateVisual(data, messageInfo->u.activateMessage.view, messageInfo->u.activateMessage.options);
            break;
        }

        case kVisualPluginDeactivateMessage: {
            status = PrismDeactivateVisual(data);
            break;
        }

        case kVisualPluginWindowChangedMessage:
        case kVisualPluginFrameChangedMessage: {
            status = PrismResizeVisual(data);
            break;
        }

        case kVisualPluginPulseMessage: {
            PrismProcessRenderData(data, messageInfo->u.pulseMessage.renderData);
            if (data->viewPtr != NULL) {
                [(__bridge PrismVisualizerView *)data->viewPtr renderFrame];
            }
            break;
        }

        case kVisualPluginDrawMessage: {
            // Already drawing every pulse (matches the reference plugin's approach — pulse
            // arrives at a steadier, more frequent rate than draw invalidation would).
            break;
        }

        case kVisualPluginStopMessage: {
            data->playing = false;
            break;
        }

        default: {
            status = unimpErr;
            break;
        }
    }

    return status;
}

#pragma mark - Plugin main entry point

OSStatus iTunesPluginMainMachO(OSType message, PluginMessageInfo *messageInfo, void *refCon) {
    (void)refCon;

    switch (message) {
        case kPluginInitMessage:
            return PrismRegisterVisualPlugin(messageInfo);
        case kPluginCleanupMessage:
            return noErr;
        default:
            return unimpErr;
    }
}
