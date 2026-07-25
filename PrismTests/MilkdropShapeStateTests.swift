//
//  MilkdropShapeStateTests.swift
//  PrismTests
//
//  Coverage for MilkdropShapeState.swift's instance-loop/persistent-state semantics — the part of
//  the shapecode_N_* port that's easy to get subtly wrong (see that file's header for why a single
//  shared variable environment, not one per instance, is the correct port of projectM's
//  ShapePerFrameContext).
//

import Testing
@testable import Prism

struct MilkdropShapeStateTests {

    @Test func disabledShapeResolvesToNoInstances() {
        let runtime = MilkdropShapeRuntime(preset: MilkdropShapePreset(enabled: false))
        let instances = runtime.resolveInstances(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(instances.isEmpty)
    }

    @Test func enabledShapeWithNoScriptStillDrawsOnceFromStaticConstants() {
        var preset = MilkdropShapePreset()
        preset.enabled = true
        preset.sides = 5
        preset.rad = 0.3
        let runtime = MilkdropShapeRuntime(preset: preset)
        let instances = runtime.resolveInstances(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(instances.count == 1)
        #expect(instances[0].sides == 5)
        #expect(instances[0].rad == 0.3)
    }

    @Test func multiInstanceScriptDifferentiatesEachInstanceByIndex() {
        var preset = MilkdropShapePreset()
        preset.enabled = true
        preset.numInst = 3
        preset.perFrameProgram = "x = 0.1 * instance;"
        let runtime = MilkdropShapeRuntime(preset: preset)
        let instances = runtime.resolveInstances(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(instances.count == 3)
        #expect(instances[0].x == 0)
        #expect(abs(instances[1].x - 0.1) < 0.0001)
        #expect(abs(instances[2].x - 0.2) < 0.0001)
    }

    @Test func perFrameStateAccumulatesAcrossInstancesWithinAFrame() {
        // Exercises that all instances of one shape share a single variable environment (matching
        // upstream's one-context-per-shape design) rather than each starting from the preset's
        // static defaults: a script that increments a custom counter should see it grow across the
        // instance loop, not reset per instance.
        var preset = MilkdropShapePreset()
        preset.enabled = true
        preset.numInst = 3
        preset.perFrameProgram = "counter = counter + 1; x = counter;"
        let runtime = MilkdropShapeRuntime(preset: preset)
        let instances = runtime.resolveInstances(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(instances.map(\.x) == [1, 2, 3])
    }

    @Test func perFrameStatePersistsAcrossFrames() {
        // `ang = ang + 0.1;` style scripts (continuous rotation) rely on the shape's variable
        // environment surviving between resolveInstances() calls, not resetting each frame.
        var preset = MilkdropShapePreset()
        preset.enabled = true
        preset.perFrameProgram = "ang = ang + 0.1;"
        let runtime = MilkdropShapeRuntime(preset: preset)

        let frame1 = runtime.resolveInstances(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        let frame2 = runtime.resolveInstances(time: 1.0 / 60, fps: 60, frame: 2, energy: MilkdropBandEnergy())
        #expect(abs(frame1[0].ang - 0.1) < 0.0001)
        #expect(abs(frame2[0].ang - 0.2) < 0.0001)
    }

    @Test func sidesAreClampedToThreeThroughOneHundred() {
        var lowPreset = MilkdropShapePreset()
        lowPreset.enabled = true
        lowPreset.sides = 2
        let low = MilkdropShapeRuntime(preset: lowPreset).resolveInstances(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(low[0].sides == 3)

        var highPreset = MilkdropShapePreset()
        highPreset.enabled = true
        highPreset.sides = 500
        let high = MilkdropShapeRuntime(preset: highPreset).resolveInstances(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(high[0].sides == 100)
    }

    @Test func colorChannelsWrapInsteadOfClampingWhenPushedOutOfRange() {
        // Real Milkdrop lets a script intentionally overshoot a color channel for a cycling
        // "flash" effect (`r=r+0.01;` past 1.0 wraps back toward 0, not pins at white). 1.2 * 255
        // = 306, 306 & 0xFF = 50, 50/255 ≈ 0.196.
        var preset = MilkdropShapePreset()
        preset.enabled = true
        preset.perFrameProgram = "r=1.2; g=-0.1; b=2.0;"
        let runtime = MilkdropShapeRuntime(preset: preset)
        let instances = runtime.resolveInstances(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(abs(instances[0].r - 50.0 / 255.0) < 0.001)
        // -0.1*255 = -25.5 -> floor-mod 256 -> 230.5 -> /255 ≈ 0.904 (wraps toward white, not black).
        #expect(abs(instances[0].g - 230.5 / 255.0) < 0.001)
        // 2.0*255 = 510, 510 mod 256 = 254, /255 ≈ 0.996.
        #expect(abs(instances[0].b - 254.0 / 255.0) < 0.001)
    }

    @Test func nonFiniteColorFallsBackInsteadOfPropagatingNaN() {
        // `pow` isn't divide-by-zero-guarded like the evaluator's other functions, so a fractional
        // power of a negative base (pow(-1, 0.5)) is a real way a preset script can produce NaN —
        // this confirms colorWrapped catches it rather than letting NaN reach the renderer.
        var preset = MilkdropShapePreset()
        preset.enabled = true
        preset.r = 0.42
        preset.perFrameProgram = "r=pow(-1,0.5);"
        let runtime = MilkdropShapeRuntime(preset: preset)
        let instances = runtime.resolveInstances(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(instances[0].r == 0.42)
    }

    @Test func initProgramSeedsVariablesBeforeFirstPerFrameEvaluation() {
        var preset = MilkdropShapePreset()
        preset.enabled = true
        preset.initProgram = "SPEED = 4;"
        preset.perFrameProgram = "rad = 0.1 * SPEED;"
        let runtime = MilkdropShapeRuntime(preset: preset)
        let instances = runtime.resolveInstances(time: 0, fps: 60, frame: 1, energy: MilkdropBandEnergy())
        #expect(abs(instances[0].rad - 0.4) < 0.0001)
    }

    @Test func audioReactiveScriptReadsBandEnergy() {
        var preset = MilkdropShapePreset()
        preset.enabled = true
        preset.perFrameProgram = "rad = 0.05 * bass;"
        let runtime = MilkdropShapeRuntime(preset: preset)
        let energy = MilkdropBandEnergy(bass: 2, mid: 1, treb: 1, bassAtt: 1, midAtt: 1, trebAtt: 1)
        let instances = runtime.resolveInstances(time: 0, fps: 60, frame: 1, energy: energy)
        #expect(abs(instances[0].rad - 0.1) < 0.0001)
    }
}
