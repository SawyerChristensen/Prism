//
//  MilkdropExpressionParallelSafetyAnalyzer.swift
//  Prism
//
//  Part of the Tier-3 GPU-transpile work (see TO DO.md's Phase 1 performance-pass notes): the
//  per-pixel warp mesh (and, in principle, custom-waveform per-point/shape per-instance scripts —
//  see MilkdropExpressionMSLTranspiler.swift) currently evaluates its script once per mesh vertex
//  (825x/frame) on the CPU, against ONE shared `MilkdropVariableSlots` store reused across the
//  *entire* sweep — a script's own custom variable can therefore carry state sequentially from
//  vertex 0 to vertex 1 to vertex 2..., by design, matching upstream projectM's own single-shared-
//  PerPixelContext architecture (see MilkdropPerPixelMesh.swift's header). A GPU compute/vertex
//  dispatch runs every vertex's evaluation independently and in parallel, with no defined order and
//  no shared mutable state between invocations (short of explicit, expensive atomics/barriers,
//  which would defeat the entire point of moving this to the GPU) — so it can only ever be
//  semantics-preserving for a script that is a pure function of *that iteration's own* inputs, never
//  reading a custom variable whose only possible source is a write from a *different* iteration.
//
//  This file answers exactly that question, statically, from an already-parsed `Node` AST — no
//  execution, no guessing from source text. `Node` (MilkdropExpressionParser.swift) has no loop
//  construct, but it DOES have real short-circuit branching: `if(cond,a,b)` only ever runs the
//  taken branch, and `&&`/`||` only evaluate their right operand when the left one doesn't already
//  determine the result (`MilkdropExpressionEvaluator.eval` was fixed 7/26 to match real NS-EEL's
//  actual semantics here — see its own header note; this file's algorithm below was updated in the
//  same pass to stop assuming the opposite). Every *other* node kind still always executes
//  unconditionally regardless of data — statements run in a fixed order, and outside of `if`/`&&`/
//  `||` there's no way to skip a subexpression — so this is still a single linear def-before-use
//  scan, not a real dataflow/fixpoint analysis, just one with two special-cased node shapes:
//
//   1. Seed a `writtenSoFar` set with the call site's own known built-in names (`x`/`y`/`rad`/`ang`/
//      `zoom`/etc for the per-pixel mesh) — each is freshly reseeded by the harness before every
//      iteration (see MilkdropPerPixelMesh.swift's `calculate`), so a read of one is always safe
//      regardless of iteration order.
//   2. Walk statements in order, and within each statement walk the AST in
//      `MilkdropExpressionEvaluator.eval`'s exact traversal order (assign: value first, then mark
//      the target written; binary/unary: operands in order; call: arguments in order) — **except**
//      `if(cond,thenExpr,elseExpr)` and `&&`/`||`'s right operand, which get their own conservative
//      treatment below rather than being walked as an ordinary call/binary node, precisely because
//      they might not execute at all this iteration.
//   3. On a `.variable(name)` read: safe if `name` is already in `writtenSoFar` (a built-in, or a
//      custom temp already written earlier in *this same* iteration — e.g. `temp=x*2; y=temp+rad;`
//      is fine, a very common real-preset pattern). If not yet written this iteration: safe if
//      `name` is never assigned *anywhere* in the whole program (a load-time constant seeded once
//      by a separate init program, e.g. `SPEED=10;`, read but never touched here); **unsafe** if it
//      *is* assigned somewhere in this program — its only possible source is a write from a
//      different iteration.
//   4. On `.assign(name, _)`: add `name` to `writtenSoFar` after processing its own value.
//   5. On `.call("if", [cond, thenExpr, elseExpr])`: visit `cond` normally (always runs), then visit
//      *both* `thenExpr` and `elseExpr` for read-safety (a read inside either branch still needs a
//      guaranteed prior write, exactly as before), **but** only add a name to `writtenSoFar`
//      afterward if it's assigned in *both* branches — an assignment reachable from only one branch
//      might not have run this iteration (this vertex could take the other branch), so treating it
//      as "definitely written" would be exactly the same class of bug this whole analyzer exists to
//      catch, just introduced by the analyzer itself rather than the evaluator. A script where
//      every `if` assigns the same variable(s) on both sides (the common `if(cond,x=1,x=2)`
//      ternary-like pattern) is completely unaffected — this only makes a *stricter* call, never a
//      more permissive one, than the old code's "both sides always execute" assumption did.
//   6. On `.binary("&&"/"||", lhs, rhs)`: visit `lhs` normally; visit `rhs` for read-safety same as
//      any operand, but **never** add anything `rhs` assigns to `writtenSoFar` — there's no
//      symmetric "other branch" to fall back on the way `if` has, so any assignment inside a
//      conditionally-evaluated `&&`/`||` operand is *never* treated as a guaranteed write (real
//      preset scripts essentially never put an assignment inside a boolean operand anyway, so this
//      costs nothing in practice while staying strictly sound).
//
//  Bias for correctness over recall: a false negative (classifying an actually-unsafe script as
//  safe) would be a silent, subtly-wrong visual bug on real hardware; a false positive just forfeits
//  a perf win for that one preset (it keeps using the existing, correct CPU interpreter — see
//  MilkdropMetalRenderer's compile-with-fallback contract). `Node` is a fully closed 6-case enum
//  (see MilkdropExpressionParser.swift) with no case this file doesn't explicitly handle, so there
//  is no "unmodeled AST shape" branch to worry about in practice — every case is covered below.
//

import Foundation

enum MilkdropExpressionParallelSafetyAnalyzer {
    /// `true` if `statements` can be evaluated for every iteration of a sweep (mesh vertex/waveform
    /// point/shape instance) independently, in any order, with byte-identical results to running
    /// them sequentially against one shared store — see this file's header for the exact algorithm.
    /// `builtins` is the call site's own known, per-iteration-reseeded name set.
    static func isSweepParallelSafe(_ statements: [Node], builtins: Set<String>) -> Bool {
        var everAssigned: Set<String> = []
        for statement in statements {
            collectAssignedNames(statement, into: &everAssigned)
        }

        var writtenSoFar = builtins
        for statement in statements {
            guard visit(statement, everAssigned: everAssigned, writtenSoFar: &writtenSoFar) else {
                return false
            }
        }
        return true
    }

    /// First pass: every name assigned *anywhere* in the program, regardless of position — needed
    /// before the main scan can tell "read before its only assignment, which is later in program
    /// order" (unsafe — that assignment can only be from a different iteration) apart from "never
    /// assigned at all" (safe — a load-time constant).
    private static func collectAssignedNames(_ node: Node, into set: inout Set<String>) {
        switch node {
        case .number, .variable:
            break
        case .assign(let name, let value):
            set.insert(name)
            collectAssignedNames(value, into: &set)
        case .unary(_, let operand):
            collectAssignedNames(operand, into: &set)
        case .binary(_, let lhs, let rhs):
            collectAssignedNames(lhs, into: &set)
            collectAssignedNames(rhs, into: &set)
        case .call(_, let args):
            for arg in args { collectAssignedNames(arg, into: &set) }
        }
    }

    /// Returns `false` the moment an unsafe read is found (short-circuits the rest of the scan —
    /// one unsafe read is enough to reject the whole program). Traversal order matches
    /// `MilkdropExpressionEvaluator.eval`'s own exact evaluation order node-for-node.
    private static func visit(_ node: Node, everAssigned: Set<String>, writtenSoFar: inout Set<String>) -> Bool {
        switch node {
        case .number:
            return true
        case .variable(let name):
            if writtenSoFar.contains(name) { return true }
            return !everAssigned.contains(name)
        case .assign(let name, let value):
            guard visit(value, everAssigned: everAssigned, writtenSoFar: &writtenSoFar) else { return false }
            writtenSoFar.insert(name)
            return true
        case .unary(_, let operand):
            return visit(operand, everAssigned: everAssigned, writtenSoFar: &writtenSoFar)
        case .binary(let op, let lhs, let rhs):
            guard visit(lhs, everAssigned: everAssigned, writtenSoFar: &writtenSoFar) else { return false }
            // `&&`/`||` short-circuit — `rhs` might not run this iteration, so (per this file's
            // header, point 6) anything it assigns is checked for read-safety but never promoted
            // into the real `writtenSoFar` going forward. A throwaway copy lets `rhs` still see
            // everything already written by `lhs` (and everything before this statement) without
            // risking a name it conditionally assigns leaking out as "guaranteed."
            if op == "&&" || op == "||" {
                var rhsScratch = writtenSoFar
                return visit(rhs, everAssigned: everAssigned, writtenSoFar: &rhsScratch)
            }
            return visit(rhs, everAssigned: everAssigned, writtenSoFar: &writtenSoFar)
        case .call(let name, let args):
            // `if(cond,thenExpr,elseExpr)` short-circuits — only one branch actually runs. `cond`
            // always runs normally; `thenExpr`/`elseExpr` are each checked for read-safety against
            // the same post-`cond` baseline, but only a name assigned in *both* branches is
            // guaranteed regardless of which one actually ran, so only that intersection gets
            // promoted into the real `writtenSoFar` (see this file's header, point 5).
            if name == "if", args.count == 3 {
                guard visit(args[0], everAssigned: everAssigned, writtenSoFar: &writtenSoFar) else { return false }
                var thenWritten = writtenSoFar
                guard visit(args[1], everAssigned: everAssigned, writtenSoFar: &thenWritten) else { return false }
                var elseWritten = writtenSoFar
                guard visit(args[2], everAssigned: everAssigned, writtenSoFar: &elseWritten) else { return false }
                let guaranteedByBoth = thenWritten.subtracting(writtenSoFar).intersection(elseWritten.subtracting(writtenSoFar))
                writtenSoFar.formUnion(guaranteedByBoth)
                return true
            }
            for arg in args {
                guard visit(arg, everAssigned: everAssigned, writtenSoFar: &writtenSoFar) else { return false }
            }
            return true
        }
    }
}
