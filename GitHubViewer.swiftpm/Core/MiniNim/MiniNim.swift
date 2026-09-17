import Foundation

/// 内蔵の Nim 処理系。
///
/// 字下げでブロックを表す言語なので `MLIndentParser` を土台にしている。
/// `proc` / `type` / `var` などの節、UFCS (`x.len`)、`result` 変数といった
/// Nim らしい書き方に対応する。
public enum MiniNim: MiniLangEngine {
    public static var languageID: String { "nim" }
    public static var displayName: String { "内蔵 Nim 処理系" }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = NimLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = NimParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: NimSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum NimProfile {
    static let keywords: Set<String> = [
        "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept",
        "const", "continue", "converter", "defer", "discard", "distinct", "div", "do",
        "elif", "else", "end", "enum", "except", "export", "finally", "for", "from",
        "func", "if", "import", "in", "include", "interface", "is", "isnot", "iterator",
        "let", "macro", "method", "mixin", "mod", "nil", "not", "notin", "object", "of",
        "or", "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static",
        "template", "try", "tuple", "type", "using", "var", "when", "while", "xor",
        "yield", "true", "false", "result"
    ]

    static let profile = MLLanguageProfile(
        languageID: "nim",
        comments: [.line("#"), .block(open: "#[", close: "]#", nesting: true)],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", isMultiline: true),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators + ["..<", "..", "..^", "->", "=>",
                                                        "@", "&", "$", "%", "!=", "==",
                                                        "<=", ">=", "+=", "-=", "*=",
                                                        "/=", "&="],
        newlineTerminatesStatement: true,
        usesSemicolons: true,
        allowsNumericSeparators: true,
        functionSyntax: .keyword,
        functionKeywords: ["proc", "func", "method", "iterator", "template", "converter"],
        variableKeywords: ["var": false, "let": true, "const": true],
        typeKeywords: [:],
        ignorableModifiers: ["export", "using", "mixin", "bind"],
        lambdaArrows: ["=>"],
        nullLiterals: ["nil"],
        selfKeywords: ["self"],
        assignmentOperators: ["=", "+=", "-=", "*=", "/=", "&=", "%=", "|=", "^="])
}

final class NimLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: NimProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        let start = location
        // `` `$` `` のように記号を名前として書く書き方。
        if peek() == "`" {
            advance()
            var name = ""
            while let character = peek(), character != "`" {
                name.append(character)
                advance()
            }
            advance()
            return MLToken(kind: .identifier, text: name, location: start)
        }
        // `&"{x} と {y}"` / `fmt"..."` は補間つき文字列。
        if peek() == "&", peek(1) == "\"" {
            advance()
            return readInterpolated(start: start)
        }
        if lookahead("fmt\"") {
            _ = match("fmt")
            return readInterpolated(start: start)
        }
        return super.nextToken()
    }

    private func readInterpolated(start: SourceLocation) -> MLToken {
        advance()   // 開きの `"`
        let pieces = readInterpolatedString(terminator: "\"", interpolationPrefix: "{")
        if pieces.allSatisfy({ !$0.isExpression }) {
            let text = pieces.map { $0.text }.joined()
            return MLToken(kind: .stringLiteral, text: text, location: start,
                           stringValue: text)
        }
        return MLToken(kind: .interpolatedString, text: "", location: start, pieces: pieces)
    }
}

final class NimParser: MLIndentParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: NimProfile.profile, diagnostics: diagnostics)
    }

    override var blockIntroducer: String? { ":" }
    override var supportsIfExpression: Bool { true }
    override var hasIncrementOperators: Bool { false }
    override var memberAccessOperators: [String] { ["."] }

    /// `method` で書かれた手続き。第 1 引数の型のメソッドとして付け直す。
    private var pendingMethods: [String: [MLFunctionDecl]] = [:]
    /// 宣言された型 (`method` の受け取り先を探すのに使う)。
    private var declaredTypes: [String] = []

    // MARK: プログラム全体

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        return MLProgram(statements: attachMethods(to: statements))
    }

    /// `method f(x: Circle)` を Circle のメソッドとして型宣言に入れ直す。
    private func attachMethods(to statements: [MLStmt]) -> [MLStmt] {
        guard !pendingMethods.isEmpty else { return statements }
        var dispatchers: Set<String> = []
        let result = rewrite(statements, dispatchers: &dispatchers)
        return result + makeDispatchers(dispatchers)
    }

    /// 型宣言を探して `method` を入れ直す (`type` 節は block に包まれている)。
    private func rewrite(_ statements: [MLStmt],
                         dispatchers: inout Set<String>) -> [MLStmt] {
        var result: [MLStmt] = []
        for statement in statements {
            if case .block(let inner, let location) = statement {
                result.append(.block(rewrite(inner, dispatchers: &dispatchers), location))
                continue
            }
            guard case .typeDecl(let decl) = statement,
                  let methods = pendingMethods[decl.name] else {
                result.append(statement)
                continue
            }
            result.append(.typeDecl(MLTypeDecl(kind: decl.kind, name: decl.name,
                                               superclassName: decl.superclassName,
                                               interfaceNames: decl.interfaceNames,
                                               properties: decl.properties,
                                               methods: decl.methods + methods,
                                               initializers: decl.initializers,
                                               cases: decl.cases,
                                               nestedTypes: decl.nestedTypes,
                                               bodyStatements: decl.bodyStatements,
                                               primaryParameters: decl.primaryParameters,
                                               isAbstract: decl.isAbstract,
                                               location: decl.location)))
            for method in methods { dispatchers.insert(method.name) }
        }
        return result
    }

    /// `area(shape)` のように関数として呼んでも動くよう、振り分け役を足す。
    private func makeDispatchers(_ dispatchers: Set<String>) -> [MLStmt] {
        var result: [MLStmt] = []
        for name in dispatchers.sorted() {
            let location = SourceLocation.unknown
            let call = MLExpr.call(callee: .member(.name("#receiver", location), name,
                                                   isOptional: false, location),
                                   arguments: [MLArgument(value: .name("#rest", location),
                                                          isSpread: true)],
                                   location)
            result.append(.funcDecl(MLFunctionDecl(
                name: name,
                parameters: [MLParameter(name: "#receiver"),
                             MLParameter(name: "#rest", isVariadic: true)],
                body: [.returnStmt(call, location)], location: location)))
        }
        return result
    }

    // MARK: 文

    override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location

        if check("import") || check("from") || check("include") || check("export") {
            skipLine()
            return .noop(location)
        }
        if check("when") {
            // `when isMainModule:` はそのまま本体を実行する。
            advance()
            _ = try? parseExpression(stopAtBrace: true)
            let body = try parseBlock()
            return .block(body, location)
        }
        if check("type") { return try parseTypeSection() }
        if check("var") || check("let") || check("const") { return try parseVarSection() }
        if let keyword = matchedRoutineKeyword() { return try parseRoutine(keyword: keyword) }
        if check("case") { return try parseNimCase() }
        if check("try") { return try parseNimTry() }
        if check("block") {
            advance()
            var label: String?
            if current.kind == .identifier, !check(":") { label = advance().text }
            let body = try parseBlock()
            // `block name:` から抜けるために while(false) の形にする。
            return .whileStmt(condition: .literal(.bool(true), location),
                              body: body + [.breakStmt(label: label, location)],
                              label: label, location)
        }
        if check("discard") {
            advance()
            if isAtEnd || current.precededByNewline { return .noop(location) }
            let value = try parseExpression()
            consumeStatementEnd()
            return .expression(value, location)
        }
        if check("raise") {
            advance()
            let value = try parseExpression()
            consumeStatementEnd()
            return .throwStmt(value, location)
        }
        if check("defer") {
            advance()
            let body = try parseBlock()
            return .block(body, location)
        }
        if check("if") { return try parseIf() }
        if check("while") { return try parseWhile(label: nil) }
        if check("for") { return try parseFor(label: nil) }
        if check("return") {
            advance()
            if isAtEnd || current.precededByNewline {
                consumeStatementEnd()
                return .returnStmt(nil, location)
            }
            let value = try parseExpression()
            consumeStatementEnd()
            return .returnStmt(value, location)
        }
        if check("break") {
            advance()
            var label: String?
            if !isAtEnd, current.kind == .identifier, !current.precededByNewline {
                label = advance().text
            }
            consumeStatementEnd()
            return .breakStmt(label: label, location)
        }
        if check("continue") {
            advance()
            consumeStatementEnd()
            return .continueStmt(label: nil, location)
        }
        if let command = try parseCommandCall() { return command }

        let expression = try parseExpression()
        consumeStatementEnd()
        return .expression(expression, location)
    }

    /// 行末まで読み飛ばす。
    private func skipLine() {
        while !isAtEnd {
            advance()
            if isAtEnd || current.precededByNewline { break }
        }
    }

    private func matchedRoutineKeyword() -> String? {
        guard profile.functionKeywords.contains(current.text) else { return nil }
        return current.text
    }

    /// 括弧を省いた呼び出し (`echo "a", x`)。
    private func parseCommandCall() throws -> MLStmt? {
        guard current.kind == .identifier || current.text == "echo" else { return nil }
        let next = peek(1)
        guard !next.precededByNewline else { return nil }
        let startsArgument: Bool
        switch next.kind {
        case .stringLiteral, .interpolatedString, .integerLiteral, .floatLiteral,
             .charLiteral:
            startsArgument = true
        case .identifier:
            startsArgument = true
        case .keyword:
            startsArgument = ["true", "false", "nil"].contains(next.text)
        case .punctuation:
            startsArgument = next.text == "@" || next.text == "$"
        default:
            startsArgument = false
        }
        guard startsArgument else { return nil }

        let location = current.location
        let saved = index
        let name = advance().text
        do {
            var arguments: [MLArgument] = []
            repeat {
                arguments.append(try parseArgument())
            } while match(",")
            consumeStatementEnd()
            return .expression(.call(callee: .name(name, location), arguments: arguments,
                                     location), location)
        } catch {
            index = saved
            return nil
        }
    }

    // MARK: 変数の節

    /// `var x = 1` と、字下げした `var` 節の両方を読む。
    private func parseVarSection() throws -> MLStmt {
        let location = current.location
        let keyword = advance().text
        let isConstant = keyword != "var"
        if !isAtEnd, !current.precededByNewline {
            return try parseVarEntry(isConstant: isConstant)
        }
        // 字下げした節。
        let column = current.location.column
        var declarations: [MLStmt] = []
        while !isAtEnd, current.location.column >= column {
            skipStatementSeparators()
            if isAtEnd || current.location.column < column { break }
            let before = index
            declarations.append(try parseVarEntry(isConstant: isConstant))
            if index == before { advance() }
        }
        return .block(declarations, location)
    }

    private func parseVarEntry(isConstant: Bool) throws -> MLStmt {
        let location = current.location
        var names: [String] = [try expectIdentifier("変数名")]
        _ = match("*")
        while match(",") {
            names.append(try expectIdentifier("変数名"))
            _ = match("*")
        }
        var typeName: String?
        if match(":") { typeName = try parseNimTypeName() }
        skipPragma()
        var value: MLExpr?
        if match("=") { value = try parseExpression() }
        consumeStatementEnd()

        let initial = value ?? .defaultValue(typeName: typeName, location)
        if names.count == 1 {
            return .varDecl(pattern: .binding(names[0]), typeName: typeName, value: initial,
                            isConstant: isConstant, location)
        }
        let entries: [MLStmt] = names.map {
            .varDecl(pattern: .binding($0), typeName: typeName, value: initial,
                     isConstant: isConstant, location)
        }
        return .block(entries, location)
    }

    // MARK: 手続き

    private func parseRoutine(keyword: String) throws -> MLStmt {
        let location = current.location
        advance()   // proc / func / method / ...
        let name = try expectIdentifier("手続きの名前")
        _ = match("*")
        skipGenericParameters()

        var parameters: [MLParameter] = []
        if match("(") {
            while !isAtEnd, !check(")") {
                parameters.append(contentsOf: try parseParameterGroup())
                if !match(",") && !match(";") { break }
            }
            try expect(")", "引数の終わり")
        }
        var returnTypeName: String?
        if match(":") { returnTypeName = try parseNimTypeName() }
        skipPragma()

        var body: [MLStmt] = []
        if match("=") { body = try parseIndentedBlock() }

        // `result` を用意して、最後に返す。
        if let returnTypeName {
            if case .expression(let value, let l)? = body.last {
                body[body.count - 1] = .returnStmt(value, l)
            }
            let prologue = MLStmt.varDecl(pattern: .binding("result"),
                                          typeName: returnTypeName,
                                          value: .defaultValue(typeName: returnTypeName,
                                                               location),
                                          isConstant: false, location)
            let epilogue = MLStmt.returnStmt(.name("result", location), location)
            body = [prologue] + body + [epilogue]
        }

        let decl = MLFunctionDecl(name: name, parameters: parameters, body: body,
                                  returnTypeName: returnTypeName, location: location)
        // `method` は第 1 引数の型に付け直して動的に選べるようにする。
        if keyword == "method", let first = parameters.first, let owner = first.typeName,
           declaredTypes.contains(owner) {
            // 第 1 引数の名前を self の別名として束ねる。
            let bind = MLStmt.varDecl(pattern: .binding(first.name), typeName: nil,
                                      value: .selfRef(location), isConstant: true, location)
            let methodDecl = MLFunctionDecl(
                name: name,
                parameters: Array(parameters.dropFirst()),
                body: [bind] + body,
                returnTypeName: returnTypeName, location: location)
            pendingMethods[owner, default: []].append(methodDecl)
            return .noop(location)
        }
        return .funcDecl(decl)
    }

    /// `a, b: int = 0` のようにまとめて書かれた引数を開く。
    private func parseParameterGroup() throws -> [MLParameter] {
        var isByReference = false
        if match("var") { isByReference = true }
        var names: [String] = [try expectIdentifier("引数名")]
        while check(","), peek(1).kind == .identifier,
              peek(2).is(",") || peek(2).is(":") {
            advance()
            names.append(try expectIdentifier("引数名"))
        }
        var typeName: String?
        var isVariadic = false
        if match(":") {
            if match("varargs") {
                isVariadic = true
                skipGenericParameters()
            } else {
                typeName = try parseNimTypeName()
            }
        }
        var defaultValue: MLExpr?
        if match("=") { defaultValue = try parseExpression() }
        return names.map {
            MLParameter(name: $0, typeName: typeName, defaultValue: defaultValue,
                        isVariadic: isVariadic, isByReference: isByReference)
        }
    }

    // MARK: 型の節

    private func parseTypeSection() throws -> MLStmt {
        let location = current.location
        advance()   // type
        var declarations: [MLStmt] = []
        if !isAtEnd, !current.precededByNewline {
            declarations.append(.typeDecl(try parseTypeEntry()))
            return .block(declarations, location)
        }
        let column = current.location.column
        while !isAtEnd, current.location.column >= column {
            skipStatementSeparators()
            if isAtEnd || current.location.column < column { break }
            let before = index
            declarations.append(.typeDecl(try parseTypeEntry()))
            if index == before { advance() }
        }
        return .block(declarations, location)
    }

    private func parseTypeEntry() throws -> MLTypeDecl {
        let location = current.location
        let name = try expectIdentifier("型名")
        declaredTypes.append(name)
        _ = match("*")
        skipGenericParameters()
        skipPragma()
        try expect("=", "型の定義")

        var kind = MLTypeDecl.Kind.structType
        if match("ref") || match("ptr") { kind = .classType }
        skipPragma()

        if match("enum") {
            var cases: [MLCaseDecl] = []
            let column = current.location.column
            while !isAtEnd, current.location.column >= column || !current.precededByNewline {
                guard current.kind == .identifier else { break }
                let caseName = advance().text
                var rawValue: MLExpr?
                if match("=") { rawValue = try parseExpression() }
                cases.append(MLCaseDecl(name: caseName, rawValue: rawValue))
                if !match(",") && !current.precededByNewline { break }
                if isAtEnd || (current.precededByNewline
                               && current.location.column < column) { break }
            }
            return MLTypeDecl(kind: .enumType, name: name, cases: cases, location: location)
        }

        guard match("object") || match("tuple") else {
            // `type Score = int` のような別名は読み飛ばす。
            _ = try? parseNimTypeName()
            consumeStatementEnd()
            return MLTypeDecl(kind: .structType, name: name, location: location)
        }
        skipPragma()
        var superclassName: String?
        if match("of") {
            let base = try expectIdentifier("親の型名")
            if base != "RootObj" { superclassName = base }
            kind = .classType
        }

        var properties: [MLPropertyDecl] = []
        if !isAtEnd, current.precededByNewline {
            let column = current.location.column
            if column > currentIndent {
                while !isAtEnd, current.location.column >= column {
                    skipStatementSeparators()
                    if isAtEnd || current.location.column < column { break }
                    guard current.kind == .identifier else { break }
                    var fieldNames: [String] = [advance().text]
                    _ = match("*")
                    while match(",") {
                        fieldNames.append(try expectIdentifier("フィールド名"))
                        _ = match("*")
                    }
                    var fieldType: String?
                    if match(":") { fieldType = try parseNimTypeName() }
                    for fieldName in fieldNames {
                        properties.append(MLPropertyDecl(
                            name: fieldName, typeName: fieldType,
                            defaultValue: .defaultValue(typeName: fieldType, location)))
                    }
                    consumeStatementEnd()
                }
            }
        }
        return MLTypeDecl(kind: kind, name: name, superclassName: superclassName,
                          properties: properties, location: location)
    }

    // MARK: case / try

    private func parseNimCase() throws -> MLStmt {
        let location = current.location
        advance()   // case
        let subject = try parseExpression(stopAtBrace: true)
        _ = match(":")
        var arms: [MLMatchArm] = []
        while !isAtEnd {
            skipStatementSeparators()
            if check("of") {
                advance()
                var patterns: [MLPattern] = []
                repeat {
                    let expression = try parseExpression(stopAtBrace: true)
                    if case .literal(let value, _) = expression {
                        patterns.append(.literal(value))
                    } else {
                        patterns.append(.expression(expression))
                    }
                } while match(",")
                let body = try parseBlock()
                arms.append(MLMatchArm(patterns: patterns, body: body))
                continue
            }
            if check("elif") {
                advance()
                let condition = try parseExpression(stopAtBrace: true)
                let body = try parseBlock()
                arms.append(MLMatchArm(patterns: [.wildcard], guardCondition: condition,
                                       body: body))
                continue
            }
            if check("else") {
                advance()
                let body = try parseBlock()
                arms.append(MLMatchArm(patterns: [], body: body, isDefault: true))
                break
            }
            break
        }
        return .matchStmt(subject: subject, arms: arms, label: nil, location)
    }

    private func parseNimTry() throws -> MLStmt {
        let location = current.location
        advance()   // try
        let body = try parseBlock()
        var catches: [MLCatchClause] = []
        var finallyBody: [MLStmt]?
        while !isAtEnd {
            skipStatementSeparators()
            if check("except") {
                advance()
                var typeName: String?
                var binding: String?
                if current.kind == .identifier, !check(":") {
                    typeName = try parseNimTypeName()
                    if match("as") { binding = try expectIdentifier("例外の変数名") }
                }
                let clauseBody = try parseBlock()
                catches.append(MLCatchClause(typeName: typeName, binding: binding,
                                             body: clauseBody))
                continue
            }
            if check("finally") {
                advance()
                finallyBody = try parseBlock()
                continue
            }
            break
        }
        return .tryStmt(body: body, catches: catches, finallyBody: finallyBody, location)
    }

    // MARK: 型名・注釈

    private func parseNimTypeName() throws -> String {
        var name = ""
        if match("ref") || match("ptr") || match("var") { /* 修飾は読み捨てる */ }
        if check("seq") || check("array") || check("openArray") || check("Table")
            || check("set") || check("HashSet") {
            name = advance().text
            if match("[") {
                var depth = 1
                while !isAtEnd, depth > 0 {
                    if check("[") { depth += 1 }
                    if check("]") { depth -= 1 }
                    advance()
                }
            }
            return name
        }
        guard current.kind == .identifier || current.kind == .keyword else { return "" }
        name = advance().text
        skipGenericParameters()
        while check("."), peek(1).kind == .identifier {
            advance()
            name += "." + advance().text
        }
        return name
    }

    /// `{. .}` のプラグマを読み飛ばす。
    private func skipPragma() {
        while check("{"), peek(1).is(".") {
            var depth = 0
            repeat {
                if check("{") { depth += 1 }
                if check("}") { depth -= 1 }
                advance()
            } while !isAtEnd && depth > 0
        }
    }

    override func skipGenericParameters() {
        guard check("["), peek(1).kind != .integerLiteral else { return }
        // 添字と区別するため、`[` のあとが型名のときだけ読み飛ばす。
        guard peek(1).kind == .identifier || peek(1).kind == .keyword else { return }
        var depth = 0
        repeat {
            if check("[") { depth += 1 }
            if check("]") { depth -= 1 }
            advance()
        } while !isAtEnd && depth > 0
    }

    // MARK: 式

    override func precedence(of op: String) -> Int? {
        switch op {
        case "div", "mod", "shl", "shr": return 13
        case "xor": return 4
        case "notin", "isnot": return 8
        case "&": return 12
        default: return super.precedence(of: op)
        }
    }

    override func parseUnary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        // `$x` は文字列化。
        if check("$") {
            advance()
            let operand = try parseUnary(stopAtBrace: stopAtBrace)
            return .call(callee: .name("$", location),
                         arguments: [MLArgument(value: operand)], location)
        }
        return try super.parseUnary(stopAtBrace: stopAtBrace)
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        // `@[1, 2, 3]` は seq リテラル。
        if check("@"), peek(1).is("[") {
            advance()
            return try parseListOrMapLiteral()
        }
        // `initTable[string, int]()` の `[...]` は型引数なので読み飛ばす。
        if current.kind == .identifier, peek(1).is("["), looksLikeGenericCall() {
            let name = advance().text
            skipBalanced(open: "[", close: "]")
            return .name(name, location)
        }
        if check("if") { return try parseIfExpression() }
        if check("case") {
            let statement = try parseNimCase()
            guard case .matchStmt(let subject, let arms, _, _) = statement else {
                return .block([statement], location)
            }
            return .match(subject: subject, arms: arms, location)
        }
        if check("proc") || check("func") {
            // 無名手続き。
            advance()
            var parameters: [MLParameter] = []
            if match("(") {
                while !isAtEnd, !check(")") {
                    parameters.append(contentsOf: try parseParameterGroup())
                    if !match(",") && !match(";") { break }
                }
                try expect(")", "引数の終わり")
            }
            if match(":") { _ = try parseNimTypeName() }
            skipPragma()
            _ = match("=")
            let body = try parseIndentedBlock()
            return .lambda(MLFunctionDecl(name: "", parameters: parameters,
                                          body: liftedReturn(body), location: location),
                           location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    /// `f[T](x)` の形か (閉じ括弧のすぐ後ろが `(` なら型引数とみなす)。
    private func looksLikeGenericCall() -> Bool {
        var cursor = index + 1
        var depth = 0
        while cursor < tokens.count {
            let text = tokens[cursor].text
            if text == "[" { depth += 1 }
            if text == "]" {
                depth -= 1
                if depth == 0 {
                    return cursor + 1 < tokens.count && tokens[cursor + 1].is("(")
                }
            }
            cursor += 1
        }
        return false
    }

    /// 最後の式をそのまま戻り値にする。
    private func liftedReturn(_ body: [MLStmt]) -> [MLStmt] {
        guard case .expression(let value, let location)? = body.last else { return body }
        return body.dropLast() + [.returnStmt(value, location)]
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        NimLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        NimParser(tokens: tokens, diagnostics: diagnostics)
    }
}
