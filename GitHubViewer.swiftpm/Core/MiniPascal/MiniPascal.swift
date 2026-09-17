import Foundation

/// 内蔵の Pascal 処理系。
///
/// `begin` … `end` でブロックを閉じるので `MLEndBlockParser` を土台にしている。
/// Pascal は大文字小文字を区別しないので、字句解析の時点で識別子を小文字に
/// そろえてある。
public enum MiniPascal: MiniLangEngine {
    public static var languageID: String { "pascal" }
    public static var displayName: String { "内蔵 Pascal 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = PascalLexer(source: source, diagnostics: diagnostics).tokenize()
        return try PascalParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = PascalLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = PascalParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: PascalSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum PascalProfile {
    static let keywords: Set<String> = [
        "and", "array", "asm", "begin", "case", "const", "constructor", "destructor",
        "div", "do", "downto", "else", "end", "file", "for", "function", "goto", "if",
        "implementation", "in", "inherited", "initialization", "interface", "label",
        "mod", "nil", "not", "object", "of", "or", "packed", "procedure", "program",
        "record", "repeat", "set", "shl", "shr", "string", "then", "to", "type", "unit",
        "until", "uses", "var", "while", "with", "xor", "true", "false", "class",
        "private", "public", "protected", "property", "try", "except", "finally",
        "raise", "on", "operator", "out", "result"
    ]

    static let profile = MLLanguageProfile(
        languageID: "pascal",
        comments: [.line("//"), .block(open: "{", close: "}", nesting: false),
                   .block(open: "(*", close: "*)", nesting: false)],
        strings: [MLLanguageProfile.StringStyle(quote: "'", allowsEscapes: false)],
        keywords: keywords,
        operators: [":=", "<>", "<=", ">=", "..", "+=", "-=", "*=", "/=",
                    "+", "-", "*", "/", "=", "<", ">", "(", ")", "[", "]",
                    ",", ";", ":", ".", "^", "@"],
        newlineTerminatesStatement: false,
        usesSemicolons: true,
        allowsNumericSeparators: false,
        functionSyntax: .keyword,
        functionKeywords: ["function", "procedure"],
        variableKeywords: [:],
        typeKeywords: [:],
        ignorableModifiers: ["packed", "private", "public", "protected"],
        lambdaArrows: [],
        nullLiterals: ["nil"],
        selfKeywords: ["self"],
        assignmentOperators: [":=", "+=", "-=", "*=", "/="])
}

final class PascalLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: PascalProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        let start = location
        // 文字列は `''` で引用符 1 つを表す。
        if peek() == "'" { return readPascalString(start: start) }
        // `#65` は文字コード。
        if peek() == "#", let next = peek(1), next.isNumber {
            advance()
            var digits = ""
            while let character = peek(), character.isNumber {
                digits.append(character)
                advance()
            }
            let code = UInt32(digits) ?? 32
            let scalar = Unicode.Scalar(code) ?? " "
            return MLToken(kind: .charLiteral, text: String(Character(scalar)),
                           location: start, stringValue: String(Character(scalar)))
        }
        // `$FF` は 16 進数。
        if peek() == "$", let next = peek(1), next.isHexDigit {
            advance()
            var digits = ""
            while let character = peek(), character.isHexDigit {
                digits.append(character)
                advance()
            }
            return MLToken(kind: .integerLiteral, text: digits, location: start,
                           intValue: Int64(digits, radix: 16) ?? 0)
        }
        guard let character = peek(), MLLexerBase.isIdentifierStart(character) else {
            return super.nextToken()
        }
        // 大文字小文字を区別しないので、すべて小文字にそろえる。
        let text = readIdentifier().lowercased()
        let kind: MLTokenKind = profile.keywords.contains(text) ? .keyword : .identifier
        return MLToken(kind: kind, text: text, location: start)
    }

    /// `'It''s'` のような引用符の重ねに対応する。
    private func readPascalString(start: SourceLocation) -> MLToken {
        advance()   // 開きの `'`
        var text = ""
        while !isAtEnd {
            guard let character = peek() else { break }
            if character == "'" {
                advance()
                if peek() == "'" {
                    text.append("'")
                    advance()
                    continue
                }
                break
            }
            text.append(character)
            advance()
        }
        return MLToken(kind: .stringLiteral, text: text, location: start, stringValue: text)
    }
}

final class PascalParser: MLEndBlockParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: PascalProfile.profile, diagnostics: diagnostics)
    }

    override var blockTerminators: Set<String> { ["end"] }
    override var branchKeywords: Set<String> { ["else"] }
    override var thenKeywords: Set<String> { ["then", "do"] }
    override var blockOpener: String? { "begin" }
    override var hasIncrementOperators: Bool { false }
    override var memberAccessOperators: [String] { ["."] }

    /// いま読んでいる関数の名前 (`Fib := ...` を戻り値の代入として扱うため)。
    private var currentFunctionName: String?
    /// 宣言済みの型名。
    private var declaredTypes: Set<String> = []

    // MARK: プログラム全体

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        var mainBody: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            if check("program") || check("unit") || check("uses") || check("library") {
                skipUntilSemicolon()
                continue
            }
            if check("interface") || check("implementation") {
                advance()
                continue
            }
            // 宣言の節はそのまま並べる (block に包むと外から見えなくなる)。
            if check("var") || check("const") {
                statements += try parseDeclarationSection()
                continue
            }
            if check("type") {
                statements += try parseTypeSection()
                continue
            }
            if check("begin") {
                // 主プログラムの本体。
                mainBody = try parseBlock()
                _ = match(".")
                continue
            }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        return MLProgram(statements: statements + mainBody)
    }

    private func skipUntilSemicolon() {
        while !isAtEnd, !check(";") { advance() }
        _ = match(";")
    }

    // MARK: 文

    override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location

        if check("var") || check("const") {
            return .block(try parseDeclarationSection(), location)
        }
        if check("type") { return .block(try parseTypeSection(), location) }
        if check("function") || check("procedure") {
            return .funcDecl(try parseRoutine())
        }
        if check("begin") {
            let body = try parseBlock()
            _ = match(";")
            return .block(body, location)
        }
        if check("if") { return try parsePascalIf() }
        if check("while") {
            advance()
            let condition = try parseExpression()
            _ = match("do")
            let body = try parseStatementOrBlock()
            return .whileStmt(condition: condition, body: body, label: nil, location)
        }
        if check("repeat") {
            advance()
            let body = try parseStatements(until: ["until"])
            _ = match("until")
            let condition = try parseExpression()
            _ = match(";")
            return .doWhile(body: body, condition: condition, isUntil: true, label: nil,
                            location)
        }
        if check("for") { return try parsePascalFor() }
        if check("case") { return try parsePascalCase() }
        if check("try") { return try parsePascalTry() }
        if check("raise") {
            advance()
            let value = try parseExpression()
            _ = match(";")
            return .throwStmt(value, location)
        }
        if check("break") {
            advance()
            _ = match(";")
            return .breakStmt(label: nil, location)
        }
        if check("continue") {
            advance()
            _ = match(";")
            return .continueStmt(label: nil, location)
        }
        if check("exit") {
            advance()
            var value: MLExpr?
            if match("(") {
                if !check(")") { value = try parseExpression() }
                try expect(")", "exit")
            }
            _ = match(";")
            if value == nil, currentFunctionName != nil {
                return .returnStmt(.name("result", location), location)
            }
            return .returnStmt(value, location)
        }
        if check("with") {
            // `with X do` は対応しないので、本体だけ読む。
            advance()
            _ = try? parseExpression()
            _ = match("do")
            let body = try parseStatementOrBlock()
            return .block(body, location)
        }

        // 括弧なしの手続き呼び出し (`WriteLn;`)。
        if current.kind == .identifier, peek(1).is(";") {
            let name = advance().text
            _ = match(";")
            return .expression(.call(callee: .name(name, location), arguments: [], location),
                               location)
        }

        let expression = try parseExpression()
        _ = match(";")
        return .expression(rewriteResultAssignment(expression), location)
    }

    /// `Fib := N` を `Result := N` と読み替える。
    private func rewriteResultAssignment(_ expression: MLExpr) -> MLExpr {
        guard let name = currentFunctionName,
              case .assign(let op, let target, let value, let location) = expression,
              case .name(let targetName, _) = target, targetName == name else {
            return expression
        }
        return .assign(op: op, target: .name("result", location), value: value, location)
    }

    /// `begin ... end` か、単文 1 つ。
    private func parseStatementOrBlock() throws -> [MLStmt] {
        if check("begin") {
            let body = try parseBlock()
            _ = match(";")
            return body
        }
        guard let statement = try parseStatement() else { return [] }
        return [statement]
    }

    private func parsePascalIf() throws -> MLStmt {
        let location = current.location
        try expect("if", "if 文")
        let condition = try parseExpression()
        _ = match("then")
        let then = try parseStatementOrBlock()
        var otherwise: [MLStmt]?
        if match("else") { otherwise = try parseStatementOrBlock() }
        return .ifStmt(condition: condition, then: then, otherwise: otherwise, location)
    }

    private func parsePascalFor() throws -> MLStmt {
        let location = current.location
        try expect("for", "for 文")
        let name = try expectIdentifier("繰り返し変数")
        if match("in") {
            let sequence = try parseExpression()
            _ = match("do")
            let body = try parseStatementOrBlock()
            return .forIn(pattern: .binding(name), sequence: sequence, body: body,
                          whereClause: nil, label: nil, location)
        }
        try expect(":=", "for の初期値")
        let start = try parseExpression()
        let isDown = check("downto")
        guard match("to") || match("downto") else {
            throw report("for には to か downto が必要です")
        }
        let limit = try parseExpression()
        _ = match("do")
        let body = try parseStatementOrBlock()

        let initializer = MLStmt.expression(
            .assign(op: "=", target: .name(name, location), value: start, location), location)
        let condition = MLExpr.binary(op: isDown ? ">=" : "<=", lhs: .name(name, location),
                                      rhs: limit, location)
        let step = MLStmt.expression(
            .assign(op: isDown ? "-=" : "+=", target: .name(name, location),
                    value: .literal(.int(1), location), location), location)
        return .forClassic(initializer: [initializer], condition: condition, step: [step],
                           body: body, label: nil, location)
    }

    private func parsePascalCase() throws -> MLStmt {
        let location = current.location
        try expect("case", "case 文")
        let subject = try parseExpression()
        try expect("of", "case 文")
        var arms: [MLMatchArm] = []
        while !isAtEnd, !check("end"), !check("else") {
            skipStatementSeparators()
            if check("end") || check("else") { break }
            var patterns: [MLPattern] = []
            repeat {
                let lower = try parseExpression()
                if match("..") {
                    let upper = try parseExpression()
                    patterns.append(.range(lower: lower, upper: upper, isClosed: true))
                } else if case .literal(let value, _) = lower {
                    patterns.append(.literal(value))
                } else {
                    patterns.append(.expression(lower))
                }
            } while match(",")
            try expect(":", "case の分岐")
            let body = try parseStatementOrBlock()
            arms.append(MLMatchArm(patterns: patterns, body: body))
            _ = match(";")
        }
        if match("else") {
            let body = try parseStatements(until: ["end"])
            arms.append(MLMatchArm(patterns: [], body: body, isDefault: true))
        }
        _ = match("end")
        _ = match(";")
        return .matchStmt(subject: subject, arms: arms, label: nil, location)
    }

    private func parsePascalTry() throws -> MLStmt {
        let location = current.location
        try expect("try", "try 文")
        let body = try parseStatements(until: ["except", "finally", "end"])
        var catches: [MLCatchClause] = []
        var finallyBody: [MLStmt]?
        if match("except") {
            if match("on") {
                var binding: String?
                var typeName: String?
                if current.kind == .identifier, peek(1).is(":") {
                    binding = advance().text
                    advance()
                }
                typeName = try? parseTypeName()
                _ = match("do")
                let clause = try parseStatements(until: ["end", "else"])
                catches.append(MLCatchClause(typeName: typeName, binding: binding,
                                             body: clause))
            } else {
                let clause = try parseStatements(until: ["end", "finally"])
                catches.append(MLCatchClause(body: clause))
            }
        }
        if match("finally") {
            finallyBody = try parseStatements(until: ["end"])
        }
        _ = match("end")
        _ = match(";")
        return .tryStmt(body: body, catches: catches, finallyBody: finallyBody, location)
    }

    // MARK: 宣言

    /// `var x, y: Integer;` の節。
    private func parseDeclarationSection() throws -> [MLStmt] {
        let location = current.location
        let isConstant = check("const")
        advance()
        var declarations: [MLStmt] = []
        while !isAtEnd, current.kind == .identifier {
            var names: [String] = [advance().text]
            while match(",") { names.append(try expectIdentifier("変数名")) }
            var typeName: String?
            var value: MLExpr?
            if match(":") { typeName = try parsePascalTypeName() }
            if match("=") || match(":=") { value = try parseExpression() }
            _ = match(";")
            for name in names {
                declarations.append(.varDecl(pattern: .binding(name), typeName: typeName,
                                             value: value
                                                ?? .defaultValue(typeName: typeName, location),
                                             isConstant: isConstant && value != nil,
                                             location))
            }
        }
        return declarations
    }

    /// `type TPoint = record ... end;` の節。
    private func parseTypeSection() throws -> [MLStmt] {
        let location = current.location
        try expect("type", "type 節")
        var declarations: [MLStmt] = []
        while !isAtEnd, current.kind == .identifier {
            let name = advance().text
            declaredTypes.insert(name)
            try expect("=", "型の定義")
            if match("record") || match("object") || match("class") {
                var properties: [MLPropertyDecl] = []
                while !isAtEnd, !check("end") {
                    skipStatementSeparators()
                    if check("end") { break }
                    while profile.ignorableModifiers.contains(current.text) { advance() }
                    guard current.kind == .identifier else { break }
                    var fields: [String] = [advance().text]
                    while match(",") { fields.append(try expectIdentifier("フィールド名")) }
                    var fieldType: String?
                    if match(":") { fieldType = try parsePascalTypeName() }
                    _ = match(";")
                    for field in fields {
                        properties.append(MLPropertyDecl(
                            name: field, typeName: fieldType,
                            defaultValue: .defaultValue(typeName: fieldType, location)))
                    }
                }
                _ = match("end")
                _ = match(";")
                declarations.append(.typeDecl(MLTypeDecl(kind: .structType, name: name,
                                                         properties: properties,
                                                         location: location)))
                continue
            }
            if match("(") {
                // 列挙型。
                var cases: [MLCaseDecl] = []
                while !isAtEnd, !check(")") {
                    let caseName = try expectIdentifier("列挙のケース")
                    var rawValue: MLExpr?
                    if match("=") { rawValue = try parseExpression() }
                    cases.append(MLCaseDecl(name: caseName, rawValue: rawValue))
                    if !match(",") { break }
                }
                try expect(")", "列挙の終わり")
                _ = match(";")
                declarations.append(.typeDecl(MLTypeDecl(kind: .enumType, name: name,
                                                         cases: cases, location: location)))
                continue
            }
            // 別名や配列型はそのまま読み飛ばす。
            _ = try? parsePascalTypeName()
            _ = match(";")
        }
        _ = location
        return declarations
    }

    private func parseRoutine() throws -> MLFunctionDecl {
        let location = current.location
        let isFunction = check("function")
        advance()
        var name = try expectIdentifier("手続きの名前")
        // `TPoint.Length` のようなメソッド定義は名前をつなげる。
        while match(".") { name += "." + (try expectIdentifier("メソッド名")) }

        var parameters: [MLParameter] = []
        if match("(") {
            while !isAtEnd, !check(")") {
                parameters.append(contentsOf: try parsePascalParameters())
                if !match(";") && !match(",") { break }
            }
            try expect(")", "引数の終わり")
        }
        var returnTypeName: String?
        if isFunction, match(":") { returnTypeName = try parsePascalTypeName() }
        _ = match(";")
        // `forward;` や呼び出し規約は読み飛ばす。
        while current.kind == .identifier, peek(1).is(";"),
              ["forward", "cdecl", "stdcall", "overload", "inline", "register"]
                .contains(current.text) {
            advance()
            advance()
        }

        let previousFunction = currentFunctionName
        currentFunctionName = isFunction ? name : nil
        defer { currentFunctionName = previousFunction }

        // 入れ子の宣言 (var / const / type / 内側の手続き)。
        var prelude: [MLStmt] = []
        while check("var") || check("const") || check("type")
                || check("function") || check("procedure") {
            if check("function") || check("procedure") {
                prelude.append(.funcDecl(try parseRoutine()))
            } else if check("type") {
                prelude += try parseTypeSection()
            } else {
                prelude += try parseDeclarationSection()
            }
        }

        var body = try parseBlock()
        _ = match(";")
        if isFunction {
            body = [.varDecl(pattern: .binding("result"), typeName: returnTypeName,
                             value: .defaultValue(typeName: returnTypeName, location),
                             isConstant: false, location)]
                + prelude + body
                + [.returnStmt(.name("result", location), location)]
        } else {
            body = prelude + body
        }
        return MLFunctionDecl(name: name, parameters: parameters, body: body,
                              returnTypeName: returnTypeName, location: location)
    }

    /// `var A, B: Integer` のようにまとめて書かれた引数。
    private func parsePascalParameters() throws -> [MLParameter] {
        var isByReference = false
        if match("var") || match("out") { isByReference = true }
        _ = match("const")
        var names: [String] = [try expectIdentifier("引数名")]
        while match(",") { names.append(try expectIdentifier("引数名")) }
        var typeName: String?
        if match(":") { typeName = try parsePascalTypeName() }
        var defaultValue: MLExpr?
        if match("=") { defaultValue = try parseExpression() }
        return names.map {
            MLParameter(name: $0, typeName: typeName, defaultValue: defaultValue,
                        isByReference: isByReference)
        }
    }

    /// `array[1..10] of Integer` のような型の書き方を読む。
    private func parsePascalTypeName() throws -> String {
        if match("array") {
            if match("[") {
                var depth = 1
                while !isAtEnd, depth > 0 {
                    if check("[") { depth += 1 }
                    if check("]") { depth -= 1 }
                    advance()
                }
            }
            _ = match("of")
            _ = try? parsePascalTypeName()
            return "array"
        }
        if match("^") { return try parsePascalTypeName() }
        if match("set") {
            _ = match("of")
            _ = try? parsePascalTypeName()
            return "set"
        }
        if check("record") { return "record" }
        guard current.kind == .identifier || current.kind == .keyword else { return "" }
        return advance().text
    }

    // MARK: 式

    override func precedence(of op: String) -> Int? {
        switch op {
        case "=": return 7
        case "<>": return 7
        case "div", "mod", "shl", "shr": return 13
        case "xor": return 4
        case "in": return 8
        default: return super.precedence(of: op)
        }
    }

    /// `:=` はただの代入なので、複合代入と間違えないよう `=` に直す。
    override func parseAssignment(stopAtBrace: Bool) throws -> MLExpr {
        let left = try parseTernary(stopAtBrace: stopAtBrace)
        guard profile.assignmentOperators.contains(current.text),
              current.kind == .punctuation else { return left }
        let location = current.location
        let op = advance().text
        let right = try parseAssignment(stopAtBrace: stopAtBrace)
        return .assign(op: op == ":=" ? "=" : op, target: left, value: right, location)
    }

    override func parseArgument() throws -> MLArgument {
        let value = try parseExpression()
        // `Write(X:8:2)` の桁指定。
        guard check(":") else { return MLArgument(value: value) }
        let location = current.location
        advance()
        let width = try parseExpression()
        var decimals: MLExpr = .literal(.int(-1), location)
        if match(":") { decimals = try parseExpression() }
        return MLArgument(value: .call(callee: .name("#format", location),
                                       arguments: [MLArgument(value: value),
                                                   MLArgument(value: width),
                                                   MLArgument(value: decimals)],
                                       location))
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        // `[1, 2, 3]` は集合。配列として扱う。
        if check("[") { return try parseListOrMapLiteral() }
        if check("@") {
            advance()
            return try parseUnary(stopAtBrace: stopAtBrace)
        }
        if check("string") {
            advance()
            return .name("string", location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        PascalLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        PascalParser(tokens: tokens, diagnostics: diagnostics)
    }
}
