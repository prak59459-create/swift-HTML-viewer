import Foundation

/// 内蔵 Java インタプリタのトークン種別。
enum JavaTokenKind: Equatable {
    case identifier
    case keyword
    case intLiteral
    case longLiteral
    case doubleLiteral
    case stringLiteral
    case charLiteral
    case op
    case eof
}

struct JavaToken {
    var kind: JavaTokenKind
    var text: String
    var location: SourceLocation
}

private let javaKeywords: Set<String> = [
    "class", "public", "private", "protected", "static", "final", "void",
    "int", "long", "double", "float", "boolean", "char", "byte", "short", "String",
    "if", "else", "for", "while", "do", "return", "break", "continue", "new",
    "true", "false", "null", "this", "super", "extends", "implements",
    "switch", "case", "default", "import", "package", "throw", "throws",
    "try", "catch", "finally", "interface", "abstract", "instanceof", "enum"
]

/// 内蔵 Java インタプリタの字句解析器。
struct JavaLexer {
    private let chars: [Character]
    private var index = 0
    private var line = 1
    private var column = 1
    private let diagnostics: DiagnosticBag

    init(source: String, diagnostics: DiagnosticBag) {
        self.chars = Array(source)
        self.diagnostics = diagnostics
    }

    private var current: Character? { index < chars.count ? chars[index] : nil }
    private func peek(_ offset: Int = 1) -> Character? {
        let target = index + offset
        return target < chars.count ? chars[target] : nil
    }

    private mutating func advance() -> Character? {
        guard let c = current else { return nil }
        index += 1
        if c == "\n" { line += 1; column = 1 } else { column += 1 }
        return c
    }

    private var location: SourceLocation { SourceLocation(line: line, column: column) }

    mutating func tokenize() -> [JavaToken] {
        var tokens: [JavaToken] = []
        while true {
            skipWhitespaceAndComments()
            guard let c = current else { break }
            let start = location
            if c.isLetter || c == "_" || c == "$" {
                var text = ""
                while let cc = current, cc.isLetter || cc.isNumber || cc == "_" || cc == "$" {
                    text.append(cc); _ = advance()
                }
                let kind: JavaTokenKind = javaKeywords.contains(text) ? .keyword : .identifier
                tokens.append(JavaToken(kind: kind, text: text, location: start))
                continue
            }
            if c.isNumber {
                tokens.append(readNumber(start: start))
                continue
            }
            if c == "\"" {
                tokens.append(readString(start: start))
                continue
            }
            if c == "'" {
                tokens.append(readChar(start: start))
                continue
            }
            tokens.append(readOperator(start: start))
        }
        tokens.append(JavaToken(kind: .eof, text: "", location: location))
        return tokens
    }

    private mutating func skipWhitespaceAndComments() {
        while let c = current {
            if c.isWhitespace { _ = advance(); continue }
            if c == "/" && peek() == "/" {
                while let cc = current, cc != "\n" { _ = advance() }
                continue
            }
            if c == "/" && peek() == "*" {
                _ = advance(); _ = advance()
                while let cc = current, !(cc == "*" && peek() == "/") { _ = advance() }
                _ = advance(); _ = advance()
                continue
            }
            break
        }
    }

    private mutating func readNumber(start: SourceLocation) -> JavaToken {
        var text = ""
        var isDouble = false
        while let c = current, c.isNumber || c == "_" {
            if c != "_" { text.append(c) }
            _ = advance()
        }
        if current == "." && (peek()?.isNumber ?? false) {
            isDouble = true
            text.append("."); _ = advance()
            while let c = current, c.isNumber || c == "_" {
                if c != "_" { text.append(c) }
                _ = advance()
            }
        }
        if current == "e" || current == "E" {
            isDouble = true
            text.append("e"); _ = advance()
            if current == "+" || current == "-" { text.append(current!); _ = advance() }
            while let c = current, c.isNumber { text.append(c); _ = advance() }
        }
        if current == "d" || current == "D" {
            isDouble = true; _ = advance()
        } else if current == "f" || current == "F" {
            isDouble = true; _ = advance()
        } else if current == "L" || current == "l" {
            _ = advance()
            return JavaToken(kind: .longLiteral, text: text, location: start)
        }
        return JavaToken(kind: isDouble ? .doubleLiteral : .intLiteral, text: text, location: start)
    }

    private mutating func readString(start: SourceLocation) -> JavaToken {
        _ = advance() // opening quote
        var text = ""
        while let c = current, c != "\"" {
            if c == "\\" {
                _ = advance()
                text.append(escapeChar())
            } else {
                text.append(c); _ = advance()
            }
        }
        _ = advance() // closing quote
        return JavaToken(kind: .stringLiteral, text: text, location: start)
    }

    private mutating func readChar(start: SourceLocation) -> JavaToken {
        _ = advance() // opening quote
        var text = ""
        if let c = current, c == "\\" {
            _ = advance()
            text.append(escapeChar())
        } else if let c = current {
            text.append(c); _ = advance()
        }
        if current == "'" { _ = advance() }
        return JavaToken(kind: .charLiteral, text: text, location: start)
    }

    private mutating func escapeChar() -> Character {
        guard let c = current else { return "\\" }
        _ = advance()
        switch c {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "\\": return "\\"
        case "\"": return "\""
        case "'": return "'"
        case "0": return "\0"
        default: return c
        }
    }

    private static let multiCharOperators: [String] = [
        "<<=", ">>=", ">>>", "...",
        "==", "!=", "<=", ">=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=", "%=",
        "&=", "|=", "^=", "->", "::", "<<", ">>"
    ]

    private mutating func readOperator(start: SourceLocation) -> JavaToken {
        for op in Self.multiCharOperators {
            if matches(op) {
                for _ in 0..<op.count { _ = advance() }
                return JavaToken(kind: .op, text: op, location: start)
            }
        }
        let c = advance() ?? " "
        return JavaToken(kind: .op, text: String(c), location: start)
    }

    private func matches(_ text: String) -> Bool {
        var i = index
        for ch in text {
            guard i < chars.count, chars[i] == ch else { return false }
            i += 1
        }
        return true
    }
}
