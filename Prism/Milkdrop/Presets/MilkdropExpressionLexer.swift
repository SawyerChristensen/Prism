//
//  MilkdropExpressionLexer.swift
//  Prism
//
//  Tokenizer for the per-frame expression language — see MilkdropExpressionEvaluator.swift's
//  header for the overall design. Split out from that file since the lexer/parser/evaluator are
//  independently understandable pieces.
//

import Foundation

enum Token: Equatable {
    case number(Float)
    case identifier(String)
    case op(String)   // + - * / % = == != < > <= >= && || !
    case lparen, rparen, comma, semicolon
}

struct Lexer {
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
