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

import Foundation

/// A parsed, ready-to-evaluate per-frame program. Parsing happens once at load time; `evaluate`
/// just walks the AST, so running it every rendered frame is cheap.
final class MilkdropExpressionProgram {
    private let statements: [Node]

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
            case "&&": return (left != 0 && right != 0) ? 1 : 0
            case "||": return (left != 0 || right != 0) ? 1 : 0
            default: return 0
            }
        case .call(let name, let argNodes):
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
        case "asin": return asin(a0)
        case "acos": return acos(a0)
        case "atan": return atan(a0)
        case "atan2": return atan2(a0, a1)
        case "abs": return abs(a0)
        case "sqrt": return a0 < 0 ? 0 : sqrt(a0)
        case "sqr": return a0 * a0
        case "pow": return pow(a0, a1)
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
