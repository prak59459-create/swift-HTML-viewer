import Foundation

/// C++ の字句解析器。プリプロセッサ行 (`#include` など) はここで読み飛ばす。
enum CppTokenKind: Equatable {
    case identifier
    case intLiteral
    case doubleLiteral
    case stringLiteral
    case charLiteral
    case keyword
    case punctuation
    case eof
}

struct CppToken {
    var kind: CppTokenKind
    var text: String
    /// 文字列/文字リテラルはエスケープ処理済みの値をここに入れる。
    var stringValue: String = ""
    var location: SourceLocation
}

/// C++ の予約語 (認識するもののみ)。
let cppKeywords: Set<String> = [
    "int", "double", "float", "bool", "char", "void", "auto", "string",
    "true", "false", "if", "else", "for", "while", "do", "switch", "case",
    "default", "break", "continue", "return", "struct", "class", "public",
    "private", "protected", "const", "static", "new", "delete", "this",
    "namespace", "using", "nullptr", "long", "short", "unsigned",
    "virtual", "override", "template", "typename"
]

final class CppLexer {
    private let source: [Character]
    private var index = 0
    private var line = 1
    private var column = 1
    private let diagnostics: DiagnosticBag

    init(source: String, diagnostics: DiagnosticBag) {
        self.source = Array(source)
        self.diagnostics = diagnostics
    }

    private var current: Character? { index < source.count ? source[index] : nil }
    private func peek(_ offset: Int = 1) -> Character? {
        let i = index + offset
        return i < source.count ? source[i] : nil
    }

    private func advance() -> Character? {
        guard index < source.count else { return nil }
        let character = source[index]
        index += 1
        if character == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        return character
    }

    private var location: SourceLocation { SourceLocation(line: line, column: column) }

    func tokenize() -> [CppToken] {
        var tokens: [CppToken] = []
        while true {
            skipWhitespaceCommentsAndDirectives()
            guard let c = current else { break }
            let startLocation = location
            if c.isLetter || c == "_" {
                var text = ""
                while let ch = current, ch.isLetter || ch.isNumber || ch == "_" {
                    text.append(ch)
                    _ = advance()
                }
                let kind: CppTokenKind = cppKeywords.contains(text) ? .keyword : .identifier
                tokens.append(CppToken(kind: kind, text: text, location: startLocation))
                continue
            }
            if c.isNumber {
                var text = ""
                var isDouble = false
                while let ch = current, ch.isNumber {
                    text.append(ch)
                    _ = advance()
                }
                if current == ".", let next = peek(), next.isNumber {
                    isDouble = true
                    text.append(".")
                    _ = advance()
                    while let ch = current, ch.isNumber {
                        text.append(ch)
                        _ = advance()
                    }
                }
                if current == "f" || current == "F" {
                    _ = advance() // float 接尾辞
                }
                if current == "L" || current == "l" || current == "u" || current == "U" {
                    _ = advance()
                }
                tokens.append(CppToken(kind: isDouble ? .doubleLiteral : .intLiteral, text: text, location: startLocation))
                continue
            }
            if c == "\"" {
                _ = advance()
                var value = ""
                while let ch = current, ch != "\"" {
                    if ch == "\\", let next = peek() {
                        value.append(unescape(next))
                        _ = advance(); _ = advance()
                    } else {
                        value.append(ch)
                        _ = advance()
                    }
                }
                _ = advance() // closing quote
                tokens.append(CppToken(kind: .stringLiteral, text: value, stringValue: value, location: startLocation))
                continue
            }
            if c == "'" {
                _ = advance()
                var value = ""
                while let ch = current, ch != "'" {
                    if ch == "\\", let next = peek() {
                        value.append(unescape(next))
                        _ = advance(); _ = advance()
                    } else {
                        value.append(ch)
                        _ = advance()
                    }
                }
                _ = advance()
                tokens.append(CppToken(kind: .charLiteral, text: value, stringValue: value, location: startLocation))
                continue
            }
            // 記号 (複数文字の演算子を優先的にマッチ)
            let three = threeCharOperator()
            if let three = three {
                tokens.append(CppToken(kind: .punctuation, text: three, location: startLocation))
                continue
            }
            let two = twoCharOperator()
            if let two = two {
                tokens.append(CppToken(kind: .punctuation, text: two, location: startLocation))
                continue
            }
            _ = advance()
            tokens.append(CppToken(kind: .punctuation, text: String(c), location: startLocation))
        }
        tokens.append(CppToken(kind: .eof, text: "", location: location))
        return tokens
    }

    private func unescape(_ c: Character) -> Character {
        switch c {
        case "n": return "\n"
        case "t": return "\t"
        case "\\": return "\\"
        case "\"": return "\""
        case "'": return "'"
        case "0": return "\0"
        case "r": return "\r"
        default: return c
        }
    }

    private static let threeCharOps: Set<String> = ["<<=", ">>="]
    private static let twoCharOps: Set<String> = [
        "<<", ">>", "==", "!=", "<=", ">=", "&&", "||", "++", "--",
        "+=", "-=", "*=", "/=", "%=", "->", "::"
    ]

    private func threeCharOperator() -> String? {
        guard let a = current, let b = peek(1), let cc = peek(2) else { return nil }
        let candidate = String([a, b, cc])
        if Self.threeCharOps.contains(candidate) {
            _ = advance(); _ = advance(); _ = advance()
            return candidate
        }
        return nil
    }

    private func twoCharOperator() -> String? {
        guard let a = current, let b = peek(1) else { return nil }
        let candidate = String([a, b])
        if Self.twoCharOps.contains(candidate) {
            _ = advance(); _ = advance()
            return candidate
        }
        return nil
    }

    private func skipWhitespaceCommentsAndDirectives() {
        while true {
            if let c = current, c.isWhitespace {
                _ = advance()
                continue
            }
            if current == "/", peek() == "/" {
                while let c = current, c != "\n" { _ = advance() }
                continue
            }
            if current == "/", peek() == "*" {
                _ = advance(); _ = advance()
                while let c = current, !(c == "*" && peek() == "/") { _ = advance() }
                _ = advance(); _ = advance()
                continue
            }
            if current == "#" {
                // プリプロセッサ指令 (#include, #define など) は行末まで読み飛ばす。
                while let c = current, c != "\n" { _ = advance() }
                continue
            }
            break
        }
    }
}
