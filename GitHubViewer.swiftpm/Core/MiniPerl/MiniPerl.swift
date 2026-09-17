import Foundation

/// 内蔵の Perl 処理系。
///
/// `$x` / `@list` / `%hash` の記号は名前の一部として持つ (Perl 自身も
/// 記号ごとに別の入れ物なので、そのほうが素直に動く)。
/// 正規表現は字句解析の時点で「模様と旗」に分け、組み込み関数として扱う。
public enum MiniPerl: MiniLangEngine {
    public static var languageID: String { "perl" }
    public static var displayName: String { "内蔵 Perl 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = PerlLexer(source: source, diagnostics: diagnostics).tokenize()
        return try PerlParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = PerlLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = PerlParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: PerlSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum PerlProfile {
    static let keywords: Set<String> = [
        "my", "our", "local", "sub", "if", "elsif", "else", "unless", "while", "until",
        "for", "foreach", "do", "last", "next", "redo", "return", "use", "no", "package",
        "require", "and", "or", "not", "xor", "eq", "ne", "lt", "gt", "le", "ge", "cmp",
        "qw", "q", "qq", "m", "s", "tr", "y", "undef", "defined", "exists", "delete",
        "ref", "bless", "wantarray", "eval", "die", "warn", "print", "printf", "sort",
        "map", "grep", "keys", "values", "each", "push", "pop", "shift", "unshift",
        "splice", "scalar", "reverse", "join", "split", "sprintf", "unless", "x"
    ]

    static let profile = MLLanguageProfile(
        languageID: "perl",
        comments: [.line("#")],
        strings: [],   // 文字列は PerlLexer で読む。
        keywords: keywords,
        operators: ["<=>", "**=", "||=", "&&=", "//=", "...", "=~", "!~", "->", "=>",
                    "==", "!=", "<=", ">=", "&&", "||", "//", "**", "++", "--",
                    "+=", "-=", "*=", "/=", ".=", "%=", "x=", "|=", "&=", "^=",
                    "<<", ">>", "..", "::",
                    "+", "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", "~",
                    "?", ":", ";", ",", ".", "(", ")", "[", "]", "{", "}", "\\"],
        newlineTerminatesStatement: false,
        usesSemicolons: true,
        allowsNumericSeparators: true,
        functionSyntax: .keyword,
        functionKeywords: ["sub"],
        variableKeywords: ["my": false, "our": false, "local": false],
        typeKeywords: [:],
        ignorableModifiers: [],
        lambdaArrows: [],
        nullLiterals: ["undef"],
        selfKeywords: [],
        assignmentOperators: ["=", "+=", "-=", "*=", "/=", ".=", "%=", "**=", "||=",
                              "&&=", "//=", "x=", "|=", "&=", "^="])
}

final class PerlLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: PerlProfile.profile, diagnostics: diagnostics)
    }

    /// 直前に出した字句 (`/` が割り算か正規表現かの判断に使う)。
    private var previous: MLToken?

    override func tokenize() -> [MLToken] {
        var tokens: [MLToken] = []
        var sawNewline = false
        while true {
            let skipped = skipIgnorable()
            sawNewline = sawNewline || skipped
            guard !isAtEnd else { break }
            guard var token = nextToken() else { continue }
            token.precededByNewline = sawNewline
            sawNewline = false
            previous = token
            tokens.append(token)
        }
        tokens.append(MLToken(kind: .endOfFile, text: "", location: location,
                              precededByNewline: sawNewline))
        return tokens
    }

    override func nextToken() -> MLToken? {
        let start = location
        guard let character = peek() else { return nil }

        // `$x` / `@list` / `%hash` / `&sub` / `$_` / `@_` / `$1`
        if character == "$" || character == "@" || character == "%" {
            if let next = peek(1), MLLexerBase.isIdentifierStart(next) || next.isNumber
                || next == "_" || (character == "$" && next == "$") {
                advance()
                var name = String(character)
                if peek() == "$" { name += String(advance() ?? "$") }
                if let digit = peek(), digit.isNumber {
                    while let number = peek(), number.isNumber {
                        name.append(number)
                        advance()
                    }
                } else {
                    name += readIdentifier()
                }
                return MLToken(kind: .identifier, text: name, location: start)
            }
            // `%` は剰余、`@` や `$` 単体はそのまま記号。
        }

        // 文字列。
        if character == "\"" { return readPerlString(terminator: "\"", interpolates: true,
                                                     start: start) }
        if character == "'" { return readPerlString(terminator: "'", interpolates: false,
                                                    start: start) }

        // `qw(a b c)` / `q(...)` / `qq(...)`
        if lookahead("qw"), let next = peek(2), isDelimiter(next) {
            _ = match("qw")
            return readWordList(start: start)
        }
        if lookahead("qq"), let next = peek(2), isDelimiter(next) {
            _ = match("qq")
            let (open, close) = delimiters()
            _ = open
            return readPerlString(terminator: close, interpolates: true, start: start)
        }
        if lookahead("q"), let next = peek(1), isDelimiter(next), next != "w", next != "q" {
            _ = match("q")
            let (open, close) = delimiters()
            _ = open
            return readPerlString(terminator: close, interpolates: false, start: start)
        }

        // 正規表現。
        if lookahead("m"), let next = peek(1), isDelimiter(next) {
            _ = match("m")
            return readMatch(start: start)
        }
        if lookahead("qr"), let next = peek(2), isDelimiter(next) {
            _ = match("qr")
            return readMatch(start: start)
        }
        if lookahead("s"), let next = peek(1), isDelimiter(next) {
            _ = match("s")
            return readSubstitution(start: start, text: "#subst")
        }
        if (lookahead("tr") && isDelimiter(peek(2) ?? " "))
            || (lookahead("y") && isDelimiter(peek(1) ?? " ")) {
            _ = match("tr") || match("y")
            return readSubstitution(start: start, text: "#trans")
        }
        if character == "/", regexCanStartHere {
            return readMatch(start: start)
        }

        return super.nextToken()
    }

    /// 直前の字句から見て、ここで正規表現が始まれるか。
    private var regexCanStartHere: Bool {
        guard let previous else { return true }
        switch previous.kind {
        case .identifier, .integerLiteral, .floatLiteral, .stringLiteral,
             .interpolatedString, .charLiteral:
            return false
        case .keyword:
            return !["undef"].contains(previous.text)
        default:
            return ![")", "]", "}"].contains(previous.text)
        }
    }

    private func isDelimiter(_ character: Character) -> Bool {
        "/|!{([<#,~^".contains(character)
    }

    /// 区切り記号の組を取り出す (`{}` などは対になる)。
    private func delimiters() -> (Character, Character) {
        let open = advance() ?? "/"
        switch open {
        case "{": return ("{", "}")
        case "(": return ("(", ")")
        case "[": return ("[", "]")
        case "<": return ("<", ">")
        default: return (open, open)
        }
    }

    private func readUntil(_ terminator: Character, opening: Character?) -> String {
        var text = ""
        var depth = 1
        while let character = peek() {
            if character == "\\" {
                advance()
                if let escaped = advance() {
                    // 正規表現の `\` はそのまま残す。
                    text.append("\\")
                    text.append(escaped)
                }
                continue
            }
            if let opening, character == opening {
                depth += 1
            } else if character == terminator {
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

    private func readFlags() -> String {
        var flags = ""
        while let character = peek(), character.isLetter {
            flags.append(character)
            advance()
        }
        return flags
    }

    /// `m/PAT/FLAGS` を 1 つの字句にまとめる。
    private func readMatch(start: SourceLocation) -> MLToken {
        let (open, close) = delimiters()
        let pattern = readUntil(close, opening: open == close ? nil : open)
        let flags = readFlags()
        return MLToken(kind: .symbol, text: "#match", location: start,
                       pieces: [MLStringPiece(text: pattern, isExpression: false,
                                              location: start),
                                MLStringPiece(text: flags, isExpression: false,
                                              location: start)])
    }

    /// `s/PAT/REP/FLAGS` を 1 つの字句にまとめる。
    private func readSubstitution(start: SourceLocation, text: String) -> MLToken {
        let (open, close) = delimiters()
        let pattern = readUntil(close, opening: open == close ? nil : open)
        var replacement: String
        if open != close {
            // `s{a}{b}` のように 2 組で書く形。
            skipIgnorable()
            let (secondOpen, secondClose) = delimiters()
            replacement = readUntil(secondClose,
                                    opening: secondOpen == secondClose ? nil : secondOpen)
        } else {
            replacement = readUntil(close, opening: nil)
        }
        let flags = readFlags()
        return MLToken(kind: .symbol, text: text, location: start,
                       pieces: [MLStringPiece(text: pattern, isExpression: false,
                                              location: start),
                                MLStringPiece(text: replacement, isExpression: false,
                                              location: start),
                                MLStringPiece(text: flags, isExpression: false,
                                              location: start)])
    }

    /// `qw(a b c)` は文字列のリスト。
    private func readWordList(start: SourceLocation) -> MLToken {
        let (open, close) = delimiters()
        let text = readUntil(close, opening: open == close ? nil : open)
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return MLToken(kind: .symbol, text: "#words", location: start,
                       pieces: words.map { MLStringPiece(text: $0, isExpression: false,
                                                         location: start) })
    }

    /// Perl の文字列 (`"$name さん"` の補間つき)。
    private func readPerlString(terminator: Character, interpolates: Bool,
                                start: SourceLocation) -> MLToken {
        if peek() == terminator || peek() == "\"" || peek() == "'" { advance() }
        var pieces: [MLStringPiece] = []
        var literal = ""

        func flush() {
            if !literal.isEmpty {
                pieces.append(MLStringPiece(text: literal, isExpression: false,
                                            location: start))
                literal = ""
            }
        }

        while let character = peek() {
            if character == terminator {
                advance()
                break
            }
            if character == "\\" {
                advance()
                if interpolates {
                    literal += decodeEscape()
                } else if let escaped = advance() {
                    // 素の文字列では `\\` と `\'` だけが特別。
                    if escaped != "\\" && escaped != terminator { literal.append("\\") }
                    literal.append(escaped)
                }
                continue
            }
            if interpolates, character == "$" || character == "@",
               let next = peek(1), MLLexerBase.isIdentifierStart(next) || next == "_" {
                advance()
                var name = String(character) + readIdentifier()
                // `$h{key}` や `$a[0]` もそのまま式にする。
                while let bracket = peek(), bracket == "[" || bracket == "{" {
                    let close: Character = bracket == "[" ? "]" : "}"
                    var depth = 0
                    repeat {
                        guard let inner = peek() else { break }
                        if inner == bracket { depth += 1 }
                        if inner == close { depth -= 1 }
                        name.append(inner)
                        advance()
                    } while depth > 0 && !isAtEnd
                }
                // `->` でつながる参照も拾う。
                while lookahead("->"), let after = peek(2), after == "[" || after == "{" {
                    _ = match("->")
                    name += "->"
                    let bracket = peek() ?? "["
                    let close: Character = bracket == "[" ? "]" : "}"
                    var depth = 0
                    repeat {
                        guard let inner = peek() else { break }
                        if inner == bracket { depth += 1 }
                        if inner == close { depth -= 1 }
                        name.append(inner)
                        advance()
                    } while depth > 0 && !isAtEnd
                }
                flush()
                pieces.append(MLStringPiece(text: name, isExpression: true, location: start))
                continue
            }
            literal.append(character)
            advance()
        }
        flush()
        if pieces.allSatisfy({ !$0.isExpression }) {
            let text = pieces.map { $0.text }.joined()
            return MLToken(kind: .stringLiteral, text: text, location: start,
                           stringValue: text)
        }
        return MLToken(kind: .interpolatedString, text: "", location: start, pieces: pieces)
    }
}

final class PerlParser: MLProfileParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: PerlProfile.profile, diagnostics: diagnostics)
    }

    override var hasIncrementOperators: Bool { true }
    override var memberAccessOperators: [String] { ["->"] }

    // MARK: 文

    override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location

        if check("use") || check("no") || check("package") || check("require") {
            while !isAtEnd, !check(";") { advance() }
            _ = match(";")
            return .noop(location)
        }
        if check("sub"), peek(1).kind == .identifier {
            return .funcDecl(try parsePerlSub())
        }
        if check("if") || check("unless") { return try parsePerlIf() }
        if check("while") || check("until") { return try parsePerlWhile() }
        if check("for") || check("foreach") { return try parsePerlFor() }
        if check("last") {
            advance()
            let statement = MLStmt.breakStmt(label: nil, location)
            return try applyModifiers(to: statement, location: location)
        }
        if check("next") {
            advance()
            let statement = MLStmt.continueStmt(label: nil, location)
            return try applyModifiers(to: statement, location: location)
        }
        if check("return") {
            advance()
            var value: MLExpr?
            if !check(";") && !check("if") && !check("unless") {
                value = try parseExpression()
            }
            return try applyModifiers(to: .returnStmt(value, location), location: location)
        }
        if check("{") {
            advance()
            var body: [MLStmt] = []
            while !isAtEnd, !check("}") {
                skipStatementSeparators()
                if check("}") { break }
                let before = index
                if let statement = try parseStatement() { body.append(statement) }
                if index == before { advance() }
            }
            try expect("}", "ブロックの終わり")
            return .block(body, location)
        }
        if let keyword = matchedVariableKeyword() {
            return try applyModifiers(to: try parsePerlDeclaration(keyword: keyword,
                                                                   location: location),
                                      location: location)
        }

        let expression = try parseExpression()
        return try applyModifiers(to: .expression(expression, location), location: location)
    }

    /// `print "x" if $ok;` のような後置の修飾子。
    private func applyModifiers(to statement: MLStmt,
                                location: SourceLocation) throws -> MLStmt {
        var result = statement
        while !isAtEnd {
            if match("if") {
                result = .ifStmt(condition: try parseExpression(), then: [result],
                                 otherwise: nil, location)
                continue
            }
            if match("unless") {
                let condition = try parseExpression()
                result = .ifStmt(condition: .unary(op: "!", operand: condition,
                                                   isPostfix: false, location),
                                 then: [result], otherwise: nil, location)
                continue
            }
            if match("while") {
                result = .whileStmt(condition: try parseExpression(), body: [result],
                                    label: nil, location)
                continue
            }
            if match("until") {
                let condition = try parseExpression()
                result = .whileStmt(condition: .unary(op: "!", operand: condition,
                                                      isPostfix: false, location),
                                    body: [result], label: nil, location)
                continue
            }
            if match("foreach") || match("for") {
                let sequence = try parseExpression()
                result = .forIn(pattern: .binding("$_"), sequence: sequence, body: [result],
                                whereClause: nil, label: nil, location)
                continue
            }
            break
        }
        _ = match(";")
        return result
    }

    /// `my ($a, $b) = @_;` / `my @list = ...;`
    private func parsePerlDeclaration(keyword: String,
                                      location: SourceLocation) throws -> MLStmt {
        if match("(") {
            var names: [String] = []
            while !isAtEnd, !check(")") {
                if current.kind == .identifier { names.append(advance().text) }
                else { advance() }
                if !match(",") { break }
            }
            try expect(")", "宣言の終わり")
            var value: MLExpr = .listLiteral([], spreadIndices: [], location)
            if match("=") { value = try parseExpression() }
            let pattern = MLPattern.list(names.map { .binding($0) }, restIndex: nil,
                                         restName: nil)
            return .varDecl(pattern: pattern, typeName: nil, value: value,
                            isConstant: false, location)
        }
        let name = try expectIdentifier("変数名")
        var value: MLExpr?
        if match("=") { value = try parseExpression() }
        var initial = value ?? defaultValue(for: name, location: location)
        // `%h = (...)` は並びをハッシュに、`@a = ...` は並びを配列にする。
        if name.hasPrefix("%") {
            initial = .call(callee: .name("#hashfrom", location),
                            arguments: [MLArgument(value: initial)], location)
        } else if name.hasPrefix("@") {
            initial = .call(callee: .name("#listfrom", location),
                            arguments: [MLArgument(value: initial)], location)
        }
        return .varDecl(pattern: .binding(name), typeName: nil, value: initial,
                        isConstant: false, location)
    }

    private func defaultValue(for name: String, location: SourceLocation) -> MLExpr {
        if name.hasPrefix("@") { return .listLiteral([], spreadIndices: [], location) }
        if name.hasPrefix("%") { return .mapLiteral([], location) }
        return .literal(.unit, location)
    }

    private func parsePerlIf() throws -> MLStmt {
        let location = current.location
        let isUnless = check("unless")
        advance()
        try expect("(", "条件")
        var condition = try parseExpression()
        try expect(")", "条件の終わり")
        if isUnless {
            condition = .unary(op: "!", operand: condition, isPostfix: false, location)
        }
        let then = try parseBraceBlock()
        var otherwise: [MLStmt]?
        if check("elsif") {
            otherwise = [try parsePerlElsif()]
        } else if match("else") {
            otherwise = try parseBraceBlock()
        }
        return .ifStmt(condition: condition, then: then, otherwise: otherwise, location)
    }

    private func parsePerlElsif() throws -> MLStmt {
        let location = current.location
        try expect("elsif", "elsif")
        try expect("(", "条件")
        let condition = try parseExpression()
        try expect(")", "条件の終わり")
        let then = try parseBraceBlock()
        var otherwise: [MLStmt]?
        if check("elsif") {
            otherwise = [try parsePerlElsif()]
        } else if match("else") {
            otherwise = try parseBraceBlock()
        }
        return .ifStmt(condition: condition, then: then, otherwise: otherwise, location)
    }

    private func parsePerlWhile() throws -> MLStmt {
        let location = current.location
        let isUntil = check("until")
        advance()
        try expect("(", "条件")
        var condition = try parseExpression()
        try expect(")", "条件の終わり")
        if isUntil {
            condition = .unary(op: "!", operand: condition, isPostfix: false, location)
        }
        let body = try parseBraceBlock()
        return .whileStmt(condition: condition, body: body, label: nil, location)
    }

    private func parsePerlFor() throws -> MLStmt {
        let location = current.location
        advance()   // for / foreach
        // `foreach my $x (@list)`
        var variableName: String?
        if match("my") || match("our") || match("local") {
            variableName = try expectIdentifier("繰り返し変数")
        } else if current.kind == .identifier, current.text.hasPrefix("$"), peek(1).is("(") {
            variableName = advance().text
        }
        try expect("(", "for の始まり")
        if variableName == nil {
            // `for (init; cond; step)` かどうかを見分ける。
            let saved = index
            var depth = 1
            var isClassic = false
            var cursor = index
            while cursor < tokens.count, depth > 0 {
                let text = tokens[cursor].text
                if text == "(" { depth += 1 }
                if text == ")" { depth -= 1 }
                if text == ";" && depth == 1 { isClassic = true }
                cursor += 1
            }
            if isClassic {
                var initializer: [MLStmt] = []
                if !check(";") {
                    if let keyword = matchedVariableKeyword() {
                        initializer.append(try parsePerlDeclaration(keyword: keyword,
                                                                    location: location))
                    } else {
                        initializer.append(.expression(try parseExpression(), location))
                    }
                }
                _ = match(";")
                var condition: MLExpr?
                if !check(";") { condition = try parseExpression() }
                try expect(";", "for の条件")
                var step: [MLStmt] = []
                if !check(")") { step.append(.expression(try parseExpression(), location)) }
                try expect(")", "for の終わり")
                let body = try parseBraceBlock()
                return .forClassic(initializer: initializer, condition: condition,
                                   step: step, body: body, label: nil, location)
            }
            index = saved
        }
        let sequence = try parseExpression()
        try expect(")", "for の終わり")
        let body = try parseBraceBlock()
        return .forIn(pattern: .binding(variableName ?? "$_"), sequence: sequence,
                      body: body, whereClause: nil, label: nil, location)
    }

    private func parsePerlSub() throws -> MLFunctionDecl {
        let location = current.location
        try expect("sub", "サブルーチン")
        let name = try expectIdentifier("サブルーチンの名前")
        let body = try parseBraceBlock()
        // 引数は `@_` に入れる。
        return MLFunctionDecl(name: name,
                              parameters: [MLParameter(name: "@_", isVariadic: true)],
                              body: body, location: location)
    }

    func parseBraceBlock() throws -> [MLStmt] {
        try expect("{", "ブロックの始まり")
        var body: [MLStmt] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            let before = index
            if let statement = try parseStatement() { body.append(statement) }
            if index == before { advance() }
        }
        try expect("}", "ブロックの終わり")
        return body
    }

    // MARK: 式

    override func precedence(of op: String) -> Int? {
        switch op {
        case "or", "xor": return 1
        case "and": return 2
        case "eq", "ne", "<=>", "cmp": return 7
        case "lt", "gt", "le", "ge": return 8
        case "x": return 13
        case ".": return 12
        case "//": return 9
        default: return super.precedence(of: op)
        }
    }

    /// `%h = (...)` の代入も、並びをハッシュに直す。
    override func parseAssignment(stopAtBrace: Bool) throws -> MLExpr {
        let left = try parseTernary(stopAtBrace: stopAtBrace)
        guard profile.assignmentOperators.contains(current.text),
              current.kind == .punctuation else { return left }
        let location = current.location
        let op = advance().text
        var right = try parseAssignment(stopAtBrace: stopAtBrace)
        if op == "=", case .name(let name, _) = left {
            if name.hasPrefix("%") {
                right = .call(callee: .name("#hashfrom", location),
                              arguments: [MLArgument(value: right)], location)
            } else if name.hasPrefix("@") {
                right = .call(callee: .name("#listfrom", location),
                              arguments: [MLArgument(value: right)], location)
            }
        }
        return .assign(op: op, target: left, value: right, location)
    }

    /// `$x =~ s/a/b/` は代入になるので、二項演算の前に見ておく。
    override func parseBinary(minimumPrecedence: Int, stopAtBrace: Bool) throws -> MLExpr {
        var left = try super.parseBinary(minimumPrecedence: minimumPrecedence,
                                         stopAtBrace: stopAtBrace)
        while check("=~") || check("!~") {
            let location = current.location
            let isNegated = check("!~")
            advance()
            if current.kind == .symbol,
               current.text == "#subst" || current.text == "#trans" {
                let token = advance()
                let name = token.text == "#subst" ? "#substitute" : "#translate"
                let call = MLExpr.call(
                    callee: .name(name, location),
                    arguments: [MLArgument(value: left)]
                        + token.pieces.map { MLArgument(value: .literal(.string($0.text),
                                                                        location)) },
                    location)
                left = .assign(op: "=", target: left, value: call, location)
                continue
            }
            let pattern = try super.parseBinary(minimumPrecedence: 15,
                                                stopAtBrace: stopAtBrace)
            let call = MLExpr.call(callee: .name("#matches", location),
                                   arguments: [MLArgument(value: left),
                                               MLArgument(value: pattern)], location)
            left = isNegated ? .unary(op: "!", operand: call, isPostfix: false, location)
                             : call
        }
        return left
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location

        // 正規表現・`qw()`。
        if current.kind == .symbol {
            let token = advance()
            switch token.text {
            case "#match":
                return .call(callee: .name("#pattern", location),
                             arguments: token.pieces.map {
                                 MLArgument(value: .literal(.string($0.text), location))
                             }, location)
            case "#subst", "#trans":
                // `$_` に対する置換とみなす。
                let name = token.text == "#subst" ? "#substitute" : "#translate"
                let call = MLExpr.call(
                    callee: .name(name, location),
                    arguments: [MLArgument(value: .name("$_", location))]
                        + token.pieces.map { MLArgument(value: .literal(.string($0.text),
                                                                        location)) },
                    location)
                return .assign(op: "=", target: .name("$_", location), value: call, location)
            case "#words":
                return .listLiteral(token.pieces.map { .literal(.string($0.text), location) },
                                    spreadIndices: [], location)
            default:
                break
            }
        }

        // `sub { ... }` の無名サブルーチン。
        if check("sub"), peek(1).is("{") {
            advance()
            let body = try parseBraceBlock()
            return .lambda(MLFunctionDecl(name: "",
                                          parameters: [MLParameter(name: "@_",
                                                                   isVariadic: true)],
                                          body: body, location: location), location)
        }
        // `\@list` などの参照は、そのまま値として扱う。
        if check("\\") {
            advance()
            return try parseUnary(stopAtBrace: stopAtBrace)
        }
        // ブロックを取る組み込み (`sort { $a <=> $b } @list`)。
        if current.kind == .keyword || current.kind == .identifier,
           PerlParser.blockTakingFunctions.contains(current.text), peek(1).is("{") {
            let name = advance().text
            let body = try parseBraceBlock()
            let closure = MLExpr.lambda(
                MLFunctionDecl(name: "", parameters: [], body: liftedReturn(body),
                               usesImplicitArguments: true, location: location), location)
            var arguments: [MLArgument] = [MLArgument(value: closure)]
            _ = match(",")
            while !isAtEnd, !check(";"), !check(")"), !check("}") {
                arguments.append(MLArgument(value: try parseAssignment(
                    stopAtBrace: stopAtBrace)))
                if !match(",") { break }
            }
            return .call(callee: .name(name, location), arguments: arguments, location)
        }
        // `{ a => 1 }` は無名ハッシュ。
        if check("{"), !stopAtBrace { return try parseHashLiteral() }
        // `(1, 2, 3)` はリスト。括弧 1 つだけならただのまとまり。
        if check("(") {
            advance()
            var items: [MLExpr] = []
            var sawComma = false
            while !isAtEnd, !check(")") {
                var item = try parseAssignment(stopAtBrace: false)
                // `key => value` は組にする。
                if check("=>") {
                    if case .name(let name, let keyLocation) = item, !name.hasPrefix("$") {
                        item = .literal(.string(name), keyLocation)
                    }
                    advance()
                    let paired = try parseAssignment(stopAtBrace: false)
                    item = .tupleLiteral([item, paired], location)
                }
                items.append(item)
                if match(",") { sawComma = true } else { break }
            }
            try expect(")", "括弧の終わり")
            if items.count == 1 && !sawComma { return items[0] }
            return .listLiteral(items, spreadIndices: [], location)
        }
        // 括弧なしの組み込み呼び出し (`print "x";` / `push @a, 1;`)。
        if (current.kind == .keyword || current.kind == .identifier),
           PerlParser.bareFunctions.contains(current.text), !peek(1).is("(") {
            let name = advance().text
            var arguments: [MLArgument] = []
            while !isAtEnd, !check(";"), !check(")"), !check("}"), !check("]"), !check(","),
                  !check("if"), !check("unless"), !check("for"), !check("foreach"),
                  !check("while"), !check("until"), !check("or"), !check("and") {
                arguments.append(MLArgument(value: try parseAssignment(
                    stopAtBrace: stopAtBrace)))
                if !match(",") { break }
            }
            return .call(callee: .name(name, location), arguments: arguments, location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    /// ブロックの最後の式を戻り値にする。
    private func liftedReturn(_ body: [MLStmt]) -> [MLStmt] {
        guard case .expression(let value, let location)? = body.last else { return body }
        return body.dropLast() + [.returnStmt(value, location)]
    }

    private func parseHashLiteral() throws -> MLExpr {
        let location = current.location
        try expect("{", "ハッシュの始まり")
        var pairs: [(key: MLExpr, value: MLExpr)] = []
        while !isAtEnd, !check("}") {
            var key = try parseAssignment(stopAtBrace: false)
            // `a => 1` の左は裸の文字列でもよい。
            if case .name(let name, let keyLocation) = key, !name.hasPrefix("$") {
                key = .literal(.string(name), keyLocation)
            }
            guard match("=>") || match(",") else { break }
            pairs.append((key: key, value: try parseAssignment(stopAtBrace: false)))
            if !match(",") { break }
        }
        try expect("}", "ハッシュの終わり")
        return .mapLiteral(pairs, location)
    }

    /// `$list[0]` は `@list` の要素、`$h{k}` は `%h` の要素。
    override func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        var expression = try parsePrimary(stopAtBrace: stopAtBrace)
        while !isAtEnd {
            let location = current.location
            if check("["), canSubscript(expression) {
                advance()
                let index = try parseExpression()
                try expect("]", "添字")
                expression = .subscriptExpr(retarget(expression, sigil: "@"), index: index,
                                            upper: nil, location)
                continue
            }
            if check("{"), canSubscript(expression) {
                advance()
                let index = try parseHashKey()
                try expect("}", "ハッシュの添字")
                expression = .subscriptExpr(retarget(expression, sigil: "%"), index: index,
                                            upper: nil, location)
                continue
            }
            if check("->") {
                advance()
                if match("[") {
                    let index = try parseExpression()
                    try expect("]", "添字")
                    expression = .subscriptExpr(expression, index: index, upper: nil,
                                                location)
                    continue
                }
                if match("{") {
                    let index = try parseHashKey()
                    try expect("}", "ハッシュの添字")
                    expression = .subscriptExpr(expression, index: index, upper: nil,
                                                location)
                    continue
                }
                if match("(") {
                    var arguments: [MLArgument] = []
                    while !isAtEnd, !check(")") {
                        arguments.append(try parseArgument())
                        if !match(",") { break }
                    }
                    try expect(")", "引数の終わり")
                    expression = .call(callee: expression, arguments: arguments, location)
                    continue
                }
                let name = try expectIdentifier("メソッド名")
                var arguments: [MLArgument] = []
                if match("(") {
                    while !isAtEnd, !check(")") {
                        arguments.append(try parseArgument())
                        if !match(",") { break }
                    }
                    try expect(")", "引数の終わり")
                }
                expression = .call(callee: .member(expression, name, isOptional: false,
                                                   location),
                                   arguments: arguments, location)
                continue
            }
            if check("(") , isCallable(expression) {
                advance()
                var arguments: [MLArgument] = []
                while !isAtEnd, !check(")") {
                    arguments.append(try parseArgument())
                    if !match(",") { break }
                }
                try expect(")", "引数の終わり")
                expression = .call(callee: expression, arguments: arguments, location)
                continue
            }
            if check("++") || check("--") {
                let op = advance().text
                expression = .unary(op: op, operand: expression, isPostfix: true, location)
                continue
            }
            break
        }
        return expression
    }

    /// `{ key }` の中は裸の語も文字列として扱う。
    private func parseHashKey() throws -> MLExpr {
        if current.kind == .identifier, !current.text.hasPrefix("$"),
           peek(1).is("}") {
            let token = advance()
            return .literal(.string(token.text), token.location)
        }
        return try parseExpression()
    }

    /// 添字を付けられる形か。
    private func canSubscript(_ expression: MLExpr) -> Bool {
        switch expression {
        case .name(let name, _):
            return name.hasPrefix("$") || name.hasPrefix("@") || name.hasPrefix("%")
        case .subscriptExpr:
            return true
        default:
            return false
        }
    }

    private func isCallable(_ expression: MLExpr) -> Bool {
        switch expression {
        case .name(let name, _): return !name.hasPrefix("@") && !name.hasPrefix("%")
        default: return true
        }
    }

    /// `$list[0]` の受け手を `@list` に、`$h{k}` の受け手を `%h` に直す。
    private func retarget(_ expression: MLExpr, sigil: String) -> MLExpr {
        guard case .name(let name, let location) = expression, name.hasPrefix("$") else {
            return expression
        }
        return .name(sigil + name.dropFirst(), location)
    }

    override func parseArgument() throws -> MLArgument {
        let value = try parseAssignment(stopAtBrace: false)
        // `a => 1` は名前つきの組。
        if match("=>") {
            var key = value
            if case .name(let name, let location) = value, !name.hasPrefix("$") {
                key = .literal(.string(name), location)
            }
            let paired = try parseAssignment(stopAtBrace: false)
            return MLArgument(value: .tupleLiteral([key, paired], value.location))
        }
        return MLArgument(value: value)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        PerlLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        PerlParser(tokens: tokens, diagnostics: diagnostics)
    }

    /// ブロックを先に取る組み込み。
    static let blockTakingFunctions: Set<String> = ["sort", "map", "grep"]

    /// 括弧を省いて呼べる組み込み。
    static let bareFunctions: Set<String> = [
        "print", "printf", "push", "pop", "shift", "unshift", "keys", "values", "scalar",
        "reverse", "join", "split", "sort", "die", "warn", "defined", "exists", "delete",
        "ref", "chomp", "chop", "uc", "lc", "ucfirst", "lcfirst", "length", "sprintf",
        "return", "abs", "int", "sqrt", "each"
    ]
}
