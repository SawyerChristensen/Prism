//
//  MilkdropVisualizerModelTests.swift
//  PrismTests
//
//  Coverage for MilkdropVisualizerModel's warpParams — specifically the two things easy to get
//  wrong when wiring a persistent per-frame variable dict to a struct read every frame by the
//  renderer: (1) static preset constants with no per-frame code touching them still need to reach
//  warpParams (see updatePresetPerFrame's restructuring away from its old early-return), and (2) a
//  per-frame script's cumulative writes (`rot=rot+0.1;`) need to actually accumulate across calls.
//

import Foundation
import Testing
@testable import Prism

struct MilkdropVisualizerModelTests {

    /// Writes `text` to a temp `.milk` file and returns its URL — MilkdropVisualizerModel only
    /// loads from a URL (it parses via MilkdropPresetFile.init(contentsOf:)), so this is the
    /// closest thing to a text-based fixture available for it.
    private func presetFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".milk")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func noPresetLoadedLeavesWarpParamsAtNeutralDefaults() {
        let model = MilkdropVisualizerModel()
        model.updatePresetPerFrame(time: 1, fps: 60, frame: 60, energy: MilkdropBandEnergy())
        #expect(model.warpParams.zoom == 1.0)
        #expect(model.warpParams.rot == 0.0)
        #expect(model.warpParams.decay == 0.98)
    }

    @Test func staticZoomConstantReachesWarpParamsWithNoPerFrameCodeAtAll() throws {
        // The regression case: a preset that sets `zoom` as a plain top-level constant and never
        // touches it again from per-frame code. Before restructuring updatePresetPerFrame's
        // early-return, this value would never reach warpParams.
        let model = MilkdropVisualizerModel()
        let url = try presetFile("[preset00]\nzoom=1.5\nrot=0.3\n")
        model.loadPreset(from: url)
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(model.warpParams.zoom == 1.5)
        #expect(model.warpParams.rot == 0.3)
    }

    @Test func perFrameScriptAccumulatesRotationAcrossFrames() throws {
        let model = MilkdropVisualizerModel()
        let url = try presetFile("[preset00]\nper_frame_1=rot=rot+0.1;\n")
        model.loadPreset(from: url)
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(abs(model.warpParams.rot - 0.1) < 0.0001)
        model.updatePresetPerFrame(time: 1.0 / 60, fps: 60, frame: 2, energy: MilkdropBandEnergy())
        #expect(abs(model.warpParams.rot - 0.2) < 0.0001)
    }

    @Test func audioReactiveZoomScriptReadsBandEnergy() throws {
        let model = MilkdropVisualizerModel()
        let url = try presetFile("[preset00]\nper_frame_1=zoom=1.0+0.1*bass;\n")
        model.loadPreset(from: url)
        let energy = MilkdropBandEnergy(bass: 2, mid: 1, treb: 1, bassAtt: 1, midAtt: 1, trebAtt: 1)
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: energy)
        #expect(abs(model.warpParams.zoom - 1.2) < 0.0001)
    }

    @Test func loadingANewPresetResetsWarpParamsRatherThanLeakingThePreviousOnesState() throws {
        let model = MilkdropVisualizerModel()
        let cumulative = try presetFile("[preset00]\nper_frame_1=zoom=zoom+0.5;\n")
        model.loadPreset(from: cumulative)
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(abs(model.warpParams.zoom - 1.5) < 0.0001)

        let plain = try presetFile("[preset00]\nzoom=1.0\n")
        model.loadPreset(from: plain)
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(model.warpParams.zoom == 1.0)
    }

    // MARK: - borderParams (Border.cpp / DarkenCenter.cpp — same wiring pattern as warpParams above)

    @Test func noPresetLoadedLeavesBorderParamsAtNeutralDefaults() {
        let model = MilkdropVisualizerModel()
        model.updatePresetPerFrame(time: 1, fps: 60, frame: 60, energy: MilkdropBandEnergy())
        #expect(model.borderParams.outerA == 0.0)
        #expect(model.borderParams.innerA == 0.0)
        #expect(model.borderParams.innerR == 0.25)
        #expect(model.borderParams.darkenCenter == 0.0)
    }

    @Test func staticBorderConstantsReachBorderParamsWithNoPerFrameCodeAtAll() throws {
        let model = MilkdropVisualizerModel()
        let url = try presetFile("[preset00]\nob_a=0.9\nib_a=0.5\nbDarkenCenter=1\n")
        model.loadPreset(from: url)
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(model.borderParams.outerA == 0.9)
        #expect(model.borderParams.innerA == 0.5)
        #expect(model.borderParams.darkenCenter == 1.0)
    }

    @Test func perFrameScriptCanAnimateBorderAlpha() throws {
        let model = MilkdropVisualizerModel()
        let url = try presetFile("[preset00]\nper_frame_1=ob_a=0.5+0.5*sin(time);\n")
        model.loadPreset(from: url)
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(abs(model.borderParams.outerA - 0.5) < 0.0001)
    }

    @Test func loadingANewPresetResetsBorderParamsRatherThanLeakingThePreviousOnesState() throws {
        let model = MilkdropVisualizerModel()
        let bordered = try presetFile("[preset00]\nob_a=1.0\nbDarkenCenter=1\n")
        model.loadPreset(from: bordered)
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(model.borderParams.outerA == 1.0)
        #expect(model.borderParams.darkenCenter == 1.0)

        let plain = try presetFile("[preset00]\nnWaveMode=0\n")
        model.loadPreset(from: plain)
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(model.borderParams.outerA == 0.0)
        #expect(model.borderParams.darkenCenter == 0.0)
    }

    // MARK: - Old-style final composite (VideoEcho.cpp/Filters.cpp)

    @Test func noPresetLoadedIsNotOldStyle() {
        let model = MilkdropVisualizerModel()
        #expect(model.usesOldStyleFinalComposite == false)
    }

    @Test func loadingAPresetWithNoVersionKeySetsOldStyleFlag() throws {
        let model = MilkdropVisualizerModel()
        let url = try presetFile("[preset00]\nnWaveMode=0\n")
        model.loadPreset(from: url)
        #expect(model.usesOldStyleFinalComposite == true)
    }

    @Test func loadingAModernVersionedPresetClearsOldStyleFlag() throws {
        let model = MilkdropVisualizerModel()
        let old = try presetFile("[preset00]\nnWaveMode=0\n")
        model.loadPreset(from: old)
        #expect(model.usesOldStyleFinalComposite == true)

        let modern = try presetFile("[preset00]\nMILKDROP_PRESET_VERSION=201\n")
        model.loadPreset(from: modern)
        #expect(model.usesOldStyleFinalComposite == false)
    }

    @Test func staticOldStyleCompositeConstantsReachParamsWithNoPerFrameCodeAtAll() throws {
        let model = MilkdropVisualizerModel()
        let url = try presetFile("[preset00]\nfGammaAdj=1.5\nfVideoEchoAlpha=0.4\nbInvert=1\n")
        model.loadPreset(from: url)
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(model.oldStyleCompositeParams.gammaAdj == 1.5)
        #expect(model.oldStyleCompositeParams.videoEchoAlpha == 0.4)
        #expect(model.oldStyleCompositeParams.invert == 1.0)
    }

    @Test func perFrameScriptCanAnimateGamma() throws {
        let model = MilkdropVisualizerModel()
        let url = try presetFile("[preset00]\nper_frame_1=gamma=1.0+sin(time);\n")
        model.loadPreset(from: url)
        model.updatePresetPerFrame(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(abs(model.oldStyleCompositeParams.gammaAdj - 1.0) < 0.0001)
    }

    @Test func hueRandomOffsetsAreFreshOnEveryLoad() throws {
        // Not a fixed/shipped constant (PresetState.cpp rolls these from real randomness) — two
        // separate loads should (overwhelmingly likely) produce different offsets, confirming this
        // isn't accidentally a hardcoded default.
        let model = MilkdropVisualizerModel()
        let url = try presetFile("[preset00]\nnWaveMode=0\n")
        model.loadPreset(from: url)
        let first = model.hueRandomOffsets
        model.loadPreset(from: url)
        let second = model.hueRandomOffsets
        #expect(first != second)
    }
}
