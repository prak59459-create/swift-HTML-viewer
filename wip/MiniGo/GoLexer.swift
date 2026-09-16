import Foundation

/// Go のソースを表すトークンの種類。
public enum GoTokenKind: Equatable {
    case identifier(String)
    case integer(Int)
    case double(Double)
    case string(String)
    case op(String)
    case endOfFile
}

public struct GoToken: Equatable {
    public var kind: GoTokenKind
    public var location: SourceLocation
    /// 直前に改行があったか (Go はセミコロン自動挿入があるため必要)。
    public var precededByNewline: Bool

    public var identifier: String? {
        if case .identifier(let name) = kind { return name }
        return nil
    }

    public func isOperator(_ symbol: String) -> Bool { kind == .op(symbol) }
    public func isKeyword(_ keyword: String) -> Bool { identifier == keyword }

    public var text: String {
        switch kind {
        case .identifier(let name): return name
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        case .string: return "文字列"
        case .op(let symbol): return symbol
        case .endOfFile: return "ファイルの終わり"
        }
    }
}

/// Go のソースをトークンに分解する。
struct GoLexer {
    private let characters: [Character]
    private var index = 0
    private var line = 1
    private var column = 1
    private let diagnostics: DiagnosticBag

    private static let operators = [
        "<<=", ">>=", "&^=",
        "...", "<<", ">>", "&^",
        "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=",
        "&=", "|=", "^=", "++", "--", ":=", "->",
        "+", "-", "*", "/", "%", "=", "<", ">", "!", "?", ":", ";", ",", ".",
        "(", ")", "[", "]", "{", "}", "&", "|", "^", "~",
    ]

    static let keywords: Set<String> = [
        "package", "import", "func", "var", "const", "type", "struct", "interface",
        "map", "chan", "if", "else", "for", "range", "switch", "case", "default",
        "break", "continue", "return", "go", "defer", "select", "fallthrough",
        "true", "false", "nil", "iota", "int", "int64", "float64", "string", "bool", "byte", "rune", "error",
    ]

    init(source: String, diagnostics: DiagnosticBag) {
        self.characters = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        self.diagnostics = diagnostics
    }

    mutating func tokenize() -> [GoToken] {
        var tokens: [GoToken] = []
        while true {
            let token = next()
            tokens.append(token)
            if case .endOfFile = token.kind { break }
        }
        return tokens
    }

    private var isAtEnd: Bool { index >= characters.count }

    private func peek(_ offset: Int = 0) -> Character? {
        let position = index + offset
        return position < characters.count ? characters[position] : nil
    }

    @discardableResult
    private mutating func advance() -> Character? {
        guard index < characters.count else { return nil }
        let character = characters[index]
        index += 1
        if character == "\n" { line += 1; column = 1 } else { column += 1 }
        return character
    }

    private func matchesAhead(_ text: String) -> Bool {
        let symbol = Array(text)
        guard index + symbol.count <= characters.count else { return false }
        for (offset, expected) in symbol.enumerated() where characters[index + offset] != expected {
            return false
        }
        return true
    }

    private mutating func skipTrivia(sawNewline: inout Bool) {
        while let character = peek() {
            if character == "\n" {
                sawNewline = true
                advance()
            } else if character == " " || character == "\t" || character == "\r" {
                advance()
            } else if character == "/", peek(1) == "/" {
                while let current = peek(), current != "\n" { advance() }
            } else if character == "/", peek(1) == "*" {
                advance(); advance()
                while !isAtEnd, !matchesAhead("*/") {
                    if peek() == "\n" { sawNewline = true }
                    advance()
                }
                advance(); advance()
            } else {
                break
            }
        }
    }

    private mutating func next() -> GoToken {
        var sawNewline = false
        skipTrivia(sawNewline: &sawNewline)
        let location = SourceLocation(line: line, column: column)
        guard let character = peek() else {
            return GoToken(kind: .endOfFile, location: location, precededByNewline: sawNewline)
        }

        if character.isLetter || character == "_" {
            var name = ""
            while let current = peek(), current.isLetter || current.isNumber || current == "_" {
                name.append(current)
                advance()
            }
            return GoToken(kind: .identifier(name), location: location, precededByNewline: sawNewline)
        }

        if character.isNumber {
            return readNumber(location: location, sawNewline: sawNewline)
        }

        if character == "\"" {
            return readString(location: location, sawNewline: sawNewline)
        }
        if character == "`" {
            return readRawString(location: location, sawNewline: sawNewline)
        }
        if character == "'" {
            return readRune(location: location, sawNewline: sawNewline)
        }

        for symbol in GoLexer.operators where matchesAhead(symbol) {
            for _ in symbol { advance() }
            return GoToken(kind: .op(symbol), location: location, precededByNewline: sawNewline)
        }

        let unexpected = advance().map(String.init) ?? "?"
        diagnostics.error("解釈できない文字です: '\(unexpected)'", at: location)
        return GoToken(kind: .op(";"), location: location, precededByNewline: sawNewline)
    }

    private mutating func readNumber(location: SourceLocation, sawNewline: Bool) -> GoToken {
        var text = ""
        var isDouble = false
        while let character = peek(), character.isNumber || character == "_" {
            if character != "_" { text.append(character) }
            advance()
        }
        if peek() == ".", let next = peek(1), next.isNumber {
            isDouble = true
            text.append(".")
            advance()
            while let character = peek(), character.isNumber {
                text.append(character)
                advance()
            }
        }
        if let character = peek(), character == "e" || character == "E" {
            let sign = peek(1)
            let digit = (sign == "+" || sign == "-") ? peek(2) : sign
            if digit?.isNumber == true {
                isDouble = true
                text.append("e")
                advance()
                if let sign, sign == "+" || sign == "-" { text.append(sign); advance() }
                while let character = peek(), character.isNumber { text.append(character); advance() }
            }
        }
        if isDouble {
            return GoToken(kind: .double(Double(text) ?? 0), location: location, precededByNewline: sawNewline)
        }
        return GoToken(kind: .integer(Int(text) ?? 0), location: location, precededByNewline: sawNewline)
    }

    private mutating func readString(location: SourceLocation, sawNewline: Bool) -> GoToken {
        advance()
        var text = ""
        while let character = peek(), character != "\"" {
            if character == "\\", let next = peek(1) {
                advance(); advance()
                switch next {
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "r": text.append("\r")
                case "\\": text.append("\\")
                case "\"": text.append("\"")
                case "'": text.append("'")
                default: text.append(next)
                }
                continue
            }
            if character == "\n" {
                diagnostics.error("文字列が閉じていません。", at: location)
                break
            }
            text.append(character)
            advance()
        }
        if peek() == "\"" { advance() }
        return GoToken(kind: .string(text), location: location, precededByNewline: sawNewline)
    }

    private mutating func readRawString(location: SourceLocation, sawNewline: Bool) -> GoToken {
        advance()
        var text = ""
        while let character = peek(), character != "`" {
            text.append(character)
            advance()
        }
        if peek() == "`" { advance() }
        return GoToken(kind: .string(text), location: location, precededByNewline: sawNewline)
    }

    private mutating func readRune(location: SourceLocation, sawNewline: Bool) -> GoToken {
        advance()
        var value: Int = 0
        if let character = peek(), character == "\\", let next = peek(1) {
            advance(); advance()
            switch next {
            case "n": value = 10
            case "t": value = 9
            case "r": value = 13
            case "\\": value = 92
            case "'": value = 39
            case "0": value = 0
            default: value = Int(next.asciiValue ?? 0)
            }
        } else if let character = peek() {
            value = Int(character.unicodeScalars.first!.value)
            advance()
        }
        if peek() == "'" { advance() }
        return GoToken(kind: .integer(value), location: location, precededByNewline: sawNewline)
    }
}
