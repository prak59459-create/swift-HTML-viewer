import Foundation

public enum PHPTokenKind: Equatable {
    /// `<?php` の外にある、そのまま出力される文字列。
    case inlineHTML(String)
    case variable(String)
    case identifier(String)
    case integer(Int64)
    case number(Double)
    /// `'...'` (中身はそのまま)
    case singleQuoted(String)
    /// `"..."` (変数展開は構文解析のときに行う)
    case doubleQuoted(String)
    case op(String)
    case endOfFile
}

public struct PHPToken: Equatable {
    public var kind: PHPTokenKind
    public var location: SourceLocation

    public var text: String {
        switch kind {
        case .inlineHTML: return "HTML"
        case .variable(let name): return "$" + name
        case .identifier(let name): return name
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .singleQuoted(let value), .doubleQuoted(let value): return "\"\(value)\""
        case .op(let symbol): return symbol
        case .endOfFile: return "ファイルの終わり"
        }
    }

    public func isOperator(_ symbol: String) -> Bool { kind == .op(symbol) }

    public var identifier: String? {
        if case .identifier(let name) = kind { return name }
        return nil
    }

    /// PHP のキーワードは大文字小文字を区別しない。
    public func isKeyword(_ keyword: String) -> Bool {
        identifier?.lowercased() == keyword
    }
}

/// PHP のソースをトークンに分解する。`<?php ... ?>` の外は HTML として扱う。
struct PHPLexer {
    private let characters: [Character]
    private var index = 0
    private var line = 1
    private var column = 1
    private var inPHP = false
    private let diagnostics: DiagnosticBag

    private static let operators = [
        "<<=", ">>=", "===", "!==", "**=", "...", "??=", "<=>", "?->",
        "==", "!=", "<>", "<=", ">=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=",
        ".=", "%=", "??", "->", "=>", "::", "<<", ">>", "**", "|=", "&=", "^=",
        "+", "-", "*", "/", "%", ".", "=", "<", ">", "!", "?", ":", ";", ",",
        "(", ")", "[", "]", "{", "}", "&", "|", "^", "~", "@", "$", "\\",
    ]

    init(source: String, diagnostics: DiagnosticBag) {
        self.characters = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        self.diagnostics = diagnostics
    }

    mutating func tokenize() -> [PHPToken] {
        var tokens: [PHPToken] = []
        while true {
            let token = next()
            tokens.append(token)
            if case .endOfFile = token.kind { break }
        }
        return tokens
    }

    // MARK: - 文字の操作

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
        if character == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
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

    // MARK: - トークン

    private mutating func next() -> PHPToken {
        if inPHP, emitEchoToken {
            emitEchoToken = false
            return PHPToken(kind: .identifier("echo"), location: SourceLocation(line: line, column: column))
        }
        if !inPHP {
            return readInlineHTML()
        }

        skipTrivia()
        let location = SourceLocation(line: line, column: column)
        guard let character = peek() else {
            return PHPToken(kind: .endOfFile, location: location)
        }

        // 終了タグ
        if matchesAhead("?>") {
            advance()
            advance()
            // 直後の改行 1 つは出力されない
            if peek() == "\n" { advance() }
            inPHP = false
            return next()
        }

        if character == "$", let nameStart = peek(1), nameStart.isLetter || nameStart == "_" {
            advance()
            var name = ""
            while let current = peek(), current.isLetter || current.isNumber || current == "_" {
                name.append(current)
                advance()
            }
            return PHPToken(kind: .variable(name), location: location)
        }

        if character.isLetter || character == "_" {
            var name = ""
            while let current = peek(), current.isLetter || current.isNumber || current == "_" {
                name.append(current)
                advance()
            }
            return PHPToken(kind: .identifier(name), location: location)
        }

        if character.isNumber || (character == "." && (peek(1)?.isNumber ?? false)) {
            return readNumber(location: location)
        }

        if character == "'" {
            return readSingleQuoted(location: location)
        }

        if character == "\"" {
            return readDoubleQuoted(location: location)
        }

        for symbol in PHPLexer.operators where matchesAhead(symbol) {
            for _ in symbol { advance() }
            return PHPToken(kind: .op(symbol), location: location)
        }

        let unexpected = advance().map(String.init) ?? "?"
        diagnostics.error("解釈できない文字です: '\(unexpected)'", at: location)
        return PHPToken(kind: .op(";"), location: location)
    }

    private mutating func readInlineHTML() -> PHPToken {
        let location = SourceLocation(line: line, column: column)
        var text = ""
        while !isAtEnd {
            if matchesAhead("<?php") {
                for _ in 0..<5 { advance() }
                inPHP = true
                break
            }
            if matchesAhead("<?=") {
                for _ in 0..<3 { advance() }
                inPHP = true
                emitEchoToken = true
                break
            }
            text.append(advance() ?? " ")
        }
        if text.isEmpty {
            if isAtEnd, !inPHP { return PHPToken(kind: .endOfFile, location: location) }
            return next()
        }
        return PHPToken(kind: .inlineHTML(text), location: location)
    }

    /// `<?=` を読んだ直後かどうか (次のトークンとして echo を挟む)。
    private var emitEchoToken = false

    private mutating func skipTrivia() {
        while let character = peek() {
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                advance()
            } else if character == "/", peek(1) == "/" {
                while let current = peek(), current != "\n" {
                    if matchesAhead("?>") { return }
                    advance()
                }
            } else if character == "#" {
                while let current = peek(), current != "\n" {
                    if matchesAhead("?>") { return }
                    advance()
                }
            } else if character == "/", peek(1) == "*" {
                advance()
                advance()
                while !isAtEnd {
                    if matchesAhead("*/") {
                        advance()
                        advance()
                        break
                    }
                    advance()
                }
            } else {
                break
            }
        }
    }

    private mutating func readNumber(location: SourceLocation) -> PHPToken {
        var text = ""
        if peek() == "0", let second = peek(1), second == "x" || second == "X" {
            advance()
            advance()
            var digits = ""
            while let character = peek(), character.isHexDigit || character == "_" {
                if character != "_" { digits.append(character) }
                advance()
            }
            return PHPToken(kind: .integer(Int64(digits, radix: 16) ?? 0), location: location)
        }
        if peek() == "0", let second = peek(1), second == "b" || second == "B" {
            advance()
            advance()
            var digits = ""
            while let character = peek(), character == "0" || character == "1" || character == "_" {
                if character != "_" { digits.append(character) }
                advance()
            }
            return PHPToken(kind: .integer(Int64(digits, radix: 2) ?? 0), location: location)
        }

        var isFloating = false
        while let character = peek(), character.isNumber || character == "_" {
            if character != "_" { text.append(character) }
            advance()
        }
        if peek() == ".", peek(1)?.isNumber ?? false {
            isFloating = true
            text.append(".")
            advance()
            while let character = peek(), character.isNumber || character == "_" {
                if character != "_" { text.append(character) }
                advance()
            }
        }
        if let character = peek(), character == "e" || character == "E" {
            let sign = peek(1)
            let digit = (sign == "+" || sign == "-") ? peek(2) : sign
            if digit?.isNumber == true {
                isFloating = true
                text.append("e")
                advance()
                if let sign, sign == "+" || sign == "-" {
                    text.append(sign)
                    advance()
                }
                while let character = peek(), character.isNumber {
                    text.append(character)
                    advance()
                }
            }
        }
        if isFloating {
            return PHPToken(kind: .number(Double(text) ?? 0), location: location)
        }
        if let value = Int64(text) {
            return PHPToken(kind: .integer(value), location: location)
        }
        return PHPToken(kind: .number(Double(text) ?? 0), location: location)
    }

    private mutating func readSingleQuoted(location: SourceLocation) -> PHPToken {
        advance()
        var text = ""
        while let character = peek(), character != "'" {
            if character == "\\", let next = peek(1) {
                if next == "'" || next == "\\" {
                    advance()
                    text.append(next)
                    advance()
                    continue
                }
            }
            text.append(character)
            advance()
        }
        if peek() == "'" { advance() } else { diagnostics.error("文字列が閉じていません。", at: location) }
        return PHPToken(kind: .singleQuoted(text), location: location)
    }

    private mutating func readDoubleQuoted(location: SourceLocation) -> PHPToken {
        advance()
        var text = ""
        while let character = peek(), character != "\"" {
            if character == "\\", let next = peek(1) {
                advance()
                advance()
                switch next {
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "r": text.append("\r")
                case "e": text.append("\u{1B}")
                case "v": text.append("\u{0B}")
                case "f": text.append("\u{0C}")
                case "0": text.append("\0")
                case "\\": text.append("\\")
                case "\"": text.append("\"")
                case "$": text.append("\u{1}")   // 展開しない $ の目印
                default:
                    text.append("\\")
                    text.append(next)
                }
                continue
            }
            text.append(character)
            advance()
        }
        if peek() == "\"" { advance() } else { diagnostics.error("文字列が閉じていません。", at: location) }
        return PHPToken(kind: .doubleQuoted(text), location: location)
    }
}
