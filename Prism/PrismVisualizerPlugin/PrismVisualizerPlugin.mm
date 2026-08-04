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
#import <os/log.h>

// Diagnostic-only, temporary: plain NSLog's "%@"/"%s" arguments get privacy-redacted to
// "<private>" in the unified log by default (confirmed empirically - every diagnostic line came
// back as "<private>" during the "blank grey screen" investigation, useless for figuring out what
// Music.app/VisualizerService was actually sending). os_log with an explicit {public} modifier
// bypasses that redaction. See the "stuck on first preset" / "blank grey" investigation.
#define PrismLog(fmt, ...) os_log(OS_LOG_DEFAULT, "[Prism Visualizer] " fmt, ##__VA_ARGS__)

#define kPrismVisualPluginName CFSTR("Prism")
#define kPrismVisualPluginCreator 'prsm'

typedef struct {
    void *appCookie;
    ITAppProcPtr appProc;

    void *enginePtr; // CFBridgingRetain'd ProjectMEngine *
    void *viewPtr;   // CFBridgingRetain'd PrismVisualizerView *

    __unsafe_unretained NSView *destView; // owned by Music.app; only valid while active

    // CFBridgingRetain'd NSString* - identifies the track last seen via kVisualPluginPlayMessage
    // (see PrismTrackIdentity), so a genuine track change can be told apart from a resume-after-
    // pause that also sends Play with no track change. NULL until the first Play message arrives.
    // See the kVisualPluginPlayMessage case's own comment for why this exists instead of using
    // kVisualPluginChangeTrackMessage ('Ctrk') directly.
    void *lastTrackIdentity;
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
        PrismLog("No .milk presets found in %{public}@ or %{public}@ — rendering blank until presets are available.",
                  bundledPresetsDir, kPrismDefaultPresetPackPath);
    } else {
        PrismLog("Found %{public}lu candidate presets (bundled dir: %{public}@)",
                  (unsigned long)candidates.count, bundledPresetsDir);
    }

    PrismCachedPresetCandidates = candidates;
    return candidates;
}

#pragma mark - Track identity (see kVisualPluginPlayMessage's own comment)

/// `ITUniStr255` is a Pascal-style string: `str[0]` holds the length, `str[1...]` the characters
/// (same convention `PrismGetVisualName` below already uses the other direction). Returns `nil`
/// for a zero-length string, so callers can tell "field present but empty" apart from "field
/// absent" without an extra length check of their own.
static NSString *PrismStringFromITUniStr255(const UniChar *str) {
    UniChar length = str[0];
    if (length == 0) {
        return nil;
    }
    return [NSString stringWithCharacters:&str[1] length:length];
}

/// A string identifying *this specific track*, built from whichever of name/artist/album
/// `ITTrackInfo.validFields` actually reports as present - not just `name` alone, since two
/// different tracks sharing a bare title (e.g. two different artists' "Intro") would otherwise
/// look identical. `nil` only when `trackInfo` itself is NULL or reports none of the three fields
/// valid - genuinely no identity to compare.
static NSString *PrismTrackIdentity(const ITTrackInfo *trackInfo) {
    if (trackInfo == NULL) {
        return nil;
    }
    NSString *name = (trackInfo->validFields & kITTINameFieldMask) ? PrismStringFromITUniStr255(trackInfo->name) : nil;
    NSString *artist = (trackInfo->validFields & kITTIArtistFieldMask) ? PrismStringFromITUniStr255(trackInfo->artist) : nil;
    NSString *album = (trackInfo->validFields & kITTIAlbumFieldMask) ? PrismStringFromITUniStr255(trackInfo->album) : nil;
    if (name == nil && artist == nil && album == nil) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@|%@|%@", name ?: @"", artist ?: @"", album ?: @""];
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
    PrismLog("Loading preset (smooth=%{public}d): %{public}@", smoothTransition, presetURL.path);
    [engine loadPresetAtURL:presetURL smoothTransition:smoothTransition];
}

/// Advances to a new random preset iff `trackInfo` identifies a genuinely different track than
/// `data->lastTrackIdentity` (see `PrismTrackIdentity`) - called from both
/// `kVisualPluginPlayMessage` and `kVisualPluginChangeTrackMessage`, sharing this one de-dup path
/// so getting both for the same track change (however unlikely) still only loads one preset.
///
/// This exists because `kVisualPluginChangeTrackMessage` ('Ctrk') - which this plugin originally
/// (and, per Apple's own iTunes Visual SDK sample/Tech Note 2016 and the open-source projectM
/// Music plugin this file is modeled on, "correctly") relied on exclusively - was empirically
/// confirmed to never arrive at all from the modern Music.app/VisualizerService host on macOS:
/// logging every message this plugin receives (excluding the high-frequency Pulse/Draw ones) over
/// a full session, including a real track skip, showed only 'null' (Idle), 'Vfrm' (resize),
/// 'vstp' (Stop) and 'Vply' (Play) - Stop immediately followed by Play is exactly what a real
/// track skip looks like in this host, with no 'Ctrk' anywhere. Comparing track identity across
/// Play messages (rather than just reloading unconditionally on every Play) is what keeps a
/// resume-after-pause - which also sends Play with no track change - from picking a new preset
/// every single time, the exact failure mode the original ChangeTrack-only design was trying to
/// avoid by not wiring this to Play in the first place.
static void PrismHandlePossibleTrackChange(PrismPluginData *data, const ITTrackInfo *trackInfo) {
    if (data == NULL || data->enginePtr == NULL) {
        return;
    }
    NSString *identity = PrismTrackIdentity(trackInfo);
    if (identity == nil) {
        return;
    }
    NSString *lastIdentity = (__bridge NSString *)data->lastTrackIdentity;
    if ([identity isEqualToString:lastIdentity]) {
        return;
    }
    if (data->lastTrackIdentity != NULL) {
        CFBridgingRelease(data->lastTrackIdentity);
    }
    data->lastTrackIdentity = (void *)CFBridgingRetain(identity);
    PrismLog("Track identity changed to %{public}@ - advancing preset", identity);
    PrismLoadRandomPreset((__bridge ProjectMEngine *)data->enginePtr, /*smoothTransition=*/YES);
}

#pragma mark - Visual lifecycle

static OSStatus PrismActivateVisual(PrismPluginData *data, VISUAL_PLATFORM_VIEW destView, OptionBits options) {
    (void)options;

    PrismLog("Activate: destView=%{public}@ bounds=%{public}@ window=%{public}@",
              destView, NSStringFromRect(destView.bounds), destView.window);

    data->destView = destView;

    if (data->enginePtr == NULL) {
        ProjectMEngine *engine = [[ProjectMEngine alloc] init];
        if (engine == nil) {
            PrismLog("Failed to create ProjectMEngine (EGL/projectM init failed) — see log above.");
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
        PrismLog("Created PrismVisualizerView with frame=%{public}@, added to destView (subviews now %{public}lu)",
                  NSStringFromRect(view.frame), (unsigned long)destView.subviews.count);
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

    // A fresh engine on the next Activate has no preset history of its own - dropping this means
    // that engine's first Play message always advances (matching Activate's own hard-cut load),
    // rather than potentially comparing against a track identity from a now-destroyed engine.
    if (data->lastTrackIdentity != NULL) {
        CFBridgingRelease(data->lastTrackIdentity);
        data->lastTrackIdentity = NULL;
    }

    data->destView = nil;

    return noErr;
}

static OSStatus PrismResizeVisual(PrismPluginData *data) {
    if (data->viewPtr != NULL && data->destView != nil) {
        PrismVisualizerView *view = (__bridge PrismVisualizerView *)data->viewPtr;
        view.frame = data->destView.bounds;
        PrismLog("Resize: destView.bounds=%{public}@", NSStringFromRect(data->destView.bounds));
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

/// Diagnostic-only: renders an OSType message code back into its 4-char literal (e.g. 'Vpls') so
/// log lines read the same as the kVisualPlugin*Message names in iTunesVisualAPI.h, instead of a
/// bare decimal. Temporary aid for confirming which messages Music.app actually sends this plugin
/// at runtime (see the "stuck on first preset" investigation) - safe to leave in, cheap, and only
/// invoked at most once per message excluding the high-frequency Pulse/Draw ones (see below).
static NSString *PrismFourCharCodeString(OSType code) {
    char chars[5] = {
        (char)((code >> 24) & 0xFF), (char)((code >> 16) & 0xFF),
        (char)((code >> 8) & 0xFF), (char)(code & 0xFF), 0
    };
    return [NSString stringWithUTF8String:chars];
}

static OSStatus PrismVisualPluginHandler(OSType message, VisualPluginMessageInfo *messageInfo, void *refCon) {
    PrismPluginData *data = (PrismPluginData *)refCon;
    OSStatus status = noErr;

    // Every message except the two that fire dozens of times a second (Pulse at up to 60Hz, Draw
    // alongside it) - logging those would drown out everything else. This is what tells us
    // definitively whether kVisualPluginChangeTrackMessage ('chtr') is actually arriving from
    // Music.app at all, and in what order relative to Activate/Play, rather than guessing.
    if (message != kVisualPluginPulseMessage && message != kVisualPluginDrawMessage) {
        PrismLog("Message: '%{public}@' (engine=%{public}s)", PrismFourCharCodeString(message),
                  (data != NULL && data->enginePtr != NULL) ? "alive" : "nil");
    }

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
        case kVisualPluginCoverArtMessage:
        case kVisualPluginSetPositionMessage: {
            // Not used: Prism doesn't overlay track metadata/artwork in the visualizer itself.
            break;
        }

        case kVisualPluginPlayMessage: {
            // The actual, empirically-confirmed source of track-change detection in this host -
            // see PrismHandlePossibleTrackChange's own doc comment for why
            // kVisualPluginChangeTrackMessage alone (below) isn't enough. Track-identity
            // comparison inside that function is what keeps a resume-after-pause (which also
            // sends Play with no track change) from picking a new preset every time.
            PrismHandlePossibleTrackChange(data, messageInfo->u.playMessage.trackInfo);
            break;
        }

        case kVisualPluginChangeTrackMessage: {
            // Kept as a harmless secondary path in case some Music/iTunes version does send this
            // after all - PrismHandlePossibleTrackChange's own de-dup (by track identity) means
            // this can never double-advance for a track kVisualPluginPlayMessage already handled.
            PrismHandlePossibleTrackChange(data, messageInfo->u.changeTrackMessage.trackInfo);
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
            // Not used: no playback-state bookkeeping needed here - track-change detection reads
            // trackInfo directly off kVisualPluginPlayMessage (see PrismHandlePossibleTrackChange).
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
