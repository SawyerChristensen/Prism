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

    @Test func crlfLineEndingsParseCorrectly() {
        // Every real .milk file sampled from an actual Milkdrop/NestDrop preset pack (Windows-
        // authored, near-universally CRLF-terminated) failed to parse *at all* before this fix:
        // Swift's String treats "\r\n" as a single Character (an extended grapheme cluster —
        // `"\r\n".count == 1`), so splitting on the Character "\n" alone never finds a split point
        // in a CRLF file, and the entire file comes back as one unparseable "line." Built with
        // explicit "\r\n" here rather than a `"""`-literal, since triple-quoted Swift string
        // literals always normalize to plain "\n" regardless of this source file's own line
        // endings — the exact reason every other test in this file missed this bug.
        let text = "[preset00]\r\nnWaveMode=7\r\nper_frame_1=zoom=zoom+0.01;\r\nper_pixel_1=zoom=1;\r\n"
        let file = MilkdropPresetFile(text: text)
        #expect(file.waveMode == 7)
        #expect(file.perFrameProgram.contains("zoom=zoom+0.01"))
        #expect(file.perPixelProgram == "zoom=1;")
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

    @Test func customWaveformKeysDontLeakIntoPerFrameAndParseIntoTheirOwnSlots() {
        // Real content (trimmed) of projectM's presets/tests/252-wavecode-spectrum2.milk.
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
        // wave_0/wave_1's per_point code correctly lands in their own custom-waveform slots now.
        #expect(file.customWaves[0].enabled == true)
        #expect(file.customWaves[0].perPointProgram.contains("x=sample"))
        #expect(file.customWaves[1].enabled == false) // Only wavecode_0_enabled was set.
        #expect(file.customWaves[1].perPointProgram.contains("if(sw,osa,sample)"))
    }

    // MARK: - Custom waveforms (wavecode_N_*)

    @Test func parsesWavecodeConstants() {
        let file = MilkdropPresetFile(text: """
        [preset00]
        wavecode_2_enabled=1
        wavecode_2_samples=256
        wavecode_2_sep=4
        wavecode_2_bSpectrum=1
        wavecode_2_bUseDots=1
        wavecode_2_bDrawThick=1
        wavecode_2_bAdditive=1
        wavecode_2_scaling=2.5
        wavecode_2_smoothing=0.25
        wavecode_2_r=0.1
        wavecode_2_g=0.2
        wavecode_2_b=0.3
        wavecode_2_a=0.4
        """)
        let wave = file.customWaves[2]
        #expect(wave.enabled == true)
        #expect(wave.samples == 256)
        #expect(wave.sep == 4)
        #expect(wave.spectrum == true)
        #expect(wave.useDots == true)
        #expect(wave.drawThick == true)
        #expect(wave.additive == true)
        #expect(wave.scaling == 2.5)
        #expect(wave.smoothing == 0.25)
        #expect(wave.r == 0.1)
        #expect(wave.g == 0.2)
        #expect(wave.b == 0.3)
        #expect(wave.a == 0.4)
        // Untouched slots keep CustomWaveform.hpp's own defaults.
        #expect(file.customWaves[0].enabled == false)
        #expect(file.customWaves[0].samples == 512)
        #expect(file.customWaves[0].scaling == 1.0)
    }

    @Test func waveCodeSlotsHaveNoUnderscoreBeforeTheDigitUnlikeMainPerFrame() {
        let file = MilkdropPresetFile(text: """
        [preset00]
        wavecode_0_enabled=1
        wave_0_init1=SPEED=2;
        wave_0_per_frame1=a=0.5+0.1*sin(time*SPEED);
        wave_0_per_point1=x=0.5+0.1*
        wave_0_per_point2=  sin(time*SPEED);
        """)
        #expect(file.customWaves[0].initProgram.contains("SPEED=2"))
        #expect(file.customWaves[0].perFrameProgram.contains("sin(time*SPEED)"))
        #expect(file.customWaves[0].perPointProgram.contains("sin(time*SPEED)"))
    }

    @Test func wavecodeDoesNotCollideWithUnindexedWaveConstants() {
        // wave_x/wave_y/wave_r/wave_g/wave_b (no digit right after `wave_`) are the *main*
        // preset's plain top-level wave constants, not a custom-waveform code slot — confirming
        // splitIndexedKey correctly rejects them (no numeric prefix to find) rather than
        // misparsing "x"/"y"/"r"/"g"/"b" as a code-family name with no digit suffix.
        let file = MilkdropPresetFile(text: """
        [preset00]
        wave_x=0.25
        wave_y=0.75
        wave_r=0.5
        wavecode_0_enabled=1
        """)
        #expect(file.waveX == 0.25)
        #expect(file.waveY == 0.75)
        #expect(file.waveR == 0.5)
        #expect(file.customWaves[0].enabled == true)
        #expect(file.customWaves.allSatisfy { $0.initProgram.isEmpty && $0.perFrameProgram.isEmpty && $0.perPointProgram.isEmpty })
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

    /// `textured`/`tex_ang`/`tex_zoom`/`image` — CustomShape.cpp:37-59's projectM-specific/textured
    /// fields, added alongside the textured shape rendering path in MilkdropMetalRenderer.swift.
    @Test func parsesTexturedShapecodeFields() {
        let file = MilkdropPresetFile(text: """
        [preset00]
        shapecode_0_enabled=1
        shapecode_0_textured=1
        shapecode_0_tex_ang=0.5
        shapecode_0_tex_zoom=2.0
        shapecode_0_image=worms.jpg
        shapecode_2_enabled=1
        shapecode_2_textured=0
        """)
        #expect(file.shapes[0].textured == true)
        #expect(file.shapes[0].texAng == 0.5)
        #expect(file.shapes[0].texZoom == 2.0)
        #expect(file.shapes[0].image == "worms.jpg")
        #expect(file.shapes[2].textured == false)
        // A preset with no shapecode_N_textured/tex_ang/tex_zoom keys at all keeps the untextured,
        // no-zoom defaults (confirmed against CustomShape.cpp's own member initializers).
        #expect(file.shapes[1].textured == false)
        #expect(file.shapes[1].texZoom == 1.0)
        #expect(file.shapes[1].image == "")
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

    // MARK: - Warp transform (zoom/rot/cx/cy/dx/dy/sx/sy/warp/decay)

    @Test func parsesWarpTransformConstants() {
        // Key names confirmed against projectM's PresetState.cpp (zoom/rot/cx/cy/dx/dy/warp/sx/sy
        // are plain lowercase; decay/zoomExponent/warpAnimSpeed/warpScale use the `f`-prefixed
        // Milkdrop naming convention, matching fWaveScale/fWaveSmoothing elsewhere in this file).
        let file = MilkdropPresetFile(text: """
        [preset00]
        zoom=1.05
        fZoomExponent=1.2
        rot=0.02
        cx=0.4
        cy=0.6
        dx=0.01
        dy=-0.01
        warp=0.5
        sx=1.1
        sy=0.9
        fDecay=0.95
        fWarpAnimSpeed=2.0
        fWarpScale=0.5
        """)
        #expect(file.zoom == 1.05)
        #expect(file.zoomExponent == 1.2)
        #expect(file.rot == 0.02)
        #expect(file.rotCX == 0.4)
        #expect(file.rotCY == 0.6)
        #expect(file.xPush == 0.01)
        #expect(file.yPush == -0.01)
        #expect(file.warpAmount == 0.5)
        #expect(file.stretchX == 1.1)
        #expect(file.stretchY == 0.9)
        #expect(file.decay == 0.95)
        #expect(file.warpAnimSpeed == 2.0)
        #expect(file.warpScale == 0.5)
    }

    @Test func warpTransformConstantsDefaultToRealMilkdropValuesWhenAbsent() {
        // Defaults confirmed against projectM's PresetState.hpp field initializers — not 0 for
        // most of these (unlike a generic "missing key" fallback), since 0 would mean "no zoom"/
        // "no stretch" for a multiplicative value, not "neutral."
        let file = MilkdropPresetFile(text: "[preset00]\nnWaveMode=0\n")
        #expect(file.zoom == 1.0)
        #expect(file.zoomExponent == 1.0)
        #expect(file.rot == 0.0)
        #expect(file.rotCX == 0.5)
        #expect(file.rotCY == 0.5)
        #expect(file.xPush == 0.0)
        #expect(file.yPush == 0.0)
        #expect(file.warpAmount == 1.0)
        #expect(file.stretchX == 1.0)
        #expect(file.stretchY == 1.0)
        #expect(file.decay == 0.98)
        #expect(file.warpAnimSpeed == 1.0)
        #expect(file.warpScale == 1.0)
    }

    // MARK: - Border / darken-center (Border.cpp / DarkenCenter.cpp)

    @Test func parsesBorderAndDarkenCenterConstants() {
        // Key names confirmed against projectM's PresetState.cpp: ob_*/ib_* are plain lowercase
        // (same convention as zoom/rot/cx/cy above), bDarkenCenter uses the `b`-prefixed boolean
        // naming convention (matching shapecode's bAdditive/bThickOutline elsewhere).
        let file = MilkdropPresetFile(text: """
        [preset00]
        ob_size=0.02
        ob_r=0.1
        ob_g=0.2
        ob_b=0.3
        ob_a=0.9
        ib_size=0.03
        ib_r=0.4
        ib_g=0.5
        ib_b=0.6
        ib_a=0.8
        bDarkenCenter=1
        """)
        #expect(file.outerBorderSize == 0.02)
        #expect(file.outerBorderR == 0.1)
        #expect(file.outerBorderG == 0.2)
        #expect(file.outerBorderB == 0.3)
        #expect(file.outerBorderA == 0.9)
        #expect(file.innerBorderSize == 0.03)
        #expect(file.innerBorderR == 0.4)
        #expect(file.innerBorderG == 0.5)
        #expect(file.innerBorderB == 0.6)
        #expect(file.innerBorderA == 0.8)
        #expect(file.darkenCenter == true)
    }

    @Test func borderAndDarkenCenterDefaultToRealMilkdropValuesWhenAbsent() {
        // Defaults confirmed against PresetState.hpp: both borders' alpha default to 0 (invisible),
        // but the inner border's *color* still defaults to a visible gray (0.25/0.25/0.25) — a
        // preset that sets only ib_a relies on that gray, not black.
        let file = MilkdropPresetFile(text: "[preset00]\nnWaveMode=0\n")
        #expect(file.outerBorderSize == 0.01)
        #expect(file.outerBorderR == 0.0)
        #expect(file.outerBorderG == 0.0)
        #expect(file.outerBorderB == 0.0)
        #expect(file.outerBorderA == 0.0)
        #expect(file.innerBorderSize == 0.01)
        #expect(file.innerBorderR == 0.25)
        #expect(file.innerBorderG == 0.25)
        #expect(file.innerBorderB == 0.25)
        #expect(file.innerBorderA == 0.0)
        #expect(file.darkenCenter == false)
    }

    // MARK: - Old-style final composite (VideoEcho.cpp/Filters.cpp)

    @Test func noMilkdropPresetVersionKeyMeansOldStyle() {
        // Confirmed against PresetState.hpp: `presetVersion` defaults to 100 (not "unknown"/absent
        // as a distinct state) — every 1.x-era preset predates this key entirely, so its absence is
        // itself the old-style signal, the same as PresetState::Initialize's own version-gating.
        let file = MilkdropPresetFile(text: "[preset00]\nnWaveMode=0\n")
        #expect(file.presetVersion == 100)
        #expect(file.usesOldStyleFinalComposite == true)
    }

    @Test func presetVersionAtOrAboveTwoHundredIsNotOldStyle() {
        let file = MilkdropPresetFile(text: "[preset00]\nMILKDROP_PRESET_VERSION=201\n")
        #expect(file.usesOldStyleFinalComposite == false)
    }

    @Test func parsesVideoEchoAndGammaAndFilterConstants() {
        let file = MilkdropPresetFile(text: """
        [preset00]
        fGammaAdj=1.5
        fVideoEchoZoom=3.0
        fVideoEchoAlpha=0.4
        nVideoEchoOrientation=2
        bBrighten=1
        bDarken=1
        bSolarize=1
        bInvert=1
        """)
        #expect(file.gammaAdj == 1.5)
        #expect(file.videoEchoZoom == 3.0)
        #expect(file.videoEchoAlpha == 0.4)
        #expect(file.videoEchoOrientation == 2)
        #expect(file.brighten == true)
        #expect(file.darken == true)
        #expect(file.solarize == true)
        #expect(file.invert == true)
    }

    @Test func videoEchoAndFilterConstantsDefaultToRealMilkdropValuesWhenAbsent() {
        // Confirmed against PresetState.hpp: gammaAdj defaults to 2.0 (not 1.0) and videoEchoZoom
        // to 2.0 — an old-style preset that sets nothing still gets brightness-doubled output.
        let file = MilkdropPresetFile(text: "[preset00]\nnWaveMode=0\n")
        #expect(file.gammaAdj == 2.0)
        #expect(file.videoEchoZoom == 2.0)
        #expect(file.videoEchoAlpha == 0.0)
        #expect(file.videoEchoOrientation == 0)
        #expect(file.brighten == false)
        #expect(file.darken == false)
        #expect(file.solarize == false)
        #expect(file.invert == false)
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
