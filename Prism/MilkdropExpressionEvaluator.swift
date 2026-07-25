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

import Foundation

private enum Token: Equatable {
    case number(Float)
    case identifier(String)
    case op(String)   // + - * / % = == != < > <= >= && || !
    case lparen, rparen, comma, semicolon
}

private struct Lexer {
    private let chars: [Character]
    private var index = 0

    init(_ source: String) {
        chars = Array(source)
    }

    mutating func tokenize() -> [Token] {
        var tokens: [Token] = []
        while let token = next() {
            tokens.append(token)
        }
        return tokens
    }

    private mutating func next() -> Token? {
        skipWhitespaceAndComments()
        guard index < chars.count else { return nil }
        let c = chars[index]

        if c.isNumber || (c == "." && index + 1 < chars.count && chars[index + 1].isNumber) {
            return number()
        }
        if c.isLetter || c == "_" {
            return identifier()
        }
        switch c {
        case "(": index += 1; return .lparen
        case ")": index += 1; return .rparen
        case ",": index += 1; return .comma
        case ";": index += 1; return .semicolon
        case "=", "!", "<", ">":
            index += 1
            if index < chars.count, chars[index] == "=" {
                index += 1
                return .op(String(c) + "=")
            }
            return .op(String(c))
        case "&":
            index += 1
            if index < chars.count, chars[index] == "&" { index += 1 }
            return .op("&&")
        case "|":
            index += 1
            if index < chars.count, chars[index] == "|" { index += 1 }
            return .op("||")
        case "+", "-", "*", "/", "%":
            index += 1
            return .op(String(c))
        default:
            // Unrecognized character (e.g. stray preset syntax we don't support) — skip it rather
            // than aborting the whole program.
            index += 1
            return next()
        }
    }

    private mutating func skipWhitespaceAndComments() {
        while index < chars.count {
            let c = chars[index]
            if c.isWhitespace {
                index += 1
            } else if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
            } else {
                break
            }
        }
    }

    private mutating func number() -> Token {
        var text = ""
        while index < chars.count, chars[index].isNumber || chars[index] == "." {
            text.append(chars[index])
            index += 1
        }
        if index < chars.count, chars[index] == "e" || chars[index] == "E" {
            var lookahead = index + 1
            if lookahead < chars.count, chars[lookahead] == "+" || chars[lookahead] == "-" { lookahead += 1 }
            if lookahead < chars.count, chars[lookahead].isNumber {
                text.append(chars[index])
                index += 1
                while index < chars.count, chars[index] == "+" || chars[index] == "-" || chars[index].isNumber {
                    text.append(chars[index])
                    index += 1
                }
            }
        }
        return .number(Float(text) ?? 0)
    }

    private mutating func identifier() -> Token {
        var text = ""
        while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" {
            text.append(chars[index])
            index += 1
        }
        return .identifier(text)
    }
}

private indirect enum Node {
    case number(Float)
    case variable(String)
    case assign(String, Node)
    case binary(String, Node, Node)
    case unary(String, Node)
    case call(String, [Node])
}

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

/// Recursive-descent parser, C-like precedence: assignment (lowest) -> || -> && -> equality ->
/// relational -> additive -> multiplicative -> unary -> primary (highest).
private struct Parser {
    private let tokens: [Token]
    private var pos = 0

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    mutating func parseProgram() -> [Node] {
        var statements: [Node] = []
        while pos < tokens.count {
            while peek() == .semicolon { pos += 1 }
            guard pos < tokens.count else { break }
            statements.append(parseExpr())
            while peek() == .semicolon { pos += 1 }
        }
        return statements
    }

    private func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

    private mutating func parseExpr() -> Node {
        if case .identifier(let name) = peek(), pos + 1 < tokens.count, tokens[pos + 1] == .op("=") {
            pos += 2
            let value = parseExpr()
            return .assign(name, value)
        }
        return parseOr()
    }

    private mutating func parseOr() -> Node {
        var node = parseAnd()
        while peek() == .op("||") {
            pos += 1
            node = .binary("||", node, parseAnd())
        }
        return node
    }

    private mutating func parseAnd() -> Node {
        var node = parseEquality()
        while peek() == .op("&&") {
            pos += 1
            node = .binary("&&", node, parseEquality())
        }
        return node
    }

    private mutating func parseEquality() -> Node {
        var node = parseRelational()
        while let t = peek(), t == .op("==") || t == .op("!=") {
            guard case .op(let o) = t else { break }
            pos += 1
            node = .binary(o, node, parseRelational())
        }
        return node
    }

    private mutating func parseRelational() -> Node {
        var node = parseAdditive()
        while let t = peek(), t == .op("<") || t == .op(">") || t == .op("<=") || t == .op(">=") {
            guard case .op(let o) = t else { break }
            pos += 1
            node = .binary(o, node, parseAdditive())
        }
        return node
    }

    private mutating func parseAdditive() -> Node {
        var node = parseMultiplicative()
        while let t = peek(), t == .op("+") || t == .op("-") {
            guard case .op(let o) = t else { break }
            pos += 1
            node = .binary(o, node, parseMultiplicative())
        }
        return node
    }

    private mutating func parseMultiplicative() -> Node {
        var node = parseUnary()
        while let t = peek(), t == .op("*") || t == .op("/") || t == .op("%") {
            guard case .op(let o) = t else { break }
            pos += 1
            node = .binary(o, node, parseUnary())
        }
        return node
    }

    private mutating func parseUnary() -> Node {
        if let t = peek(), t == .op("-") || t == .op("!") {
            guard case .op(let o) = t else { fatalError("unreachable") }
            pos += 1
            return .unary(o, parseUnary())
        }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> Node {
        guard let t = peek() else { return .number(0) }
        switch t {
        case .number(let value):
            pos += 1
            return .number(value)
        case .identifier(let name):
            pos += 1
            if peek() == .lparen {
                pos += 1
                var args: [Node] = []
                if peek() != .rparen {
                    args.append(parseExpr())
                    while peek() == .comma {
                        pos += 1
                        args.append(parseExpr())
                    }
                }
                if peek() == .rparen { pos += 1 }
                return .call(name, args)
            }
            return .variable(name)
        case .lparen:
            pos += 1
            let node = parseExpr()
            if peek() == .rparen { pos += 1 }
            return node
        default:
            // Stray token (stray comma, unmatched paren, etc.) — consume it and yield a neutral
            // value instead of getting stuck, so one malformed statement doesn't wedge the parser.
            pos += 1
            return .number(0)
        }
    }
}
