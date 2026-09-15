import Foundation

/// C のキーワード。
public enum Keyword: String, Equatable, CaseIterable {
    case void, char, short, int, long, float, double, signed, unsigned
    case structKeyword = "struct"
    case union
    case enumKeyword = "enum"
    case typedef, staticKeyword = "static", externKeyword = "extern"
    case constKeyword = "const", volatile, sizeofKeyword = "sizeof"
    case ifKeyword = "if", elseKeyword = "else"
    case whileKeyword = "while", doKeyword = "do", forKeyword = "for"
    case switchKeyword = "switch", caseKeyword = "case", defaultKeyword = "default"
    case breakKeyword = "break", continueKeyword = "continue", returnKeyword = "return"
    case gotoKeyword = "goto"
}

/// 記号。長いものから順に照合する。
public enum Punctuator: String, Equatable, CaseIterable {
    case ellipsis = "..."
    case shiftLeftAssign = "<<=", shiftRightAssign = ">>="
    case arrow = "->", increment = "++", decrement = "--"
    case shiftLeft = "<<", shiftRight = ">>"
    case lessEqual = "<=", greaterEqual = ">=", equal = "==", notEqual = "!="
    case logicalAnd = "&&", logicalOr = "||"
    case plusAssign = "+=", minusAssign = "-=", starAssign = "*=", slashAssign = "/="
    case percentAssign = "%=", ampersandAssign = "&=", pipeAssign = "|=", caretAssign = "^="
    case leftParen = "(", rightParen = ")"
    case leftBrace = "{", rightBrace = "}"
    case leftBracket = "[", rightBracket = "]"
    case semicolon = ";", comma = ",", dot = "."
    case plus = "+", minus = "-", star = "*", slash = "/", percent = "%"
    case less = "<", greater = ">", assign = "="
    case ampersand = "&", pipe = "|", caret = "^", tilde = "~", exclaim = "!"
    case question = "?", colon = ":"
    case hash = "#"

    /// 長い記号を先に試すための並び。
    static let ordered: [Punctuator] = Punctuator.allCases.sorted { $0.rawValue.count > $1.rawValue.count }
}

public enum TokenKind: Equatable {
    case identifier(String)
    case keyword(Keyword)
    case integer(Int64, isLong: Bool)
    case floating(Double)
    case character(Int64)
    case string(String)
    case punctuator(Punctuator)
    case endOfFile
}

public struct Token: Equatable {
    public var kind: TokenKind
    public var location: SourceLocation
    /// プリプロセッサ指令の判定に使う (行の最初のトークンか)。
    public var isAtLineStart: Bool

    public var identifier: String? {
        if case .identifier(let name) = kind { return name }
        return nil
    }

    public func isPunctuator(_ punctuator: Punctuator) -> Bool {
        kind == .punctuator(punctuator)
    }

    public func isKeyword(_ keyword: Keyword) -> Bool {
        kind == .keyword(keyword)
    }

    public var text: String {
        switch kind {
        case .identifier(let name): return name
        case .keyword(let keyword): return keyword.rawValue
        case .integer(let value, _): return String(value)
        case .floating(let value): return String(value)
        case .character(let value): return "'\(Character(UnicodeScalar(UInt8(truncatingIfNeeded: value))))'"
        case .string(let value): return "\"\(value)\""
        case .punctuator(let punctuator): return punctuator.rawValue
        case .endOfFile: return "ファイルの終わり"
        }
    }
}

/// C のソースをトークン列に分解する。
struct Lexer {
    private let characters: [Character]
    private var index = 0
    private var line = 1
    private var column = 1
    private var atLineStart = true
    private let diagnostics: DiagnosticBag

    init(source: String, diagnostics: DiagnosticBag) {
        self.characters = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        self.diagnostics = diagnostics
    }

    static let keywordLookup: [String: Keyword] = {
        var table: [String: Keyword] = [:]
        for keyword in Keyword.allCases { table[keyword.rawValue] = keyword }
        return table
    }()

    mutating func tokenize() -> [Token] {
        var tokens: [Token] = []
        while let token = next() {
            tokens.append(token)
            if case .endOfFile = token.kind { break }
        }
        return tokens
    }

    // MARK: - 文字単位の操作

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
            atLineStart = true
        } else {
            column += 1
        }
        return character
    }

    private mutating func skipTrivia() {
        while let character = peek() {
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                advance()
            } else if character == "\\", peek(1) == "\n" {
                advance()
                advance()
            } else if character == "/", peek(1) == "/" {
                while let current = peek(), current != "\n" { advance() }
            } else if character == "/", peek(1) == "*" {
                advance()
                advance()
                while !isAtEnd {
                    if peek() == "*", peek(1) == "/" {
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

    // MARK: - トークン

    private mutating func next() -> Token? {
        skipTrivia()
        let startsLine = atLineStart
        let location = SourceLocation(line: line, column: column)
        guard let character = peek() else {
            return Token(kind: .endOfFile, location: location, isAtLineStart: startsLine)
        }
        atLineStart = false

        if character.isLetter || character == "_" {
            return identifierToken(location: location, isAtLineStart: startsLine)
        }
        if character.isNumber || (character == "." && (peek(1)?.isNumber ?? false)) {
            return numberToken(location: location, isAtLineStart: startsLine)
        }
        if character == "\"" {
            return stringToken(location: location, isAtLineStart: startsLine)
        }
        if character == "'" {
            return characterToken(location: location, isAtLineStart: startsLine)
        }
        return punctuatorToken(location: location, isAtLineStart: startsLine)
    }

    private mutating func identifierToken(location: SourceLocation, isAtLineStart: Bool) -> Token {
        var text = ""
        while let character = peek(), character.isLetter || character.isNumber || character == "_" {
            text.append(character)
            advance()
        }
        if let keyword = Lexer.keywordLookup[text] {
            return Token(kind: .keyword(keyword), location: location, isAtLineStart: isAtLineStart)
        }
        return Token(kind: .identifier(text), location: location, isAtLineStart: isAtLineStart)
    }

    private mutating func numberToken(location: SourceLocation, isAtLineStart: Bool) -> Token {
        var text = ""

        // 16 進数 / 8 進数
        if peek() == "0", let second = peek(1), second == "x" || second == "X" {
            advance()
            advance()
            var digits = ""
            while let character = peek(), character.isHexDigit {
                digits.append(character)
                advance()
            }
            let isLong = consumeIntegerSuffix()
            let value = Int64(digits, radix: 16) ?? 0
            return Token(kind: .integer(value, isLong: isLong), location: location, isAtLineStart: isAtLineStart)
        }

        var isFloating = false
        while let character = peek(), character.isNumber {
            text.append(character)
            advance()
        }
        if peek() == ".", peek(1)?.isNumber ?? true {
            isFloating = true
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
            if let character = peek(), character == "f" || character == "F" { advance() }
            let value = Double(text) ?? 0
            return Token(kind: .floating(value), location: location, isAtLineStart: isAtLineStart)
        }

        let isLong = consumeIntegerSuffix()
        if let character = peek(), character == "." || character == "f" || character == "F" {
            // "1." のような書き方
            if character == "." {
                advance()
                let value = Double(text) ?? 0
                return Token(kind: .floating(value), location: location, isAtLineStart: isAtLineStart)
            }
        }
        // 先頭 0 は 8 進数
        if text.count > 1, text.hasPrefix("0") {
            let value = Int64(text.dropFirst(), radix: 8) ?? 0
            return Token(kind: .integer(value, isLong: isLong), location: location, isAtLineStart: isAtLineStart)
        }
        let value = Int64(text) ?? 0
        return Token(kind: .integer(value, isLong: isLong), location: location, isAtLineStart: isAtLineStart)
    }

    private mutating func consumeIntegerSuffix() -> Bool {
        var isLong = false
        while let character = peek() {
            if character == "u" || character == "U" {
                advance()
            } else if character == "l" || character == "L" {
                isLong = true
                advance()
            } else {
                break
            }
        }
        return isLong
    }

    private mutating func stringToken(location: SourceLocation, isAtLineStart: Bool) -> Token {
        advance() // 開きクォート
        var text = ""
        while let character = peek(), character != "\"" {
            if character == "\n" {
                diagnostics.error("文字列リテラルが閉じていません。", at: location)
                break
            }
            if character == "\\" {
                advance()
                text.append(Character(UnicodeScalar(UInt8(truncatingIfNeeded: readEscape()))))
            } else {
                text.append(character)
                advance()
            }
        }
        if peek() == "\"" { advance() }
        return Token(kind: .string(text), location: location, isAtLineStart: isAtLineStart)
    }

    private mutating func characterToken(location: SourceLocation, isAtLineStart: Bool) -> Token {
        advance() // 開きクォート
        var value: Int64 = 0
        if peek() == "\\" {
            advance()
            value = readEscape()
        } else if let character = advance() {
            value = Int64(character.unicodeScalars.first?.value ?? 0)
        }
        if peek() == "'" {
            advance()
        } else {
            diagnostics.error("文字リテラルが閉じていません。", at: location)
            while let character = peek(), character != "'" && character != "\n" { advance() }
            if peek() == "'" { advance() }
        }
        return Token(kind: .character(value), location: location, isAtLineStart: isAtLineStart)
    }

    /// `\` の後ろを読んで文字コードを返す。
    private mutating func readEscape() -> Int64 {
        guard let character = advance() else { return 0 }
        switch character {
        case "n": return 10
        case "t": return 9
        case "r": return 13
        case "0": return 0
        case "a": return 7
        case "b": return 8
        case "f": return 12
        case "v": return 11
        case "\\": return 92
        case "'": return 39
        case "\"": return 34
        case "?": return 63
        case "x":
            var digits = ""
            while let next = peek(), next.isHexDigit, digits.count < 2 {
                digits.append(next)
                advance()
            }
            return Int64(digits, radix: 16) ?? 0
        default:
            if character.isNumber {
                var digits = String(character)
                while let next = peek(), next.isNumber, digits.count < 3 {
                    digits.append(next)
                    advance()
                }
                return Int64(digits, radix: 8) ?? 0
            }
            return Int64(character.unicodeScalars.first?.value ?? 0)
        }
    }

    private mutating func punctuatorToken(location: SourceLocation, isAtLineStart: Bool) -> Token {
        for punctuator in Punctuator.ordered {
            let symbol = Array(punctuator.rawValue)
            guard symbol.count <= characters.count - index else { continue }
            var matches = true
            for (offset, expected) in symbol.enumerated() where characters[index + offset] != expected {
                matches = false
                break
            }
            if matches {
                for _ in symbol { advance() }
                return Token(kind: .punctuator(punctuator), location: location, isAtLineStart: isAtLineStart)
            }
        }
        let unexpected = advance().map(String.init) ?? "?"
        diagnostics.error("解釈できない文字です: '\(unexpected)'", at: location)
        return Token(kind: .punctuator(.semicolon), location: location, isAtLineStart: isAtLineStart)
    }
}
