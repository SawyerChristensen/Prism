//
//  MilkdropExpressionEvaluator.swift
//  Prism
//
//  A small interpreter for the subset of Milkdrop/projectM's per-frame expression language
//  (NS-EEL — see vendor/projectm-eval/docs/Expression-Syntax.md in the projectM repo) actually
//  used by preset "per_frame_N=" lines: semicolon-separated statements, C-like operator
//  precedence, `name=expr` assignment (including chains like `a=b=1;`), and a handful of math
//  functions. This is a from-scratch Swift implementation rather than a bridge to projectM's own
//  C evaluator library — sufficient for driving the waveform-only preset variables Prism actually
//  reads (see MilkdropPresetFile.swift), without adding a C dependency to the Xcode project for it.
//
//  Unknown functions/variables don't throw — they evaluate to 0, same spirit as NS-EEL's own
//  "undeclared variables start at 0" behavior — so a preset using warp/composite-shader features
//  Prism doesn't implement degrades quietly instead of failing to load.
//
//  Tokenizing lives in MilkdropExpressionLexer.swift, parsing in MilkdropExpressionParser.swift;
//  this file is just the AST walker and builtin-function table.
//
//  Perf note (added 7/26): evaluating a parsed `Node` tree directly against a `[String: Float]`
//  dictionary (`evaluate(_ variables: inout [String: Float])` below) requires a string hash +
//  lookup for every variable read/write, and a string `switch` for every function call — a real,
//  measured cost for presets that run this hundreds to thousands of times per frame (a
//  `per_pixel_N=` mesh sweep alone is 825 evaluations/frame — see TO DO.md's performance-pass
//  notes). `resolved(against:)` below produces a `MilkdropResolvedProgram`: the same statements,
//  but with every variable name resolved to a stable integer slot in a `MilkdropVariableSlots`
//  store and every builtin function name resolved to a `MilkdropBuiltinFunction` enum case, both
//  ONCE (at resolve time, not eval time). `MilkdropResolvedProgram.evaluate(_:)` then walks that
//  resolved tree doing only array indexing and enum switches — zero string hashing — matching real
//  projectM's own compiled-bytecode evaluator (`projectm_eval_context_register_variable` resolves
//  a pointer-addressable slot once; subsequent reads/writes are a pointer dereference, no
//  dictionary at all). The original `[String: Float]`-based `evaluate`/`eval`/`callFunction` below
//  are kept exactly as they were — used as the reference implementation
//  `MilkdropExpressionEvaluatorTests.swift`/`MilkdropResolvedProgramTests.swift` check the new
//  resolved path against for byte-identical output, and still the simplest option for a program
//  that only ever runs once or twice (e.g. a shape/waveform's init code) where resolving isn't
//  worth the ceremony — see each call site (MilkdropShapeState.swift, MilkdropCustomWaveform.swift)
//  for which path it actually uses.
//

import Foundation

// MARK: - Variable storage (slot-indexed — see this file's perf note above)

/// Backs every NS-EEL variable environment in this codebase (MilkdropVisualizerModel's
/// `presetVariables`, MilkdropPerPixelMeshRuntime's `variables`, MilkdropCustomWaveformRuntime's
/// `frameVariables`/`pointVariables`, MilkdropShapeRuntime's `variables`) — replaces a raw
/// `[String: Float]` with a name->slot symbol table (`slot(for:)`, resolved once) plus O(1)
/// array-indexed storage (`value(at:)`/`setValue(_:at:)`) for hot-path code that caches its slot
/// indices up front (see MilkdropPerPixelMesh.swift/MilkdropCustomWaveform.swift/
/// MilkdropShapeState.swift for that pattern in their per-vertex/per-point/per-instance loops).
///
/// `subscript(name:)` mirrors `[String: Float]`'s own subscript exactly (nil for a never-set name,
/// matching the `variables["x"] ?? fallback` idiom used throughout this codebase) for call sites
/// where a variable is only touched once or a handful of times per frame (not in a per-vertex/
/// per-point/per-instance loop) — still hashes `name` internally, same cost as the dictionary it
/// replaces, just no longer the dominant cost anywhere after this change.
final class MilkdropVariableSlots {
    private var nameToSlot: [String: Int] = [:]
    private var values: [Float] = []

    /// Resolves `name` to a stable slot index, allocating a fresh zero-initialized slot the first
    /// time `name` is seen (matches NS-EEL's "undeclared variable starts at 0" semantics).
    /// Idempotent — multiple programs sharing one store (e.g. a shape's init program and its
    /// ongoing per-frame program) resolve the same name to the same slot, so a value one program
    /// writes is visible to the other.
    func slot(for name: String) -> Int {
        if let existing = nameToSlot[name] { return existing }
        let index = values.count
        nameToSlot[name] = index
        values.append(0)
        return index
    }

    @inline(__always) func value(at slot: Int) -> Float { values[slot] }
    @inline(__always) func setValue(_ newValue: Float, at slot: Int) { values[slot] = newValue }

    /// Bulk-seeds from a plain dictionary literal, for call sites that used to fully replace their
    /// `[String: Float]` with a literal on every preset load (see MilkdropVisualizerView.swift's
    /// `loadPreset`) — unlike a real dictionary reassignment this does not clear slots already
    /// resolved in this instance, so callers that relied on a full reset use a fresh
    /// `MilkdropVariableSlots()` instance per load instead (both existing call sites already do,
    /// since a fresh instance is needed per preset regardless).
    func load(_ dict: [String: Float]) {
        for (name, value) in dict { self[name] = value }
    }

    subscript(name: String) -> Float? {
        get { nameToSlot[name].map { values[$0] } }
        set { setValue(newValue ?? 0, at: slot(for: name)) }
    }
}

// MARK: - Builtin function resolution

/// Every NS-EEL builtin the evaluator (either path) supports, resolved once from its source-text
/// name (`resolve(_:)`) instead of a string `switch` on every single function-call evaluation.
enum MilkdropBuiltinFunction {
    case sin, cos, tan, asin, acos, atan, atan2, abs, sqrt, sqr, pow, exp, log, log10
    case min, max, sign, int, ifFn, above, below, equal, band, bor, bnot, rand
    /// Any name not in the table below — real Milkdrop scripts sometimes reference warp/
    /// shader-only helpers or custom-shape-only functions this evaluator has never supported;
    /// matches the original evaluator's `default: return 0` in `callFunction`.
    case unsupported

    static func resolve(_ name: String) -> MilkdropBuiltinFunction {
        switch name {
        case "sin": return .sin
        case "cos": return .cos
        case "tan": return .tan
        case "asin": return .asin
        case "acos": return .acos
        case "atan": return .atan
        case "atan2": return .atan2
        case "abs": return .abs
        case "sqrt": return .sqrt
        case "sqr": return .sqr
        case "pow": return .pow
        case "exp": return .exp
        case "log": return .log
        case "log10": return .log10
        case "min": return .min
        case "max": return .max
        case "sign": return .sign
        case "int": return .int
        case "if": return .ifFn
        case "above": return .above
        case "below": return .below
        case "equal": return .equal
        case "band": return .band
        case "bor": return .bor
        case "bnot": return .bnot
        case "rand": return .rand
        default: return .unsupported
        }
    }
}

/// Mirrors `Node` (MilkdropExpressionParser.swift), with every variable name resolved to a
/// `MilkdropVariableSlots` slot index and every builtin function name resolved to a
/// `MilkdropBuiltinFunction` — see this file's perf note above. Binary/unary operators are
/// deliberately left as their original `String` token (`"+"`, `"<="`, etc.) rather than also
/// resolved to an enum: Swift's string `switch` over a small, fixed set of short ASCII operator
/// tokens is materially cheaper than a `[String: Float]` dictionary hash/lookup or a 25-case
/// function-name switch, so the marginal win from resolving these too is small relative to the
/// added surface area — a deliberate, documented scope cut, not an oversight.
indirect enum ResolvedNode {
    case number(Float)
    case variable(Int)
    case assign(Int, ResolvedNode)
    case unary(String, ResolvedNode)
    case binary(String, ResolvedNode, ResolvedNode)
    case call(MilkdropBuiltinFunction, [ResolvedNode])
}

/// A `MilkdropExpressionProgram` resolved against one specific `MilkdropVariableSlots` store (see
/// `MilkdropExpressionProgram.resolved(against:)`) — `evaluate` walks this doing only array
/// indexing and enum switches, no string hashing at all.
final class MilkdropResolvedProgram {
    fileprivate let statements: [ResolvedNode]

    fileprivate init(statements: [ResolvedNode]) {
        self.statements = statements
    }

    func evaluate(_ store: MilkdropVariableSlots) {
        for statement in statements {
            _ = Self.eval(statement, store)
        }
    }

    private static func eval(_ node: ResolvedNode, _ store: MilkdropVariableSlots) -> Float {
        switch node {
        case .number(let value):
            return value
        case .variable(let slot):
            return store.value(at: slot)
        case .assign(let slot, let value):
            let result = eval(value, store)
            store.setValue(result, at: slot)
            return result
        case .unary(let op, let operand):
            let value = eval(operand, store)
            return op == "-" ? -value : (value == 0 ? 1 : 0)
        case .binary(let op, let lhs, let rhs):
            // `&&`/`||` short-circuit in real NS-EEL (vendor/projectm-eval/TreeFunctions.c's
            // `prjm_eval_func_boolean_and_op`/`_or_op` — the right operand's side effects, if any,
            // must not run when the left operand alone already determines the result) — confirmed
            // 7/26 against upstream, correcting a previous wrong assumption in this file (every
            // other binary operator has no side effects to worry about, so those still evaluate
            // both sides unconditionally).
            if op == "&&" {
                let left = eval(lhs, store)
                if left == 0 { return 0 }
                return eval(rhs, store) != 0 ? 1 : 0
            }
            if op == "||" {
                let left = eval(lhs, store)
                if left != 0 { return 1 }
                return eval(rhs, store) != 0 ? 1 : 0
            }
            let left = eval(lhs, store)
            let right = eval(rhs, store)
            switch op {
            case "+": return left + right
            case "-": return left - right
            case "*": return left * right
            case "/": return right == 0 ? 0 : left / right
            case "%": return right == 0 ? 0 : left.truncatingRemainder(dividingBy: right)
            case "<": return left < right ? 1 : 0
            case ">": return left > right ? 1 : 0
            case "<=": return left <= right ? 1 : 0
            case ">=": return left >= right ? 1 : 0
            case "==": return left == right ? 1 : 0
            case "!=": return left != right ? 1 : 0
            default: return 0
            }
        case .call(let function, let argNodes):
            // `if(cond,a,b)` short-circuits in real NS-EEL (`prjm_eval_func_if`) — only the taken
            // branch's expression (and any side effects, e.g. an assignment) actually runs, unlike
            // `above`/`below`/`equal`/`band`/`bor`/`bnot`/every other builtin, which are ordinary
            // eager 2-arg functions with no such contract. Confirmed 7/26 against upstream,
            // correcting a previous wrong assumption in this file (see this file's other short-
            // circuit fix on `&&`/`||` just above, and MilkdropExpressionParallelSafetyAnalyzer
            // .swift's matching update).
            if function == .ifFn, argNodes.count == 3 {
                let cond = eval(argNodes[0], store)
                return cond != 0 ? eval(argNodes[1], store) : eval(argNodes[2], store)
            }
            // Same eager-evaluation/no-array-allocation contract as the original evaluator's
            // `.call` case — see its own comment for why (a per_pixel_N= mesh sweep alone runs
            // ~800 evaluations/frame).
            let a0: Float = argNodes.count > 0 ? eval(argNodes[0], store) : 0
            let a1: Float = argNodes.count > 1 ? eval(argNodes[1], store) : 0
            let a2: Float = argNodes.count > 2 ? eval(argNodes[2], store) : 0
            if argNodes.count > 3 {
                for i in 3..<argNodes.count { _ = eval(argNodes[i], store) }
            }
            return callFunction(function, a0, a1, a2)
        }
    }

    private static func callFunction(_ function: MilkdropBuiltinFunction, _ a0: Float, _ a1: Float, _ a2: Float) -> Float {
        switch function {
        case .sin: return sin(a0)
        case .cos: return cos(a0)
        case .tan: return tan(a0)
        // asin/acos are only defined on [-1, 1] — a preset feeding in an unnormalized signal
        // (`bass` routinely exceeds 1, see MilkdropBeatState's minimumBassFloor) hits NaN under
        // plain IEEE rules otherwise, with nothing downstream to catch it before it reaches a
        // per-frame variable like `decay`/`zoom` and poisons the GPU feedback texture (see
        // Shaders.metal's milkdrop_sanitize4 for the fuller mechanism). Clamping to the domain
        // degrades to the nearest valid answer instead, matching this file's existing sqrt/log
        // domain-guard convention below.
        case .asin: return asin(Swift.min(1, Swift.max(-1, a0)))
        case .acos: return acos(Swift.min(1, Swift.max(-1, a0)))
        case .atan: return atan(a0)
        case .atan2: return atan2(a0, a1)
        case .abs: return abs(a0)
        case .sqrt: return a0 < 0 ? 0 : sqrt(a0)
        case .sqr: return a0 * a0
        // A negative base with a non-integer exponent is NaN under IEEE pow (e.g. `pow(x-1,
        // 0.5)` when x dips below 1) — same domain-violation-returns-0 convention as sqrt/log
        // just below, rather than letting NaN through.
        case .pow: return (a0 < 0 && a1 != a1.rounded()) ? 0 : pow(a0, a1)
        case .exp: return exp(a0)
        case .log: return a0 > 0 ? log(a0) : 0
        case .log10: return a0 > 0 ? log10(a0) : 0
        case .min: return Swift.min(a0, a1)
        case .max: return Swift.max(a0, a1)
        case .sign: return a0 > 0 ? 1 : (a0 < 0 ? -1 : 0)
        case .int: return a0.rounded(.towardZero)
        case .ifFn: return a0 != 0 ? a1 : a2
        case .above: return a0 > a1 ? 1 : 0
        case .below: return a0 < a1 ? 1 : 0
        case .equal: return a0 == a1 ? 1 : 0
        case .band: return (a0 != 0 && a1 != 0) ? 1 : 0
        case .bor: return (a0 != 0 || a1 != 0) ? 1 : 0
        case .bnot: return a0 == 0 ? 1 : 0
        case .rand: return a0 <= 0 ? 0 : Float.random(in: 0..<a0)
        case .unsupported: return 0
        }
    }
}

// MARK: - Original dictionary-based program

/// A parsed, ready-to-evaluate per-frame program. Parsing happens once at load time; `evaluate`
/// just walks the AST, so running it every rendered frame is cheap.
final class MilkdropExpressionProgram {
    /// Not `fileprivate`: consumed directly by MilkdropExpressionParallelSafetyAnalyzer.swift and
    /// MilkdropExpressionMSLTranspiler.swift (both need the original, unresolved `[Node]` tree,
    /// not the resolved-slot form `resolved(against:)` below produces) — same module, so `internal`
    /// (the default) is the right visibility rather than a bespoke accessor method.
    let statements: [Node]

    /// `nil` if the source contains no usable statements (e.g. comments-only or empty).
    init?(source: String) {
        var lexer = Lexer(source)
        var parser = Parser(tokens: lexer.tokenize())
        let parsed = parser.parseProgram()
        guard !parsed.isEmpty else { return nil }
        statements = parsed
    }

    /// Executes every statement in order against `variables`, mutating it in place. Assignment
    /// targets that already exist in `variables` are updated; new ones are inserted (matching
    /// NS-EEL's implicit variable declaration).
    func evaluate(_ variables: inout [String: Float]) {
        for statement in statements {
            _ = Self.eval(statement, &variables)
        }
    }

    /// Same as the `[String: Float]` overload above, against a `MilkdropVariableSlots` store via
    /// its string-keyed subscript — same cost profile (still hashes every access). Used by call
    /// sites whose store is a `MilkdropVariableSlots` instance but which only run this program
    /// once (e.g. init code), where resolving a program that never runs again isn't worth it — see
    /// `resolved(against:)` below for the path hot per-vertex/per-point/per-instance loops use
    /// instead.
    func evaluate(_ store: MilkdropVariableSlots) {
        for statement in statements {
            _ = Self.evalStore(statement, store)
        }
    }

    /// Resolves this program's variable/function references against `store`'s slot table — call
    /// once, right after both this program and `store` exist, and reuse the result for every
    /// subsequent per-vertex/per-point/per-instance evaluation. Every distinct variable name in
    /// this program gets a stable slot in `store` (allocated if not already present), so multiple
    /// programs sharing one store (e.g. a shape's init program, resolved separately and run once,
    /// and its ongoing per-frame program) resolve the same name to the same slot.
    func resolved(against store: MilkdropVariableSlots) -> MilkdropResolvedProgram {
        MilkdropResolvedProgram(statements: statements.map { Self.resolve($0, store) })
    }

    private static func resolve(_ node: Node, _ store: MilkdropVariableSlots) -> ResolvedNode {
        switch node {
        case .number(let value):
            return .number(value)
        case .variable(let name):
            return .variable(store.slot(for: name))
        case .assign(let name, let value):
            return .assign(store.slot(for: name), resolve(value, store))
        case .unary(let op, let operand):
            return .unary(op, resolve(operand, store))
        case .binary(let op, let lhs, let rhs):
            return .binary(op, resolve(lhs, store), resolve(rhs, store))
        case .call(let name, let argNodes):
            return .call(MilkdropBuiltinFunction.resolve(name), argNodes.map { resolve($0, store) })
        }
    }

    // Evaluates directly against a MilkdropVariableSlots' string-keyed subscript — see the
    // `evaluate(_ store:)` overload above for why this exists alongside the resolved-slot path.
    private static func evalStore(_ node: Node, _ store: MilkdropVariableSlots) -> Float {
        switch node {
        case .number(let value):
            return value
        case .variable(let name):
            return store[name] ?? 0
        case .assign(let name, let value):
            let result = evalStore(value, store)
            store[name] = result
            return result
        case .unary(let op, let operand):
            let value = evalStore(operand, store)
            return op == "-" ? -value : (value == 0 ? 1 : 0)
        case .binary(let op, let lhs, let rhs):
            // Short-circuit `&&`/`||` — see `MilkdropResolvedProgram.eval`'s matching fix for the
            // real-NS-EEL-semantics rationale (both paths must agree: this one is the reference
            // implementation the resolved-slot path is checked against for byte-identical output).
            if op == "&&" {
                let left = evalStore(lhs, store)
                if left == 0 { return 0 }
                return evalStore(rhs, store) != 0 ? 1 : 0
            }
            if op == "||" {
                let left = evalStore(lhs, store)
                if left != 0 { return 1 }
                return evalStore(rhs, store) != 0 ? 1 : 0
            }
            let left = evalStore(lhs, store)
            let right = evalStore(rhs, store)
            switch op {
            case "+": return left + right
            case "-": return left - right
            case "*": return left * right
            case "/": return right == 0 ? 0 : left / right
            case "%": return right == 0 ? 0 : left.truncatingRemainder(dividingBy: right)
            case "<": return left < right ? 1 : 0
            case ">": return left > right ? 1 : 0
            case "<=": return left <= right ? 1 : 0
            case ">=": return left >= right ? 1 : 0
            case "==": return left == right ? 1 : 0
            case "!=": return left != right ? 1 : 0
            default: return 0
            }
        case .call(let name, let argNodes):
            // Short-circuit `if(cond,a,b)` — see `MilkdropResolvedProgram.eval`'s matching fix.
            if name == "if", argNodes.count == 3 {
                let cond = evalStore(argNodes[0], store)
                return cond != 0 ? evalStore(argNodes[1], store) : evalStore(argNodes[2], store)
            }
            let a0: Float = argNodes.count > 0 ? evalStore(argNodes[0], store) : 0
            let a1: Float = argNodes.count > 1 ? evalStore(argNodes[1], store) : 0
            let a2: Float = argNodes.count > 2 ? evalStore(argNodes[2], store) : 0
            if argNodes.count > 3 {
                for i in 3..<argNodes.count { _ = evalStore(argNodes[i], store) }
            }
            return callFunction(name, a0, a1, a2)
        }
    }

    private static func eval(_ node: Node, _ vars: inout [String: Float]) -> Float {
        switch node {
        case .number(let value):
            return value
        case .variable(let name):
            return vars[name] ?? 0
        case .assign(let name, let value):
            let result = eval(value, &vars)
            vars[name] = result
            return result
        case .unary(let op, let operand):
            let value = eval(operand, &vars)
            return op == "-" ? -value : (value == 0 ? 1 : 0)
        case .binary(let op, let lhs, let rhs):
            // Short-circuit `&&`/`||` — real NS-EEL semantics (see `MilkdropResolvedProgram.eval`'s
            // matching fix). This function is the reference oracle `MilkdropExpressionEvaluatorTests
            // .swift`/`MilkdropResolvedProgramTests.swift` check every other path against for
            // byte-identical output, so it must lead this fix, not follow it.
            if op == "&&" {
                let left = eval(lhs, &vars)
                if left == 0 { return 0 }
                return eval(rhs, &vars) != 0 ? 1 : 0
            }
            if op == "||" {
                let left = eval(lhs, &vars)
                if left != 0 { return 1 }
                return eval(rhs, &vars) != 0 ? 1 : 0
            }
            let left = eval(lhs, &vars)
            let right = eval(rhs, &vars)
            switch op {
            case "+": return left + right
            case "-": return left - right
            case "*": return left * right
            case "/": return right == 0 ? 0 : left / right
            case "%": return right == 0 ? 0 : left.truncatingRemainder(dividingBy: right)
            case "<": return left < right ? 1 : 0
            case ">": return left > right ? 1 : 0
            case "<=": return left <= right ? 1 : 0
            case ">=": return left >= right ? 1 : 0
            case "==": return left == right ? 1 : 0
            case "!=": return left != right ? 1 : 0
            default: return 0
            }
        case .call(let name, let argNodes):
            // Short-circuit `if(cond,a,b)` — real NS-EEL semantics (`prjm_eval_func_if`): only the
            // taken branch's expression, including any assignment side effect, actually runs.
            if name == "if", argNodes.count == 3 {
                let cond = eval(argNodes[0], &vars)
                return cond != 0 ? eval(argNodes[1], &vars) : eval(argNodes[2], &vars)
            }
            // Every supported builtin below takes at most 3 arguments, evaluated inline instead of
            // via `argNodes.map { ... }` — that `.map` used to heap-allocate a fresh `[Float]` array
            // on *every single function call*, which dominates real cost here: a per_pixel_N= mesh
            // sweep alone runs ~800 evaluations/frame, each typically containing several sin/cos/if
            // calls, so this was tens of thousands of avoidable allocations per second even at a
            // modest frame rate. A call with more than 3 arguments (not used by any builtin here,
            // but the parser doesn't forbid it) still evaluates every extra argument for its side
            // effects — matching the original's behavior of always evaluating every argument node,
            // regardless of whether callFunction below actually reads it — just without allocating.
            let a0: Float = argNodes.count > 0 ? eval(argNodes[0], &vars) : 0
            let a1: Float = argNodes.count > 1 ? eval(argNodes[1], &vars) : 0
            let a2: Float = argNodes.count > 2 ? eval(argNodes[2], &vars) : 0
            if argNodes.count > 3 {
                for i in 3..<argNodes.count { _ = eval(argNodes[i], &vars) }
            }
            return callFunction(name, a0, a1, a2)
        }
    }

    private static func callFunction(_ name: String, _ a0: Float, _ a1: Float, _ a2: Float) -> Float {
        switch name {
        case "sin": return sin(a0)
        case "cos": return cos(a0)
        case "tan": return tan(a0)
        // See MilkdropResolvedProgram.callFunction's matching asin/acos/pow guards above — this is
        // the same domain-safety fix applied to the string-keyed evaluator path.
        case "asin": return asin(Swift.min(1, Swift.max(-1, a0)))
        case "acos": return acos(Swift.min(1, Swift.max(-1, a0)))
        case "atan": return atan(a0)
        case "atan2": return atan2(a0, a1)
        case "abs": return abs(a0)
        case "sqrt": return a0 < 0 ? 0 : sqrt(a0)
        case "sqr": return a0 * a0
        case "pow": return (a0 < 0 && a1 != a1.rounded()) ? 0 : pow(a0, a1)
        case "exp": return exp(a0)
        case "log": return a0 > 0 ? log(a0) : 0
        case "log10": return a0 > 0 ? log10(a0) : 0
        case "min": return Swift.min(a0, a1)
        case "max": return Swift.max(a0, a1)
        case "sign": return a0 > 0 ? 1 : (a0 < 0 ? -1 : 0)
        case "int": return a0.rounded(.towardZero)
        case "if": return a0 != 0 ? a1 : a2
        case "above": return a0 > a1 ? 1 : 0
        case "below": return a0 < a1 ? 1 : 0
        case "equal": return a0 == a1 ? 1 : 0
        case "band": return (a0 != 0 && a1 != 0) ? 1 : 0
        case "bor": return (a0 != 0 || a1 != 0) ? 1 : 0
        case "bnot": return a0 == 0 ? 1 : 0
        case "rand": return a0 <= 0 ? 0 : Float.random(in: 0..<a0)
        default: return 0 // Unsupported builtin (warp/shader-only helpers, custom shapes, etc.).
        }
    }
}
