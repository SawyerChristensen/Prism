// Headless per-preset FPS benchmark. Same standalone-binary trick as
// dev-notes/projectm-corpus-scan-2026-07-27 (bypasses Xcode/the sandboxed app entirely, driving
// ProjectMEngine's offscreen IOSurface render path directly - no window, no NSApplication, no
// screen needed at all) but measures real per-frame wall-clock time at a realistic resolution
// instead of just checking load/render succeeded. That scan used a tiny 128x128 smoke-test size,
// which is deliberately too small to expose real per-pixel shader cost - this benchmark's whole
// point is that cost, so it renders at a real window-sized resolution instead.
//
// Unlike the corpus scan (one fresh process per preset, 8-way parallel - fine for a pass/fail
// check), this is one persistent process working through the corpus serially: parallel workers
// would contend for the GPU and make every preset's measured FPS artificially low, and the corpus
// scan already showed real projectM 4.2 renders the entire corpus with zero crashes/timeouts, so
// the crash-per-process isolation that justified a fresh process each time isn't buying much here.
// Resilience instead comes from flushing the output CSV after every single preset and skipping
// rows already present on startup - see run_preset_fps_benchmark.sh, which loops this binary and
// relies on that resume behavior if it ever does die mid-run.
//
// Build: see run_preset_fps_benchmark.sh (same clang++ invocation shape as the corpus scan probe).
// Usage: fps_benchmark <presetRootDir> <outputCSV> [width] [height]

#import "ProjectMEngine.h"
#import <Foundation/Foundation.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <unordered_set>
#include <vector>

using Clock = std::chrono::steady_clock;

namespace {

// Bounds on the two timed phases. Warmup absorbs first-load cost (shader compile, transition
// ramp-up) that would otherwise bias a fast preset's average down if it landed inside the measured
// window. Measurement floors at minMeasureSeconds so a handful of sub-millisecond frames on a very
// fast preset don't produce a noisy average, and ceilings at maxMeasureSeconds so a pathologically
// slow preset can't blow up the total run time. Worst case per preset is warmupMaxSeconds +
// maxMeasureSeconds (~5.5s); typical presets finish in under a second once warm.
constexpr int warmupFrames = 8;
constexpr double warmupMaxSeconds = 3.0;
constexpr int maxMeasureFrames = 60;
constexpr double minMeasureSeconds = 0.5;
constexpr double maxMeasureSeconds = 2.5;

constexpr int sampleRate = 44100;
constexpr size_t samplesPerFrame = 512;

double elapsedSeconds(Clock::time_point start)
{
    return std::chrono::duration<double>(Clock::now() - start).count();
}

// Continuous synthetic stereo signal (fixed frequency/amplitude, phase carried across calls via
// `sampleIndex`) rather than silence - some presets branch per-frame on audio level, and silence
// would let those skip work a real listening session never would.
void feedSyntheticPCM(ProjectMEngine* engine, long long& sampleIndex)
{
    std::vector<float> pcm(samplesPerFrame * 2);
    for (size_t i = 0; i < samplesPerFrame; i++)
    {
        double t = (double)sampleIndex / (double)sampleRate;
        float sample = 0.35f * sinf(2.0f * (float)M_PI * 220.0f * (float)t)
            + 0.15f * sinf(2.0f * (float)M_PI * 5000.0f * (float)t);
        pcm[i * 2 + 0] = sample;
        pcm[i * 2 + 1] = sample;
        sampleIndex++;
    }
    [engine addInterleavedStereoPCM:pcm.data() frameCount:samplesPerFrame];
}

// CSV-escapes a field that may itself contain commas/quotes (preset filenames sometimes do).
std::string csvField(const std::string& raw)
{
    if (raw.find_first_of(",\"\n") == std::string::npos)
    {
        return raw;
    }
    std::string escaped = "\"";
    for (char c : raw)
    {
        if (c == '"') escaped += '"';
        escaped += c;
    }
    escaped += '"';
    return escaped;
}

// Parses just the first field of one CSV row, undoing csvField()'s own escaping (wrapped in
// double quotes, with "" for a literal quote, whenever the raw value contains a comma/quote/
// newline). A naive find(',') split previously lived here on the assumption real preset paths
// never contain a raw comma - false: 692 of the corpus's own filenames do, which meant this never
// recognized those as already done and re-benchmarked them every single restart, forever.
std::string firstCSVField(const std::string& line)
{
    if (!line.empty() && line.front() == '"')
    {
        std::string field;
        for (size_t i = 1; i < line.size(); i++)
        {
            if (line[i] == '"')
            {
                if (i + 1 < line.size() && line[i + 1] == '"') { field += '"'; i++; continue; }
                break; // closing quote
            }
            field += line[i];
        }
        return field;
    }
    size_t comma = line.find(',');
    return comma != std::string::npos ? line.substr(0, comma) : line;
}

std::unordered_set<std::string> loadAlreadyDoneRelativePaths(const std::string& csvPath)
{
    std::unordered_set<std::string> done;
    FILE* f = fopen(csvPath.c_str(), "r");
    if (f == nullptr)
    {
        return done;
    }
    char line[4096];
    bool first = true;
    while (fgets(line, sizeof(line), f) != nullptr)
    {
        if (first) { first = false; continue; } // header
        done.insert(firstCSVField(std::string(line)));
    }
    fclose(f);
    return done;
}

} // namespace

int main(int argc, char** argv)
{
    @autoreleasepool
    {
        if (argc < 3)
        {
            fprintf(stderr, "usage: fps_benchmark <presetRootDir> <outputCSV> [width] [height]\n");
            return 2;
        }
        NSString* rootPath = [NSString stringWithUTF8String:argv[1]];
        std::string outputCSV = argv[2];
        size_t width = argc > 3 ? (size_t)atoi(argv[3]) : 1280;
        size_t height = argc > 4 ? (size_t)atoi(argv[4]) : 720;

        NSURL* rootURL = [NSURL fileURLWithPath:rootPath isDirectory:YES];
        NSFileManager* fm = [NSFileManager defaultManager];
        NSDirectoryEnumerator<NSURL*>* enumerator = [fm
            enumeratorAtURL:rootURL
            includingPropertiesForKeys:@[]
            options:NSDirectoryEnumerationSkipsHiddenFiles
            errorHandler:nil];
        NSMutableArray<NSURL*>* presetURLs = [NSMutableArray array];
        for (NSURL* url in enumerator)
        {
            if ([url.pathExtension.lowercaseString isEqualToString:@"milk"])
            {
                [presetURLs addObject:url];
            }
        }
        [presetURLs sortUsingComparator:^NSComparisonResult(NSURL* a, NSURL* b) {
            return [a.path compare:b.path];
        }];

        size_t rootPathLength = rootPath.length;
        std::unordered_set<std::string> alreadyDone = loadAlreadyDoneRelativePaths(outputCSV);

        bool csvExists = [fm fileExistsAtPath:[NSString stringWithUTF8String:outputCSV.c_str()]];
        FILE* csv = fopen(outputCSV.c_str(), "a");
        if (csv == nullptr)
        {
            fprintf(stderr, "error: couldn't open %s for writing\n", outputCSV.c_str());
            return 1;
        }
        if (!csvExists)
        {
            fprintf(csv, "relativePath,filename,status,fps,frames,elapsedSeconds,detail\n");
            fflush(csv);
        }

        ProjectMEngine* engine = [[ProjectMEngine alloc] init];
        if (engine == nil)
        {
            fprintf(stderr, "error: ProjectMEngine init failed\n");
            return 1;
        }

        __block BOOL loadFailed = NO;
        __block std::string failureMessage;
        engine.presetLoadFailureHandler = ^(NSString* filename, NSString* message) {
            loadFailed = YES;
            failureMessage = message.UTF8String;
        };

        long long sampleIndex = 0;
        size_t total = presetURLs.count;
        size_t skipped = 0, processed = 0;
        Clock::time_point runStart = Clock::now();

        for (NSURL* presetURL in presetURLs)
        {
            NSString* fullPath = presetURL.path;
            std::string relativePath = [fullPath substringFromIndex:rootPathLength].UTF8String;
            if (!relativePath.empty() && relativePath.front() == '/')
            {
                relativePath.erase(0, 1);
            }
            std::string filename = presetURL.lastPathComponent.UTF8String;

            if (alreadyDone.count(relativePath) > 0)
            {
                skipped++;
                continue;
            }

            loadFailed = NO;
            failureMessage.clear();
            [engine loadPresetAtURL:presetURL smoothTransition:NO];

            // Warmup: absorb first-load shader compile / transition ramp-up before starting the
            // real timer. Time-bounded, not just frame-count-bounded, so a preset slow enough that
            // even its warmup frames take a while can't stall the whole run indefinitely.
            Clock::time_point warmupStart = Clock::now();
            bool sawSurface = false;
            for (int i = 0; i < warmupFrames && elapsedSeconds(warmupStart) < warmupMaxSeconds; i++)
            {
                feedSyntheticPCM(engine, sampleIndex);
                IOSurfaceRef surface = [engine renderFrameWithWidth:width height:height];
                if (surface != NULL) sawSurface = true;
                if (loadFailed) break;
            }

            if (loadFailed)
            {
                fprintf(csv, "%s,%s,fail,0,0,0,%s\n",
                    csvField(relativePath).c_str(), csvField(filename).c_str(),
                    csvField("preset_switch_failed: " + failureMessage).c_str());
                fflush(csv);
                processed++;
                continue;
            }
            if (!sawSurface)
            {
                fprintf(csv, "%s,%s,fail,0,0,0,%s\n",
                    csvField(relativePath).c_str(), csvField(filename).c_str(),
                    csvField("no_surface_during_warmup").c_str());
                fflush(csv);
                processed++;
                continue;
            }

            // Measured window: stop once both the frame-count and minimum-duration floors are
            // cleared, or the hard time ceiling is hit, whichever comes first.
            int frames = 0;
            Clock::time_point measureStart = Clock::now();
            double measured = 0;
            bool failedMidMeasure = false;
            while (true)
            {
                measured = elapsedSeconds(measureStart);
                if (frames >= maxMeasureFrames && measured >= minMeasureSeconds) break;
                if (measured >= maxMeasureSeconds) break;

                feedSyntheticPCM(engine, sampleIndex);
                IOSurfaceRef surface = [engine renderFrameWithWidth:width height:height];
                if (loadFailed || surface == NULL)
                {
                    failedMidMeasure = true;
                    break;
                }
                frames++;
            }
            measured = elapsedSeconds(measureStart);

            if (failedMidMeasure || frames == 0)
            {
                std::string detail = loadFailed ? ("preset_switch_failed: " + failureMessage) : "render_failed_mid_measurement";
                fprintf(csv, "%s,%s,fail,0,%d,%.3f,%s\n",
                    csvField(relativePath).c_str(), csvField(filename).c_str(), frames, measured,
                    csvField(detail).c_str());
                fflush(csv);
                processed++;
                continue;
            }

            double fps = frames / measured;
            fprintf(csv, "%s,%s,ok,%.2f,%d,%.3f,\n",
                csvField(relativePath).c_str(), csvField(filename).c_str(), fps, frames, measured);
            fflush(csv);
            processed++;

            if (processed % 10 == 0 || processed == total - skipped)
            {
                double elapsedRun = elapsedSeconds(runStart);
                double rate = processed / (elapsedRun > 0 ? elapsedRun : 1);
                double remaining = total - skipped - processed;
                double etaMinutes = rate > 0 ? remaining / rate / 60.0 : 0;
                fprintf(stderr, "[%zu/%zu, %zu skipped] %s: %.1f fps (%.1f/s, ETA %.1fm)\n",
                    processed, total - skipped, skipped, filename.c_str(), fps, rate, etaMinutes);
            }
        }

        fclose(csv);
        fprintf(stderr, "done: %zu processed, %zu skipped (already in %s), %zu total\n",
            processed, skipped, outputCSV.c_str(), total);
        return 0;
    }
}
