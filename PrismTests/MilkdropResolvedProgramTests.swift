//
//  MilkdropResolvedProgramTests.swift
//  PrismTests
//
//  Regression coverage for the slot-based NS-EEL evaluator added 7/26 (see
//  MilkdropExpressionEvaluator.swift's perf note): `MilkdropExpressionProgram.resolved(against:)`
//  produces a `MilkdropResolvedProgram` that evaluates against integer-indexed `MilkdropVariableSlots`
//  storage instead of a `[String: Float]` dictionary, eliminating string hashing from the hot
//  per-vertex/per-point/per-instance evaluation path. The critical correctness requirement is that
//  this produces byte-identical output to the original dictionary-based evaluator (still kept,
//  unchanged, in MilkdropExpressionEvaluator.swift) for every input — verified here across the same
//  cases MilkdropExpressionEvaluatorTests.swift covers, run through both paths side by side, plus a
//  from-scratch standalone `swiftc` harness (14,254 checks, 0 failures: 20 synthetic
//  operator/builtin/edge-case programs plus 6 real per_pixel_N= scripts pulled from the actual
//  ~9,795-file preset pack on this machine, each evaluated across 8 sequential passes sharing one
//  persistent store to mimic a real mesh sweep) and a throughput benchmark (1.692ms -> 0.823ms per
//  simulated 825-vertex mesh sweep, ~2.06x) — see TO DO.md for the full writeup.
//

import Testing
@testable import Prism

struct MilkdropResolvedProgramTests {
    /// Runs `source` through both the original dictionary-based evaluator and the new resolved-slot
    /// evaluator, seeded identically, and asserts every variable either path touched matches exactly.
    private func compareOldAndNew(_ source: String, _ initial: [String: Float] = [:]) {
        var dict = initial
        MilkdropExpressionProgram(source: source)?.evaluate(&dict)

        let store = MilkdropVariableSlots()
        for (name, value) in initial { store[name] = value }
        MilkdropExpressionProgram(source: source)?.resolved(against: store).evaluate(store)

        for (name, oldValue) in dict {
            let newValue = store[name] ?? 0
            #expect(oldValue == newValue || (oldValue.isNaN && newValue.isNaN), "mismatch on '\(name)': old=\(oldValue) new=\(newValue)")
        }
    }

    @Test func oneArgumentFunctionsMatchTheOriginalEvaluator() {
        compareOldAndNew("a=sqrt(16); b=abs(-3); c=sin(0); d=int(3.9);")
    }

    @Test func twoArgumentFunctionsMatchTheOriginalEvaluator() {
        compareOldAndNew("a=pow(2,10); b=min(3,7); c=max(3,7); d=atan2(0,1); e=above(5,2); f=below(2,5);")
    }

    @Test func threeArgumentIfMatchesTheOriginalEvaluator() {
        compareOldAndNew("a=if(1,10,20); b=if(0,10,20);")
    }

    @Test func extraArgumentsBeyondThreeStillEvaluateForSideEffects() {
        compareOldAndNew("a=min(1, 2, sideEffect=99, anotherSideEffect=42);")
    }

    @Test func assignmentChainsMatchTheOriginalEvaluator() {
        compareOldAndNew("a=b=c=5;")
    }

    @Test func nestedFunctionCallsMatchTheOriginalEvaluator() {
        compareOldAndNew("a=max(sqrt(16), min(10, pow(2,2)));")
    }

    @Test func unsupportedFunctionEvaluatesToZeroRatherThanCrashing() {
        let store = MilkdropVariableSlots()
        MilkdropExpressionProgram(source: "a=someUnsupportedShaderHelper(1,2,3);")?.resolved(against: store).evaluate(store)
        #expect(store["a"] == 0)
    }

    @Test func undeclaredVariableReadsAsZero() {
        let store = MilkdropVariableSlots()
        MilkdropExpressionProgram(source: "a=neverAssigned+1;")?.resolved(against: store).evaluate(store)
        #expect(store["a"] == 1)
    }

    @Test func guardedOpsMatchTheOriginalEvaluator() {
        // Division/modulo by zero, sqrt/log of a negative — the evaluator's defensive guards
        // (`right == 0 ? 0 : ...`, `a0 < 0 ? 0 : sqrt(a0)`, etc.) must be reproduced exactly.
        compareOldAndNew("a=5/0; b=-5/0; c=7%0; d=sqrt(-4); e=log(-5); f=log(0); g=log10(-1);")
    }

    @Test func realPerPixelStyleScriptMatchesTheOriginalEvaluator() {
        let initial: [String: Float] = [
            "x": 0.42, "y": 0.61, "rad": 0.3, "ang": 1.2, "time": 12.34,
            "bass": 0.8, "treb": 0.3, "q1": 0.5, "q2": -0.2, "zoom": 1.0,
        ]
        compareOldAndNew("""
        an = ang + q1 - .7854*.5;
        zm = .5 + .5*sin(an*4);
        zoom = 1 + zm*q2;
        rot = -.01*sin((ang + q1)*4)*(1 - pow(rad,2)*3);
        cx = 0.5 + 0.1*cos(time) + q1;
        dx = if(above(bass, 1), dx*0.9, dx*0.99);
        """, initial)
    }

    // MARK: - MilkdropVariableSlots itself

    @Test func slotResolutionIsIdempotentAndSharedAcrossPrograms() {
        let store = MilkdropVariableSlots()
        let firstSlot = store.slot(for: "x")
        let secondSlot = store.slot(for: "x")
        #expect(firstSlot == secondSlot)

        store.setValue(42, at: firstSlot)
        #expect(store.value(at: secondSlot) == 42)
        #expect(store["x"] == 42)
    }

    @Test func subscriptGetReturnsNilForAnUnresolvedName() {
        let store = MilkdropVariableSlots()
        #expect(store["neverTouched"] == nil)
    }

    @Test func subscriptSetCreatesASlotAndIsReadableByValueAt() {
        let store = MilkdropVariableSlots()
        store["y"] = 7
        #expect(store.value(at: store.slot(for: "y")) == 7)
    }

    @Test func loadBulkSeedsFromADictionaryLiteral() {
        let store = MilkdropVariableSlots()
        store.load(["a": 1, "b": 2, "c": 3])
        #expect(store["a"] == 1)
        #expect(store["b"] == 2)
        #expect(store["c"] == 3)
    }

    @Test func twoProgramsSharingOneStoreResolveTheSameNameToTheSameSlot() {
        // Mirrors a real runtime's init program + ongoing per-frame/per-vertex program sharing one
        // persistent store (e.g. MilkdropShapeRuntime's initProgram then perFrameProgram) — a value
        // one program writes must be visible to the other via the same slot.
        let store = MilkdropVariableSlots()
        MilkdropExpressionProgram(source: "SPEED=10;")?.evaluate(store)
        let resolved = MilkdropExpressionProgram(source: "out=SPEED*2;")?.resolved(against: store)
        resolved?.evaluate(store)
        #expect(store["out"] == 20)
    }
}
