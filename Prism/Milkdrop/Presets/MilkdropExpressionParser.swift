//
//  MilkdropExpressionParser.swift
//  Prism
//
//  Recursive-descent parser producing a Node AST from MilkdropExpressionLexer's tokens — see
//  MilkdropExpressionEvaluator.swift's header for the overall design.
//

import Foundation

indirect enum Node {
    case number(Float)
    case variable(String)
    case assign(String, Node)
    case binary(String, Node, Node)
    case unary(String, Node)
    case call(String, [Node])
}

/// C-like precedence: assignment (lowest) -> || -> && -> equality -> relational -> additive ->
/// multiplicative -> unary -> primary (highest).
struct Parser {
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
