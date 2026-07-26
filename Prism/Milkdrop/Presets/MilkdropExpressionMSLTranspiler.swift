//
//  MilkdropExpressionMSLTranspiler.swift
//  Prism
//
//  Part of the Tier-3 GPU-transpile work (see MilkdropExpressionParallelSafetyAnalyzer.swift's
//  header for the correctness precondition this transpiler's caller must check first). Translates
//  an already-parsed `Node` AST (MilkdropExpressionParser.swift) directly into Metal Shading
//  Language source, mirroring `MilkdropExpressionEvaluator.eval`/`callFunction` case-for-case —
//  much simpler than MilkdropShaderTranslator.swift's HLSL-source-text translation, since the
//  input here is already a structured tree, not text to scan/pattern-match.
//
//  THE SINGLE MOST IMPORTANT CORRECTNESS RULE HERE: `if`/`above`/`below`/`equal`/`band`/`bor`/
//  `bnot`, and the `&&`/`||` binary operators, must all become ordinary MSL *function calls* —
//  never MSL's native `?:`/`&&`/`||`. Those MSL operators are short-circuit/lazily evaluated;
//  NS-EEL's are not — confirmed directly against `MilkdropExpressionEvaluator.eval`'s `.call` case
//  (evaluates `a0`/`a1`/`a2` unconditionally before `callFunction` even looks at which builtin it
//  is) and its `.binary` case (evaluates `left`/`right` unconditionally before the operator
//  switch). `if(x>0, y=1, z=2)` must always assign *both* y and z; a naive "looks like C, translate
//  directly" mapping to `x>0 ? (y=1) : (z=2)` would silently drop the untaken branch's side effect
//  on real GPU hardware. Every builtin below — even natively-1:1 ones like `sin`/`cos` — routes
//  through a small `milkdrop_fn_*` shim function taking exactly 3 `float` parameters (unused
//  ones padded with a `0.0f` literal, not an expression), so that MSL's own eager, always-evaluate-
//  every-argument call semantics reproduce NS-EEL's "always evaluate up to 3 arguments regardless
//  of which builtin ignores which" contract uniformly, with no special-casing per builtin.
//
//  Other guard formulas (`/`, `%`, `sqrt`, `log`, `log10`) reproduce
//  `MilkdropExpressionEvaluator.callFunction`'s exact guards verbatim (e.g. `right == 0 ? 0 :
//  left/right`) rather than relying on IEEE inf/nan, which MSL doesn't guarantee handles the same
//  way as Swift in every case (especially under fast-math — see the caller's `MTLCompileOptions`).
//
//  Every NS-EEL-sourced identifier (built-in or custom) is emitted with a `v_` prefix in the
//  generated MSL (`zoom` -> `v_zoom`) to guarantee no collision with an MSL/C++ reserved word a
//  preset author's arbitrary variable name might otherwise happen to match (`float`, `class`,
//  `texture2d`, etc.) — the caller's surrounding template must use the same convention for
//  whichever built-in locals it seeds.
//

import Foundation

enum MilkdropExpressionMSLTranspiler {
    /// A successfully transpiled program.
    struct Result {
        /// Semicolon-terminated MSL statements implementing the program, one per input statement,
        /// in order — paste directly into a function body, after `shimFunctions` and a `float
        /// v_<name> = 0;` declaration for each of `customVariableNames`.
        var body: String
        /// Every non-builtin variable name referenced anywhere in the program (read or written) —
        /// the caller must declare a `float v_<name> = 0;` local for each before `body` runs (MSL
        /// requires explicit declaration; NS-EEL's implicit "undeclared variable starts at 0" is
        /// reproduced this way). Sorted for stable, reproducible output.
        var customVariableNames: [String]
    }

    /// The MSL identifier a given NS-EEL name maps to — see this file's header on why every name
    /// is prefixed, not just ones that happen to collide with a reserved word.
    static func mslIdentifier(for name: String) -> String {
        "v_\(name)"
    }

    /// Shim function definitions every transpiled `Result.body` may call into — must be included
    /// verbatim in the surrounding MSL source, once, before any transpiled body. See this file's
    /// header for why these exist instead of native MSL operators/control flow.
    static let shimFunctions = """
    inline float milkdrop_fn_sin(float a0, float a1, float a2) { return sin(a0); }
    inline float milkdrop_fn_cos(float a0, float a1, float a2) { return cos(a0); }
    inline float milkdrop_fn_tan(float a0, float a1, float a2) { return tan(a0); }
    inline float milkdrop_fn_asin(float a0, float a1, float a2) { return asin(a0); }
    inline float milkdrop_fn_acos(float a0, float a1, float a2) { return acos(a0); }
    inline float milkdrop_fn_atan(float a0, float a1, float a2) { return atan(a0); }
    inline float milkdrop_fn_atan2(float a0, float a1, float a2) { return atan2(a0, a1); }
    inline float milkdrop_fn_abs(float a0, float a1, float a2) { return abs(a0); }
    inline float milkdrop_fn_sqrt(float a0, float a1, float a2) { return a0 < 0.0 ? 0.0 : sqrt(a0); }
    inline float milkdrop_fn_sqr(float a0, float a1, float a2) { return a0 * a0; }
    inline float milkdrop_fn_pow(float a0, float a1, float a2) { return pow(a0, a1); }
    inline float milkdrop_fn_exp(float a0, float a1, float a2) { return exp(a0); }
    inline float milkdrop_fn_log(float a0, float a1, float a2) { return a0 > 0.0 ? log(a0) : 0.0; }
    inline float milkdrop_fn_log10(float a0, float a1, float a2) { return a0 > 0.0 ? log10(a0) : 0.0; }
    inline float milkdrop_fn_min(float a0, float a1, float a2) { return min(a0, a1); }
    inline float milkdrop_fn_max(float a0, float a1, float a2) { return max(a0, a1); }
    inline float milkdrop_fn_sign(float a0, float a1, float a2) { return a0 > 0.0 ? 1.0 : (a0 < 0.0 ? -1.0 : 0.0); }
    inline float milkdrop_fn_int(float a0, float a1, float a2) { return trunc(a0); }
    inline float milkdrop_fn_if(float a0, float a1, float a2) { return a0 != 0.0 ? a1 : a2; }
    inline float milkdrop_fn_above(float a0, float a1, float a2) { return a0 > a1 ? 1.0 : 0.0; }
    inline float milkdrop_fn_below(float a0, float a1, float a2) { return a0 < a1 ? 1.0 : 0.0; }
    inline float milkdrop_fn_equal(float a0, float a1, float a2) { return a0 == a1 ? 1.0 : 0.0; }
    inline float milkdrop_fn_band(float a0, float a1, float a2) { return (a0 != 0.0 && a1 != 0.0) ? 1.0 : 0.0; }
    inline float milkdrop_fn_bor(float a0, float a1, float a2) { return (a0 != 0.0 || a1 != 0.0) ? 1.0 : 0.0; }
    inline float milkdrop_fn_bnot(float a0, float a1, float a2) { return a0 == 0.0 ? 1.0 : 0.0; }
    inline float milkdrop_fn_unsupported(float a0, float a1, float a2) { return 0.0; }
    inline float milkdrop_fn_not(float a0) { return a0 == 0.0 ? 1.0 : 0.0; }
    inline float milkdrop_fn_and(float a0, float a1) { return (a0 != 0.0 && a1 != 0.0) ? 1.0 : 0.0; }
    inline float milkdrop_fn_or(float a0, float a1) { return (a0 != 0.0 || a1 != 0.0) ? 1.0 : 0.0; }
    inline float milkdrop_fn_div(float a, float b) { return b == 0.0 ? 0.0 : a / b; }
    inline float milkdrop_fn_mod(float a, float b) { return b == 0.0 ? 0.0 : fmod(a, b); }
    """

    /// Transpiles `statements` into MSL, or `nil` if the program uses a construct this transpiler
    /// doesn't support (currently just `rand()` — no safe GPU equivalent preserving
    /// per-invocation statistical independence without extra machinery not worth it for v1) — same
    /// `nil`-on-any-failure contract as `MilkdropShaderTranslator.translate`, so a caller always
    /// has a safe, known-good fallback (the existing CPU interpreter) to use instead.
    static func transpile(_ statements: [Node], builtins: Set<String>) -> Result? {
        var customNames: Set<String> = []
        var lines: [String] = []
        for statement in statements {
            guard let expr = transpileNode(statement, builtins: builtins, customNames: &customNames) else { return nil }
            lines.append("\(expr);")
        }
        return Result(body: lines.joined(separator: "\n"), customVariableNames: customNames.sorted())
    }

    private static func transpileNode(_ node: Node, builtins: Set<String>, customNames: inout Set<String>) -> String? {
        switch node {
        case .number(let value):
            return "\(value)f"
        case .variable(let name):
            if !builtins.contains(name) { customNames.insert(name) }
            return mslIdentifier(for: name)
        case .assign(let name, let value):
            guard let valueExpr = transpileNode(value, builtins: builtins, customNames: &customNames) else { return nil }
            if !builtins.contains(name) { customNames.insert(name) }
            return "(\(mslIdentifier(for: name)) = \(valueExpr))"
        case .unary(let op, let operand):
            guard let operandExpr = transpileNode(operand, builtins: builtins, customNames: &customNames) else { return nil }
            return op == "-" ? "(-(\(operandExpr)))" : "milkdrop_fn_not(\(operandExpr))"
        case .binary(let op, let lhs, let rhs):
            guard let lhsExpr = transpileNode(lhs, builtins: builtins, customNames: &customNames),
                  let rhsExpr = transpileNode(rhs, builtins: builtins, customNames: &customNames)
            else { return nil }
            return transpileBinary(op, lhsExpr, rhsExpr)
        case .call(let name, let argNodes):
            guard name != "rand" else { return nil }
            var argExprs: [String] = []
            for arg in argNodes {
                guard let expr = transpileNode(arg, builtins: builtins, customNames: &customNames) else { return nil }
                argExprs.append(expr)
            }
            return transpileCall(name, argExprs)
        }
    }

    /// `+`/`-`/`*` are native MSL operators (no short-circuit risk — arithmetic always evaluates
    /// both operands in both languages). Comparisons are an explicit ternary on the comparison
    /// itself (safe: the comparison IS the condition, always evaluated, unlike a ternary's
    /// branches) rather than a shim, since MSL has no native "returns 1.0/0.0" comparison form.
    /// `/`/`%`/`&&`/`||` route through shims — `/`/`%` for the guard formula, `&&`/`||` for eager
    /// (non-short-circuit) evaluation — see this file's header.
    private static func transpileBinary(_ op: String, _ lhs: String, _ rhs: String) -> String {
        switch op {
        case "+": return "(\(lhs) + \(rhs))"
        case "-": return "(\(lhs) - \(rhs))"
        case "*": return "(\(lhs) * \(rhs))"
        case "/": return "milkdrop_fn_div(\(lhs), \(rhs))"
        case "%": return "milkdrop_fn_mod(\(lhs), \(rhs))"
        case "<": return "((\(lhs)) < (\(rhs)) ? 1.0f : 0.0f)"
        case ">": return "((\(lhs)) > (\(rhs)) ? 1.0f : 0.0f)"
        case "<=": return "((\(lhs)) <= (\(rhs)) ? 1.0f : 0.0f)"
        case ">=": return "((\(lhs)) >= (\(rhs)) ? 1.0f : 0.0f)"
        case "==": return "((\(lhs)) == (\(rhs)) ? 1.0f : 0.0f)"
        case "!=": return "((\(lhs)) != (\(rhs)) ? 1.0f : 0.0f)"
        case "&&": return "milkdrop_fn_and(\(lhs), \(rhs))"
        case "||": return "milkdrop_fn_or(\(lhs), \(rhs))"
        default: return "0.0f"
        }
    }

    /// Every builtin dispatches to a fixed-3-parameter shim (see this file's header on why, even
    /// for natively-1:1 ones). Missing arguments (fewer than 3 supplied) are padded with a literal
    /// `0.0f` — nothing to evaluate there, matching the evaluator's own `argNodes.count > 0 ? ... :
    /// 0` default. A 4th+ argument (no real builtin needs one, but the parser doesn't forbid it) is
    /// still evaluated for its side effects, sequenced via MSL's comma operator ahead of the actual
    /// call — matching the evaluator's own `if argNodes.count > 3 { for i in 3..<argNodes.count { _
    /// = eval(...) } }` tail loop.
    private static func transpileCall(_ name: String, _ argExprs: [String]) -> String {
        let a0 = argExprs.count > 0 ? argExprs[0] : "0.0f"
        let a1 = argExprs.count > 1 ? argExprs[1] : "0.0f"
        let a2 = argExprs.count > 2 ? argExprs[2] : "0.0f"
        let call = "\(shimName(for: name))(\(a0), \(a1), \(a2))"
        guard argExprs.count > 3 else { return call }
        let extras = argExprs[3...].joined(separator: ", ")
        return "(\(extras), \(call))"
    }

    private static func shimName(for name: String) -> String {
        switch name {
        case "sin": return "milkdrop_fn_sin"
        case "cos": return "milkdrop_fn_cos"
        case "tan": return "milkdrop_fn_tan"
        case "asin": return "milkdrop_fn_asin"
        case "acos": return "milkdrop_fn_acos"
        case "atan": return "milkdrop_fn_atan"
        case "atan2": return "milkdrop_fn_atan2"
        case "abs": return "milkdrop_fn_abs"
        case "sqrt": return "milkdrop_fn_sqrt"
        case "sqr": return "milkdrop_fn_sqr"
        case "pow": return "milkdrop_fn_pow"
        case "exp": return "milkdrop_fn_exp"
        case "log": return "milkdrop_fn_log"
        case "log10": return "milkdrop_fn_log10"
        case "min": return "milkdrop_fn_min"
        case "max": return "milkdrop_fn_max"
        case "sign": return "milkdrop_fn_sign"
        case "int": return "milkdrop_fn_int"
        case "if": return "milkdrop_fn_if"
        case "above": return "milkdrop_fn_above"
        case "below": return "milkdrop_fn_below"
        case "equal": return "milkdrop_fn_equal"
        case "band": return "milkdrop_fn_band"
        case "bor": return "milkdrop_fn_bor"
        case "bnot": return "milkdrop_fn_bnot"
        default: return "milkdrop_fn_unsupported" // Matches the evaluator's own `default: return 0`.
        }
    }
}
