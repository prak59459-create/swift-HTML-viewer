import Foundation

public enum SwiftTokenKind: Equatable {
    case identifier(String)
    case integer(Int)
    case double(Double)
    /// 文字列。`segments` は「そのままの文字」と「補間する式のソース」が交互に入る。
    case string(segments: [SwiftStringSegment])
    case op(String)
    case endOfFile
}

public enum SwiftStringSegment: Equatable {
    case text(String)
    case expression(String)
}

public struct SwiftToken: Equatable {
    public var kind: SwiftTokenKind
    public var location: SourceLocation
    /// 直前に空白や改行があったか (末尾クロージャの判定などに使う)。
    public var startsLine: Bool

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

/// Swift のソースをトークンに分解する。
struct SwiftLexer {
    private let characters: [Character]
    private var index = 0
    private var line = 1
    private var column = 1
    private var atLineStart = true
    private let diagnostics: DiagnosticBag

    private static let operators = [
        "...", "..<", "===", "!==", "&&=", "||=",
        "->", "==", "!=", "<=", ">=", "&&", "||", "??", "+=", "-=", "*=", "/=", "%=",
        "?.", "<<", ">>",
        "+", "-", "*", "/", "%", "=", "<", ">", "!", "?", ":", ";", ",", ".",
        "(", ")", "[", "]", "{", "}", "&", "|", "^", "~", "@", "\\", "_",
    ]

    init(source: String, diagnostics: DiagnosticBag) {
        self.characters = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        self.diagnostics = diagnostics
    }

    mutating func tokenize() -> [SwiftToken] {
        var tokens: [SwiftToken] = []
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
        if character == "\n" {
            line += 1
            column = 1
            atLineStart = true
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

    private mutating func skipTrivia() {
        while let character = peek() {
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                advance()
            } else if character == "/", peek(1) == "/" {
                while let current = peek(), current != "\n" { advance() }
            } else if character == "/", peek(1) == "*" {
                var depth = 0
                while !isAtEnd {
                    if matchesAhead("/*") {
                        depth += 1
                        advance()
                        advance()
                        continue
                    }
                    if matchesAhead("*/") {
                        depth -= 1
                        advance()
                        advance()
                        if depth == 0 { break }
                        continue
                    }
                    advance()
                }
            } else {
                break
            }
        }
    }

    private mutating func next() -> SwiftToken {
        skipTrivia()
        let startsLine = atLineStart
        atLineStart = false
        let location = SourceLocation(line: line, column: column)
        guard let character = peek() else {
            return SwiftToken(kind: .endOfFile, location: location, startsLine: startsLine)
        }

        if character.isLetter || character == "_" || character == "$" {
            var name = ""
            if character == "$" {
                name.append(character)
                advance()
            }
            while let current = peek(), current.isLetter || current.isNumber || current == "_" {
                name.append(current)
                advance()
            }
            if name.isEmpty { name = "_" }
            return SwiftToken(kind: .identifier(name), location: location, startsLine: startsLine)
        }

        if character.isNumber {
            return readNumber(location: location, startsLine: startsLine)
        }

        if character == "\"" {
            return readString(location: location, startsLine: startsLine)
        }

        for symbol in SwiftLexer.operators where matchesAhead(symbol) {
            // `1...5` の `...` と `a.b` の `.` を取り違えないよう、長いものから照合済み
            for _ in symbol { advance() }
            return SwiftToken(kind: .op(symbol), location: location, startsLine: startsLine)
        }

        let unexpected = advance().map(String.init) ?? "?"
        diagnostics.error("解釈できない文字です: '\(unexpected)'", at: location)
        return SwiftToken(kind: .op(";"), location: location, startsLine: startsLine)
    }

    private mutating func readNumber(location: SourceLocation, startsLine: Bool) -> SwiftToken {
        var text = ""
        if peek() == "0", let second = peek(1), second == "x" || second == "X" {
            advance()
            advance()
            var digits = ""
            while let character = peek(), character.isHexDigit || character == "_" {
                if character != "_" { digits.append(character) }
                advance()
            }
            return SwiftToken(kind: .integer(Int(digits, radix: 16) ?? 0), location: location,
                              startsLine: startsLine)
        }
        if peek() == "0", let second = peek(1), second == "b" {
            advance()
            advance()
            var digits = ""
            while let character = peek(), character == "0" || character == "1" || character == "_" {
                if character != "_" { digits.append(character) }
                advance()
            }
            return SwiftToken(kind: .integer(Int(digits, radix: 2) ?? 0), location: location,
                              startsLine: startsLine)
        }

        var isDouble = false
        while let character = peek(), character.isNumber || character == "_" {
            if character != "_" { text.append(character) }
            advance()
        }
        // `1...5` のような範囲と小数点を区別する
        if peek() == ".", let next = peek(1), next.isNumber {
            isDouble = true
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
                isDouble = true
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
        if isDouble {
            return SwiftToken(kind: .double(Double(text) ?? 0), location: location, startsLine: startsLine)
        }
        return SwiftToken(kind: .integer(Int(text) ?? 0), location: location, startsLine: startsLine)
    }

    private mutating func readString(location: SourceLocation, startsLine: Bool) -> SwiftToken {
        // 複数行文字列 """..."""
        if matchesAhead("\"\"\"") {
            advance()
            advance()
            advance()
            if peek() == "\n" { advance() }
            var text = ""
            while !isAtEnd, !matchesAhead("\"\"\"") {
                text.append(advance() ?? " ")
            }
            if matchesAhead("\"\"\"") {
                advance()
                advance()
                advance()
            }
            // 末尾の改札 (閉じる """ の前の改行) を落とす
            if text.hasSuffix("\n") { text.removeLast() }
            return SwiftToken(kind: .string(segments: segments(from: text)), location: location,
                              startsLine: startsLine)
        }

        advance() // 開きクォート
        var raw = ""
        while let character = peek(), character != "\"" {
            if character == "\\", let next = peek(1) {
                if next == "(" {
                    // 補間: 対応する括弧まで取り込む
                    advance()
                    advance()
                    var depth = 1
                    var inner = ""
                    while let current = peek() {
                        if current == "(" { depth += 1 }
                        if current == ")" {
                            depth -= 1
                            if depth == 0 { advance(); break }
                        }
                        inner.append(current)
                        advance()
                    }
                    raw += "\u{2}" + inner + "\u{3}"
                    continue
                }
                advance()
                advance()
                switch next {
                case "n": raw.append("\n")
                case "t": raw.append("\t")
                case "r": raw.append("\r")
                case "0": raw.append("\0")
                case "\\": raw.append("\\")
                case "\"": raw.append("\"")
                case "'": raw.append("'")
                default:
                    raw.append("\\")
                    raw.append(next)
                }
                continue
            }
            if character == "\n" {
                diagnostics.error("文字列が閉じていません。", at: location)
                break
            }
            raw.append(character)
            advance()
        }
        if peek() == "\"" { advance() }
        return SwiftToken(kind: .string(segments: segments(from: raw)), location: location,
                          startsLine: startsLine)
    }

    /// 補間の目印 (\u{2} ... \u{3}) を式として切り出す。
    private func segments(from raw: String) -> [SwiftStringSegment] {
        var result: [SwiftStringSegment] = []
        var text = ""
        var expression = ""
        var inExpression = false
        for character in raw {
            if character == "\u{2}" {
                if !text.isEmpty {
                    result.append(.text(text))
                    text = ""
                }
                inExpression = true
                expression = ""
                continue
            }
            if character == "\u{3}" {
                result.append(.expression(expression))
                inExpression = false
                continue
            }
            if inExpression {
                expression.append(character)
            } else {
                text.append(character)
            }
        }
        if !text.isEmpty { result.append(.text(text)) }
        return result
    }
}
