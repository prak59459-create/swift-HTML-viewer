import Foundation

/// 内蔵の Go 処理系。
public enum MiniGo: MiniLangEngine {
    public static var languageID: String { "go" }
    public static var displayName: String { "内蔵 Go 処理系" }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            executeOnCurrentThread(source: source, input: input, limits: limits)
        }
    }

    static func executeOnCurrentThread(source: String, input: String,
                                       limits: MiniLangLimits) -> MiniLangExecution {
        let diagnostics = DiagnosticBag(source: source)
        let tokens = GoLexer(source: source, diagnostics: diagnostics).tokenize()
        let parser = GoParser(tokens: tokens, diagnostics: diagnostics)
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
        let interpreter = MLInterpreter(semantics: GoSemantics(), limits: limits, input: input)
        return interpreter.run(program)
    }
}

// MARK: - 見た目

enum GoProfile {
    static let keywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else",
        "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
        "package", "range", "return", "select", "struct", "switch", "type", "var",
        "true", "false", "nil", "make", "new", "len", "cap", "append", "copy", "delete",
        "panic", "recover"
    ]

    static let profile = MLLanguageProfile(
        languageID: "go",
        comments: [.line("//"), .block(open: "/*", close: "*/", nesting: false)],
        strings: [MLLanguageProfile.StringStyle(quote: "\""),
                  MLLanguageProfile.StringStyle(quote: "`", allowsEscapes: false),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators + [":=", "<-", "&^", "&^="],
        newlineTerminatesStatement: true,
        usesSemicolons: true,
        functionSyntax: .keyword,
        functionKeywords: ["func"],
        variableKeywords: ["var": false, "const": true],
        typeKeywords: [:],
        ignorableModifiers: [],
        nullLiterals: ["nil"],
        selfKeywords: [])
}

final class GoLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: GoProfile.profile, diagnostics: diagnostics)
    }
}

final class GoParser: MLProfileParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: GoProfile.profile, diagnostics: diagnostics)
    }

    override func entryPointName() -> String? { "main" }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            if check("package") || check("import") {
                advance()
                if check("(") { skipBalanced(open: "(", close: ")") }
                else { skipToStatementEnd() }
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

        // ラベル。
        if current.kind == .identifier, peek(1).is(":"), isLoopKeyword(peek(2).text) {
            let label = advance().text
            advance()
            return try parseLabeledStatement(label: label)
        }
        if check("type") { return try parseTypeAlias() }
        if check("defer") || check("go") {
            advance()
            let value = try parseExpression()
            consumeStatementEnd()
            // `defer` は関数の最後にまわすべきだが、簡単のためその場で実行する。
            return .expression(value, location)
        }
        if check("var") || check("const") {
            return try parseGoVariable()
        }
        // `x := 1` / `a, b := f()`
        if let short = try parseShortDeclaration() { return short }
        if check("switch") { return try parseGoSwitch(label: nil) }
        if check("select") {
            advance()
            _ = try? parseBlock()
            return .noop(location)
        }
        if check("for") { return try parseGoFor(label: nil) }
        if check("return") {
            advance()
            if isStatementBoundary() {
                consumeStatementEnd()
                return .returnStmt(nil, location)
            }
            // Go は複数の値を返せるので、2 つ以上ならタプルにする。
            var values: [MLExpr] = [try parseExpression()]
            while match(",") { values.append(try parseExpression()) }
            consumeStatementEnd()
            return .returnStmt(values.count == 1 ? values[0]
                                                 : .tupleLiteral(values, location), location)
        }
        return try super.parseStatement()
    }

    override func parseLabeledStatement(label: String) throws -> MLStmt? {
        if check("for") { return try parseGoFor(label: label) }
        if check("switch") { return try parseGoSwitch(label: label) }
        return try super.parseLabeledStatement(label: label)
    }

    /// `type Point struct { X, Y int }` / `type Celsius float64`
    private func parseTypeAlias() throws -> MLStmt {
        let location = current.location
        try expect("type")
        if check("(") {
            advance()
            var declarations: [MLStmt] = []
            while !isAtEnd, !check(")") {
                skipStatementSeparators()
                if check(")") { break }
                declarations.append(try parseSingleTypeDeclaration())
            }
            try expect(")", "type の終わり")
            return .block(declarations, location)
        }
        return try parseSingleTypeDeclaration()
    }

    private func parseSingleTypeDeclaration() throws -> MLStmt {
        let location = current.location
        let name = try expectIdentifier("型名")
        skipGenericParameters()
        if check("struct") {
            advance()
            let properties = try parseStructFields()
            return .typeDecl(MLTypeDecl(kind: .structType, name: name, properties: properties,
                                        location: location))
        }
        if check("interface") {
            advance()
            skipBalanced(open: "{", close: "}")
            return .typeDecl(MLTypeDecl(kind: .interfaceType, name: name, location: location))
        }
        // それ以外は別名なので無視する。
        _ = try? parseGoTypeName()
        consumeStatementEnd()
        return .noop(location)
    }

    private func parseStructFields() throws -> [MLPropertyDecl] {
        try expect("{", "struct の本体")
        var properties: [MLPropertyDecl] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            var names: [String] = [try expectIdentifier("フィールド名")]
            while match(",") { names.append(try expectIdentifier("フィールド名")) }
            let typeName = try parseGoTypeName()
            // タグ (`json:"x"`) は読み飛ばす。
            if current.kind == .stringLiteral { advance() }
            for name in names {
                properties.append(MLPropertyDecl(name: name, typeName: typeName))
            }
            consumeStatementEnd()
        }
        try expect("}", "struct の終わり")
        return properties
    }

    /// Go の型は `[]int` `map[string]int` `*T` `func(...)` など。名前として持つだけ。
    private func parseGoTypeName() throws -> String {
        if match("*") { return "Pointer<" + (try parseGoTypeName()) + ">" }
        if check("[") {
            advance()
            if check("]") {
                advance()
                return "Array<" + (try parseGoTypeName()) + ">"
            }
            _ = try parseExpression()
            try expect("]", "配列の型")
            return "Array<" + (try parseGoTypeName()) + ">"
        }
        if check("map") {
            advance()
            try expect("[", "map の型")
            let key = try parseGoTypeName()
            try expect("]", "map の型")
            let value = try parseGoTypeName()
            return "Map<\(key),\(value)>"
        }
        if check("func") {
            advance()
            if check("(") { skipBalanced(open: "(", close: ")") }
            if current.kind == .identifier || check("(") || check("[") || check("*") {
                _ = try? parseGoTypeName()
            }
            return "Func"
        }
        if check("chan") {
            advance()
            return "Chan<" + (try parseGoTypeName()) + ">"
        }
        if check("interface") {
            advance()
            skipBalanced(open: "{", close: "}")
            return "Any"
        }
        if check("struct") {
            advance()
            skipBalanced(open: "{", close: "}")
            return "Struct"
        }
        if check("...") {
            advance()
            return "Array<" + (try parseGoTypeName()) + ">"
        }
        var name = try expectIdentifier("型名")
        if check("."), peek(1).kind == .identifier {
            advance()
            name += "." + advance().text
        }
        skipGenericParameters()
        return name
    }

    override func parseTypeName() throws -> String {
        try parseGoTypeName()
    }

    /// `var x int = 1` / `var x = 1` / `const ( A = 1 \n B = 2 )`
    private func parseGoVariable() throws -> MLStmt {
        let location = current.location
        let isConstant = current.text == "const"
        advance()
        if check("(") {
            advance()
            var declarations: [MLStmt] = []
            var lastValue: MLExpr?
            var counter = 0
            while !isAtEnd, !check(")") {
                skipStatementSeparators()
                if check(")") { break }
                let declaration = try parseSingleGoVariable(isConstant: isConstant,
                                                            iotaValue: counter,
                                                            previousValue: lastValue)
                if case .varDecl(_, _, let value, _, _) = declaration.statement, value != nil {
                    lastValue = value
                }
                declarations.append(declaration.statement)
                counter += 1
            }
            try expect(")", "宣言の終わり")
            return .block(declarations, location)
        }
        return try parseSingleGoVariable(isConstant: isConstant, iotaValue: 0,
                                         previousValue: nil).statement
    }

    private struct GoVariable {
        var statement: MLStmt
    }

    private func parseSingleGoVariable(isConstant: Bool, iotaValue: Int,
                                       previousValue: MLExpr?) throws -> GoVariable {
        let location = current.location
        var names: [String] = [try expectIdentifier("変数名")]
        while match(",") { names.append(try expectIdentifier("変数名")) }
        var typeName: String?
        if !check("=") , !isStatementBoundary(), !check(")") {
            typeName = try parseGoTypeName()
        }
        var values: [MLExpr] = []
        if match("=") {
            repeat { values.append(try parseExpression()) } while match(",")
        } else if isConstant, let previous = previousValue {
            // `const ( A = iota \n B \n C )` のように値を省略した場合。
            values = [substituteIota(previous, with: iotaValue)]
        }
        consumeStatementEnd()

        var declarations: [MLStmt] = []
        // `a, b = f()` のような多値受け取り。
        if names.count > 1, values.count == 1 {
            let pattern = MLPattern.tuple(names.map { $0 == "_" ? .wildcard : .binding($0) })
            declarations.append(.varDecl(pattern: pattern, typeName: nil, value: values[0],
                                          isConstant: isConstant, location))
        } else {
            for (index, name) in names.enumerated() {
                let value = index < values.count ? values[index] : nil
                declarations.append(.varDecl(pattern: name == "_" ? .wildcard : .binding(name),
                                              typeName: typeName, value: value,
                                              isConstant: isConstant, location))
            }
        }
        return GoVariable(statement: declarations.count == 1 ? declarations[0]
                                                             : .block(declarations, location))
    }

    /// `iota` を具体的な番号に置き換える。
    private func substituteIota(_ expression: MLExpr, with value: Int) -> MLExpr {
        switch expression {
        case .name("iota", let location):
            return .literal(.int(Int64(value)), location)
        case .binary(let op, let lhs, let rhs, let location):
            return .binary(op: op, lhs: substituteIota(lhs, with: value),
                           rhs: substituteIota(rhs, with: value), location)
        case .unary(let op, let operand, let isPostfix, let location):
            return .unary(op: op, operand: substituteIota(operand, with: value),
                          isPostfix: isPostfix, location)
        default:
            return expression
        }
    }

    /// `x := expr` / `a, b := expr`
    private func parseShortDeclaration() throws -> MLStmt? {
        guard current.kind == .identifier else { return nil }
        var offset = 0
        while peek(offset).kind == .identifier {
            offset += 1
            if peek(offset).is(",") { offset += 1; continue }
            break
        }
        guard peek(offset).is(":=") else { return nil }
        let location = current.location
        var names: [String] = [advance().text]
        while match(",") { names.append(try expectIdentifier("変数名")) }
        try expect(":=", "短い宣言")
        var values: [MLExpr] = []
        repeat { values.append(try parseExpression()) } while match(",")
        consumeStatementEnd()

        if names.count > 1, values.count == 1 {
            let pattern = MLPattern.tuple(names.map { $0 == "_" ? .wildcard : .binding($0) })
            return .varDecl(pattern: pattern, typeName: nil, value: values[0],
                            isConstant: false, location)
        }
        var declarations: [MLStmt] = []
        for (index, name) in names.enumerated() {
            let value = index < values.count ? values[index] : nil
            declarations.append(.varDecl(pattern: name == "_" ? .wildcard : .binding(name),
                                          typeName: nil, value: value,
                                          isConstant: false, location))
        }
        return declarations.count == 1 ? declarations[0] : .block(declarations, location)
    }

    /// Go の `for` は 4 通り。
    private func parseGoFor(label: String?) throws -> MLStmt {
        let location = current.location
        try expect("for")

        // `for { }` (無限ループ)
        if check("{") {
            return .whileStmt(condition: .literal(.bool(true), location),
                              body: try parseBlock(), label: label, location)
        }
        // `for i, v := range xs { }`
        let saved = index
        if let rangeLoop = try parseRangeClause(label: label, location: location) {
            return rangeLoop
        }
        index = saved

        // `for cond { }` か `for init; cond; step { }`
        var initializer: [MLStmt] = []
        var condition: MLExpr?
        var step: [MLStmt] = []
        if !check(";") {
            if let short = try parseShortDeclarationWithoutEnd() {
                initializer.append(short)
            } else {
                let expression = try parseExpression(stopAtBrace: true)
                if check("{") {
                    // `for cond { }`
                    return .whileStmt(condition: expression, body: try parseBlock(),
                                      label: label, location)
                }
                initializer.append(.expression(expression, location))
            }
        }
        if check("{") {
            // `for i := 0 { }` のような形は条件なしとみなす。
            return .forClassic(initializer: initializer, condition: nil, step: [],
                               body: try parseBlock(), label: label, location)
        }
        try expect(";", "for の初期化のあと")
        if !check(";") { condition = try parseExpression(stopAtBrace: true) }
        try expect(";", "for の条件のあと")
        if !check("{") {
            repeat {
                if let short = try parseShortDeclarationWithoutEnd() {
                    step.append(short)
                } else {
                    step.append(.expression(try parseExpression(stopAtBrace: true), location))
                }
            } while match(",")
        }
        let body = try parseBlock()
        return .forClassic(initializer: initializer, condition: condition, step: step,
                           body: body, label: label, location)
    }

    private func parseShortDeclarationWithoutEnd() throws -> MLStmt? {
        guard current.kind == .identifier else { return nil }
        var offset = 0
        while peek(offset).kind == .identifier {
            offset += 1
            if peek(offset).is(",") { offset += 1; continue }
            break
        }
        guard peek(offset).is(":=") else { return nil }
        let location = current.location
        var names: [String] = [advance().text]
        while match(",") { names.append(try expectIdentifier("変数名")) }
        try expect(":=", "短い宣言")
        var values: [MLExpr] = []
        repeat { values.append(try parseExpression(stopAtBrace: true)) } while match(",")
        if names.count > 1, values.count == 1 {
            let pattern = MLPattern.tuple(names.map { $0 == "_" ? .wildcard : .binding($0) })
            return .varDecl(pattern: pattern, typeName: nil, value: values[0],
                            isConstant: false, location)
        }
        var declarations: [MLStmt] = []
        for (index, name) in names.enumerated() {
            declarations.append(.varDecl(pattern: name == "_" ? .wildcard : .binding(name),
                                          typeName: nil,
                                          value: index < values.count ? values[index] : nil,
                                          isConstant: false, location))
        }
        return declarations.count == 1 ? declarations[0] : .block(declarations, location)
    }

    /// `for i, v := range xs { }` / `for range xs { }`
    private func parseRangeClause(label: String?,
                                  location: SourceLocation) throws -> MLStmt? {
        var names: [String] = []
        if check("range") {
            advance()
        } else {
            guard current.kind == .identifier else { return nil }
            names.append(advance().text)
            while match(",") {
                guard current.kind == .identifier else { return nil }
                names.append(advance().text)
            }
            guard match(":=") || match("=") else { return nil }
            guard match("range") else { return nil }
        }
        let sequence = try parseExpression(stopAtBrace: true)
        let body = try parseBlock()

        // `range` は添字と値の 2 つを返す。
        if names.isEmpty {
            return .forIn(pattern: .wildcard, sequence: makeEnumerate(sequence, location),
                          body: body, whereClause: nil, label: label, location)
        }
        if names.count == 1 {
            let pattern = MLPattern.tuple([names[0] == "_" ? .wildcard : .binding(names[0]),
                                           .wildcard])
            return .forIn(pattern: pattern, sequence: makeEnumerate(sequence, location),
                          body: body, whereClause: nil, label: label, location)
        }
        let pattern = MLPattern.tuple(names.map { $0 == "_" ? .wildcard : .binding($0) })
        return .forIn(pattern: pattern, sequence: makeEnumerate(sequence, location),
                      body: body, whereClause: nil, label: label, location)
    }

    private func makeEnumerate(_ sequence: MLExpr, _ location: SourceLocation) -> MLExpr {
        .call(callee: .name("#enumerate", location),
              arguments: [MLArgument(value: sequence)], location)
    }

    /// Go の `switch` は式なしでも書けて、`break` を書かなくても落ちない。
    private func parseGoSwitch(label: String?) throws -> MLStmt {
        let location = current.location
        try expect("switch")
        var subject: MLExpr = .literal(.bool(true), location)
        var initializer: [MLStmt] = []
        if !check("{") {
            if let short = try parseShortDeclarationWithoutEnd() {
                initializer.append(short)
                if match(";") , !check("{") {
                    subject = try parseExpression(stopAtBrace: true)
                }
            } else {
                let expression = try parseExpression(stopAtBrace: true)
                if match(";") {
                    initializer.append(.expression(expression, location))
                    if !check("{") { subject = try parseExpression(stopAtBrace: true) }
                } else {
                    subject = expression
                }
            }
        }
        try expect("{", "switch の本体")
        var arms: [MLMatchArm] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            var patterns: [MLPattern] = []
            var isDefault = false
            if check("default") {
                advance()
                isDefault = true
            } else {
                try expect("case", "switch の分岐")
                repeat {
                    patterns.append(.expression(try parseExpression()))
                } while match(",")
            }
            try expect(":", "switch の分岐")
            var body: [MLStmt] = []
            var fallsThrough = false
            while !isAtEnd, !check("case"), !check("default"), !check("}") {
                skipStatementSeparators()
                if isAtEnd || check("case") || check("default") || check("}") { break }
                if check("fallthrough") {
                    advance()
                    fallsThrough = true
                    consumeStatementEnd()
                    continue
                }
                let before = index
                if let statement = try parseStatement() { body.append(statement) }
                if index == before { advance() }
            }
            arms.append(MLMatchArm(patterns: patterns, body: body,
                                   fallsThrough: fallsThrough, isDefault: isDefault))
        }
        try expect("}", "switch の終わり")
        let statement = MLStmt.matchStmt(subject: subject, arms: arms, label: label, location)
        if initializer.isEmpty { return statement }
        return .block(initializer + [statement], location)
    }

    /// Go の関数宣言。メソッド (`func (p Point) Norm()`) にも対応する。
    override func parseFunctionDeclaration() throws -> MLFunctionDecl {
        let location = current.location
        try expect("func", "関数宣言")
        // レシーバ。
        var receiverName: String?
        var receiverType: String?
        if check("(") {
            let saved = index
            advance()
            if current.kind == .identifier, !peek(1).is(",") {
                let name = advance().text
                if !check(")") {
                    if let typeName = try? parseGoTypeName(), check(")") {
                        receiverName = name
                        receiverType = MLInterpreter.baseTypeName(typeName)
                        advance()
                    } else {
                        index = saved
                    }
                } else {
                    index = saved
                }
            } else {
                index = saved
            }
        }
        let name = try expectIdentifier("関数名")
        skipGenericParameters()
        var parameters = try parseGoParameterList()
        if let receiverName, receiverType != nil {
            parameters.insert(MLParameter(name: receiverName), at: 0)
        }
        // 戻り値。
        if check("(") {
            skipBalanced(open: "(", close: ")")
        } else if !check("{"), !isStatementBoundary() {
            _ = try? parseGoTypeName()
        }
        let body = check("{") ? try parseBlock() : []
        let fullName = receiverType.map { "\($0).\(name)" } ?? name
        return MLFunctionDecl(name: fullName, parameters: parameters, body: body,
                              location: location)
    }

    private func parseGoParameterList() throws -> [MLParameter] {
        try expect("(", "引数の始まり")
        var parameters: [MLParameter] = []
        while !isAtEnd, !check(")") {
            // `a, b int` のようにまとめて型を書ける。
            var names: [String] = []
            var isVariadic = false
            if match("...") { isVariadic = true }
            names.append(try expectIdentifier("引数名"))
            while check(","), peek(1).kind == .identifier,
                  peek(2).is(",") || peek(2).kind == .identifier || peek(2).is("[")
                    || peek(2).is("*") || peek(2).is("...") {
                advance()
                names.append(try expectIdentifier("引数名"))
            }
            var typeName: String?
            if !check(",") , !check(")") {
                if match("...") { isVariadic = true }
                typeName = try parseGoTypeName()
            }
            for name in names {
                parameters.append(MLParameter(name: name, typeName: typeName,
                                              isVariadic: isVariadic))
            }
            if !match(",") { break }
        }
        try expect(")", "引数の終わり")
        return parameters
    }

    /// `Point{X: 1, Y: 2}` / `[]int{1, 2, 3}` / `map[string]int{...}`
    override func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        var expression = try super.parsePostfix(stopAtBrace: stopAtBrace)
        if !stopAtBrace, check("{"), case .name(let typeName, let location) = expression,
           let first = typeName.first, first.isUppercase {
            expression = try parseCompositeLiteral(typeName: typeName, location: location)
        }
        return expression
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        // `[]int{...}` / `map[string]int{...}` / `[3]int{...}`
        if check("[") || check("map") {
            let saved = index
            if let typeName = try? parseGoTypeName(), check("{") {
                if typeName.hasPrefix("Map") {
                    return try parseMapLiteral(location: location)
                }
                let items = try parseSliceLiteral()
                return .listLiteral(items, spreadIndices: [], location)
            }
            index = saved
        }
        if check("func") {
            // 無名関数。
            advance()
            let parameters = try parseGoParameterList()
            if check("(") { skipBalanced(open: "(", close: ")") }
            else if !check("{") { _ = try? parseGoTypeName() }
            let body = try parseBlock()
            return .lambda(MLFunctionDecl(name: "", parameters: parameters, body: body,
                                          location: location), location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    private func parseSliceLiteral() throws -> [MLExpr] {
        try expect("{", "スライスリテラル")
        var items: [MLExpr] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            if check("{") {
                items.append(.listLiteral(try parseSliceLiteral(), spreadIndices: [],
                                          current.location))
            } else {
                items.append(try parseExpression())
            }
            if !match(",") { break }
        }
        skipStatementSeparators()
        try expect("}", "スライスリテラルの終わり")
        return items
    }

    private func parseMapLiteral(location: SourceLocation) throws -> MLExpr {
        try expect("{", "map リテラル")
        var pairs: [(key: MLExpr, value: MLExpr)] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            let key = try parseExpression()
            try expect(":", "map の区切り")
            pairs.append((key: key, value: try parseExpression()))
            if !match(",") { break }
        }
        skipStatementSeparators()
        try expect("}", "map リテラルの終わり")
        return .mapLiteral(pairs, location)
    }

    private func parseCompositeLiteral(typeName: String,
                                       location: SourceLocation) throws -> MLExpr {
        try expect("{", "構造体リテラル")
        var arguments: [MLArgument] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            if current.kind == .identifier, peek(1).is(":") {
                let label = advance().text
                advance()
                arguments.append(MLArgument(label: label, value: try parseExpression()))
            } else {
                arguments.append(MLArgument(value: try parseExpression()))
            }
            if !match(",") { break }
        }
        skipStatementSeparators()
        try expect("}", "構造体リテラルの終わり")
        return .construct(typeName: typeName, arguments: arguments, location)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        GoLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        GoParser(tokens: tokens, diagnostics: diagnostics)
    }
}
