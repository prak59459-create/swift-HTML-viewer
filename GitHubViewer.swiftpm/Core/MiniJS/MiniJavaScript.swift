import Foundation

/// 内蔵の JavaScript 処理系。
///
/// Web でいちばんよく使う言語なので、CDN 頼みにせず端末の中だけで動かせるようにしてある。
public enum MiniJavaScript: MiniLangEngine {
    public static var languageID: String { "javascript" }
    public static var displayName: String { "内蔵 JavaScript 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = JSLexer(source: source, diagnostics: diagnostics).tokenize()
        return try JSParser(tokens: tokens, diagnostics: diagnostics,
                            isTypeScript: false).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            run(source: source, input: input, limits: limits, isTypeScript: false)
        }
    }

    static func run(source: String, input: String, limits: MiniLangLimits,
                    isTypeScript: Bool) -> MiniLangExecution {
        let diagnostics = DiagnosticBag(source: source)
        let tokens = JSLexer(source: source, diagnostics: diagnostics).tokenize()
        let parser = JSParser(tokens: tokens, diagnostics: diagnostics,
                              isTypeScript: isTypeScript)
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
        let interpreter = MLInterpreter(semantics: JSSemantics(), limits: limits, input: input)
        interpreter.semanticsReturnsOperandsFromLogicalOperators = true
        return interpreter.run(program)
    }
}

/// 内蔵の TypeScript 処理系。
///
/// 型注釈は読み飛ばし、実行時の意味は JavaScript と同じにしている
/// (TypeScript 自身も型を消してから動かすため)。
public enum MiniTypeScript: MiniLangEngine {
    public static var languageID: String { "typescript" }
    public static var displayName: String { "内蔵 TypeScript 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = JSLexer(source: source, diagnostics: diagnostics).tokenize()
        return try JSParser(tokens: tokens, diagnostics: diagnostics,
                            isTypeScript: true).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            MiniJavaScript.run(source: source, input: input, limits: limits,
                               isTypeScript: true)
        }
    }
}

// MARK: - 見た目

enum JSProfile {
    static let keywords: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "enum", "export", "extends", "false",
        "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new",
        "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof",
        "var", "void", "while", "with", "yield", "static", "get", "set", "of",
        "undefined", "async", "interface", "type", "implements", "private", "public",
        "protected", "readonly", "abstract", "declare", "namespace", "as", "is",
        "keyof", "never", "unknown", "any"
    ]

    static let profile = MLLanguageProfile(
        languageID: "javascript",
        comments: [.line("//"), .block(open: "/*", close: "*/", nesting: false)],
        strings: [MLLanguageProfile.StringStyle(quote: "\""),
                  MLLanguageProfile.StringStyle(quote: "'"),
                  MLLanguageProfile.StringStyle(quote: "`", interpolationPrefix: "${",
                                                isMultiline: false)],
        keywords: keywords,
        // `?:` は JavaScript の演算子ではない (`a ? b : c` と `x?: T` に分かれる)。
        operators: MLLanguageProfile.cStyleOperators.filter { $0 != "?:" }
            + ["===", "!==", "=>", "?.", "??", "??=", "**", "**=", "...", ">>>"],
        newlineTerminatesStatement: true,
        usesSemicolons: true,
        identifierExtras: ["$"],
        functionSyntax: .keyword,
        functionKeywords: ["function"],
        variableKeywords: ["var": false, "let": false, "const": true],
        typeKeywords: ["class": .classType],
        ignorableModifiers: ["export", "default", "async", "static", "public", "private",
                             "protected", "readonly", "abstract", "declare", "@"],
        lambdaArrows: ["=>"],
        nullLiterals: ["undefined"],
        selfKeywords: ["this"])
}

final class JSLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: JSProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        // 正規表現リテラルは扱わない (`/` は割り算としてだけ読む)。
        if let character = peek(), character == "$",
           let next = peek(1), MLLexerBase.isIdentifierStart(next) || next == "$" {
            let start = location
            advance()
            let name = readIdentifier(extraCharacters: ["$"])
            return MLToken(kind: .identifier, text: "$" + name, location: start)
        }
        if let character = peek(), character.isNumber {
            let token = readNumber(allowsUnderscoreSeparator: true)
            if peek() == "n" { advance() }   // BigInt の接尾辞。
            return token
        }
        return super.nextToken()
    }
}

final class JSParser: MLProfileParser {
    let isTypeScript: Bool

    init(tokens: [MLToken], diagnostics: DiagnosticBag, isTypeScript: Bool) {
        self.isTypeScript = isTypeScript
        super.init(tokens: tokens, profile: JSProfile.profile, diagnostics: diagnostics)
    }

    override var memberAccessOperators: [String] { [".", "?."] }

    override var supportsIfExpression: Bool { false }

    override var catchBindsNameOnly: Bool { true }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
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

        // `import` / `export` は読み飛ばす (単一ファイルで動かすため)。
        if check("import") {
            skipToStatementEnd()
            return .noop(location)
        }
        if check("export") {
            advance()
            _ = match("default")
            if check("{") {
                skipBalanced(open: "{", close: "}")
                skipToStatementEnd()
                return .noop(location)
            }
            return try parseStatement()
        }
        // TypeScript の型宣言は実行時に意味がない。
        if isTypeScript, check("interface") || check("type") || check("declare")
            || check("namespace") {
            if check("type") {
                skipToStatementEnd()
                return .noop(location)
            }
            advance()
            if current.kind == .identifier { advance() }
            skipGenericParameters()
            if check("extends") {
                advance()
                while !isAtEnd, !check("{") { advance() }
            }
            if check("{") { skipBalanced(open: "{", close: "}") }
            else { skipToStatementEnd() }
            return .noop(location)
        }
        // TypeScript の `enum` は「名前 → 数値」と「数値 → 名前」を両方持つ表になる。
        if isTypeScript, check("enum") || (check("const") && peek(1).is("enum")) {
            _ = match("const")
            advance()
            let name = try expectIdentifier("列挙の名前")
            try expect("{", "列挙の本体")
            var pairs: [(key: MLExpr, value: MLExpr)] = []
            var nextValue: Int64 = 0
            while !isAtEnd, !check("}") {
                skipStatementSeparators()
                if check("}") { break }
                let caseName = current.kind == .stringLiteral
                    ? (advance().stringValue ?? "")
                    : try expectIdentifier("列挙のケース")
                var value: MLExpr = .literal(.int(nextValue), location)
                var isNumeric = true
                if match("=") {
                    let assigned = try parseExpression()
                    value = assigned
                    if case .literal(.int(let number), _) = assigned {
                        nextValue = number
                    } else {
                        isNumeric = false
                    }
                }
                pairs.append((key: .literal(.string(caseName), location), value: value))
                if isNumeric {
                    // 数値の列挙は逆引きもできる。
                    pairs.append((key: .literal(.int(nextValue), location),
                                  value: .literal(.string(caseName), location)))
                    nextValue += 1
                }
                if !match(",") { break }
            }
            skipStatementSeparators()
            try expect("}", "列挙の終わり")
            return .varDecl(pattern: .binding(name), typeName: nil,
                            value: .mapLiteral(pairs, location), isConstant: true, location)
        }
        if check("async") {
            advance()
            return try parseStatement()
        }
        if check("function") {
            return .funcDecl(try parseJSFunction(requiresName: true))
        }
        if check("throw") {
            advance()
            let value = try parseExpression()
            consumeStatementEnd()
            return .throwStmt(value, location)
        }
        if check("do") { return try parseDoWhile(label: nil) }
        return try super.parseStatement()
    }

    /// `function f(a, b = 1, ...rest) { }`
    private func parseJSFunction(requiresName: Bool) throws -> MLFunctionDecl {
        let location = current.location
        try expect("function", "関数宣言")
        _ = match("*")
        var name = ""
        if current.kind == .identifier || (current.kind == .keyword && !check("(")) {
            name = advance().text
        } else if requiresName {
            name = try expectIdentifier("関数名")
        }
        skipGenericParameters()
        let parameters = try parseJSParameters()
        skipTypeAnnotation(stopsAtBrace: true)
        let body = try parseBlock()
        return MLFunctionDecl(name: name, parameters: parameters, body: body,
                              location: location)
    }

    /// 直前に読んだ引数リストのうち、`public x` のように
    /// そのままフィールドになるもの (TypeScript の引数プロパティ)。
    private var lastParameterProperties: [String] = []

    private func parseJSParameters() throws -> [MLParameter] {
        try expect("(", "引数の始まり")
        var parameters: [MLParameter] = []
        var properties: [String] = []
        defer { lastParameterProperties = properties }
        while !isAtEnd, !check(")") {
            var isVariadic = false
            if match("...") { isVariadic = true }
            var isProperty = false
            while profile.ignorableModifiers.contains(current.text), current.text != "@" {
                if ["public", "private", "protected", "readonly"].contains(current.text) {
                    isProperty = true
                }
                advance()
            }
            if isProperty, current.kind == .identifier {
                properties.append(current.text)
            }
            // 分割代入の引数。
            if check("{") || check("[") {
                let pattern = try parseDestructuringPattern()
                var defaultValue: MLExpr?
                skipTypeAnnotation()
                if match("=") { defaultValue = try parseExpression() }
                parameters.append(MLParameter(name: "#arg\(parameters.count)",
                                              defaultValue: defaultValue, pattern: pattern))
                if !match(",") { break }
                continue
            }
            let name = try expectIdentifier("引数名")
            // `x?: T` は省略できる引数なので、既定値を undefined にする。
            let isOptional = match("?")
            skipTypeAnnotation()
            var defaultValue: MLExpr? = isOptional ? .literal(.unit, current.location) : nil
            if match("=") { defaultValue = try parseExpression() }
            parameters.append(MLParameter(name: name, defaultValue: defaultValue,
                                          isVariadic: isVariadic))
            if !match(",") { break }
        }
        try expect(")", "引数の終わり")
        return parameters
    }

    /// TypeScript の `: 型` を読み飛ばす。
    ///
    /// - Parameter stopsAtBrace: 戻り値の型のあとに関数本体が続く場面では、
    ///   `{` を型の一部とみなさずそこで止める。
    func skipTypeAnnotation(stopsAtBrace: Bool = false) {
        guard isTypeScript, check(":") else { return }
        advance()
        var depth = 0
        while !isAtEnd {
            let text = current.text
            if depth == 0, stopsAtBrace, text == "{" { return }
            if text == "(" || text == "[" || text == "{" || text == "<" { depth += 1 }
            if text == ")" || text == "]" || text == "}" || text == ">" {
                if depth == 0 { return }
                depth -= 1
            }
            if depth == 0, text == "=" || text == "," || text == ";" { return }
            if depth == 0, text == "=>" { return }
            if depth == 0, current.precededByNewline, !text.isEmpty,
               text != "|" , text != "&" { return }
            advance()
        }
    }

    override func skipGenericParameters() {
        guard isTypeScript, check("<") else { return }
        super.skipGenericParameters()
    }

    /// `let {a, b} = obj` / `let [x, y] = arr`
    private func parseDestructuringPattern() throws -> MLPattern {
        if check("[") {
            advance()
            var items: [MLPattern] = []
            var restIndex: Int?
            var restName: String?
            while !isAtEnd, !check("]") {
                if match("...") {
                    restIndex = items.count
                    restName = try expectIdentifier("残りの要素")
                } else if check(",") {
                    items.append(.wildcard)
                } else {
                    items.append(try parseDestructuringPattern())
                }
                if !match(",") { break }
            }
            try expect("]", "分割代入")
            return .list(items, restIndex: restIndex, restName: restName)
        }
        if check("{") {
            advance()
            var named: [(String, MLPattern)] = []
            while !isAtEnd, !check("}") {
                if match("...") {
                    _ = try expectIdentifier("残りの要素")
                    if !match(",") { break }
                    continue
                }
                let key = try expectIdentifier("プロパティ名")
                if match(":") {
                    named.append((key, try parseDestructuringPattern()))
                } else {
                    named.append((key, .binding(key)))
                }
                if !match(",") { break }
            }
            try expect("}", "分割代入")
            return .map(named.map { (key: MLExpr.literal(.string($0.0), current.location),
                                     value: $0.1) })
        }
        let name = try expectIdentifier("変数名")
        return name == "_" ? .wildcard : .binding(name)
    }

    override func parseBindingPattern() throws -> MLPattern {
        if check("{") || check("[") { return try parseDestructuringPattern() }
        let name = try expectIdentifier("変数名")
        _ = match("!")
        skipTypeAnnotation()
        return name == "_" ? .wildcard : .binding(name)
    }

    override func parseVariableDeclaration(keyword: String, location: SourceLocation,
                                           consumesEnd: Bool = true) throws -> MLStmt {
        let isConstant = profile.variableKeywords[keyword] ?? false
        var declarations: [MLStmt] = []
        repeat {
            let pattern = try parseBindingPattern()
            var value: MLExpr?
            if match("=") { value = try parseExpression() }
            declarations.append(.varDecl(pattern: pattern, typeName: nil, value: value,
                                          isConstant: isConstant, location))
        } while match(",")
        if consumesEnd { consumeStatementEnd() }
        return declarations.count == 1 ? declarations[0] : .block(declarations, location)
    }

    override func parseForInitializerDeclaration() throws -> MLStmt? { nil }

    /// `for (const x of xs)` / `for (const k in obj)`
    override func parseForInHeader(location: SourceLocation, label: String?,
                                   hadParenthesis: Bool) throws -> MLStmt? {
        let saved = index
        var pattern: MLPattern?
        var sequence: MLExpr?
        var isKeyLoop = false
        diagnostics.beginSuppression()
        do {
            _ = matchedVariableKeyword()
            let parsed = try parseBindingPattern()
            guard check("of") || check("in") else { throw AbortCompilation() }
            isKeyLoop = current.text == "in"
            advance()
            sequence = try parseExpression(stopAtBrace: true)
            pattern = parsed
        } catch {
            index = saved
            diagnostics.endSuppression()
            return nil
        }
        diagnostics.endSuppression()
        guard let pattern, var sequence else {
            index = saved
            return nil
        }
        if hadParenthesis { _ = match(")") }
        if isKeyLoop {
            sequence = .call(callee: .member(.name("Object", location), "keys",
                                             isOptional: false, location),
                             arguments: [MLArgument(value: sequence)], location)
        }
        let body = try parseStatementAsBlock()
        return .forIn(pattern: pattern, sequence: sequence, body: body,
                      whereClause: nil, label: label, location)
    }

    /// アロー関数と `function` 式。
    override func parseLambdaIfPresent(stopAtBrace: Bool) throws -> MLExpr? {
        let location = current.location
        if check("function") {
            let decl = try parseJSFunction(requiresName: false)
            return .lambda(decl, location)
        }
        if check("async"), peek(1).is("(") || peek(1).kind == .identifier {
            let saved = index
            advance()
            if let lambda = try parseLambdaIfPresent(stopAtBrace: stopAtBrace) { return lambda }
            index = saved
        }
        // `x => ...`
        if current.kind == .identifier, peek(1).is("=>") {
            let name = advance().text
            advance()
            return .lambda(try parseArrowBody(parameters: [MLParameter(name: name)],
                                              location: location), location)
        }
        // `(a, b) => ...`
        guard check("(") else { return nil }
        var offset = 1
        var depth = 1
        while depth > 0, !peek(offset).isEndOfFile {
            if peek(offset).is("(") { depth += 1 }
            if peek(offset).is(")") { depth -= 1 }
            offset += 1
        }
        // TypeScript では `(): 型 =>` と書けるので、戻り値の型注釈も飛ばす。
        var arrowOffset = offset
        if isTypeScript, peek(arrowOffset).is(":") {
            var typeDepth = 0
            arrowOffset += 1
            while !peek(arrowOffset).isEndOfFile {
                let text = peek(arrowOffset).text
                if text == "(" || text == "<" || text == "[" || text == "{" { typeDepth += 1 }
                if text == ")" || text == ">" || text == "]" || text == "}" {
                    if typeDepth == 0 { break }
                    typeDepth -= 1
                }
                if typeDepth == 0, text == "=>" { break }
                arrowOffset += 1
            }
        }
        guard peek(arrowOffset).is("=>") else { return nil }
        let parameters = try parseJSParameters()
        skipTypeAnnotation()
        try expect("=>", "アロー関数")
        return .lambda(try parseArrowBody(parameters: parameters, location: location),
                       location)
    }

    private func parseArrowBody(parameters: [MLParameter],
                                location: SourceLocation) throws -> MLFunctionDecl {
        if check("{") {
            return MLFunctionDecl(name: "", parameters: parameters, body: try parseBlock(),
                                  location: location)
        }
        let value = try parseExpression()
        return MLFunctionDecl(name: "", parameters: parameters,
                              body: [.returnStmt(value, value.location)], location: location)
    }

    /// `{ a: 1, b, [k]: v, f() {} }`
    override func parseBraceLiteral() throws -> MLExpr {
        let location = current.location
        try expect("{", "オブジェクトリテラル")
        var pairs: [(key: MLExpr, value: MLExpr)] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            if match("...") {
                // 展開はここでは対応しない。
                _ = try parseExpression()
                if !match(",") { break }
                continue
            }
            var key: MLExpr
            if check("[") {
                advance()
                key = try parseExpression()
                try expect("]", "計算されたキー")
            } else if current.kind == .stringLiteral {
                key = .literal(.string(advance().stringValue ?? ""), location)
            } else if current.kind == .integerLiteral {
                key = .literal(.int(advance().intValue ?? 0), location)
            } else {
                key = .literal(.string(try expectIdentifier("プロパティ名")), location)
            }
            if check("(") {
                // メソッド短縮記法。
                let parameters = try parseJSParameters()
                skipTypeAnnotation(stopsAtBrace: true)
                let body = try parseBlock()
                pairs.append((key: key,
                              value: .lambda(MLFunctionDecl(name: "", parameters: parameters,
                                                            body: body, location: location),
                                             location)))
            } else if match(":") {
                pairs.append((key: key, value: try parseExpression()))
            } else if case .literal(.string(let name), _) = key {
                // 短縮記法 `{ x }`
                pairs.append((key: key, value: .name(name, location)))
            }
            if !match(",") { break }
        }
        skipStatementSeparators()
        try expect("}", "オブジェクトリテラルの終わり")
        return .mapLiteral(pairs, location)
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        // `null` と `undefined` は別物なので、`null` は専用の値にする。
        if check("null") {
            advance()
            return .literal(JSSemantics.nullValue, location)
        }
        if check("typeof") {
            advance()
            let operand = try parseUnary(stopAtBrace: stopAtBrace)
            return .call(callee: .name("#typeof", location),
                         arguments: [MLArgument(value: operand)], location)
        }
        if check("void") {
            advance()
            _ = try parseUnary(stopAtBrace: stopAtBrace)
            return .literal(.unit, location)
        }
        if check("delete") {
            advance()
            let target = try parseUnary(stopAtBrace: stopAtBrace)
            if case .subscriptExpr(let receiver, let index, _, _) = target {
                return .call(callee: .name("#delete", location),
                             arguments: [MLArgument(value: receiver),
                                         MLArgument(value: index)], location)
            }
            if case .member(let receiver, let name, _, _) = target {
                return .call(callee: .name("#delete", location),
                             arguments: [MLArgument(value: receiver),
                                         MLArgument(value: .literal(.string(name), location))],
                             location)
            }
            return .literal(.bool(true), location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    /// `[1, 2, ...rest]`
    override func parseListOrMapLiteral() throws -> MLExpr {
        let location = current.location
        try expect("[", "配列リテラル")
        var items: [MLExpr] = []
        var spreadIndices: Set<Int> = []
        while !isAtEnd, !check("]") {
            if match("...") {
                spreadIndices.insert(items.count)
                items.append(try parseExpression())
            } else if check(",") {
                items.append(.literal(.unit, location))
            } else {
                items.append(try parseExpression())
            }
            if !match(",") { break }
        }
        try expect("]", "配列リテラルの終わり")
        return .listLiteral(items, spreadIndices: spreadIndices, location)
    }

    override func parseArgument() throws -> MLArgument {
        if match("...") {
            return MLArgument(value: try parseExpression(), isSpread: true)
        }
        return MLArgument(value: try parseExpression())
    }

    /// クラス本体。JavaScript は型注釈なしでメソッドを並べる。
    override func parseTypeMember(into body: inout TypeBody, kind: MLTypeDecl.Kind,
                                  typeName: String) throws {
        skipStatementSeparators()
        if check("}") { return }
        var isStatic = false
        while profile.ignorableModifiers.contains(current.text) {
            if current.text == "static" { isStatic = true }
            if current.text == "@" {
                advance()
                if current.kind == .identifier { advance() }
                if check("(") { skipBalanced(open: "(", close: ")") }
                continue
            }
            advance()
        }
        // getter / setter
        if (check("get") || check("set")), peek(1).kind == .identifier {
            let isGetter = advance().text == "get"
            let name = try expectIdentifier("プロパティ名")
            let parameters = try parseJSParameters()
            skipTypeAnnotation(stopsAtBrace: true)
            let accessorBody = try parseBlock()
            if let existing = body.properties.firstIndex(where: { $0.name == name }) {
                if isGetter { body.properties[existing].getter = accessorBody }
                else {
                    body.properties[existing].setter = accessorBody
                    body.properties[existing].setterParameter = parameters.first?.name
                }
            } else {
                body.properties.append(MLPropertyDecl(
                    name: name, isStatic: isStatic,
                    getter: isGetter ? accessorBody : nil,
                    setter: isGetter ? nil : accessorBody,
                    setterParameter: isGetter ? nil : parameters.first?.name))
            }
            return
        }
        guard current.kind == .identifier || current.kind == .keyword
                || current.kind == .stringLiteral else {
            advance()
            return
        }
        let name = current.kind == .stringLiteral ? (advance().stringValue ?? "")
                                                  : advance().text
        _ = match("?")
        if check("(") {
            skipGenericParameters()
            let parameters = try parseJSParameters()
            let parameterProperties = lastParameterProperties
            skipTypeAnnotation(stopsAtBrace: true)
            var methodBody = try parseBlock()
            // `constructor(public w: number)` は `this.w = w` と同じ意味。
            if name == "constructor", !parameterProperties.isEmpty {
                let assignments = parameterProperties.map { property in
                    MLStmt.expression(
                        .assign(op: "=",
                                target: .member(.selfRef(current.location), property,
                                                isOptional: false, current.location),
                                value: .name(property, current.location), current.location),
                        current.location)
                }
                methodBody = assignments + methodBody
            }
            let isInitializer = name == "constructor"
            let decl = MLFunctionDecl(name: isInitializer ? "init" : name,
                                      parameters: parameters, body: methodBody,
                                      isStatic: isStatic, isInitializer: isInitializer,
                                      location: current.location)
            if isInitializer { body.initializers.append(decl) }
            else { body.methods.append(decl) }
            return
        }
        // フィールド。
        skipTypeAnnotation()
        var defaultValue: MLExpr?
        if match("=") { defaultValue = try parseExpression() }
        consumeStatementEnd()
        body.properties.append(MLPropertyDecl(name: name, defaultValue: defaultValue,
                                              isStatic: isStatic))
    }

    override func parseTypeDeclaration(kind: MLTypeDecl.Kind) throws -> MLTypeDecl {
        let location = current.location
        while profile.ignorableModifiers.contains(current.text) { advance() }
        try expect("class", "クラス宣言")
        let name = try expectIdentifier("クラス名")
        skipGenericParameters()
        var superclassName: String?
        if match("extends") {
            superclassName = try expectIdentifier("親クラス名")
            skipGenericParameters()
        }
        if isTypeScript, match("implements") {
            repeat { _ = try expectIdentifier("インタフェース名") } while match(",")
        }
        let savedTypeName = currentTypeName
        currentTypeName = name
        defer { currentTypeName = savedTypeName }
        let body = try parseTypeBody(kind: .classType, typeName: name)
        return MLTypeDecl(kind: .classType, name: name, superclassName: superclassName,
                          properties: body.properties, methods: body.methods,
                          initializers: body.initializers, location: location)
    }

    override func precedence(of op: String) -> Int? {
        if op == "===" || op == "!==" { return 7 }
        if op == "in" || op == "instanceof" { return 8 }
        return super.precedence(of: op)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        JSLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        JSParser(tokens: tokens, diagnostics: diagnostics, isTypeScript: isTypeScript)
    }
}
