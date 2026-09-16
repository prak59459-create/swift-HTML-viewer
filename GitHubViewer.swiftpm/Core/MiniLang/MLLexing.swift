import Foundation

/// 字句の種類。言語ごとの細かい違いは `text` を見て判断する。
public enum MLTokenKind: Equatable {
    case identifier
    case keyword
    case integerLiteral
    case floatLiteral
    case stringLiteral
    case charLiteral
    /// 補間つき文字列 (`"a \(b)"`)。断片は `pieces` に入る。
    case interpolatedString
    case symbol
    case punctuation
    case newline
    /// Python / Haskell などの字下げ開始。
    case indent
    case dedent
    case endOfFile
}

public struct MLToken {
    public var kind: MLTokenKind
    /// 見たままの文字列 (識別子なら名前、記号なら記号)。
    public var text: String
    public var location: SourceLocation
    /// 文字列リテラルのエスケープ解決後の値。
    public var stringValue: String?
    public var intValue: Int64?
    public var doubleValue: Double?
    /// 補間つき文字列の断片。`isExpression` が true の部分は式として再解析する。
    public var pieces: [MLStringPiece]
    /// 直前に改行があったか (改行でセミコロンを補う言語用)。
    public var precededByNewline: Bool

    public init(kind: MLTokenKind, text: String, location: SourceLocation,
                stringValue: String? = nil, intValue: Int64? = nil, doubleValue: Double? = nil,
                pieces: [MLStringPiece] = [], precededByNewline: Bool = false) {
        self.kind = kind
        self.text = text
        self.location = location
        self.stringValue = stringValue
        self.intValue = intValue
        self.doubleValue = doubleValue
        self.pieces = pieces
        self.precededByNewline = precededByNewline
    }

    public var isEndOfFile: Bool { kind == .endOfFile }

    public func `is`(_ text: String) -> Bool { self.text == text && kind != .stringLiteral }
}

public struct MLStringPiece {
    public var text: String
    public var isExpression: Bool
    public var location: SourceLocation

    public init(text: String, isExpression: Bool, location: SourceLocation) {
        self.text = text
        self.isExpression = isExpression
        self.location = location
    }
}

/// 字句解析の土台。文字の読み進めと、よくある数値・文字列の読み取りを持つ。
///
/// 各言語はこれを継承して `nextToken()` を書く。
open class MLLexerBase {
    public let source: [Character]
    public private(set) var position = 0
    public private(set) var line = 1
    public private(set) var column = 1
    public let diagnostics: DiagnosticBag

    public init(source: String, diagnostics: DiagnosticBag) {
        self.source = Array(source)
        self.diagnostics = diagnostics
    }

    // MARK: 文字の読み進め

    public var isAtEnd: Bool { position >= source.count }

    public var location: SourceLocation { SourceLocation(line: line, column: column) }

    public func peek(_ offset: Int = 0) -> Character? {
        let index = position + offset
        guard index >= 0, index < source.count else { return nil }
        return source[index]
    }

    @discardableResult
    public func advance() -> Character? {
        guard position < source.count else { return nil }
        let character = source[position]
        position += 1
        if character == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        return character
    }

    /// 次が `text` ならそれを消費して true。
    @discardableResult
    public func match(_ text: String) -> Bool {
        let characters = Array(text)
        guard position + characters.count <= source.count else { return false }
        for (offset, character) in characters.enumerated()
        where source[position + offset] != character {
            return false
        }
        for _ in characters { advance() }
        return true
    }

    public func lookahead(_ text: String) -> Bool {
        let characters = Array(text)
        guard position + characters.count <= source.count else { return false }
        for (offset, character) in characters.enumerated()
        where source[position + offset] != character {
            return false
        }
        return true
    }

    /// 改行を含まない空白を読み飛ばす。
    public func skipInlineWhitespace() {
        while let character = peek(), character != "\n", character.isWhitespace {
            advance()
        }
    }

    /// 改行も含めて空白を読み飛ばす。
    public func skipWhitespace() {
        while let character = peek(), character.isWhitespace { advance() }
    }

    /// 行コメント。
    public func skipLineComment() {
        while let character = peek(), character != "\n" { advance() }
    }

    /// 入れ子にできるブロックコメント。
    public func skipBlockComment(open: String, close: String, allowsNesting: Bool) {
        var depth = 1
        while !isAtEnd, depth > 0 {
            if allowsNesting, lookahead(open) {
                _ = match(open)
                depth += 1
                continue
            }
            if lookahead(close) {
                _ = match(close)
                depth -= 1
                continue
            }
            advance()
        }
    }

    // MARK: 識別子

    public static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character.unicodeScalars.first.map { $0.value > 127 } == true
    }

    public static func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    /// 識別子を読む (先頭の 1 文字はすでに条件を満たしている前提)。
    public func readIdentifier(extraCharacters: Set<Character> = []) -> String {
        var text = ""
        while let character = peek(),
              MLLexerBase.isIdentifierPart(character) || extraCharacters.contains(character) {
            text.append(character)
            advance()
        }
        return text
    }

    // MARK: 数値

    /// 数値リテラルを読む。`_` 区切り・16/8/2 進数・指数・小数に対応。
    public func readNumber(allowsUnderscoreSeparator: Bool = true) -> MLToken {
        let start = location
        var text = ""

        func take() {
            if let character = peek() {
                text.append(character)
                advance()
            }
        }

        // 基数つきリテラル。
        if peek() == "0", let next = peek(1) {
            let radix: Int?
            switch next {
            case "x", "X": radix = 16
            case "o", "O": radix = 8
            case "b", "B": radix = 2
            default: radix = nil
            }
            if let radix {
                advance()
                advance()
                var digits = ""
                while let character = peek() {
                    if allowsUnderscoreSeparator, character == "_" {
                        advance()
                        continue
                    }
                    guard character.isHexDigit,
                          Int(String(character), radix: radix) != nil else { break }
                    digits.append(character)
                    advance()
                }
                let value = Int64(digits, radix: radix) ?? 0
                return MLToken(kind: .integerLiteral, text: digits, location: start,
                               intValue: value)
            }
        }

        while let character = peek() {
            if allowsUnderscoreSeparator, character == "_" {
                advance()
                continue
            }
            guard character.isNumber else { break }
            take()
        }

        var isFloat = false
        // 小数点。`1..5` のような範囲記法と区別する。
        if peek() == ".", let next = peek(1), next.isNumber {
            isFloat = true
            take()
            while let character = peek() {
                if allowsUnderscoreSeparator, character == "_" {
                    advance()
                    continue
                }
                guard character.isNumber else { break }
                take()
            }
        }

        // 指数部。
        if let character = peek(), character == "e" || character == "E" {
            let sign = peek(1)
            let digit = (sign == "+" || sign == "-") ? peek(2) : sign
            if let digit, digit.isNumber {
                isFloat = true
                take()
                if let sign, sign == "+" || sign == "-" { take() }
                while let character = peek(), character.isNumber { take() }
            }
        }

        if isFloat {
            return MLToken(kind: .floatLiteral, text: text, location: start,
                           doubleValue: Double(text) ?? 0)
        }
        if let value = Int64(text) {
            return MLToken(kind: .integerLiteral, text: text, location: start, intValue: value)
        }
        // Int64 に収まらないときは小数として扱う。
        return MLToken(kind: .floatLiteral, text: text, location: start,
                       doubleValue: Double(text) ?? 0)
    }

    // MARK: 文字列

    /// よくあるエスケープの解釈。
    open func decodeEscape() -> String {
        guard let character = advance() else { return "" }
        switch character {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "0": return "\0"
        case "\\": return "\\"
        case "\"": return "\""
        case "'": return "'"
        case "`": return "`"
        case "a": return "\u{07}"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "v": return "\u{0B}"
        case "e": return "\u{1B}"
        case "$": return "$"
        case "\n": return ""
        case "x":
            var digits = ""
            while digits.count < 2, let next = peek(), next.isHexDigit {
                digits.append(next)
                advance()
            }
            guard let value = UInt32(digits, radix: 16),
                  let scalar = Unicode.Scalar(value) else { return "" }
            return String(Character(scalar))
        case "u", "U":
            var digits = ""
            if peek() == "{" {
                advance()
                while let next = peek(), next != "}" {
                    digits.append(next)
                    advance()
                }
                advance()
            } else {
                let limit = character == "u" ? 4 : 8
                while digits.count < limit, let next = peek(), next.isHexDigit {
                    digits.append(next)
                    advance()
                }
            }
            guard let value = UInt32(digits, radix: 16),
                  let scalar = Unicode.Scalar(value) else { return "" }
            return String(Character(scalar))
        default:
            return String(character)
        }
    }

    /// 単純な文字列リテラル (補間なし)。開きの引用符はすでに消費済み。
    public func readSimpleString(terminator: Character,
                                 allowsEscapes: Bool = true) -> String {
        var text = ""
        while let character = peek() {
            if character == terminator {
                advance()
                break
            }
            if allowsEscapes, character == "\\" {
                advance()
                text += decodeEscape()
                continue
            }
            text.append(character)
            advance()
        }
        return text
    }

    /// 補間つき文字列を読む。
    ///
    /// - Parameters:
    ///   - terminator: 閉じ記号。
    ///   - interpolationPrefix: `\(` や `${` のような開始記号。
    ///   - simpleVariablePrefix: `$name` のように括弧なしで書ける記号 (無ければ nil)。
    public func readInterpolatedString(terminator: Character,
                                       interpolationPrefix: String,
                                       simpleVariablePrefix: Character? = nil,
                                       allowsEscapes: Bool = true) -> [MLStringPiece] {
        var pieces: [MLStringPiece] = []
        var literal = ""
        var literalStart = location

        func flush() {
            if !literal.isEmpty {
                pieces.append(MLStringPiece(text: literal, isExpression: false,
                                            location: literalStart))
                literal = ""
            }
            literalStart = location
        }

        while let character = peek() {
            if character == terminator {
                advance()
                break
            }
            if allowsEscapes, character == "\\" {
                // 補間の開始が `\(` の場合はエスケープより優先する。
                if interpolationPrefix.first == "\\", lookahead(interpolationPrefix) {
                    _ = match(interpolationPrefix)
                    flush()
                    pieces.append(readInterpolationBody(open: "(", close: ")"))
                    continue
                }
                advance()
                literal += decodeEscape()
                continue
            }
            if !interpolationPrefix.isEmpty, interpolationPrefix.first != "\\",
               lookahead(interpolationPrefix) {
                _ = match(interpolationPrefix)
                flush()
                let open = interpolationPrefix.last ?? "{"
                pieces.append(readInterpolationBody(open: open,
                                                    close: open == "(" ? ")" : "}"))
                continue
            }
            if let prefix = simpleVariablePrefix, character == prefix,
               let next = peek(1), MLLexerBase.isIdentifierStart(next) {
                advance()
                flush()
                let start = location
                var name = readIdentifier()
                // `$obj->field` / `$arr[0]` のような簡単な後続も拾う。
                while true {
                    if lookahead("->"), let after = peek(2),
                       MLLexerBase.isIdentifierStart(after) {
                        _ = match("->")
                        name += "->" + readIdentifier()
                        continue
                    }
                    if peek() == "[" {
                        var depth = 0
                        var text = ""
                        while let character = peek() {
                            if character == "[" { depth += 1 }
                            if character == "]" { depth -= 1 }
                            text.append(character)
                            advance()
                            if depth == 0 { break }
                        }
                        name += text
                        continue
                    }
                    break
                }
                pieces.append(MLStringPiece(text: String(prefix) + name, isExpression: true,
                                            location: start))
                continue
            }
            literal.append(character)
            advance()
        }
        flush()
        return pieces
    }

    /// 対応する括弧まで読んで、補間の中身を式の断片として返す。
    private func readInterpolationBody(open: Character, close: Character) -> MLStringPiece {
        let start = location
        var depth = 1
        var text = ""
        while let character = peek() {
            if character == open { depth += 1 }
            if character == close {
                depth -= 1
                if depth == 0 {
                    advance()
                    break
                }
            }
            // 中の文字列リテラルはそのまま通す。
            if character == "\"" || character == "'" {
                let quote = character
                text.append(character)
                advance()
                while let inner = peek() {
                    text.append(inner)
                    advance()
                    if inner == "\\", let escaped = peek() {
                        text.append(escaped)
                        advance()
                        continue
                    }
                    if inner == quote { break }
                }
                continue
            }
            text.append(character)
            advance()
        }
        return MLStringPiece(text: text, isExpression: true, location: start)
    }
}

/// 構文解析の土台。字句列の上を進み、よくある失敗の報告をまとめる。
open class MLParserBase {
    public var tokens: [MLToken]
    public var index = 0
    public let diagnostics: DiagnosticBag

    public init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }

    public var current: MLToken {
        index < tokens.count ? tokens[index]
            : MLToken(kind: .endOfFile, text: "", location: tokens.last?.location
                      ?? SourceLocation(line: 1, column: 1))
    }

    public func peek(_ offset: Int = 0) -> MLToken {
        let target = index + offset
        guard target >= 0, target < tokens.count else {
            return MLToken(kind: .endOfFile, text: "",
                           location: tokens.last?.location ?? SourceLocation(line: 1, column: 1))
        }
        return tokens[target]
    }

    public var isAtEnd: Bool { current.kind == .endOfFile }

    @discardableResult
    public func advance() -> MLToken {
        let token = current
        if index < tokens.count { index += 1 }
        return token
    }

    public func check(_ text: String) -> Bool {
        !isAtEnd && current.kind != .stringLiteral && current.text == text
    }

    public func check(_ kind: MLTokenKind) -> Bool { current.kind == kind }

    @discardableResult
    public func match(_ texts: String...) -> Bool {
        for text in texts where check(text) {
            advance()
            return true
        }
        return false
    }

    @discardableResult
    public func matchKind(_ kind: MLTokenKind) -> MLToken? {
        guard check(kind) else { return nil }
        return advance()
    }

    @discardableResult
    public func expect(_ text: String, _ context: String = "") throws -> MLToken {
        guard check(text) else {
            throw report("\(text) が必要です" + (context.isEmpty ? "" : " (\(context))"))
        }
        return advance()
    }

    @discardableResult
    public func expectIdentifier(_ context: String = "") throws -> String {
        guard current.kind == .identifier || current.kind == .keyword else {
            throw report("名前が必要です" + (context.isEmpty ? "" : " (\(context))"))
        }
        return advance().text
    }

    /// エラーを記録して、解析を打ち切るための例外を返す。
    public func report(_ message: String, at location: SourceLocation? = nil) -> Error {
        diagnostics.error(message + "。ここでは `\(describeCurrent())` が見つかりました",
                          at: location ?? current.location)
        return AbortCompilation()
    }

    private func describeCurrent() -> String {
        switch current.kind {
        case .endOfFile: return "ファイルの終わり"
        case .newline: return "改行"
        case .stringLiteral, .interpolatedString: return "文字列"
        default: return current.text
        }
    }

    /// エラーからの復帰: 指定した記号のどれかまで読み飛ばす。
    public func recover(until stops: Set<String>) {
        while !isAtEnd, !stops.contains(current.text) { advance() }
    }
}
