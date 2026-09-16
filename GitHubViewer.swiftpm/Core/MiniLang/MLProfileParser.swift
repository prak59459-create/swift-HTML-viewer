import Foundation

/// 中括弧を使う言語のための汎用構文解析器。
///
/// 「だいたいの C 系言語」はこれだけで読める。各言語は必要なところだけ
/// メソッドを上書きして差分を足す。
open class MLProfileParser: MLParserBase {
    public let profile: MLLanguageProfile
    /// 解析中の型名 (メソッド宣言の判定に使う)。
    public var currentTypeName: String?

    public init(tokens: [MLToken], profile: MLLanguageProfile, diagnostics: DiagnosticBag) {
        self.profile = profile
        super.init(tokens: tokens, diagnostics: diagnostics)
    }

    // MARK: - プログラム全体

    open func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            let before = index
            do {
                if let statement = try parseTopLevel() { statements.append(statement) }
            } catch is AbortCompilation {
                throw AbortCompilation()
            }
            if index == before { advance() }
        }
        return MLProgram(statements: statements, entryPoint: entryPointName())
    }

    /// トップレベルに書けるもの。既定は文と同じ。
    open func parseTopLevel() throws -> MLStmt? {
        try parseStatement()
    }

    /// `main` のように、トップレベル実行のあとに呼ぶ開始点。
    open func entryPointName() -> String? { nil }

    // MARK: - 区切り

    open func skipStatementSeparators() {
        while !isAtEnd {
            if profile.usesSemicolons, check(";") {
                advance()
                continue
            }
            if check(.newline) {
                advance()
                continue
            }
            break
        }
    }

    /// 文の終わりを消費する。
    open func consumeStatementEnd() {
        if profile.usesSemicolons, check(";") {
            advance()
            return
        }
        if check(.newline) { advance() }
    }

    // MARK: - 文

    open func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location

        // ラベル `outer:` (`case` などと混同しないよう次が識別子でないことを見る)。
        if current.kind == .identifier, peek(1).is(":"), isLoopKeyword(peek(2).text) {
            let label = advance().text
            advance()
            return try parseLabeledStatement(label: label)
        }

        if check("{") {
            return .block(try parseBlock(), location)
        }

        if let keyword = matchedVariableKeyword() {
            return try parseVariableDeclaration(keyword: keyword, location: location)
        }

        if isFunctionDeclarationStart() {
            return .funcDecl(try parseFunctionDeclaration())
        }

        if let kind = matchedTypeKeyword() {
            return .typeDecl(try parseTypeDeclaration(kind: kind))
        }

        switch current.text {
        case "if": return try parseIf()
        case "while": return try parseWhile(label: nil)
        case "do": return try parseDoWhile(label: nil)
        case "repeat": return try parseRepeat(label: nil)
        case "for": return try parseFor(label: nil)
        case "foreach": return try parseFor(label: nil)
        case "switch", "match", "when": return try parseSwitch(label: nil)
        case "return":
            advance()
            if isStatementBoundary() {
                consumeStatementEnd()
                return .returnStmt(nil, location)
            }
            let value = try parseExpression()
            consumeStatementEnd()
            return .returnStmt(value, location)
        case "break":
            advance()
            let label = matchOptionalLabel()
            consumeStatementEnd()
            return .breakStmt(label: label, location)
        case "continue":
            advance()
            let label = matchOptionalLabel()
            consumeStatementEnd()
            return .continueStmt(label: label, location)
        case "throw", "raise":
            advance()
            let value = try parseExpression()
            consumeStatementEnd()
            return .throwStmt(value, location)
        case "try":
            return try parseTry()
        case "guard":
            return try parseGuard()
        case "import", "package", "using", "include", "require", "use", "module", "namespace":
            // 実行に影響しない宣言は読み飛ばす。
            skipToStatementEnd()
            return .noop(location)
        default:
            break
        }

        let expression = try parseExpression()
        consumeStatementEnd()
        return .expression(expression, location)
    }

    open func isLoopKeyword(_ text: String) -> Bool {
        ["for", "while", "do", "repeat", "foreach", "loop"].contains(text)
    }

    open func parseLabeledStatement(label: String) throws -> MLStmt? {
        switch current.text {
        case "while": return try parseWhile(label: label)
        case "for", "foreach": return try parseFor(label: label)
        case "do": return try parseDoWhile(label: label)
        case "repeat": return try parseRepeat(label: label)
        default: return try parseStatement()
        }
    }

    open func matchOptionalLabel() -> String? {
        guard current.kind == .identifier, !current.precededByNewline,
              !check(";") else { return nil }
        return advance().text
    }

    /// 文の終わりに来ているか。
    open func isStatementBoundary() -> Bool {
        if isAtEnd { return true }
        if check(";") || check("}") { return true }
        if profile.newlineTerminatesStatement, current.precededByNewline { return true }
        return false
    }

    open func skipToStatementEnd() {
        while !isAtEnd, !check(";") {
            if profile.newlineTerminatesStatement, current.precededByNewline { return }
            advance()
        }
        if check(";") { advance() }
    }

    open func parseBlock() throws -> [MLStmt] {
        try expect("{", "ブロックの始まり")
        var statements: [MLStmt] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        try expect("}", "ブロックの終わり")
        return statements
    }

    /// `{ ... }` でも 1 文でもよい本体。
    open func parseStatementAsBlock() throws -> [MLStmt] {
        if check("{") { return try parseBlock() }
        skipStatementSeparators()
        if let statement = try parseStatement() { return [statement] }
        return []
    }

    // MARK: 制御構文

    open func parseIf() throws -> MLStmt {
        let location = current.location
        try expect("if")
        let condition = try parseCondition()
        let then = try parseThenBody()
        var otherwise: [MLStmt]?
        let savedIndex = index
        skipStatementSeparators()
        if check("else") {
            advance()
            if check("if") {
                otherwise = [try parseIf()]
            } else {
                _ = match("then")
                otherwise = try parseStatementAsBlock()
            }
        } else {
            index = savedIndex
        }
        return .ifStmt(condition: condition, then: then, otherwise: otherwise, location)
    }

    /// `if` を式としても書ける言語か。
    open var supportsIfExpression: Bool { false }

    /// 式としての `if`。
    open func parseIfExpression() throws -> MLExpr {
        let location = current.location
        try expect("if")
        let condition = try parseCondition()
        let then = try parseBranchExpression()
        var otherwise: MLExpr?
        let saved = index
        skipStatementSeparators()
        if check("else") {
            advance()
            otherwise = check("if") ? try parseIfExpression() : try parseBranchExpression()
        } else {
            index = saved
        }
        return .ifExpr(condition: condition, then: then, otherwise: otherwise, location)
    }

    /// `if` / `when` の分岐に書ける本体 (ブロックでも式でもよい)。
    open func parseBranchExpression() throws -> MLExpr {
        let location = current.location
        _ = match("then")
        if check("{") { return .block(try parseBlock(), location) }
        return try parseExpression()
    }

    /// `if` の条件。括弧を必須にする言語もあれば不要な言語もある。
    open func parseCondition() throws -> MLExpr {
        if check("(") {
            advance()
            let condition = try parseExpression()
            try expect(")", "条件の終わり")
            return condition
        }
        return try parseExpression(stopAtBrace: true)
    }

    open func parseThenBody() throws -> [MLStmt] {
        _ = match("then")
        return try parseStatementAsBlock()
    }

    open func parseWhile(label: String?) throws -> MLStmt {
        let location = current.location
        try expect("while")
        let condition = try parseCondition()
        _ = match("do")
        let body = try parseStatementAsBlock()
        return .whileStmt(condition: condition, body: body, label: label, location)
    }

    open func parseDoWhile(label: String?) throws -> MLStmt {
        let location = current.location
        try expect("do")
        let body = try parseStatementAsBlock()
        skipStatementSeparators()
        guard check("while") else {
            // `do { }` だけの言語 (Swift の `do`) はブロックとして扱う。
            return .block(body, location)
        }
        advance()
        let condition = try parseCondition()
        consumeStatementEnd()
        return .doWhile(body: body, condition: condition, isUntil: false,
                        label: label, location)
    }

    open func parseRepeat(label: String?) throws -> MLStmt {
        let location = current.location
        try expect("repeat")
        let body = try parseStatementAsBlock()
        skipStatementSeparators()
        if check("while") || check("until") {
            let isUntil = current.text == "until"
            advance()
            let condition = try parseCondition()
            consumeStatementEnd()
            return .doWhile(body: body, condition: condition, isUntil: isUntil,
                            label: label, location)
        }
        return .whileStmt(condition: .literal(.bool(true), location), body: body,
                          label: label, location)
    }

    open func parseFor(label: String?) throws -> MLStmt {
        let location = current.location
        advance() // for / foreach
        let hadParenthesis = match("(")

        // `for x in xs` 形式かどうかを先読みで判定する。
        if let forIn = try parseForInHeader(location: location, label: label,
                                            hadParenthesis: hadParenthesis) {
            return forIn
        }

        // C 形式 `for (init; cond; step)`
        var initializer: [MLStmt] = []
        if !check(";") {
            if let declaration = try parseForInitializerDeclaration() {
                initializer.append(declaration)
            } else if let keyword = matchedVariableKeyword() {
                initializer.append(try parseVariableDeclaration(keyword: keyword,
                                                                location: current.location,
                                                                consumesEnd: false))
            } else {
                repeat {
                    initializer.append(.expression(try parseExpression(), current.location))
                } while match(",")
            }
        }
        try expect(";", "for の初期化のあと")
        var condition: MLExpr?
        if !check(";") { condition = try parseExpression() }
        try expect(";", "for の条件のあと")
        var step: [MLStmt] = []
        if !check(")"), !check("{") {
            repeat {
                step.append(.expression(try parseExpression(), current.location))
            } while match(",")
        }
        if hadParenthesis { try expect(")", "for の終わり") }
        _ = match("do")
        let body = try parseStatementAsBlock()
        return .forClassic(initializer: initializer, condition: condition, step: step,
                           body: body, label: label, location)
    }

    /// `for (int i = 0; ...)` のように型が先に来る宣言を読む言語だけが上書きする。
    /// 文の終わりの `;` は消費しないこと。
    open func parseForInitializerDeclaration() throws -> MLStmt? { nil }

    /// `for x in xs` を読めたら返す。読めなければ位置を戻して nil。
    open func parseForInHeader(location: SourceLocation, label: String?,
                               hadParenthesis: Bool) throws -> MLStmt? {
        let saved = index
        var pattern: MLPattern?
        var sequence: MLExpr?
        var whereClause: MLExpr?

        // 見出しの部分だけを試しに読む。本体は「for-in だと確定してから」読む
        // (本体の中の構文エラーで C 形式に取り違えないため)。
        diagnostics.beginSuppression()
        do {
            _ = matchedVariableKeyword()
            let parsed = try parseForPattern()
            guard check("in") || check(":") || check("<-") else { throw AbortCompilation() }
            advance()
            sequence = try parseExpression(stopAtBrace: true)
            if match("where") || match("if") {
                whereClause = try parseExpression(stopAtBrace: true)
            }
            pattern = parsed
        } catch {
            index = saved
            diagnostics.endSuppression()
            return nil
        }
        diagnostics.endSuppression()

        guard let pattern, let sequence else {
            index = saved
            return nil
        }
        if hadParenthesis { _ = match(")") }
        _ = match("do")
        let body = try parseStatementAsBlock()
        return .forIn(pattern: pattern, sequence: sequence, body: body,
                      whereClause: whereClause, label: label, location)
    }

    /// `for` の左辺。既定は名前かタプル。
    open func parseForPattern() throws -> MLPattern {
        // 型注釈つき (`for (String name : list)`) にも対応する。
        if check("(") {
            advance()
            var items: [MLPattern] = []
            repeat {
                items.append(try parseForPattern())
            } while match(",")
            try expect(")", "for のパターン")
            return items.count == 1 ? items[0] : .tuple(items)
        }
        if check("[") {
            advance()
            var items: [MLPattern] = []
            if !check("]") {
                repeat {
                    items.append(try parseForPattern())
                } while match(",")
            }
            try expect("]", "for のパターン")
            return .list(items, restIndex: nil, restName: nil)
        }
        var name = try expectIdentifier("for の変数")
        // `for (String name : list)` のように型が先に来る形。
        if current.kind == .identifier, !check("in"), !check(":") {
            name = advance().text
        }
        if name == "_" { return .wildcard }
        return .binding(name)
    }

    open func parseSwitch(label: String?) throws -> MLStmt {
        let location = current.location
        advance() // switch / match / when
        let subject: MLExpr
        if check("(") {
            advance()
            subject = try parseExpression()
            try expect(")", "switch の対象")
        } else {
            subject = try parseExpression(stopAtBrace: true)
        }
        let arms = try parseSwitchBody()
        return .matchStmt(subject: subject, arms: arms, label: label, location)
    }

    open func parseSwitchBody() throws -> [MLMatchArm] {
        try expect("{", "switch の本体")
        var arms: [MLMatchArm] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            arms.append(try parseSwitchArm())
        }
        try expect("}", "switch の終わり")
        return arms
    }

    open func parseSwitchArm() throws -> MLMatchArm {
        var patterns: [MLPattern] = []
        var isDefault = false
        if check("default") || check("else") || check("_") {
            advance()
            isDefault = true
        } else {
            try expect("case", "switch の分岐")
            repeat {
                patterns.append(try parsePattern())
            } while match(",")
        }
        var guardCondition: MLExpr?
        if match("where", "if") { guardCondition = try parseExpression(stopAtBrace: true) }
        _ = match(":", "->", "=>", "then")

        var body: [MLStmt] = []
        var fallsThrough = false
        if check("{") {
            body = try parseBlock()
        } else {
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
        }
        // `break` だけの C 系の分岐は落ち込まない。
        if !fallsThrough, case .breakStmt? = body.last, body.count >= 1 {
            body.removeLast()
        }
        return MLMatchArm(patterns: patterns, guardCondition: guardCondition, body: body,
                          fallsThrough: fallsThrough, isDefault: isDefault)
    }

    open func parseTry() throws -> MLStmt {
        let location = current.location
        try expect("try")
        let body = try parseStatementAsBlock()
        var catches: [MLCatchClause] = []
        var finallyBody: [MLStmt]?
        while true {
            let saved = index
            skipStatementSeparators()
            if check("catch") || check("rescue") || check("except") {
                advance()
                var typeName: String?
                var binding: String?
                if match("(") {
                    // `catch (IOException e)`
                    if current.kind == .identifier || current.kind == .keyword {
                        typeName = try parseTypeName()
                        if current.kind == .identifier { binding = advance().text }
                    }
                    try expect(")", "catch の宣言")
                } else if current.kind == .identifier, !check("{") {
                    let name = advance().text
                    if current.kind == .identifier {
                        typeName = name
                        binding = advance().text
                    } else if check(":") {
                        advance()
                        binding = name
                        typeName = try parseTypeName()
                    } else {
                        binding = name
                    }
                }
                let clauseBody = try parseStatementAsBlock()
                catches.append(MLCatchClause(typeName: typeName, binding: binding,
                                             body: clauseBody))
                continue
            }
            if check("finally") || check("ensure") {
                advance()
                finallyBody = try parseStatementAsBlock()
                break
            }
            index = saved
            break
        }
        if catches.isEmpty && finallyBody == nil {
            // 例外を無視する `try` (Swift の `try expr`) はそのまま通す。
            catches.append(MLCatchClause(body: []))
        }
        return .tryStmt(body: body, catches: catches, finallyBody: finallyBody, location)
    }

    open func parseGuard() throws -> MLStmt {
        let location = current.location
        try expect("guard")
        let condition = try parseExpression(stopAtBrace: true)
        try expect("else", "guard の else")
        let elseBody = try parseStatementAsBlock()
        return .guardStmt(condition: condition, elseBody: elseBody, location)
    }

    // MARK: 変数宣言

    open func matchedVariableKeyword() -> String? {
        guard let isConstant = profile.variableKeywords[current.text] else { return nil }
        _ = isConstant
        return advance().text
    }

    open func parseVariableDeclaration(keyword: String, location: SourceLocation,
                                        consumesEnd: Bool = true) throws -> MLStmt {
        let isConstant = profile.variableKeywords[keyword] ?? false
        var declarations: [MLStmt] = []
        repeat {
            let pattern = try parseBindingPattern()
            var typeName: String?
            if match(":") { typeName = try parseTypeName() }
            var value: MLExpr?
            if match("=") { value = try parseExpression() }
            declarations.append(.varDecl(pattern: pattern, typeName: typeName, value: value,
                                          isConstant: isConstant, location))
        } while match(",")
        if consumesEnd { consumeStatementEnd() }
        return declarations.count == 1 ? declarations[0] : .block(declarations, location)
    }

    /// 変数宣言の左辺。
    open func parseBindingPattern() throws -> MLPattern {
        if check("(") || check("[") {
            return try parsePattern()
        }
        let name = try expectIdentifier("変数名")
        return name == "_" ? .wildcard : .binding(name)
    }

    // MARK: 関数宣言

    open func isFunctionDeclarationStart() -> Bool {
        switch profile.functionSyntax {
        case .keyword, .both:
            if profile.functionKeywords.contains(current.text) { return true }
            if profile.functionSyntax == .keyword { return false }
            return looksLikeTypeFirstFunction()
        case .typeFirst:
            return looksLikeTypeFirstFunction()
        }
    }

    /// 型名として使えないキーワード (文を始める語)。
    open var nonTypeKeywords: Set<String> {
        baseNonTypeKeywords.union(profile.typeKeywords.keys)
    }

    private var baseNonTypeKeywords: Set<String> {
        ["return", "if", "else", "while", "for", "foreach", "do", "switch", "match", "case",
         "default", "break", "continue", "throw", "throws", "try", "catch", "finally",
         "new", "delete", "import", "package", "using", "include", "require", "use",
         "module", "namespace", "guard", "repeat", "when", "in", "is", "as", "where",
         "then", "end", "goto", "yield", "await", "assert", "with", "super", "this",
         "self", "true", "false", "null", "nil", "none", "print", "typeof", "sizeof",
         "not", "and", "or", "instanceof", "extends", "implements", "let", "var", "val",
         "const", "def", "func", "fn", "function", "lambda", "elif", "until", "loop",
         "defer", "fallthrough", "select", "go", "spawn", "raise", "rescue", "ensure"]
    }

    /// `int f(` のような形かどうかを先読みで見る。
    open func looksLikeTypeFirstFunction() -> Bool {
        guard current.kind == .identifier || current.kind == .keyword else { return false }
        if nonTypeKeywords.contains(current.text),
           !profile.ignorableModifiers.contains(current.text) { return false }
        var offset = 0
        // 修飾子を読み飛ばす。
        while profile.ignorableModifiers.contains(peek(offset).text) { offset += 1 }
        // 型名。
        guard peek(offset).kind == .identifier || peek(offset).kind == .keyword else {
            return false
        }
        offset += 1
        // ジェネリクスやポインタ・配列。
        var depth = 0
        while true {
            let text = peek(offset).text
            if text == "<" { depth += 1; offset += 1; continue }
            if text == ">" , depth > 0 { depth -= 1; offset += 1; continue }
            if depth > 0 { offset += 1; continue }
            // `java.util.List` のような修飾つきの型名。ただし `Arrays.sort(` のような
            // メソッド呼び出しと取り違えないよう、次が `(` なら型名ではない。
            if text == ".", peek(offset + 1).kind == .identifier,
               !peek(offset + 2).is("(") {
                offset += 2
                continue
            }
            if text == "*" || text == "&" || text == "[" || text == "]" {
                offset += 1
                continue
            }
            break
        }
        // 関数名と開き括弧。
        guard peek(offset).kind == .identifier else { return false }
        return peek(offset + 1).is("(")
    }

    open func parseFunctionDeclaration() throws -> MLFunctionDecl {
        let location = current.location
        var isStatic = false
        var isAbstract = false
        while profile.ignorableModifiers.contains(current.text) {
            if current.text == "static" { isStatic = true }
            if current.text == "abstract" { isAbstract = true }
            advance()
        }
        var returnTypeName: String?
        if profile.functionKeywords.contains(current.text) {
            advance()
        } else {
            returnTypeName = try parseTypeName()
        }
        let name = try expectIdentifier("関数名")
        skipGenericParameters()
        let parameters = try parseParameterList()
        if match("->", ":") { returnTypeName = try parseTypeName() }
        skipThrowsClause()

        var body: [MLStmt] = []
        if check("{") {
            body = try parseBlock()
        } else if match("=") {
            // `def f(x) = expr` 形式。
            let value = try parseExpression()
            body = [.returnStmt(value, value.location)]
            consumeStatementEnd()
        } else {
            isAbstract = true
            consumeStatementEnd()
        }
        let isInitializer = name == currentTypeName || ["init", "constructor", "__init__"].contains(name)
        return MLFunctionDecl(name: name, parameters: parameters, body: body,
                              returnTypeName: returnTypeName, isStatic: isStatic,
                              isInitializer: isInitializer, location: location)
    }

    open func skipGenericParameters() {
        guard check("<") else { return }
        var depth = 0
        repeat {
            if check("<") { depth += 1 }
            if check(">") { depth -= 1 }
            if check(">>") { depth -= 2 }
            advance()
        } while !isAtEnd && depth > 0
    }

    /// 引数リストのうしろに付く修飾子 (C++ の `const` / `noexcept` など)。
    open var trailingFunctionQualifiers: Set<String> { [] }

    open func skipThrowsClause() {
        while trailingFunctionQualifiers.contains(current.text) { advance() }
        if check("throws") || check("rethrows") {
            advance()
            while current.kind == .identifier {
                advance()
                if !match(",") { break }
            }
        }
        while trailingFunctionQualifiers.contains(current.text) { advance() }
    }

    open func parseParameterList() throws -> [MLParameter] {
        try expect("(", "引数の始まり")
        var parameters: [MLParameter] = []
        while !isAtEnd, !check(")") {
            parameters.append(try parseParameter())
            if !match(",") { break }
        }
        try expect(")", "引数の終わり")
        return parameters
    }

    open func parseParameter() throws -> MLParameter {
        var isVariadic = false
        var isByReference = false
        var typeName: String?

        while profile.ignorableModifiers.contains(current.text) { advance() }
        if match("inout", "ref", "out", "&") { isByReference = true }
        if match("...", "*") { isVariadic = true }

        var name = try expectIdentifier("引数名")
        var label: String?

        // `name: Type`
        if match(":") {
            typeName = try parseTypeName()
        } else if current.kind == .identifier || check("*") || check("&") || check("[")
                    || check("<") {
            // `Type name` (C / Java 形式)
            typeName = name
            if check("<") { skipGenericParameters() }
            while match("*", "&") {}
            while check("["), peek(1).is("]") {
                advance()
                advance()
                typeName = "Array<\(typeName ?? "")>"
            }
            if match("...") { isVariadic = true }
            name = try expectIdentifier("引数名")
            while check("["), peek(1).is("]") {
                advance()
                advance()
                typeName = "Array<\(typeName ?? "")>"
            }
        } else if check("label") {
            label = name
        }
        if match("...") { isVariadic = true }

        var defaultValue: MLExpr?
        if match("=") { defaultValue = try parseExpression() }

        return MLParameter(label: label, name: name, typeName: typeName,
                           defaultValue: defaultValue, isVariadic: isVariadic,
                           isByReference: isByReference)
    }

    /// 型注釈を読む (中身は名前として持っておくだけ)。
    open func parseTypeName() throws -> String {
        var text = ""
        if match("?") { text = "?" }
        guard current.kind == .identifier || current.kind == .keyword else {
            // `[Int]` のような形。
            if check("[") {
                advance()
                let inner = try parseTypeName()
                if match(":") {
                    let value = try parseTypeName()
                    try expect("]", "辞書の型")
                    return "Map<\(inner),\(value)>"
                }
                try expect("]", "配列の型")
                return "Array<\(inner)>"
            }
            if check("(") {
                advance()
                var parts: [String] = []
                while !isAtEnd, !check(")") {
                    parts.append(try parseTypeName())
                    if !match(",") { break }
                }
                try expect(")", "型の括弧")
                if match("->", "=>") {
                    let result = try parseTypeName()
                    return "Func<\(parts.joined(separator: ",")),\(result)>"
                }
                return parts.count == 1 ? parts[0] : "Tuple<\(parts.joined(separator: ","))>"
            }
            throw report("型名が必要です")
        }
        text += advance().text
        // `a.b.C`
        while check("."), peek(1).kind == .identifier {
            advance()
            text += "." + advance().text
        }
        // ジェネリクス。
        if check("<") {
            var depth = 0
            var generic = ""
            repeat {
                if check("<") { depth += 1 }
                if check(">") { depth -= 1 }
                if check(">>") { depth -= 2 }
                generic += advance().text
            } while !isAtEnd && depth > 0
            text += generic
        }
        // ポインタ・配列・オプショナル。
        while true {
            if match("*") { text = "Pointer<\(text)>"; continue }
            if check("["), peek(1).is("]") {
                advance(); advance()
                text = "Array<\(text)>"
                continue
            }
            if match("?") { text = "Optional<\(text)>"; continue }
            if match("!") { text = "Optional<\(text)>"; continue }
            break
        }
        return text
    }

    // MARK: 型宣言

    open func matchedTypeKeyword() -> MLTypeDecl.Kind? {
        var offset = 0
        while profile.ignorableModifiers.contains(peek(offset).text) { offset += 1 }
        guard let kind = profile.typeKeywords[peek(offset).text] else { return nil }
        // `enum` が式の中で使われる場合を避けるため、次が名前であることを見る。
        guard peek(offset + 1).kind == .identifier else { return nil }
        return kind
    }

    open func parseTypeDeclaration(kind: MLTypeDecl.Kind) throws -> MLTypeDecl {
        let location = current.location
        var isAbstract = false
        while profile.ignorableModifiers.contains(current.text) {
            if current.text == "abstract" { isAbstract = true }
            advance()
        }
        advance() // class / struct / enum ...
        let name = try expectIdentifier("型名")
        skipGenericParameters()

        var primaryParameters: [MLParameter] = []
        if check("(") { primaryParameters = try parseParameterList() }

        var superclassName: String?
        var interfaceNames: [String] = []
        if match(":", "extends", "<") {
            repeat {
                let parent = try parseTypeName()
                if superclassName == nil { superclassName = parent }
                else { interfaceNames.append(parent) }
                // `Base(args)` のような呼び出しは読み飛ばす。
                if check("(") { skipBalanced(open: "(", close: ")") }
            } while match(",")
        }
        if match("implements", "with") {
            repeat {
                interfaceNames.append(try parseTypeName())
                if check("(") { skipBalanced(open: "(", close: ")") }
            } while match(",")
        }

        let savedTypeName = currentTypeName
        currentTypeName = name
        defer { currentTypeName = savedTypeName }

        let body = try parseTypeBody(kind: kind, typeName: name)
        return MLTypeDecl(kind: kind, name: name, superclassName: superclassName,
                          interfaceNames: interfaceNames, properties: body.properties,
                          methods: body.methods, initializers: body.initializers,
                          cases: body.cases, nestedTypes: body.nestedTypes,
                          bodyStatements: body.statements,
                          primaryParameters: primaryParameters, isAbstract: isAbstract,
                          location: location)
    }

    public struct TypeBody {
        public var properties: [MLPropertyDecl] = []
        public var methods: [MLFunctionDecl] = []
        public var initializers: [MLFunctionDecl] = []
        public var cases: [MLCaseDecl] = []
        public var nestedTypes: [MLTypeDecl] = []
        public var statements: [MLStmt] = []
        public init() {}
    }

    /// 列挙のケースに `case` キーワードが要るか (Java / C# は不要)。
    open var enumCasesNeedKeyword: Bool { true }

    open func parseTypeBody(kind: MLTypeDecl.Kind, typeName: String) throws -> TypeBody {
        var body = TypeBody()
        guard match("{") else {
            consumeStatementEnd()
            return body
        }
        // Java / C# の列挙は `case` を書かず、本体の先頭に定数を並べる。
        if kind == .enumType, !enumCasesNeedKeyword {
            while !isAtEnd, !check("}"), !check(";") {
                skipStatementSeparators()
                if check("}") || check(";") { break }
                // アノテーションは読み飛ばす。
                while check("@") {
                    advance()
                    if current.kind == .identifier { advance() }
                    if check("(") { skipBalanced(open: "(", close: ")") }
                }
                guard current.kind == .identifier else { break }
                let caseName = advance().text
                var associatedTypes: [String] = []
                if check("(") {
                    // `RED(255, 0, 0)` の引数はケースの付随値として持たせる。
                    advance()
                    var index = 0
                    while !isAtEnd, !check(")") {
                        _ = try parseExpression()
                        associatedTypes.append("Object")
                        index += 1
                        if !match(",") { break }
                    }
                    try expect(")", "列挙の引数")
                }
                if check("{") { skipBalanced(open: "{", close: "}") }
                var rawValue: MLExpr?
                if match("=") { rawValue = try parseExpression() }
                body.cases.append(MLCaseDecl(name: caseName,
                                             associatedTypes: associatedTypes,
                                             rawValue: rawValue))
                if !match(",") { break }
            }
            _ = match(";")
        }
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            let before = index
            try parseTypeMember(into: &body, kind: kind, typeName: typeName)
            if index == before { advance() }
        }
        try expect("}", "型の終わり")
        return body
    }

    open func parseTypeMember(into body: inout TypeBody, kind: MLTypeDecl.Kind,
                              typeName: String) throws {
        // 列挙のケース。
        if kind == .enumType, check("case") {
            advance()
            repeat {
                let caseName = try expectIdentifier("列挙のケース")
                var associatedTypes: [String] = []
                if check("(") {
                    advance()
                    while !isAtEnd, !check(")") {
                        associatedTypes.append(try parseTypeName())
                        if !match(",") { break }
                    }
                    try expect(")", "列挙のケース")
                }
                var rawValue: MLExpr?
                if match("=") { rawValue = try parseExpression() }
                body.cases.append(MLCaseDecl(name: caseName, associatedTypes: associatedTypes,
                                             rawValue: rawValue))
            } while match(",")
            consumeStatementEnd()
            return
        }

        var isStatic = false
        var isAbstract = false
        var sawModifier = false
        while profile.ignorableModifiers.contains(current.text) {
            if current.text == "static" || current.text == "class" { isStatic = true }
            if current.text == "abstract" { isAbstract = true }
            // アノテーション `@Foo(...)`
            if current.text == "@" {
                advance()
                if current.kind == .identifier { advance() }
                if check("(") { skipBalanced(open: "(", close: ")") }
                sawModifier = true
                continue
            }
            advance()
            sawModifier = true
        }
        _ = sawModifier

        // `static <T> void show(...)` のような総称メソッドの型引数。
        if check("<") { skipGenericParameters() }

        if let nestedKind = matchedTypeKeyword() {
            body.nestedTypes.append(try parseTypeDeclaration(kind: nestedKind))
            return
        }

        // `Base(String name) { ... }` のようなコンストラクタ。
        let isConstructor = current.text == typeName && peek(1).is("(")
        if isConstructor || isFunctionDeclarationStart() || current.text == "init" {
            let function = try parseTypeMethod(isStatic: isStatic, isAbstract: isAbstract,
                                               typeName: typeName)
            if function.isInitializer { body.initializers.append(function) }
            else { body.methods.append(function) }
            return
        }

        if let keyword = matchedVariableKeyword() {
            let isConstant = profile.variableKeywords[keyword] ?? false
            repeat {
                let name = try expectIdentifier("プロパティ名")
                var propertyTypeName: String?
                if match(":") { propertyTypeName = try parseTypeName() }
                var defaultValue: MLExpr?
                if match("=") { defaultValue = try parseExpression() }
                var getter: [MLStmt]?
                var setter: [MLStmt]?
                var setterParameter: String?
                if check("{") {
                    (getter, setter, setterParameter) = try parseAccessors()
                }
                body.properties.append(MLPropertyDecl(name: name, typeName: propertyTypeName,
                                                      defaultValue: defaultValue,
                                                      isConstant: isConstant, isStatic: isStatic,
                                                      getter: getter, setter: setter,
                                                      setterParameter: setterParameter))
            } while match(",")
            consumeStatementEnd()
            return
        }

        // `int value;` のような型が先に来るフィールド。
        if (current.kind == .identifier || current.kind == .keyword), looksLikeFieldDeclaration() {
            let fieldType = try parseTypeName()
            repeat {
                let name = try expectIdentifier("フィールド名")
                var arrayDepth = 0
                while check("["), peek(1).is("]") { advance(); advance(); arrayDepth += 1 }
                var getter: [MLStmt]?
                var setter: [MLStmt]?
                var setterParameter: String?
                // `int Value { get; set; }` のようなプロパティ。
                if check("{") {
                    (getter, setter, setterParameter) = try parseAccessors()
                }
                var defaultValue: MLExpr?
                if match("=") { defaultValue = try parseExpression() }
                var fullType = fieldType
                for _ in 0..<arrayDepth { fullType = "Array<\(fullType)>" }
                body.properties.append(MLPropertyDecl(name: name, typeName: fullType,
                                                      defaultValue: defaultValue,
                                                      isConstant: false, isStatic: isStatic,
                                                      getter: getter, setter: setter,
                                                      setterParameter: setterParameter))
            } while match(",")
            consumeStatementEnd()
            return
        }

        // それ以外は初期化のための文として扱う (Scala / Kotlin の本体式)。
        if let statement = try parseStatement() { body.statements.append(statement) }
    }

    open func parseTypeMethod(isStatic: Bool, isAbstract: Bool,
                              typeName: String) throws -> MLFunctionDecl {
        let location = current.location
        var returnTypeName: String?
        var name: String
        if profile.functionKeywords.contains(current.text) {
            advance()
            name = try expectIdentifier("メソッド名")
        } else if current.text == "init" {
            name = advance().text
        } else {
            // `Type name(...)` か `Type(...)` (コンストラクタ)。
            let saved = index
            let parsedType = try parseTypeName()
            if check("(") {
                name = parsedType
                index = saved
                _ = advance()
            } else {
                returnTypeName = parsedType
                name = try expectIdentifier("メソッド名")
            }
        }
        skipGenericParameters()
        let parameters = try parseParameterList()
        if match("->", ":") { returnTypeName = try parseTypeName() }
        skipThrowsClause()

        var body: [MLStmt] = []
        var abstract = isAbstract
        if check("{") {
            body = try parseBlock()
        } else if match("=") {
            let value = try parseExpression()
            body = [.returnStmt(value, value.location)]
            consumeStatementEnd()
        } else {
            abstract = true
            consumeStatementEnd()
        }
        let isInitializer = name == typeName
            || ["init", "constructor", "__init__", "new"].contains(name)
        return MLFunctionDecl(name: isInitializer ? "init" : name,
                              parameters: parameters, body: body,
                              returnTypeName: returnTypeName, isStatic: isStatic,
                              isInitializer: isInitializer, isAbstract: abstract,
                              location: location)
    }

    /// `var x: Int { get { } set { } }`
    open func parseAccessors() throws -> ([MLStmt]?, [MLStmt]?, String?) {
        try expect("{", "アクセサ")
        var getter: [MLStmt]?
        var setter: [MLStmt]?
        var setterParameter: String?
        var implicitGetter: [MLStmt] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            if check("get") {
                advance()
                getter = check("{") ? try parseBlock() : []
                continue
            }
            if check("set") {
                advance()
                if match("(") {
                    setterParameter = try expectIdentifier("set の引数")
                    try expect(")", "set の引数")
                }
                setter = check("{") ? try parseBlock() : []
                continue
            }
            let before = index
            if let statement = try parseStatement() { implicitGetter.append(statement) }
            if index == before { advance() }
        }
        try expect("}", "アクセサの終わり")
        if getter == nil, !implicitGetter.isEmpty {
            // `var x: Int { expr }` は取得だけの計算プロパティ。
            if implicitGetter.count == 1, case .expression(let value, let location) = implicitGetter[0] {
                getter = [.returnStmt(value, location)]
            } else {
                getter = implicitGetter
            }
        }
        return (getter, setter, setterParameter)
    }

    open func looksLikeFieldDeclaration() -> Bool {
        var offset = 0
        guard peek(offset).kind == .identifier || peek(offset).kind == .keyword else {
            return false
        }
        if nonTypeKeywords.contains(peek(offset).text) { return false }
        offset += 1
        var depth = 0
        while true {
            let text = peek(offset).text
            if text == "<" { depth += 1; offset += 1; continue }
            if text == ">", depth > 0 { depth -= 1; offset += 1; continue }
            if depth > 0 { offset += 1; continue }
            if text == "[" , peek(offset + 1).is("]") { offset += 2; continue }
            if text == "*" || text == "." { offset += 1; continue }
            break
        }
        guard peek(offset).kind == .identifier else { return false }
        let next = peek(offset + 1).text
        // `int Value { get; set; }` のようなプロパティも宣言として扱う。
        return next == ";" || next == "=" || next == "," || next == "{"
            || peek(offset + 1).is("[")
    }

    open func skipBalanced(open: String, close: String) {
        guard check(open) else { return }
        var depth = 0
        repeat {
            if check(open) { depth += 1 }
            if check(close) { depth -= 1 }
            advance()
        } while !isAtEnd && depth > 0
    }

    // MARK: - パターン

    open func parsePattern() throws -> MLPattern {
        var pattern = try parsePrimaryPattern()
        if check("|") {
            var options = [pattern]
            while match("|") { options.append(try parsePrimaryPattern()) }
            pattern = .or(options)
        }
        if match("as") {
            let typeName = try parseTypeName()
            pattern = .typed(pattern, typeName: typeName)
        }
        return pattern
    }

    open func parsePrimaryPattern() throws -> MLPattern {
        if match("_") { return .wildcard }
        if match("let", "var", "val") {
            let name = try expectIdentifier("パターンの変数")
            if match(":") {
                let typeName = try parseTypeName()
                return .typed(.binding(name), typeName: typeName)
            }
            return name == "_" ? .wildcard : .binding(name)
        }
        if check("(") {
            advance()
            var items: [MLPattern] = []
            if !check(")") {
                repeat { items.append(try parsePattern()) } while match(",")
            }
            try expect(")", "パターンの括弧")
            return items.count == 1 ? items[0] : .tuple(items)
        }
        if check("[") {
            advance()
            var items: [MLPattern] = []
            var restIndex: Int?
            var restName: String?
            while !isAtEnd, !check("]") {
                if match("...", "..") {
                    restIndex = items.count
                    if current.kind == .identifier { restName = advance().text }
                } else {
                    items.append(try parsePattern())
                }
                if !match(",") { break }
            }
            try expect("]", "リストのパターン")
            return .list(items, restIndex: restIndex, restName: restName)
        }
        // `.caseName` / `.caseName(let x)`
        if check("."), peek(1).kind == .identifier {
            advance()
            return try parseConstructorPattern(name: advance().text)
        }
        if current.kind == .identifier {
            var name = advance().text
            // `Color.Red` / `Shape::Circle` のように修飾された列挙のケース。
            while (check(".") || check("::")), peek(1).kind == .identifier {
                advance()
                name = advance().text
            }
            if check("(") { return try parseConstructorPattern(name: name) }
            if check("{") , peek(1).kind == .identifier, peek(2).is(":") {
                return try parseConstructorPattern(name: name)
            }
            // 大文字始まりは定数・型名として扱う言語が多い。
            if let first = name.first, first.isUppercase {
                return .constructor(name: name, positional: [], named: [])
            }
            if name == "_" { return .wildcard }
            return .binding(name)
        }
        // リテラル。
        let expression = try parseExpression(stopAtBrace: true)
        if case .literal(let value, _) = expression {
            // 範囲パターン。
            if check("...") || check("..<") {
                let isClosed = current.text == "..."
                advance()
                let upper = try parseExpression(stopAtBrace: true)
                return .range(lower: .literal(value, expression.location), upper: upper,
                              isClosed: isClosed)
            }
            return .literal(value)
        }
        return .expression(expression)
    }

    open func parseConstructorPattern(name: String) throws -> MLPattern {
        var positional: [MLPattern] = []
        var named: [(String, MLPattern)] = []
        if match("(") {
            while !isAtEnd, !check(")") {
                if current.kind == .identifier, peek(1).is(":") {
                    let field = advance().text
                    advance()
                    named.append((field, try parsePattern()))
                } else {
                    positional.append(try parsePattern())
                }
                if !match(",") { break }
            }
            try expect(")", "パターンの引数")
        } else if match("{") {
            while !isAtEnd, !check("}") {
                let field = try expectIdentifier("フィールドのパターン")
                try expect(":", "フィールドのパターン")
                named.append((field, try parsePattern()))
                if !match(",") { break }
            }
            try expect("}", "パターンの終わり")
        }
        return .constructor(name: name, positional: positional, named: named)
    }

    // MARK: - 式

    /// 演算子の結合の強さ。数が大きいほど強い。
    open func precedence(of op: String) -> Int? {
        switch op {
        case "||", "or": return 2
        case "&&", "and": return 3
        case "|": return 4
        case "^": return 5
        case "&": return 6
        case "==", "!=", "===", "!==", "<>", "/=", "eq", "ne": return 7
        case "<", ">", "<=", ">=", "<=>", "instanceof", "is", "in": return 8
        case "??": return 9
        case "..", "...", "..<": return 10
        case "<<", ">>", ">>>": return 11
        case "+", "-": return 12
        case "*", "/", "%": return 13
        case "**": return 15
        default: return nil
        }
    }

    /// 右結合の演算子。
    open func isRightAssociative(_ op: String) -> Bool {
        op == "**" || op == "??"
    }

    /// `{` を式の開始とみなさない文脈 (`if x {` など) では stopAtBrace を立てる。
    open func parseExpression(stopAtBrace: Bool = false) throws -> MLExpr {
        try parseAssignment(stopAtBrace: stopAtBrace)
    }

    open func parseAssignment(stopAtBrace: Bool) throws -> MLExpr {
        let left = try parseTernary(stopAtBrace: stopAtBrace)
        guard profile.assignmentOperators.contains(current.text),
              current.kind == .punctuation else { return left }
        let location = current.location
        let op = advance().text
        let right = try parseAssignment(stopAtBrace: stopAtBrace)
        return .assign(op: op, target: left, value: right, location)
    }

    open func parseTernary(stopAtBrace: Bool) throws -> MLExpr {
        let condition = try parseBinary(minimumPrecedence: 0, stopAtBrace: stopAtBrace)
        guard check("?"), !check("?.") else { return condition }
        let location = current.location
        advance()
        let then = try parseExpression(stopAtBrace: stopAtBrace)
        try expect(":", "三項演算子")
        let otherwise = try parseExpression(stopAtBrace: stopAtBrace)
        return .ternary(condition: condition, then: then, otherwise: otherwise, location)
    }

    open func parseBinary(minimumPrecedence: Int, stopAtBrace: Bool) throws -> MLExpr {
        var left = try parseUnary(stopAtBrace: stopAtBrace)
        while true {
            let op = current.text
            guard current.kind == .punctuation || current.kind == .keyword,
                  let level = precedence(of: op), level >= minimumPrecedence else { break }
            // 改行で文が切れる言語では、行頭の演算子だけ続きとみなす。
            if profile.newlineTerminatesStatement, current.precededByNewline,
               !isContinuationOperator(op) { break }
            let location = current.location
            advance()

            // 型の検査 (`x is Foo` / `x instanceof Foo`)。
            if op == "is" || op == "instanceof" {
                let typeName = try parseTypeName()
                left = .typeTest(left, typeName: typeName, location)
                continue
            }
            // 範囲。
            if op == ".." || op == "..." || op == "..<" {
                let upper = try parseBinary(minimumPrecedence: level + 1, stopAtBrace: stopAtBrace)
                left = .range(lower: left, upper: upper,
                              isClosed: op != "..<", step: nil, location)
                continue
            }
            let nextMinimum = isRightAssociative(op) ? level : level + 1
            let right = try parseBinary(minimumPrecedence: nextMinimum, stopAtBrace: stopAtBrace)
            left = .binary(op: op, lhs: left, rhs: right, location)
        }
        return left
    }

    /// 行頭に置いても前の行の続きになる演算子か。
    open func isContinuationOperator(_ op: String) -> Bool {
        ["+", "-", "*", "/", "%", "&&", "||", ".", "?:", "==", "!=", "<", ">", "<=", ">="]
            .contains(op)
    }

    open func parseUnary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if current.kind == .punctuation || current.kind == .keyword {
            switch current.text {
            case "-", "+", "!", "~", "not":
                let op = advance().text
                let operand = try parseUnary(stopAtBrace: stopAtBrace)
                return .unary(op: op, operand: operand, isPostfix: false, location)
            case "++", "--":
                let op = advance().text
                let operand = try parseUnary(stopAtBrace: stopAtBrace)
                return .unary(op: op, operand: operand, isPostfix: false, location)
            case "*":
                advance()
                return .dereference(try parseUnary(stopAtBrace: stopAtBrace), location)
            case "&":
                advance()
                return .reference(try parseUnary(stopAtBrace: stopAtBrace), location)
            case "new":
                advance()
                let typeName = try parseTypeName()
                // `new int[]{1, 2}` / `new Color[]{...}` は型名が `Array<...>` になる。
                if check("{") {
                    let items = try parseArrayInitializer()
                    return .listLiteral(items, spreadIndices: [], location)
                }
                var arguments: [MLArgument] = []
                if check("(") { arguments = try parseArgumentList() }
                else if check("[") {
                    // `new int[10]` / `new int[3][]`
                    advance()
                    let size = check("]") ? nil : try parseExpression()
                    try expect("]", "配列の生成")
                    // 残りの `[]` / `[n]` は読み捨てて 1 次元として扱う。
                    while check("[") {
                        advance()
                        if !check("]") { _ = try parseExpression() }
                        try expect("]", "配列の生成")
                    }
                    if check("{") {
                        let items = try parseArrayInitializer()
                        return .listLiteral(items, spreadIndices: [], location)
                    }
                    if let size {
                        return .call(callee: .name("#newArray", location),
                                     arguments: [MLArgument(value: size),
                                                 MLArgument(value: .literal(.string(typeName),
                                                                            location))],
                                     location)
                    }
                    return .listLiteral([], spreadIndices: [], location)
                }
                return .construct(typeName: typeName, arguments: arguments, location)
            case "await", "yield":
                advance()
                return try parseUnary(stopAtBrace: stopAtBrace)
            default:
                break
            }
        }
        return try parsePostfix(stopAtBrace: stopAtBrace)
    }

    open func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        var expression = try parsePrimary(stopAtBrace: stopAtBrace)
        while true {
            let location = current.location
            if memberAccessOperators.contains(where: { check($0) }) {
                let isOptional = current.text == "?."
                advance()
                // `list.0` のようなタプル添字。
                if current.kind == .integerLiteral {
                    let index = advance().intValue ?? 0
                    expression = .member(expression, "_\(index + 1)", isOptional: isOptional,
                                         location)
                    continue
                }
                let name = try expectIdentifier("メンバー名")
                expression = .member(expression, name, isOptional: isOptional, location)
                continue
            }
            if check("(") {
                let arguments = try parseArgumentList()
                expression = .call(callee: expression, arguments: arguments, location)
                continue
            }
            if check("["), !current.precededByNewline {
                advance()
                let index = check(":") ? MLExpr.literal(.int(0), location) : try parseExpression()
                if match(":", "...", "..<", "..") {
                    let upper = check("]") ? nil : try parseExpression()
                    try expect("]", "切り出し")
                    expression = .subscriptExpr(expression, index: index, upper: upper, location)
                    continue
                }
                try expect("]", "添字")
                expression = .subscriptExpr(expression, index: index, upper: nil, location)
                continue
            }
            if check("!"), !current.precededByNewline, isForceUnwrapContext() {
                advance()
                expression = .forceUnwrap(expression, location)
                continue
            }
            if check("++") || check("--") {
                let op = advance().text
                expression = .unary(op: op, operand: expression, isPostfix: true, location)
                continue
            }
            if check("as") {
                advance()
                let isOptional = match("?")
                _ = match("!")
                let typeName = try parseTypeName()
                expression = .cast(expression, typeName: typeName, isOptional: isOptional,
                                   location)
                continue
            }
            // 末尾クロージャ `list.map { ... }`
            if check("{"), !stopAtBrace, allowsTrailingClosure(after: expression) {
                let closure = try parseTrailingClosure()
                if case .call(let callee, let arguments, let callLocation) = expression {
                    expression = .call(callee: callee,
                                       arguments: arguments + [MLArgument(value: closure)],
                                       callLocation)
                } else {
                    expression = .call(callee: expression,
                                       arguments: [MLArgument(value: closure)], location)
                }
                continue
            }
            break
        }
        return expression
    }

    /// `a.b` のようにメンバーを取り出す記号。`->` を使う言語だけ足す。
    open var memberAccessOperators: [String] { [".", "?."] }

    /// `!` を強制アンラップとして読むか (既定では読まない)。
    open func isForceUnwrapContext() -> Bool { false }

    /// 末尾クロージャを許すか。
    open func allowsTrailingClosure(after expression: MLExpr) -> Bool { false }

    open func parseTrailingClosure() throws -> MLExpr {
        let location = current.location
        let body = try parseBlock()
        let decl = MLFunctionDecl(name: "", parameters: [], body: body,
                                  usesImplicitArguments: true, location: location)
        return .lambda(decl, location)
    }

    open func parseArgumentList() throws -> [MLArgument] {
        try expect("(", "引数の始まり")
        var arguments: [MLArgument] = []
        while !isAtEnd, !check(")") {
            arguments.append(try parseArgument())
            if !match(",") { break }
        }
        try expect(")", "引数の終わり")
        return arguments
    }

    open func parseArgument() throws -> MLArgument {
        var isSpread = false
        if match("...", "*", "&") { isSpread = current.kind == .identifier }
        var label: String?
        if (current.kind == .identifier || current.kind == .keyword), peek(1).is(":"),
           !peek(2).is(":") {
            label = advance().text
            advance()
        }
        let value = try parseExpression()
        if match("...") { isSpread = true }
        return MLArgument(label: label, value: value, isSpread: isSpread)
    }

    open func parseArrayInitializer() throws -> [MLExpr] {
        try expect("{", "配列の初期化")
        var items: [MLExpr] = []
        while !isAtEnd, !check("}") {
            if check("{") {
                items.append(.listLiteral(try parseArrayInitializer(), spreadIndices: [],
                                          current.location))
            } else {
                items.append(try parseExpression())
            }
            if !match(",") { break }
        }
        try expect("}", "配列の初期化の終わり")
        return items
    }

    // MARK: 基本の式

    open func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let token = current
        let location = token.location

        switch token.kind {
        case .integerLiteral:
            advance()
            return .literal(.int(token.intValue ?? 0), location)
        case .floatLiteral:
            advance()
            return .literal(.double(token.doubleValue ?? 0), location)
        case .stringLiteral:
            advance()
            return .literal(.string(token.stringValue ?? token.text), location)
        case .charLiteral:
            advance()
            if let first = (token.stringValue ?? token.text).first {
                return .literal(.char(first), location)
            }
            return .literal(.string(""), location)
        case .interpolatedString:
            advance()
            return try buildInterpolation(from: token)
        default:
            break
        }

        if profile.trueLiterals.contains(token.text) {
            advance()
            return .literal(.bool(true), location)
        }
        if profile.falseLiterals.contains(token.text) {
            advance()
            return .literal(.bool(false), location)
        }
        if profile.nullLiterals.contains(token.text) {
            advance()
            return .literal(.unit, location)
        }
        if profile.selfKeywords.contains(token.text) {
            advance()
            return .selfExpressionFallback(location)
        }
        if token.text == "super" {
            advance()
            return .superRef(location)
        }

        // 式としての `if` (Kotlin / Scala / Rust など)。
        if supportsIfExpression, check("if") { return try parseIfExpression() }

        // ラムダ。
        if let lambda = try parseLambdaIfPresent(stopAtBrace: stopAtBrace) { return lambda }

        if check("(") {
            advance()
            if check(")") {
                advance()
                return .tupleLiteral([], location)
            }
            var items: [MLExpr] = []
            repeat {
                items.append(try parseExpression())
            } while match(",")
            try expect(")", "括弧の終わり")
            return items.count == 1 ? items[0] : .tupleLiteral(items, location)
        }

        if check("[") {
            return try parseListOrMapLiteral()
        }

        if check("{"), !stopAtBrace {
            return try parseBraceLiteral()
        }

        // `.caseName`
        if check("."), peek(1).kind == .identifier {
            advance()
            return .implicitMember(advance().text, location)
        }

        if token.kind == .identifier || token.kind == .keyword {
            advance()
            return .name(token.text, location)
        }

        throw report("式が必要です")
    }

    /// `self` を返す式 (言語によっては別の名前で束縛されている)。
    open func parseLambdaIfPresent(stopAtBrace: Bool) throws -> MLExpr? { nil }

    /// `[1, 2, 3]` / `["a": 1]`
    open func parseListOrMapLiteral() throws -> MLExpr {
        let location = current.location
        try expect("[", "配列リテラル")
        if check(":") {
            advance()
            try expect("]", "空の辞書")
            return .mapLiteral([], location)
        }
        if check("]") {
            advance()
            return .listLiteral([], spreadIndices: [], location)
        }
        var items: [MLExpr] = []
        var spreadIndices: Set<Int> = []
        var pairs: [(key: MLExpr, value: MLExpr)] = []
        var isMap = false
        repeat {
            if check("]") { break }
            var isSpread = false
            if match("...") { isSpread = true }
            let first = try parseExpression()
            if match(":") {
                isMap = true
                pairs.append((key: first, value: try parseExpression()))
            } else {
                if isSpread { spreadIndices.insert(items.count) }
                items.append(first)
            }
        } while match(",")
        try expect("]", "配列リテラルの終わり")
        return isMap ? .mapLiteral(pairs, location)
                     : .listLiteral(items, spreadIndices: spreadIndices, location)
    }

    /// `{ ... }` が式に来たときの解釈。既定では辞書リテラル。
    open func parseBraceLiteral() throws -> MLExpr {
        let location = current.location
        try expect("{", "辞書リテラル")
        var pairs: [(key: MLExpr, value: MLExpr)] = []
        while !isAtEnd, !check("}") {
            let key: MLExpr
            if (current.kind == .identifier || current.kind == .keyword), peek(1).is(":") {
                key = .literal(.string(advance().text), current.location)
            } else {
                key = try parseExpression()
            }
            try expect(":", "辞書の区切り")
            pairs.append((key: key, value: try parseExpression()))
            if !match(",") { break }
        }
        try expect("}", "辞書リテラルの終わり")
        return .mapLiteral(pairs, location)
    }

    /// 補間つき文字列を式に組み立てる。
    open func buildInterpolation(from token: MLToken) throws -> MLExpr {
        var parts: [MLExpr] = []
        for piece in token.pieces {
            if piece.isExpression {
                parts.append(try parseSubExpression(piece.text, at: piece.location))
            } else {
                parts.append(.literal(.string(piece.text), piece.location))
            }
        }
        if parts.isEmpty { return .literal(.string(""), token.location) }
        return .interpolation(parts, token.location)
    }

    /// 文字列補間の中身など、部分的なソースを式として読み直す。
    open func parseSubExpression(_ text: String, at location: SourceLocation) throws -> MLExpr {
        let lexer = makeLexer(for: text)
        var subTokens = lexer.tokenize()
        // 位置情報を元の場所に寄せておく。
        for index in subTokens.indices {
            subTokens[index].location = location
        }
        let parser = makeSubParser(tokens: subTokens)
        return try parser.parseExpression()
    }

    /// 部分ソースを切るための字句解析器。言語ごとに上書きする。
    open func makeLexer(for text: String) -> MLProfileLexer {
        MLProfileLexer(source: text, profile: profile, diagnostics: diagnostics)
    }

    /// 部分ソースを読むための構文解析器。言語ごとに上書きする。
    open func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        MLProfileParser(tokens: tokens, profile: profile, diagnostics: diagnostics)
    }
}

extension MLExpr {
    /// `self` / `this` を表す式。
    static func selfExpressionFallback(_ location: SourceLocation) -> MLExpr {
        .selfRef(location)
    }
}
