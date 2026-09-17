import Foundation

/// 内蔵の Julia 処理系。
public enum MiniJulia: MiniLangEngine {
    public static var languageID: String { "julia" }
    public static var displayName: String { "内蔵 Julia 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = JuliaLexer(source: source, diagnostics: diagnostics).tokenize()
        return try JuliaParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = JuliaLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = JuliaParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: JuliaSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum JuliaProfile {
    static let keywords: Set<String> = [
        "baremodule", "begin", "break", "catch", "const", "continue", "do", "else",
        "elseif", "end", "export", "false", "finally", "for", "function", "global",
        "if", "import", "let", "local", "macro", "module", "mutable", "quote", "return",
        "struct", "true", "try", "using", "while", "abstract", "primitive", "type",
        "where", "in", "isa", "nothing", "missing"
    ]

    static let profile = MLLanguageProfile(
        languageID: "julia",
        comments: [.line("#"), .block(open: "#=", close: "=#", nesting: true)],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", interpolationPrefix: "$(",
                                                simpleVariablePrefix: "$",
                                                isMultiline: true),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators
            + ["÷", "≤", "≥", "≠", ".+", ".-", ".*", "./", ".^", ".==", "|>", "->",
               "//", "\\", "∈", "∉"],
        newlineTerminatesStatement: true,
        usesSemicolons: true,
        identifierExtras: ["!"],
        functionSyntax: .keyword,
        functionKeywords: ["function"],
        variableKeywords: [:],
        typeKeywords: ["struct": .structType],
        ignorableModifiers: ["mutable", "const", "global", "local", "abstract",
                             "primitive", "@"],
        nullLiterals: ["nothing", "missing"],
        selfKeywords: [])
}

final class JuliaLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: JuliaProfile.profile, diagnostics: diagnostics)
    }

    /// 記号として扱う非 ASCII の演算子 (名前の一部にしない)。
    private static let symbolOperators: Set<Character> = ["÷", "≤", "≥", "≠", "∈", "∉"]

    override func nextToken() -> MLToken? {
        if let character = peek(), JuliaLexer.symbolOperators.contains(character) {
            let start = location
            advance()
            return MLToken(kind: .punctuation, text: String(character), location: start)
        }
        // `@printf` のようなマクロ。
        if peek() == "@", let next = peek(1), MLLexerBase.isIdentifierStart(next) {
            let start = location
            advance()
            let name = readIdentifier(extraCharacters: ["!"])
            return MLToken(kind: .identifier, text: "@" + name, location: start)
        }
        return super.nextToken()
    }
}

final class JuliaParser: MLEndBlockParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: JuliaProfile.profile, diagnostics: diagnostics)
    }

    override var blockTerminators: Set<String> { ["end"] }
    override var branchKeywords: Set<String> { ["else", "elseif"] }
    override var thenKeywords: Set<String> { [] }
    override var blockOpener: String? { "begin" }
    override var supportsIfExpression: Bool { true }
    override var hasIncrementOperators: Bool { false }
    /// Julia の添字は 1 から始まる。
    override var memberAccessOperators: [String] { ["."] }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            if check("using") || check("import") || check("export") || check("module")
                || check("baremodule") {
                skipToStatementEnd()
                continue
            }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        return MLProgram(statements: statements)
    }

    override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location

        if check("using") || check("import") || check("export") {
            skipToStatementEnd()
            return .noop(location)
        }
        if check("mutable"), peek(1).is("struct") {
            advance()
            return .typeDecl(try parseJuliaStruct())
        }
        if check("struct") { return .typeDecl(try parseJuliaStruct()) }
        if check("function") { return .funcDecl(try parseJuliaFunction()) }
        if check("macro") {
            advance()
            skipToStatementEnd()
            _ = try parseStatements(until: ["end"])
            _ = match("end")
            return .noop(location)
        }
        if check("let") {
            advance()
            var initializers: [MLStmt] = []
            while !isAtEnd, !current.precededByNewline || initializers.isEmpty {
                if check("end") || current.precededByNewline { break }
                let expression = try parseExpression()
                initializers.append(.expression(expression, location))
                if !match(",") { break }
            }
            let body = try parseBlock()
            return .block(initializers + body, location)
        }
        if check("quote") {
            advance()
            _ = try parseStatements(until: ["end"])
            _ = match("end")
            return .noop(location)
        }
        if check("global") || check("local") || check("const") {
            advance()
            return try parseStatement()
        }
        if check("do") {
            // `f(x) do y ... end` はここでは扱わない。
            advance()
            _ = try parseStatements(until: ["end"])
            _ = match("end")
            return .noop(location)
        }
        // 短縮形の関数定義 `f(x) = expr`
        if let short = try parseShortFunction() { return .funcDecl(short) }
        return try super.parseStatement()
    }

    /// `f(x, y) = x + y`
    private func parseShortFunction() throws -> MLFunctionDecl? {
        guard current.kind == .identifier, peek(1).is("(") else { return nil }
        // 対応する `)` の次が `=` (かつ `==` でない) なら短縮形。
        var offset = 1
        var depth = 0
        repeat {
            if peek(offset).is("(") { depth += 1 }
            if peek(offset).is(")") { depth -= 1 }
            offset += 1
        } while depth > 0 && !peek(offset).isEndOfFile
        guard peek(offset).is("=") else { return nil }

        let location = current.location
        let name = advance().text
        let parameters = try parseJuliaParameters()
        try expect("=", "短縮形の関数定義")
        let value = try parseExpression()
        consumeStatementEnd()
        return MLFunctionDecl(name: name, parameters: parameters,
                              body: [.returnStmt(value, value.location)], location: location)
    }

    private func parseJuliaFunction() throws -> MLFunctionDecl {
        let location = current.location
        try expect("function", "関数定義")
        let name = try expectIdentifier("関数名")
        let parameters = check("(") ? try parseJuliaParameters() : []
        if check("where") { skipToStatementEnd() }
        let body = try parseBlock()
        return MLFunctionDecl(name: name, parameters: parameters, body: body,
                              location: location)
    }

    private func parseJuliaParameters() throws -> [MLParameter] {
        try expect("(", "引数の始まり")
        var parameters: [MLParameter] = []
        var sawSemicolon = false
        while !isAtEnd, !check(")") {
            if match(";") {
                sawSemicolon = true
                continue
            }
            let name = try expectIdentifier("引数名")
            var typeName: String?
            if match("::") { typeName = try parseJuliaTypeName() }
            var isVariadic = false
            if match("...") { isVariadic = true }
            var defaultValue: MLExpr?
            if match("=") { defaultValue = try parseExpression() }
            if sawSemicolon, defaultValue == nil {
                defaultValue = .literal(.unit, current.location)
            }
            parameters.append(MLParameter(label: sawSemicolon ? name : nil, name: name,
                                          typeName: typeName, defaultValue: defaultValue,
                                          isVariadic: isVariadic))
            if !match(",") { break }
        }
        try expect(")", "引数の終わり")
        return parameters
    }

    private func parseJuliaTypeName() throws -> String {
        guard current.kind == .identifier || current.kind == .keyword else {
            return "Any"
        }
        var text = advance().text
        if check("{") { skipBalanced(open: "{", close: "}") }
        while check("."), peek(1).kind == .identifier {
            advance()
            text = advance().text
        }
        return text
    }

    override func parseTypeName() throws -> String {
        try parseJuliaTypeName()
    }

    /// `struct Point x::Int; y::Int end`
    private func parseJuliaStruct() throws -> MLTypeDecl {
        let location = current.location
        try expect("struct", "構造体")
        let name = try expectIdentifier("型名")
        if check("{") { skipBalanced(open: "{", close: "}") }
        if match("<:") { _ = try? parseJuliaTypeName() }
        var properties: [MLPropertyDecl] = []
        var methods: [MLFunctionDecl] = []
        while !isAtEnd, !check("end") {
            skipStatementSeparators()
            if check("end") { break }
            if check("function") {
                methods.append(try parseJuliaFunction())
                continue
            }
            guard current.kind == .identifier else {
                advance()
                continue
            }
            let fieldName = advance().text
            var typeName: String?
            if match("::") { typeName = try parseJuliaTypeName() }
            properties.append(MLPropertyDecl(name: fieldName, typeName: typeName))
            consumeStatementEnd()
        }
        _ = match("end")
        return MLTypeDecl(kind: .structType, name: name, properties: properties,
                          methods: methods, location: location)
    }

    /// `try ... catch e ... finally ... end`
    override func parseTry() throws -> MLStmt {
        let location = current.location
        try expect("try")
        let body = try parseStatements(until: ["catch", "finally", "end"])
        var catches: [MLCatchClause] = []
        var finallyBody: [MLStmt]?
        if check("catch") {
            advance()
            var binding: String?
            if current.kind == .identifier, !current.precededByNewline {
                binding = advance().text
            }
            let clauseBody = try parseStatements(until: ["finally", "end"])
            catches.append(MLCatchClause(binding: binding, body: clauseBody))
        }
        if check("finally") {
            advance()
            finallyBody = try parseStatements(until: ["end"])
        }
        _ = match("end")
        return .tryStmt(body: body, catches: catches, finallyBody: finallyBody, location)
    }

    /// `for i in 1:10` / `for (i, v) in enumerate(xs)`
    override func parseFor(label: String?) throws -> MLStmt {
        let location = current.location
        try expect("for")
        let pattern = try parseForPattern()
        guard match("in") || match("=") || match("∈") else {
            throw report("for のあとに `in` が必要です")
        }
        let sequence = try parseExpression(stopAtBrace: true)
        let body = try parseBlock()
        return .forIn(pattern: pattern, sequence: sequence, body: body,
                      whereClause: nil, label: label, location)
    }

    /// `1:10` は範囲、`a[i]` は 1 起点の添字。
    override func precedence(of op: String) -> Int? {
        if op == ":" { return 10 }
        if op == "÷" || op == "//" { return 13 }
        if op == "≤" || op == "≥" || op == "≠" || op == "isa" || op == "∈" { return 8 }
        if op == "|>" { return 1 }
        if op == "=>" { return 6 }
        if op == "^" { return 15 }
        if op.hasPrefix("."), op.count > 1 {
            // ブロードキャスト演算子は元の演算子と同じ強さ。
            return super.precedence(of: String(op.dropFirst()))
        }
        return super.precedence(of: op)
    }

    override func isRightAssociative(_ op: String) -> Bool {
        op == "^" || super.isRightAssociative(op)
    }

    /// `x -> expr` / `(x, y) -> expr` の無名関数。
    override func parseLambdaIfPresent(stopAtBrace: Bool) throws -> MLExpr? {
        let location = current.location
        if current.kind == .identifier, peek(1).is("->") {
            let name = advance().text
            advance()
            let value = try parseExpression()
            return .lambda(MLFunctionDecl(name: "", parameters: [MLParameter(name: name)],
                                          body: [.returnStmt(value, value.location)],
                                          location: location), location)
        }
        guard check("(") else { return nil }
        var offset = 1
        var depth = 1
        while depth > 0, !peek(offset).isEndOfFile {
            if peek(offset).is("(") { depth += 1 }
            if peek(offset).is(")") { depth -= 1 }
            offset += 1
        }
        guard peek(offset).is("->") else { return nil }
        advance()
        var parameters: [MLParameter] = []
        while !isAtEnd, !check(")") {
            let name = try expectIdentifier("引数名")
            if match("::") { _ = try? parseTypeName() }
            parameters.append(MLParameter(name: name))
            if !match(",") { break }
        }
        try expect(")", "無名関数の引数")
        try expect("->", "無名関数")
        if check("begin") {
            advance()
            let body = try parseStatements(until: ["end"])
            _ = match("end")
            return .lambda(MLFunctionDecl(name: "", parameters: parameters, body: body,
                                          location: location), location)
        }
        let value = try parseExpression()
        return .lambda(MLFunctionDecl(name: "", parameters: parameters,
                                      body: [.returnStmt(value, value.location)],
                                      location: location), location)
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        // 添字の中の `end` は「最後の位置」。
        if check("end"), let receiver = subscriptReceiver {
            advance()
            return .call(callee: .name("length", location),
                         arguments: [MLArgument(value: receiver)], location)
        }
        if check("if") { return try parseIfExpression() }
        if check("begin") {
            advance()
            let body = try parseStatements(until: ["end"])
            _ = match("end")
            return .block(body, location)
        }
        // `[1, 2, 3]` と内包表記 `[x^2 for x in 1:10]`
        if check("[") { return try parseJuliaArray() }
        // `(a, b)` はタプル。
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    private func parseJuliaArray() throws -> MLExpr {
        let location = current.location
        try expect("[", "配列リテラル")
        if check("]") {
            advance()
            return .listLiteral([], spreadIndices: [], location)
        }
        let first = try parseExpression()
        // 内包表記。
        if check("for") {
            advance()
            var clauses: [MLComprehension.Clause] = []
            var filters: [MLExpr] = []
            repeat {
                let pattern = try parseForPattern()
                guard match("in") || match("=") || match("∈") else {
                    throw report("内包表記に `in` が必要です")
                }
                clauses.append(MLComprehension.Clause(pattern: pattern,
                                                      sequence: try parseExpression()))
            } while match(",")
            while match("if") { filters.append(try parseExpression()) }
            try expect("]", "内包表記の終わり")
            return .comprehension(MLComprehension(element: first, clauses: clauses,
                                                  filters: filters), location)
        }
        var items: [MLExpr] = [first]
        while match(",") {
            if check("]") { break }
            items.append(try parseExpression())
        }
        try expect("]", "配列リテラルの終わり")
        return .listLiteral(items, spreadIndices: [], location)
    }

    /// `f.(xs)` のブロードキャスト。
    override func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        var expression = try super.parsePostfix(stopAtBrace: stopAtBrace)
        while check("."), peek(1).is("(") {
            let location = advance().location
            let arguments = try parseArgumentList()
            expression = .call(callee: .name("#broadcast", location),
                               arguments: [MLArgument(value: expression)] + arguments,
                               location)
        }
        return expression
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        JuliaLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        JuliaParser(tokens: tokens, diagnostics: diagnostics)
    }
}
