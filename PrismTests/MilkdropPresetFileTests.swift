//
//  MilkdropPresetFileTests.swift
//  PrismTests
//
//  Regression coverage for MilkdropPresetFile's parsing against real quirks found in projectM's
//  own test presets (case-insensitive keys, trailing-semicolon values, per_frame_init_N), plus the
//  MilkdropExpressionEvaluator pipeline it feeds.
//

import Testing
@testable import Prism

struct MilkdropPresetFileTests {

    @Test func parsesStaticWaveConstants() {
        // Real content of projectM's presets/tests/211-wave.milk.
        let file = MilkdropPresetFile(text: """
        [preset00]
        per_frame_1000=// simple wave
        per_frame_1001=// MODE=7 DoubleLine

        fDecay=0
        nWaveMode=11
        warp=0.000000
        wave_r=1
        wave_x=0.500000
        wave_y=0.500000
        """)
        #expect(file.waveMode == 11)
        #expect(file.waveX == 0.5)
        #expect(file.waveR == 1)
        #expect(MilkdropWaveMode(presetWaveMode: file.waveMode) == .dualParallel)
        // Both lines are >= 1000 (comment convention), so there's no executable per-frame program.
        #expect(MilkdropExpressionProgram(source: file.perFrameProgram) == nil)
    }

    @Test func caseInsensitiveKeysMatchRealPresetFile() {
        // Real content of projectM's presets/tests/001-line.milk — mixes `fdecay` (lowercase) and
        // `fwavesmoothing` (all-lowercase) with `nWaveMode`/`wave_x` (mixed case). Milkdrop itself
        // matches these case-insensitively; before this fix, MilkdropPresetFile's exact-case
        // lookups silently missed `fwavesmoothing` and fell back to its 0.75 default.
        let file = MilkdropPresetFile(text: """
        [preset00]
        fdecay=0
        warp=0;
        nWaveMode=6
        fWaveScale=1
        fwavesmoothing=0.01
        wave_r=1.0
        wave_x=0.500000
        wave_y=0.500000
        """)
        #expect(file.waveMode == 6)
        #expect(file.waveScale == 1)
        #expect(file.waveSmoothing == 0.01)
    }

    @Test func trailingSemicolonOnConstantValueDoesNotBreakParsing() {
        // `warp=0;` (a stray `;` left over from copy-pasting an equation) appears in real presets
        // outside per_frame_ lines. `warp` itself isn't a value MilkdropPresetFile reads, but this
        // confirms a semicolon-suffixed value on a key we *do* read still parses correctly.
        let file = MilkdropPresetFile(text: """
        [preset00]
        fWaveScale=1.5;
        nWaveMode=3;
        """)
        #expect(file.waveScale == 1.5)
        #expect(file.waveMode == 3)
    }

    @Test func multiLineEquationConcatenatesInNumericOrder() throws {
        // Real content (trimmed) of projectM's presets/tests/104-continued-eqn.milk: one equation
        // split across two numbered per_frame_ lines mid-token.
        let file = MilkdropPresetFile(text: """
        [preset00]
        per_frame_1=ib_r=0.7+0.4*
        per_frame_2=   sin(3*time);
        """)
        #expect(file.perFrameProgram.contains("sin(3*time)"))
        let program = try #require(MilkdropExpressionProgram(source: file.perFrameProgram))
        var vars: [String: Float] = ["time": 0]
        program.evaluate(&vars)
        #expect(abs((vars["ib_r"] ?? -1) - 0.7) < 0.001) // sin(0) == 0
    }

    @Test func perFrameInitRunsOnceBeforePerFrameReadsItsVariable() throws {
        // Real content (trimmed) of projectM's presets/tests/105-per_frame_init.milk: SPEED is
        // declared once via per_frame_init_1, then read every frame by per_frame_1.
        let file = MilkdropPresetFile(text: """
        [preset00]
        per_frame_init_1=SPEED=10;
        per_frame_1=ib_r=0.7+0.4*sin(time*SPEED);
        """)
        #expect(file.perFrameInitProgram.contains("SPEED=10"))

        var vars: [String: Float] = ["time": 0]
        MilkdropExpressionProgram(source: file.perFrameInitProgram)?.evaluate(&vars)
        #expect(vars["SPEED"] == 10)

        let program = try #require(MilkdropExpressionProgram(source: file.perFrameProgram))
        program.evaluate(&vars)
        #expect(abs((vars["ib_r"] ?? -1) - 0.7) < 0.001) // sin(0*10) == sin(0) == 0
    }

    @Test func perFrameInitIndicesAboveOneThousandAreCommentsNotCode() {
        let file = MilkdropPresetFile(text: """
        [preset00]
        per_frame_init_1000=// not code
        per_frame_init_1=x=1;
        """)
        #expect(file.perFrameInitProgram == "x=1;")
    }

    @Test func unrelatedCustomWaveformKeysDontCrashParsingOrLeakIntoPerFrame() {
        // Real content (trimmed) of projectM's presets/tests/252-wavecode-spectrum2.milk: keys for
        // the (unimplemented) custom-waveform per-point system shouldn't be mistaken for per_frame_.
        let file = MilkdropPresetFile(text: """
        [preset00]
        fDecay=0
        wave_a=0
        wavecode_0_enabled=1
        wave_0_per_point1=x=sample;
        wave_1_per_point10=y = if(sw,osa,sample);
        """)
        #expect(file.perFrameProgram.isEmpty)
        #expect(file.perFrameInitProgram.isEmpty)
        // fWaveAlpha (the key MilkdropPresetFile actually maps) wasn't set — `wave_a` alone,
        // matching real upstream semantics, is inert. Default stays.
        #expect(file.waveAlpha == 0.8)
    }

    @Test func malformedExpressionDoesNotCrashAndLaterStatementsStillRun() {
        let program = MilkdropExpressionProgram(source: "wave_x = ) ( + * unclosed(((;;; wave_y=1;")
        var vars: [String: Float] = [:]
        program?.evaluate(&vars)
        #expect(vars["wave_y"] == 1)
    }

    @Test func chainedAndSelfReferencingAssignmentWork() throws {
        let program = try #require(MilkdropExpressionProgram(source: "a=b=1; wave_y=wave_y*0.9+0.05;"))
        var vars: [String: Float] = ["wave_y": 0.5]
        program.evaluate(&vars)
        #expect(vars["a"] == 1)
        #expect(vars["b"] == 1)
        #expect(abs((vars["wave_y"] ?? -1) - 0.5) < 0.001) // 0.5*0.9 + 0.05 == 0.5
    }

    // MARK: - Custom shapes (shapecode_N_*)

    @Test func parsesShapecodeConstants() {
        // Key format confirmed directly against projectM's CustomShape.cpp (shapecodePrefix =
        // "shapecode_" + index + "_"), not a real bundled test preset — none of projectM's
        // checked-out presets/tests/*.milk exercise custom shapes.
        let file = MilkdropPresetFile(text: """
        [preset00]
        shapecode_1_enabled=1
        shapecode_1_sides=6
        shapecode_1_additive=1
        shapecode_1_num_inst=3
        shapecode_1_x=0.25
        shapecode_1_rad=0.4
        shapecode_1_r=0.1
        shapecode_1_g=0.2
        shapecode_1_b=0.3
        shapecode_1_r2=0.9
        shapecode_1_border_a=0.5
        """)
        let shape = file.shapes[1]
        #expect(shape.enabled == true)
        #expect(shape.sides == 6)
        #expect(shape.additive == true)
        #expect(shape.numInst == 3)
        #expect(shape.x == 0.25)
        #expect(shape.rad == 0.4)
        #expect(shape.r == 0.1)
        #expect(shape.g == 0.2)
        #expect(shape.b == 0.3)
        #expect(shape.r2 == 0.9)
        #expect(shape.borderA == 0.5)
        // Untouched fields keep CustomShape.cpp's own defaults.
        #expect(shape.y == 0.5)
        #expect(shape.g2 == 1.0)
    }

    @Test func shapeCodeSlotsHaveNoUnderscoreBeforeTheDigitUnlikeMainPerFrame() {
        // Confirmed against PresetState.cpp: main preset code uses GetCode("per_frame_") (trailing
        // underscore, so "per_frame_1"), but shapes use GetCode(shapePrefix + "init")/"per_frame"
        // with the slot number appended directly — "shape_0_init1", not "shape_0_init_1". A parser
        // that copy-pasted the main convention would silently drop these.
        let file = MilkdropPresetFile(text: """
        [preset00]
        shapecode_0_enabled=1
        shape_0_init1=SPEED=2;
        shape_0_per_frame1=x=0.5+0.1*sin(time*SPEED);
        """)
        #expect(file.shapes[0].initProgram.contains("SPEED=2"))
        #expect(file.shapes[0].perFrameProgram.contains("sin(time*SPEED)"))
    }

    @Test func multiSlotShapeCodeConcatenatesInNumericOrder() {
        let file = MilkdropPresetFile(text: """
        [preset00]
        shapecode_2_enabled=1
        shape_2_per_frame1=ang=0.1+
        shape_2_per_frame2=  0.2*sin(time);
        """)
        #expect(file.shapes[2].perFrameProgram.contains("sin(time)"))
    }

    @Test func shapeSlotsWithNoKeysStayDisabledAtDefaults() {
        // A preset that only defines shape 1 shouldn't fabricate shapes 0, 2, 3.
        let file = MilkdropPresetFile(text: """
        [preset00]
        shapecode_1_enabled=1
        """)
        #expect(file.shapes.count == 4)
        #expect(file.shapes[0].enabled == false)
        #expect(file.shapes[1].enabled == true)
        #expect(file.shapes[2].enabled == false)
        #expect(file.shapes[3].enabled == false)
    }

    @Test func shapeIndexOutOfRangeIsIgnoredNotCrashed() {
        // Milkdrop's own CustomShapeCount is 4 (indices 0-3); a stray higher index (or a
        // non-numeric one) shouldn't crash parsing or land anywhere.
        let file = MilkdropPresetFile(text: """
        [preset00]
        shapecode_9_enabled=1
        shapecode_x_enabled=1
        nWaveMode=2
        """)
        #expect(file.waveMode == 2)
        #expect(file.shapes.allSatisfy { $0.enabled == false })
    }
}
