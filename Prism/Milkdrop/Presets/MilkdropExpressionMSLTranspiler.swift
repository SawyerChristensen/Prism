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
//  THE SINGLE MOST IMPORTANT CORRECTNESS RULE HERE (corrected 7/26 — see below): `if(cond,a,b)` and
//  the `&&`/`||` binary operators DO short-circuit in real NS-EEL (`vendor/projectm-eval/
//  TreeFunctions.c`'s `prjm_eval_func_if`/`_and`/`_or` — only the taken branch, or the right operand
//  when it's actually needed, evaluates at all) — confirmed 7/26 directly against upstream, catching
//  a previously-wrong assumption here (this file used to eagerly evaluate every branch/operand
//  through a `milkdrop_fn_if`/`milkdrop_fn_and`/`milkdrop_fn_or` shim specifically to *avoid* MSL's
//  native short-circuiting `?:`/`&&`/`||`, believing NS-EEL didn't short-circuit; it does).
//  `if`/`&&`/`||` are now transpiled to MSL's own native `?:`/`&&`/`||` instead — which happens to
//  be a genuine simplification, not new complexity, since MSL's own short-circuit semantics for
//  those three constructs already match NS-EEL's exactly, once each is properly targeted (see
//  `transpileCall`'s `if` special case and `transpileBinary`'s `&&`/`||` cases below).
//  `above`/`below`/`equal`/`band`/`bor`/`bnot` are NOT control-flow constructs — real NS-EEL treats
//  them as ordinary eager 2-argument functions with no short-circuit contract at all (only the
//  operator forms `&&`/`||` short-circuit; the function forms `band`/`bor` explicitly don't, per
//  upstream's own comment on `prjm_eval_func_boolean_and_op`) — so those five keep routing through
//  their existing `milkdrop_fn_*` shim, unchanged. Every OTHER builtin below — even natively-1:1
//  ones like `sin`/`cos` — still routes through a small `milkdrop_fn_*` shim function taking exactly
//  3 `float` parameters (unused ones padded with a `0.0f` literal, not an expression), so that
//  MSL's own eager, always-evaluate-every-argument call semantics reproduce NS-EEL's "always
//  evaluate up to 3 arguments regardless of which builtin ignores which" contract uniformly, with
//  no special-casing needed for any of those.
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
    inline float milkdrop_fn_above(float a0, float a1, float a2) { return a0 > a1 ? 1.0 : 0.0; }
    inline float milkdrop_fn_below(float a0, float a1, float a2) { return a0 < a1 ? 1.0 : 0.0; }
    inline float milkdrop_fn_equal(float a0, float a1, float a2) { return a0 == a1 ? 1.0 : 0.0; }
    inline float milkdrop_fn_band(float a0, float a1, float a2) { return (a0 != 0.0 && a1 != 0.0) ? 1.0 : 0.0; }
    inline float milkdrop_fn_bor(float a0, float a1, float a2) { return (a0 != 0.0 || a1 != 0.0) ? 1.0 : 0.0; }
    inline float milkdrop_fn_bnot(float a0, float a1, float a2) { return a0 == 0.0 ? 1.0 : 0.0; }
    inline float milkdrop_fn_unsupported(float a0, float a1, float a2) { return 0.0; }
    inline float milkdrop_fn_not(float a0) { return a0 == 0.0 ? 1.0 : 0.0; }
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
    /// `/`/`%` route through shims for their guard formula. `&&`/`||` are native MSL `&&`/`||` on a
    /// `!= 0.0f` boolean of each side (still real short-circuiting — MSL only evaluates the right
    /// side's `!= 0.0f`, and therefore `rhs` itself, when the left side doesn't already determine
    /// the result), matching real NS-EEL's own short-circuit contract for these two operators
    /// specifically — see this file's header (corrected 7/26 from the previous, wrong assumption).
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
        case "&&": return "(((\(lhs)) != 0.0f && (\(rhs)) != 0.0f) ? 1.0f : 0.0f)"
        case "||": return "(((\(lhs)) != 0.0f || (\(rhs)) != 0.0f) ? 1.0f : 0.0f)"
        default: return "0.0f"
        }
    }

    /// Every builtin except `if` dispatches to a fixed-3-parameter shim (see this file's header on
    /// why, even for natively-1:1 ones). Missing arguments (fewer than 3 supplied) are padded with
    /// a literal `0.0f` — nothing to evaluate there, matching the evaluator's own `argNodes.count >
    /// 0 ? ... : 0` default. A 4th+ argument (no real builtin needs one, but the parser doesn't
    /// forbid it) is still evaluated for its side effects, sequenced via MSL's comma operator ahead
    /// of the actual call — matching the evaluator's own `if argNodes.count > 3 { for i in
    /// 3..<argNodes.count { _ = eval(...) } }` tail loop.
    ///
    /// `if(cond,a,b)` is the one exception: real NS-EEL short-circuits it (only the taken branch's
    /// side effects run — see this file's header), so it becomes a native MSL ternary rather than
    /// an eager shim call — `cond != 0.0f` is always evaluated (matching `a0` always running), but
    /// only one of `a`/`b` ever does, exactly matching upstream. Still uses the same `0.0f`-padding
    /// convention as every other builtin for a missing argument.
    private static func transpileCall(_ name: String, _ argExprs: [String]) -> String {
        let a0 = argExprs.count > 0 ? argExprs[0] : "0.0f"
        let a1 = argExprs.count > 1 ? argExprs[1] : "0.0f"
        let a2 = argExprs.count > 2 ? argExprs[2] : "0.0f"
        if name == "if" {
            let ternary = "((\(a0)) != 0.0f ? (\(a1)) : (\(a2)))"
            guard argExprs.count > 3 else { return ternary }
            let extras = argExprs[3...].joined(separator: ", ")
            return "(\(extras), \(ternary))"
        }
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
        // "if" is intercepted at the top of transpileCall (native ternary, not a shim) — never
        // reaches here in practice; no case needed since there's no `milkdrop_fn_if` shim anymore.
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
