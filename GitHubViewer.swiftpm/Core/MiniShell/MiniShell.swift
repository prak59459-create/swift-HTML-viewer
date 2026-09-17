import Foundation

/// 内蔵のシェル (bash 風) 処理系。
///
/// 外部コマンドは動かせないので、よく使う組み込みコマンド (`echo` /
/// `printf` / `test` / `seq` / `wc` など) を用意し、パイプと
/// コマンド置換はその出力を文字列として受け渡すことで再現している。
public enum MiniShell: MiniLangEngine {
    public static var languageID: String { "shell" }
    public static var displayName: String { "内蔵シェル処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = ShellLexer(source: source, diagnostics: diagnostics).tokenize()
        return try ShellParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = ShellLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = ShellParser(tokens: tokens, diagnostics: diagnostics)
            let program: MLProgram
            do {
                program = try parser.parseProgram()
            } catch {
                if let failure = diagnostics.failureIfNeeded() { return .syntaxError(failure) }
                return MiniLangExecution(parsed: false,
                                         diagnosticsText: "構文を解析できませんでした",
                                         errorCount: 1, exitCode: 1)
            }
            if let failure = diagnostics.failureIfNeeded() { return .syntaxError(failure) }
            let interpreter = MLInterpreter(semantics: ShellSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum ShellProfile {
    static let keywords: Set<String> = [
        "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done",
        "case", "esac", "in", "function", "return", "local", "declare", "select",
        "break", "continue", "time", "coproc"
    ]

    static let profile = MLLanguageProfile(
        languageID: "shell",
        comments: [.line("#")],
        strings: [],
        keywords: keywords,
        operators: [],
        newlineTerminatesStatement: true,
        usesSemicolons: true,
        functionKeywords: ["function"],
        variableKeywords: [:],
        typeKeywords: [:],
        nullLiterals: [],
        trueLiterals: [],
        falseLiterals: [],
        selfKeywords: [],
        assignmentOperators: ["="])
}

/// シェルの字句解析。単語をひとかたまりとして切り出す。
final class ShellLexer: MLLexerBase {
    private let profile = ShellProfile.profile

    override init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, diagnostics: diagnostics)
    }

    /// 演算子として扱う記号 (長いものから照合する)。
    private static let operators: [String] = [
        "&&", "||", ";;", ">>", "<<", "==", "!=", "<=", ">=", "=~", "((", "))", "[[", "]]",
        "|", "&", ";", "(", ")", "{", "}", "<", ">", "=", "!", "\n"
    ]

    func tokenize() -> [MLToken] {
        var tokens: [MLToken] = []
        var previous: MLToken?
        while true {
            skipBlanks()
            guard !isAtEnd else { break }
            let start = location
            // コメント。
            if peek() == "#", previous == nil || isCommandBoundary(previous) {
                skipLineComment()
                continue
            }
            if peek() == "\n" {
                advance()
                tokens.append(MLToken(kind: .newline, text: "\n", location: start,
                                      precededByNewline: true))
                previous = tokens.last
                continue
            }
            if peek() == "\\", peek(1) == "\n" {
                advance()
                advance()
                continue
            }
            if let op = matchedOperator() {
                tokens.append(MLToken(kind: .punctuation, text: op, location: start))
                previous = tokens.last
                continue
            }
            let token = readWord(start: start)
            tokens.append(token)
            previous = token
        }
        tokens.append(MLToken(kind: .endOfFile, text: "", location: location))
        return tokens
    }

    private func isCommandBoundary(_ token: MLToken?) -> Bool {
        guard let token else { return true }
        return token.kind == .newline
            || [";", "&&", "||", "|", "(", ")", "{", "}", "&", ";;"].contains(token.text)
    }

    private func skipBlanks() {
        while let character = peek(), character == " " || character == "\t" {
            advance()
        }
    }

    private func matchedOperator() -> String? {
        for op in ShellLexer.operators where lookahead(op) {
            // `((` と `[[` は前後の文脈で使い分けるので、そのまま返す。
            _ = match(op)
            return op
        }
        return nil
    }

    /// 単語を 1 つ読む (引用符と展開をまたいでつながる)。
    private func readWord(start: SourceLocation) -> MLToken {
        var pieces: [MLStringPiece] = []
        var literal = ""
        var sawQuote = false

        func flush() {
            if !literal.isEmpty {
                pieces.append(MLStringPiece(text: literal, isExpression: false,
                                            location: start))
                literal = ""
            }
        }

        loop: while let character = peek() {
            switch character {
            case " ", "\t", "\n":
                break loop
            case ";", "|", "&", "<", ">", "(", ")":
                break loop
            case "'":
                sawQuote = true
                advance()
                while let inner = peek(), inner != "'" {
                    literal.append(inner)
                    advance()
                }
                advance()
            case "\"":
                sawQuote = true
                advance()
                while let inner = peek(), inner != "\"" {
                    if inner == "\\" {
                        advance()
                        if let escaped = advance() {
                            switch escaped {
                            case "n": literal.append("\n")
                            case "t": literal.append("\t")
                            case "\\", "\"", "$", "`": literal.append(escaped)
                            default:
                                literal.append("\\")
                                literal.append(escaped)
                            }
                        }
                        continue
                    }
                    if inner == "$" {
                        flush()
                        if let piece = readExpansion() { pieces.append(piece) }
                        continue
                    }
                    literal.append(inner)
                    advance()
                }
                advance()
            case "$":
                flush()
                if let piece = readExpansion() { pieces.append(piece) }
            case "\\":
                advance()
                if let escaped = advance() { literal.append(escaped) }
            case "=" where pieces.isEmpty && !sawQuote && isName(literal):
                // `NAME=` はそこで区切り、代入として扱えるようにする。
                advance()
                let name = literal + "="
                return MLToken(kind: .identifier, text: name, location: start,
                               stringValue: name)
            default:
                literal.append(character)
                advance()
            }
        }
        flush()

        if pieces.count == 1, !pieces[0].isExpression, !sawQuote {
            let text = pieces[0].text
            let kind: MLTokenKind = profile.keywords.contains(text) ? .keyword : .identifier
            return MLToken(kind: kind, text: text, location: start, stringValue: text)
        }
        if pieces.allSatisfy({ !$0.isExpression }) {
            let text = pieces.map { $0.text }.joined()
            return MLToken(kind: .stringLiteral, text: text, location: start,
                           stringValue: text)
        }
        return MLToken(kind: .interpolatedString, text: "", location: start, pieces: pieces)
    }

    /// 変数名として正しいか。
    private func isName(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `$name` / `${name}` / `$(cmd)` / `$((expr))` を式の断片として読む。
    private func readExpansion() -> MLStringPiece? {
        let start = location
        advance()   // `$`
        guard let character = peek() else { return nil }

        if character == "(" {
            advance()
            if peek() == "(" {
                advance()
                let text = readBalanced(open: "(", close: ")")
                _ = match(")")
                return MLStringPiece(text: "#arith(" + text + ")", isExpression: true,
                                     location: start)
            }
            let text = readBalanced(open: "(", close: ")")
            return MLStringPiece(text: "#capture(" + text + ")", isExpression: true,
                                 location: start)
        }
        if character == "{" {
            advance()
            var text = ""
            var depth = 1
            while let inner = peek() {
                if inner == "{" { depth += 1 }
                if inner == "}" {
                    depth -= 1
                    if depth == 0 {
                        advance()
                        break
                    }
                }
                text.append(inner)
                advance()
            }
            return MLStringPiece(text: "#param(" + text + ")", isExpression: true,
                                 location: start)
        }
        if character == "?" || character == "#" || character == "@" || character == "*" {
            advance()
            return MLStringPiece(text: "#special(" + String(character) + ")",
                                 isExpression: true, location: start)
        }
        if character.isNumber {
            var digits = ""
            while let inner = peek(), inner.isNumber {
                digits.append(inner)
                advance()
            }
            return MLStringPiece(text: "#arg(" + digits + ")", isExpression: true,
                                 location: start)
        }
        guard MLLexerBase.isIdentifierStart(character) else { return nil }
        var name = readIdentifier()
        // `$arr[0]` のような添字も拾う。
        if peek() == "[" {
            var depth = 0
            repeat {
                guard let inner = peek() else { break }
                if inner == "[" { depth += 1 }
                if inner == "]" { depth -= 1 }
                name.append(inner)
                advance()
            } while depth > 0 && !isAtEnd
        }
        return MLStringPiece(text: name, isExpression: true, location: start)
    }

    /// 対応する閉じ記号まで読む (中身はそのまま返す)。
    private func readBalanced(open: Character, close: Character) -> String {
        var text = ""
        var depth = 1
        while let character = peek() {
            if character == open { depth += 1 }
            if character == close {
                depth -= 1
                if depth == 0 {
                    advance()
                    break
                }
            }
            text.append(character)
            advance()
        }
        return text
    }
}
