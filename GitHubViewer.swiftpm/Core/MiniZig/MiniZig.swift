import Foundation

/// 内蔵の Zig 処理系。
public enum MiniZig: MiniLangEngine {
    public static var languageID: String { "zig" }
    public static var displayName: String { "内蔵 Zig 処理系" }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = ZigLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = ZigParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: ZigSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum ZigProfile {
    static let keywords: Set<String> = [
        "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await",
        "break", "callconv", "catch", "comptime", "const", "continue", "defer", "else",
        "enum", "errdefer", "error", "export", "extern", "fn", "for", "if", "inline",
        "noalias", "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume",
        "return", "linksection", "struct", "suspend", "switch", "test", "threadlocal",
        "try", "union", "unreachable", "usingnamespace", "var", "volatile", "while",
        "true", "false", "null", "undefined", "void", "bool", "i8", "i16", "i32", "i64",
        "u8", "u16", "u32", "u64", "usize", "isize", "f32", "f64", "comptime_int"
    ]

    static let profile = MLLanguageProfile(
        languageID: "zig",
        comments: [.line("//")],
        strings: [MLLanguageProfile.StringStyle(quote: "\""),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators + ["++", "**", "orelse", "|",
                                                        "=>", "..", "catch", ".*", ".?"],
        newlineTerminatesStatement: false,
        usesSemicolons: true,
        functionSyntax: .keyword,
        functionKeywords: ["fn"],
        variableKeywords: ["var": false, "const": true],
        typeKeywords: [:],
        ignorableModifiers: ["pub", "export", "extern", "inline", "comptime",
                             "threadlocal", "noalias", "packed"],
        nullLiterals: ["null", "undefined"],
        selfKeywords: [])
}

final class ZigLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: ZigProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        // `\\` で始まる複数行文字列。
        if peek() == "\\", peek(1) == "\\" {
            let start = location
            var text = ""
            while peek() == "\\", peek(1) == "\\" {
                advance()
                advance()
                while let character = peek(), character != "\n" {
                    text.append(character)
                    advance()
                }
                // 次の行も `\\` なら改行を足して続ける。
                let saved = position
                skipWhitespace()
                if peek() == "\\", peek(1) == "\\" {
                    text.append("\n")
                } else {
                    setPosition(saved)
                    break
                }
            }
            return MLToken(kind: .stringLiteral, text: text, location: start,
                           stringValue: text)
        }
        // `@import` などの組み込み関数。
        if peek() == "@", let next = peek(1), MLLexerBase.isIdentifierStart(next) {
            let start = location
            advance()
            let name = readIdentifier()
            return MLToken(kind: .identifier, text: "@" + name, location: start)
        }
        if let character = peek(), character.isNumber {
            return readNumber(allowsUnderscoreSeparator: true)
        }
        return super.nextToken()
    }
}

final class ZigParser: MLProfileParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: ZigProfile.profile, diagnostics: diagnostics)
    }

    override func entryPointName() -> String? { "main" }
    override var supportsIfExpression: Bool { true }
    /// Zig に `++` の増加はない (配列・文字列の連結記号)。
    override var hasIncrementOperators: Bool { false }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            if check("test") {
                // テストブロックは実行しない。
                advance()
                if current.kind == .stringLiteral { advance() }
                if check("{") { skipBalanced(open: "{", close: "}") }
                continue
            }
            if check("usingnamespace") {
                skipToStatementEnd()
                continue
            }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        let hasMain = statements.contains { statement in
            if case .funcDecl(let decl) = statement { return decl.name == "main" }
            return false
        }
        return MLProgram(statements: statements, entryPoint: hasMain ? "main" : nil)
    }

    override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location
        while profile.ignorableModifiers.contains(current.text) { advance() }
        if isAtEnd { return nil }

        if check("fn") { return .funcDecl(try parseZigFunction()) }
        if check("const") || check("var") {
            // `const Foo = struct { ... };` は型宣言。
            if let declaration = try parseTypeAlias() { return declaration }
            return try parseZigVariable()
        }
        if check("defer") || check("errdefer") {
            advance()
            let body = check("{") ? MLStmt.block(try parseBlock(), location)
                                  : (try parseStatement() ?? .noop(location))
            // 本来は抜けるときに実行するが、ここではその場で実行する。
            return body
        }
        if check("while") { return try parseZigWhile(label: nil) }
        if check("for") { return try parseZigFor(label: nil) }
        if check("switch") {
            let expression = try parseZigSwitch()
            consumeStatementEnd()
            return .expression(expression, location)
        }
        if check("if") { return try parseZigIf() }
        if check("try") {
            advance()
            let value = try parseExpression()
            consumeStatementEnd()
            return .expression(value, location)
        }
        if check("unreachable") {
            advance()
            consumeStatementEnd()
            return .throwStmt(.literal(.string("到達しないはずの場所に来ました"), location),
                              location)
        }
        return try super.parseStatement()
    }

    /// `const Point = struct { x: i32, y: i32, ... };`
    private func parseTypeAlias() throws -> MLStmt? {
        let saved = index
        let location = current.location
        advance()   // const / var
        guard current.kind == .identifier else {
            index = saved
            return nil
        }
        let name = advance().text
        if match(":") { _ = try? parseZigTypeName() }
        guard match("=") else {
            index = saved
            return nil
        }
        guard check("struct") || check("enum") || check("union") else {
            index = saved
            return nil
        }
        let keyword = advance().text
        if check("(") { skipBalanced(open: "(", close: ")") }
        let kind: MLTypeDecl.Kind = keyword == "enum" ? .enumType : .structType

        try expect("{", "型の本体")
        var properties: [MLPropertyDecl] = []
        var methods: [MLFunctionDecl] = []
        var cases: [MLCaseDecl] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            while profile.ignorableModifiers.contains(current.text) { advance() }
            if check("fn") {
                methods.append(try parseZigFunction(insideType: true))
                continue
            }
            if check("const") || check("var") {
                advance()
                let fieldName = try expectIdentifier("フィールド名")
                if match(":") { _ = try? parseZigTypeName() }
                var defaultValue: MLExpr?
                if match("=") { defaultValue = try parseExpression() }
                properties.append(MLPropertyDecl(name: fieldName, defaultValue: defaultValue,
                                                 isStatic: true))
                consumeStatementEnd()
                continue
            }
            guard current.kind == .identifier else {
                advance()
                continue
            }
            let fieldName = advance().text
            if kind == .enumType, !check(":") {
                var rawValue: MLExpr?
                if match("=") { rawValue = try parseExpression() }
                cases.append(MLCaseDecl(name: fieldName, rawValue: rawValue))
                _ = match(",")
                continue
            }
            var typeName: String?
            if match(":") { typeName = try parseZigTypeName() }
            var defaultValue: MLExpr?
            if match("=") { defaultValue = try parseExpression() }
            properties.append(MLPropertyDecl(name: fieldName, typeName: typeName,
                                             defaultValue: defaultValue))
            _ = match(",")
        }
        try expect("}", "型の終わり")
        consumeStatementEnd()
        return .typeDecl(MLTypeDecl(kind: kind, name: name, properties: properties,
                                    methods: methods, cases: cases, location: location))
    }

    /// `const x: i32 = 5;` / `var y = 0;`
    private func parseZigVariable() throws -> MLStmt {
        let location = current.location
        let isConstant = advance().text == "const"
        let pattern = try parseBindingPattern()
        var typeName: String?
        if match(":") { typeName = try parseZigTypeName() }
        var value: MLExpr?
        if match("=") {
            _ = match("try")
            value = try parseExpression()
        }
        consumeStatementEnd()
        return .varDecl(pattern: pattern, typeName: typeName, value: value,
                        isConstant: isConstant, location)
    }

    private func parseZigFunction(insideType: Bool = false) throws -> MLFunctionDecl {
        let location = current.location
        while profile.ignorableModifiers.contains(current.text) { advance() }
        try expect("fn", "関数宣言")
        let name = try expectIdentifier("関数名")
        try expect("(", "引数の始まり")
        var parameters: [MLParameter] = []
        while !isAtEnd, !check(")") {
            while profile.ignorableModifiers.contains(current.text) { advance() }
            let parameterName = try expectIdentifier("引数名")
            var typeName: String?
            if match(":") { typeName = try parseZigTypeName() }
            parameters.append(MLParameter(name: parameterName, typeName: typeName))
            if !match(",") { break }
        }
        try expect(")", "引数の終わり")
        // メソッドの `self` は評価器が自動で束ねるので、引数からは外す。
        var isStatic = true
        if insideType, parameters.first?.name == "self" {
            parameters.removeFirst()
            isStatic = false
        }
        if check("callconv") {
            advance()
            if check("(") { skipBalanced(open: "(", close: ")") }
        }
        // 戻り値の型 (`!void` のようなエラー合併も読む)。
        var returnTypeName: String?
        if !check("{") { returnTypeName = try? parseZigTypeName() }
        let body = check("{") ? try parseBlock() : []
        return MLFunctionDecl(name: name, parameters: parameters, body: body,
                              returnTypeName: returnTypeName,
                              isStatic: insideType && isStatic, location: location)
    }

    /// `[]const u8` `?*Foo` `!void` `[3]i32` などを名前として読む。
    private func parseZigTypeName() throws -> String {
        var prefix = ""
        while true {
            if match("!") { prefix += "!"; continue }
            if match("?") { prefix += "?"; continue }
            if match("*") { prefix += "*"; continue }
            if check("[") {
                advance()
                if check("]") {
                    advance()
                    prefix += "[]"
                    continue
                }
                _ = try? parseExpression()
                _ = match("]")
                prefix += "[]"
                continue
            }
            if match("const") || match("volatile") || match("align") { continue }
            break
        }
        guard current.kind == .identifier || current.kind == .keyword else {
            return prefix.isEmpty ? "anytype" : prefix
        }
        var text = advance().text
        if check("(") { skipBalanced(open: "(", close: ")") }
        while check("."), peek(1).kind == .identifier {
            advance()
            text += "." + advance().text
        }
        if prefix.contains("[") { return "Array<\(text)>" }
        return text
    }

    override func parseTypeName() throws -> String {
        try parseZigTypeName()
    }

    /// `while (cond) { }` / `while (it.next()) |x| { }`
    private func parseZigWhile(label: String?) throws -> MLStmt {
        let location = current.location
        try expect("while")
        try expect("(", "while の条件")
        let condition = try parseExpression()
        try expect(")", "while の条件")
        var captureName: String?
        if match("|") {
            _ = match("*")
            captureName = try expectIdentifier("取り出す名前")
            try expect("|", "取り出しの終わり")
        }
        // `while (cond) : (step) { }`
        var step: [MLStmt] = []
        if match(":") {
            try expect("(", "while の更新")
            repeat {
                step.append(.expression(try parseExpression(), location))
            } while match(",")
            try expect(")", "while の更新")
        }
        var body = try parseStatementAsBlock()
        if let captureName {
            body = [.varDecl(pattern: .binding(captureName), typeName: nil,
                             value: condition, isConstant: true, location)] + body
        }
        if step.isEmpty {
            return .whileStmt(condition: condition, body: body, label: label, location)
        }
        return .forClassic(initializer: [], condition: condition, step: step,
                           body: body, label: label, location)
    }

    /// `for (items) |item| { }` / `for (items, 0..) |item, i| { }`
    private func parseZigFor(label: String?) throws -> MLStmt {
        let location = current.location
        try expect("for")
        try expect("(", "for の対象")
        var sequences: [MLExpr] = []
        repeat {
            if check(")") { break }
            var value = try parseExpression()
            if match("..") {
                let upper = check(")") || check(",") ? nil : try parseExpression()
                value = .range(lower: value, upper: upper ?? .literal(.int(0), location),
                               isClosed: false, step: nil, location)
            }
            sequences.append(value)
        } while match(",")
        try expect(")", "for の対象")

        var names: [String] = []
        if match("|") {
            repeat {
                _ = match("*")
                names.append(try expectIdentifier("取り出す名前"))
            } while match(",")
            try expect("|", "取り出しの終わり")
        }
        let body = try parseStatementAsBlock()

        guard let first = sequences.first else {
            return .block(body, location)
        }
        // 2 つ以上並べたときは添字つきの繰り返しにする。
        if sequences.count >= 2, names.count >= 2 {
            let enumerated = MLExpr.call(callee: .name("#enumerate", location),
                                         arguments: [MLArgument(value: first)], location)
            let pattern = MLPattern.tuple([
                names.count > 1 ? .binding(names[0]) : .wildcard,
                names.count > 1 ? .binding(names[1]) : .wildcard
            ].reversed().map { $0 })
            // `#enumerate` は (添字, 値) を返すので、名前の順に合わせて入れ替える。
            return .forIn(pattern: .tuple([.binding(names[1]), .binding(names[0])]),
                          sequence: enumerated, body: body, whereClause: nil,
                          label: label, location)
                .replacingPatternIfNeeded(pattern)
        }
        let name = names.first ?? "_"
        return .forIn(pattern: name == "_" ? .wildcard : .binding(name),
                      sequence: first, body: body, whereClause: nil, label: label, location)
    }

    /// `if (a) |x| { } else { }`
    private func parseZigIf() throws -> MLStmt {
        let location = current.location
        try expect("if")
        try expect("(", "if の条件")
        let condition = try parseExpression()
        try expect(")", "if の条件")
        var captureName: String?
        if match("|") {
            _ = match("*")
            captureName = try expectIdentifier("取り出す名前")
            try expect("|", "取り出しの終わり")
        }
        var then = try parseStatementAsBlock()
        if let captureName {
            then = [.varDecl(pattern: .binding(captureName), typeName: nil, value: condition,
                             isConstant: true, location)] + then
        }
        var otherwise: [MLStmt]?
        let saved = index
        skipStatementSeparators()
        if check("else") {
            advance()
            if match("|") {
                _ = try expectIdentifier("取り出す名前")
                try expect("|", "取り出しの終わり")
            }
            otherwise = check("if") ? [try parseZigIf()] : try parseStatementAsBlock()
        } else {
            index = saved
        }
        return .ifStmt(condition: condition, then: then, otherwise: otherwise, location)
    }

    /// `switch (x) { 1 => ..., else => ... }`
    private func parseZigSwitch() throws -> MLExpr {
        let location = current.location
        try expect("switch")
        try expect("(", "switch の対象")
        let subject = try parseExpression()
        try expect(")", "switch の対象")
        try expect("{", "switch の本体")
        var arms: [MLMatchArm] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            var patterns: [MLPattern] = []
            var isDefault = false
            if check("else") {
                advance()
                isDefault = true
            } else {
                repeat {
                    if check("=>") { break }
                    let lower = try parseExpression()
                    if match("...") || match("..") {
                        let upper = try parseExpression()
                        patterns.append(.range(lower: lower, upper: upper, isClosed: true))
                    } else if case .literal(let value, _) = lower {
                        patterns.append(.literal(value))
                    } else {
                        patterns.append(.expression(lower))
                    }
                } while match(",")
            }
            try expect("=>", "switch の分岐")
            if match("|") {
                _ = try expectIdentifier("取り出す名前")
                try expect("|", "取り出しの終わり")
            }
            var body: [MLStmt]
            if check("{") {
                body = try parseBlock()
            } else {
                let value = try parseExpression()
                body = [.expression(value, value.location)]
            }
            _ = match(",")
            arms.append(MLMatchArm(patterns: patterns, body: body, isDefault: isDefault))
        }
        try expect("}", "switch の終わり")
        return .match(subject: subject, arms: arms, location)
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if check("switch") { return try parseZigSwitch() }
        if check("if") { return try parseIfExpression() }
        if check("try") {
            advance()
            return try parseUnary(stopAtBrace: stopAtBrace)
        }
        if check("."), peek(1).is("{") {
            // `.{ .x = 1, .y = 2 }` は無名の構造体リテラル。
            advance()
            advance()
            var pairs: [(key: MLExpr, value: MLExpr)] = []
            var items: [MLExpr] = []
            while !isAtEnd, !check("}") {
                skipStatementSeparators()
                if check("}") { break }
                if check("."), peek(1).kind == .identifier {
                    advance()
                    let key = advance().text
                    try expect("=", "構造体リテラル")
                    pairs.append((key: .literal(.string(key), location),
                                  value: try parseExpression()))
                } else {
                    items.append(try parseExpression())
                }
                if !match(",") { break }
            }
            skipStatementSeparators()
            try expect("}", "構造体リテラルの終わり")
            if pairs.isEmpty { return .listLiteral(items, spreadIndices: [], location) }
            return .mapLiteral(pairs, location)
        }
        // `[_]i32{1, 2, 3}` のような配列リテラル。
        if check("[") {
            let saved = index
            if (try? parseZigTypeName()) != nil, check("{") {
                advance()
                var items: [MLExpr] = []
                while !isAtEnd, !check("}") {
                    skipStatementSeparators()
                    if check("}") { break }
                    items.append(try parseExpression())
                    if !match(",") { break }
                }
                skipStatementSeparators()
                try expect("}", "配列リテラルの終わり")
                return .listLiteral(items, spreadIndices: [], location)
            }
            index = saved
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    override func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        var expression = try super.parsePostfix(stopAtBrace: stopAtBrace)
        // `Point{ .x = 3, .y = 4 }` のような構造体リテラル。
        if !stopAtBrace, check("{"), case .name(let typeName, let nameLocation) = expression,
           typeName.first?.isUppercase == true {
            advance()
            var arguments: [MLArgument] = []
            while !isAtEnd, !check("}") {
                skipStatementSeparators()
                if check("}") { break }
                if check("."), peek(1).kind == .identifier {
                    advance()
                    let field = advance().text
                    try expect("=", "構造体リテラル")
                    arguments.append(MLArgument(label: field, value: try parseExpression()))
                } else {
                    arguments.append(MLArgument(value: try parseExpression()))
                }
                if !match(",") { break }
            }
            skipStatementSeparators()
            try expect("}", "構造体リテラルの終わり")
            expression = .construct(typeName: typeName, arguments: arguments, nameLocation)
        }
        while true {
            let location = current.location
            if check(".*") || check(".?") {
                advance()
                expression = .forceUnwrap(expression, location)
                continue
            }
            if check("catch") {
                advance()
                if match("|") {
                    _ = try expectIdentifier("取り出す名前")
                    try expect("|", "取り出しの終わり")
                }
                let fallback = check("{") ? MLExpr.block(try parseBlock(), location)
                                          : try parseExpression()
                expression = .binary(op: "??", lhs: expression, rhs: fallback, location)
                continue
            }
            if check("orelse") {
                advance()
                let fallback = try parseExpression()
                expression = .binary(op: "??", lhs: expression, rhs: fallback, location)
                continue
            }
            break
        }
        return expression
    }

    override func precedence(of op: String) -> Int? {
        if op == "orelse" || op == "catch" { return 9 }
        if op == "++" { return 12 }
        if op == "and" { return 3 }
        if op == "or" { return 2 }
        return super.precedence(of: op)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        ZigLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        ZigParser(tokens: tokens, diagnostics: diagnostics)
    }
}

private extension MLStmt {
    /// `for` のパターンだけ差し替える (Zig の添字つき繰り返し用)。
    func replacingPatternIfNeeded(_ pattern: MLPattern) -> MLStmt {
        guard case .forIn(_, let sequence, let body, let whereClause,
                          let label, let location) = self else { return self }
        return .forIn(pattern: pattern, sequence: sequence, body: body,
                      whereClause: whereClause, label: label, location)
    }
}
