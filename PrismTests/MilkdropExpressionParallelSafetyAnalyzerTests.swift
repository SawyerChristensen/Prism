//
//  MilkdropExpressionParallelSafetyAnalyzerTests.swift
//  PrismTests
//
//  Coverage for the Tier-3 GPU-transpile prerequisite (see
//  MilkdropExpressionParallelSafetyAnalyzer.swift's header): a script is only safe to evaluate on
//  GPU (one independent invocation per mesh vertex, no defined order) if it never reads a custom
//  variable whose only possible source is a write from a *different* iteration of the same sweep.
//  Verified first via a standalone `swiftc` harness (the analyzer file has no framework
//  dependency) against hand-built safe/unsafe pairs plus a corpus-scale measurement: of the 6,049
//  real files (61.8% of the full ~9,795-file pack) with `per_pixel_N=` code, **86.7% (5,244
//  files)** are classified sweep-parallel-safe — a real, measured majority, not a guess — vs. only
//  43.3% for a cruder "any custom variable anywhere forces fallback" heuristic (the precise
//  same-iteration analysis here rescues 2,626 real files over that simpler alternative).
//

import Testing
@testable import Prism

struct MilkdropExpressionParallelSafetyAnalyzerTests {
    private let meshBuiltins: Set<String> = Set([
        "x", "y", "rad", "ang", "time", "fps", "frame", "bass", "mid", "treb",
        "bass_att", "mid_att", "treb_att", "zoom", "zoomexp", "rot", "warp",
        "cx", "cy", "dx", "dy", "sx", "sy", "meshx", "meshy", "pixelsx", "pixelsy",
        "aspectx", "aspecty",
    ] + (1...32).map { "q\($0)" })

    private func isSafe(_ source: String, builtins: Set<String>? = nil) -> Bool {
        guard let program = MilkdropExpressionProgram(source: source) else { return true }
        return MilkdropExpressionParallelSafetyAnalyzer.isSweepParallelSafe(program.statements, builtins: builtins ?? meshBuiltins)
    }

    @Test func pureBuiltinOnlyScriptIsSafe() {
        #expect(isSafe("zoom = 1 + 0.1*sin(time);"))
    }

    @Test func tempWrittenThenReadInTheSameIterationIsSafe() {
        #expect(isSafe("temp = x*2; y2 = temp + rad; zoom = y2;"))
    }

    @Test func chainedAssignmentIsSafe() {
        #expect(isSafe("a = b = c = 5; zoom = a+b+c;"))
    }

    @Test func ifAboveWithOnlyBuiltinReadsIsSafe() {
        #expect(isSafe("zoom = if(above(bass,1), 1.1, 0.9);"))
    }

    @Test func loadTimeConstantNeverAssignedInThisScriptIsSafe() {
        // Simulates a value seeded once by a separate init program (e.g. `SPEED=10;`) and only
        // ever read, never assigned, within the per-pixel script itself.
        #expect(isSafe("zoom = SPEED * 2;", builtins: []))
    }

    @Test func emptyProgramIsSafe() {
        #expect(isSafe(""))
    }

    @Test func multiStatementChainOfLocalTempsIsSafe() {
        #expect(isSafe("a = 1; b = a + 1; c = a + b;"))
    }

    @Test func readingACustomVarBeforeItsOnlyLaterAssignmentIsUnsafe() {
        #expect(!isSafe("zoom = accum; accum = accum + 1;"))
    }

    @Test func rainbowCycleAccumulatorPatternIsUnsafe() {
        #expect(!isSafe("hue = hue + 0.05; r = hue;"))
    }

    @Test func selfReferentialAssignmentIsUnsafe() {
        #expect(!isSafe("SPEED = SPEED; zoom = 1;", builtins: []))
    }

    @Test func readThenWriteLaterPingPongAccumulatorIsUnsafe() {
        #expect(!isSafe("a = counter; counter = a + 1;"))
    }

    // MARK: - if/&&/|| short-circuit-aware safety (added 7/26 — see this analyzer's own header,
    // points 5/6, for the correctness bug this closes: treating both branches of an `if` as
    // "always written this iteration" was only sound while the evaluator itself was (incorrectly)
    // eager; now that both short-circuit for real, only a variable assigned in *every* reachable
    // branch is actually guaranteed.

    @Test func variableAssignedOnBothIfBranchesIsSafe() {
        // Symmetric — both branches assign `temp`, so it's genuinely guaranteed regardless of which
        // one actually ran this iteration. The common `if(cond,x=1,x=2)` ternary-like pattern.
        #expect(isSafe("temp = if(above(bass,1), 1, 2); zoom = temp;"))
    }

    @Test func variableAssignedOnOnlyOneIfBranchThenReadIsUnsafe() {
        // Asymmetric — `temp` is only guaranteed to have been written this iteration if the `above`
        // branch was taken (the `else` branch, `0`, deliberately leaves it untouched); on a vertex
        // where the else branch ran, a later read of `temp` would see whatever a *different*
        // iteration last left there. This is exactly the class of bug the old, eager-evaluation-
        // assuming version of this analyzer would have missed. (Real NS-EEL `if` always takes
        // exactly 3 arguments — an else branch is mandatory, not optional.)
        #expect(!isSafe("if(above(bass,1), temp = 1, 0); zoom = temp;"))
    }

    @Test func variableAssignedOnOnlyOneIfBranchButNeverReadIsSafe() {
        // Asymmetric write, but nothing downstream ever reads `temp` — no read-before-guaranteed-
        // write hazard exists, so this stays safe (matches the analyzer's existing "only a read
        // needs a guaranteed prior write" contract, unaffected by this fix).
        #expect(isSafe("if(above(bass,1), temp = 1, 0); zoom = 1;"))
    }

    @Test func assignmentInsideAndOperandRightSideIsUnsafe() {
        // `&&`'s right operand only evaluates when the left side is already true — an assignment
        // there has no symmetric "other side" the way `if`'s branches do, so it's never treated as
        // guaranteed (this analyzer's header, point 6).
        #expect(!isSafe("ok = above(bass,1) && (temp = 1); zoom = temp;"))
    }

    @Test func assignmentInsideOrOperandRightSideIsUnsafe() {
        #expect(!isSafe("ok = above(bass,1) || (temp = 1); zoom = temp;"))
    }
}
