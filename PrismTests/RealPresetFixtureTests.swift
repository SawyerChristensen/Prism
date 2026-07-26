//
//  RealPresetFixtureTests.swift
//  PrismTests
//
//  Canary tests against real, byte-for-byte-unmodified `.milk` files (see Fixtures/) instead of
//  Swift string literals. This is the gap that let the CRLF line-ending bug (MilkdropPresetFile
//  splitting on the Character "\n", which never matches inside a real Windows-authored preset's
//  "\r\n") through undetected: every other test in this target builds its input from a `"""`
//  triple-quoted literal, which always normalizes to plain "\n" regardless of this source file's
//  own line endings, even when the literal's *text* was transcribed from a real preset. A `"""`
//  literal can never reproduce a real file's raw on-disk bytes — only an actual file on disk can.
//
//  If a change to MilkdropPresetFile ever silently breaks real-world parsing again (a new
//  encoding assumption, a line-ending regression, a key-matching change that's correct for the
//  synthetic fixtures above but wrong for real files), these are what would actually catch it.
//

import Foundation
import Testing
@testable import Prism

/// `Bundle(for:)` needs a class defined in this bundle to resolve to PrismTests.xctest's bundle,
/// not the host app's.
private final class FixtureBundleMarker {}

struct RealPresetFixtureTests {
    private static var fixturesBundle: Bundle { Bundle(for: FixtureBundleMarker.self) }

    private static func fixtureURL(_ name: String) throws -> URL {
        guard let url = fixturesBundle.url(forResource: name, withExtension: "milk") else {
            throw TestFailure("Fixture \(name).milk not found in test bundle — check its target membership.")
        }
        return url
    }

    struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Fails loudly (rather than skip) if a fixture is missing, so a target-membership mistake
    /// shows up as a red test, not a silently-vacuous pass.
    @Test func fixturesAreActuallyPresentInTheTestBundle() throws {
        _ = try Self.fixtureURL("RealPreset1_ORBEtherealPlain")
        _ = try Self.fixtureURL("RealPreset2_ColorfulMarble")
    }

    @Test func realPresetWithPerPixelAndShaderCodeParsesEverySection() throws {
        // "ORB - Ethereal Plain" — chosen for breadth: nWaveMode, per_frame, per_pixel, warp_N,
        // comp_N, and enabled shapes are all populated in this one real file. Expected values
        // confirmed by direct inspection of the file's own content, not guessed.
        let url = try Self.fixtureURL("RealPreset1_ORBEtherealPlain")
        let file = try MilkdropPresetFile(contentsOf: url)
        #expect(file.waveMode == 7)
        #expect(file.perFrameProgram.contains("basstime"))
        #expect(!file.perPixelProgram.isEmpty)
        #expect(!file.warpShaderSource.isEmpty)
        #expect(!file.compositeShaderSource.isEmpty)
        #expect(file.shapes.filter(\.enabled).count == 3)
        // All 4 wavecode_N slots are enabled in this file; slot 0 is spectrum-mode with a
        // multi-line per_point program (`v = sample; ... x = v; y = 0.45 - value2*0.1;`).
        #expect(file.customWaves.filter(\.enabled).count == 4)
        #expect(file.customWaves[0].spectrum == true)
        #expect(file.customWaves[0].perPointProgram.contains("value2*0.1"))
    }

    @Test func realPresetWithPlainPerFrameOnlyParsesCorrectly() throws {
        // "cope + flexi - colorful marble (ghost mix)" — the other common shape: per_frame + a
        // shader, but no per_pixel code and only one enabled shape. Covers the "not every real
        // preset uses every feature" case the first fixture doesn't.
        let url = try Self.fixtureURL("RealPreset2_ColorfulMarble")
        let file = try MilkdropPresetFile(contentsOf: url)
        #expect(file.waveMode == 0)
        #expect(!file.perFrameProgram.isEmpty)
        #expect(file.perPixelProgram.isEmpty)
        #expect(!file.warpShaderSource.isEmpty)
        #expect(!file.compositeShaderSource.isEmpty)
        #expect(file.shapes.filter(\.enabled).count == 1)
    }

    /// The full pipeline exactly as ContentView's file importer drives it — parse, then feed
    /// straight through MilkdropVisualizerModel, the same call path a real "open a preset" does.
    @Test func realPresetLoadsThroughTheFullVisualizerModelPipeline() throws {
        let url = try Self.fixtureURL("RealPreset1_ORBEtherealPlain")
        let model = MilkdropVisualizerModel()
        model.loadPreset(from: url)
        #expect(model.presetLoadError == nil)
        #expect(model.mode == MilkdropWaveMode(presetWaveMode: 7))
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        // A preset this size with real per_frame code populating zoom/rot should not leave
        // warpParams sitting at the untouched-preset neutral defaults.
        let touchedSomething = model.warpParams.zoom != 1.0 || model.warpParams.rot != 0.0
            || model.warpParams.warpAmount != 1.0 || model.warpParams.decay != 0.98
        #expect(touchedSomething)
    }
}
