// Per-preset smoke-test probe for the Phase 7 corpus scan: loads exactly one preset, feeds a
// little synthetic PCM, renders a handful of small frames, and exits 0/1. Deliberately a fresh
// process per preset (see corpus_scan.py) so a crash on one pathological preset doesn't take
// down the whole corpus run - real projectM C++ code, no sandboxing here.
//
// Build (from the Prism repo root):
//   clang++ -std=c++17 -fobjc-arc -O2 \
//     -framework Metal -framework Foundation -framework IOSurface -framework CoreFoundation \
//     -I Vendor/angle/include -I Vendor/projectm/src/api/include -I Vendor/projectm-build/include \
//     -I Prism/ProjectM/Bridge \
//     -L Vendor/angle/lib -L Vendor/projectm-build/lib \
//     -Wl,-rpath,"$PWD/Vendor/angle/lib" -Wl,-rpath,"$PWD/Vendor/projectm-build/lib" \
//     -lEGL -lGLESv2 -lprojectM-4 \
//     Prism/ProjectM/Bridge/ProjectMEGLContext.mm Prism/ProjectM/Bridge/ProjectMEngine.mm \
//     dev-notes/projectm-corpus-scan-2026-07-27/corpus_scan_probe_main.mm \
//     -o /tmp/corpus-scan-probe
//
// Then: python3 dev-notes/projectm-corpus-scan-2026-07-27/corpus_scan.py
#import "ProjectMEngine.h"
#import <Foundation/Foundation.h>

#include <cmath>
#include <cstdio>
#include <vector>

int main(int argc, char** argv)
{
    @autoreleasepool
    {
        if (argc < 2)
        {
            fprintf(stderr, "usage: corpus_scan_probe <preset.milk>\n");
            return 2;
        }
        NSString* presetPath = [NSString stringWithUTF8String:argv[1]];

        ProjectMEngine* engine = [[ProjectMEngine alloc] init];
        if (engine == nil)
        {
            fprintf(stderr, "FAIL init\n");
            return 1;
        }

        __block BOOL loadFailed = NO;
        __block std::string failureMessage;
        engine.presetLoadFailureHandler = ^(NSString* filename, NSString* message) {
            loadFailed = YES;
            failureMessage = message.UTF8String;
        };

        [engine loadPresetAtURL:[NSURL fileURLWithPath:presetPath] smoothTransition:NO];

        const size_t width = 128, height = 128;
        const int sampleRate = 44100;
        std::vector<float> pcm(512 * 2);
        bool anySurface = false;
        for (int frame = 0; frame < 5; frame++)
        {
            for (size_t i = 0; i < 512; i++)
            {
                float t = (float)(frame * 512 + i) / (float)sampleRate;
                float sample = 0.4f * sinf(2.0f * (float)M_PI * 220.0f * t);
                pcm[i * 2 + 0] = sample;
                pcm[i * 2 + 1] = sample;
            }
            [engine addInterleavedStereoPCM:pcm.data() frameCount:512];
            IOSurfaceRef surface = [engine renderFrameWithWidth:width height:height];
            if (surface != NULL)
            {
                anySurface = true;
            }
            if (loadFailed)
            {
                fprintf(stderr, "FAIL preset_switch_failed: %s\n", failureMessage.c_str());
                return 1;
            }
        }

        if (!anySurface)
        {
            fprintf(stderr, "FAIL no_surface_ever_rendered\n");
            return 1;
        }

        printf("OK\n");
        return 0;
    }
}
