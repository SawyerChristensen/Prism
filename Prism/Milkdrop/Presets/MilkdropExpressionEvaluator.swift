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
            let args = argNodes.map { eval($0, &vars) }
            return callFunction(name, args)
        }
    }

    private static func callFunction(_ name: String, _ args: [Float]) -> Float {
        func arg(_ i: Int) -> Float { i < args.count ? args[i] : 0 }
        switch name {
        case "sin": return sin(arg(0))
        case "cos": return cos(arg(0))
        case "tan": return tan(arg(0))
        case "asin": return asin(arg(0))
        case "acos": return acos(arg(0))
        case "atan": return atan(arg(0))
        case "atan2": return atan2(arg(0), arg(1))
        case "abs": return abs(arg(0))
        case "sqrt": return arg(0) < 0 ? 0 : sqrt(arg(0))
        case "sqr": return arg(0) * arg(0)
        case "pow": return pow(arg(0), arg(1))
        case "exp": return exp(arg(0))
        case "log": return arg(0) > 0 ? log(arg(0)) : 0
        case "log10": return arg(0) > 0 ? log10(arg(0)) : 0
        case "min": return Swift.min(arg(0), arg(1))
        case "max": return Swift.max(arg(0), arg(1))
        case "sign": return arg(0) > 0 ? 1 : (arg(0) < 0 ? -1 : 0)
        case "int": return arg(0).rounded(.towardZero)
        case "if": return arg(0) != 0 ? arg(1) : arg(2)
        case "above": return arg(0) > arg(1) ? 1 : 0
        case "below": return arg(0) < arg(1) ? 1 : 0
        case "equal": return arg(0) == arg(1) ? 1 : 0
        case "band": return (arg(0) != 0 && arg(1) != 0) ? 1 : 0
        case "bor": return (arg(0) != 0 || arg(1) != 0) ? 1 : 0
        case "bnot": return arg(0) == 0 ? 1 : 0
        case "rand": return arg(0) <= 0 ? 0 : Float.random(in: 0..<arg(0))
        default: return 0 // Unsupported builtin (warp/shader-only helpers, custom shapes, etc.).
        }
    }
}
