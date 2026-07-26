//
//  MilkdropExpressionEvaluatorTests.swift
//  PrismTests
//
//  Regression coverage for MilkdropExpressionProgram, added alongside a performance fix (7/25):
//  function calls used to evaluate their arguments via `argNodes.map { eval($0, &vars) }`, heap-
//  allocating a fresh `[Float]` array on every single call — measured as a real, meaningful cost
//  for scripts run hundreds of times per frame (per_pixel_N= mesh sweeps, custom-waveform per-point
//  scripts). Replaced with inline evaluation of up to 3 arguments (every supported builtin takes at
//  most 3), which must produce identical results and — the easy part to get subtly wrong — must
//  still evaluate every argument node for its side effects even when a builtin only reads the first
//  few, exactly like the original `.map` did for every argument regardless of arity.
//

import Testing
@testable import Prism

struct MilkdropExpressionEvaluatorTests {
    private func run(_ source: String, _ initial: [String: Float] = [:]) -> [String: Float] {
        var vars = initial
        MilkdropExpressionProgram(source: source)?.evaluate(&vars)
        return vars
    }

    @Test func oneArgumentFunctionsEvaluateCorrectly() {
        let vars = run("a=sqrt(16); b=abs(-3); c=sin(0); d=int(3.9);")
        #expect(vars["a"] == 4)
        #expect(vars["b"] == 3)
        #expect(vars["c"] == 0)
        #expect(vars["d"] == 3)
    }

    @Test func twoArgumentFunctionsEvaluateCorrectly() {
        let vars = run("a=pow(2,10); b=min(3,7); c=max(3,7); d=atan2(0,1); e=above(5,2); f=below(2,5);")
        #expect(vars["a"] == 1024)
        #expect(vars["b"] == 3)
        #expect(vars["c"] == 7)
        #expect(vars["d"] == 0)
        #expect(vars["e"] == 1)
        #expect(vars["f"] == 1)
    }

    @Test func threeArgumentIfEvaluatesCorrectly() {
        #expect(run("a=if(1,10,20);")["a"] == 10)
        #expect(run("a=if(0,10,20);")["a"] == 20)
    }

    /// The specific edge case the array-elimination refactor could have silently broken: a call
    /// with MORE than 3 arguments (no real builtin needs that many, but the parser doesn't forbid
    /// it) must still evaluate every argument for its side effects, not just the first 3 that
    /// `callFunction` actually reads.
    @Test func extraArgumentsBeyondThreeStillEvaluateForSideEffects() {
        let vars = run("a=min(1, 2, sideEffect=99, anotherSideEffect=42);")
        #expect(vars["a"] == 1)
        #expect(vars["sideEffect"] == 99)
        #expect(vars["anotherSideEffect"] == 42)
    }

    @Test func assignmentChainsStillWork() {
        let vars = run("a=b=c=5;")
        #expect(vars["a"] == 5)
        #expect(vars["b"] == 5)
        #expect(vars["c"] == 5)
    }

    @Test func nestedFunctionCallsEvaluateCorrectly() {
        // Exercises that inline a0/a1/a2 evaluation still recurses correctly when an argument is
        // itself a call (each nested eval(&vars) call gets its own a0/a1/a2 locals, not a shared
        // mutable buffer that an outer call could clobber).
        let vars = run("a=max(sqrt(16), min(10, pow(2,2)));")
        #expect(vars["a"] == 4)
    }

    @Test func unsupportedFunctionEvaluatesToZeroRatherThanCrashing() {
        #expect(run("a=someUnsupportedShaderHelper(1,2,3);")["a"] == 0)
    }

    @Test func undeclaredVariableReadsAsZero() {
        #expect(run("a=neverAssigned+1;")["a"] == 1)
    }

    // MARK: - if/&&/|| short-circuit (fixed 7/26 — see MilkdropExpressionEvaluator.swift's header:
    // real NS-EEL short-circuits these three, confirmed against vendor/projectm-eval/TreeFunctions.c
    // rather than the previous, wrong "both sides always run" assumption).

    @Test func ifOnlyEvaluatesTheTakenBranchsSideEffect() {
        let trueBranch = run("s1=0; s2=0; a=if(1, s1=1, s2=1);")
        #expect(trueBranch["s1"] == 1)
        #expect(trueBranch["s2"] == 0, "the untaken branch's assignment must not have run")

        let falseBranch = run("s1=0; s2=0; a=if(0, s1=1, s2=1);")
        #expect(falseBranch["s1"] == 0, "the untaken branch's assignment must not have run")
        #expect(falseBranch["s2"] == 1)
    }

    @Test func andOnlyEvaluatesRightSideWhenLeftIsTrue() {
        let leftFalse = run("s=0; a = (0 && (s=1));")
        #expect(leftFalse["s"] == 0, "right side must not evaluate when the left is already false")
        #expect(leftFalse["a"] == 0)

        let leftTrue = run("s=0; a = (1 && (s=1));")
        #expect(leftTrue["s"] == 1, "right side must evaluate when the left doesn't decide the result")
        #expect(leftTrue["a"] == 1)
    }

    @Test func orOnlyEvaluatesRightSideWhenLeftIsFalse() {
        let leftTrue = run("s=0; a = (1 || (s=1));")
        #expect(leftTrue["s"] == 0, "right side must not evaluate when the left is already true")
        #expect(leftTrue["a"] == 1)

        let leftFalse = run("s=0; a = (0 || (s=1));")
        #expect(leftFalse["s"] == 1, "right side must evaluate when the left doesn't decide the result")
        #expect(leftFalse["a"] == 1)
    }

    @Test func bandAndBorFunctionFormsDoNotShortCircuit() {
        // Unlike the `&&`/`||` operators just above, the `band`/`bor` *function* forms are ordinary
        // eager 2-argument functions in real NS-EEL — no short-circuit contract at all (confirmed
        // against vendor/projectm-eval/TreeFunctions.c's own comment distinguishing the two).
        let vars = run("s1=0; s2=0; a=band(0, s1=1); b=bor(1, s2=1);")
        #expect(vars["s1"] == 1, "band's second argument must still evaluate even though the first is falsy")
        #expect(vars["s2"] == 1, "bor's second argument must still evaluate even though the first is truthy")
    }
}
