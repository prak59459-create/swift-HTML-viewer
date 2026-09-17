import Foundation

/// 内蔵の Rust 処理系。
///
/// 所有権・借用は実行時の意味に影響しないので検査せず、
/// 構文と標準ライブラリの振る舞いを再現することに集中している。
public enum MiniRust: MiniLangEngine {
    public static var languageID: String { "rust" }
    public static var displayName: String { "内蔵 Rust 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = RustLexer(source: source, diagnostics: diagnostics).tokenize()
        return try RustParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            executeOnCurrentThread(source: source, input: input, limits: limits)
        }
    }

    static func executeOnCurrentThread(source: String, input: String,
                                       limits: MiniLangLimits) -> MiniLangExecution {
        let diagnostics = DiagnosticBag(source: source)
        let tokens = RustLexer(source: source, diagnostics: diagnostics).tokenize()
        let parser = RustParser(tokens: tokens, diagnostics: diagnostics)
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
        let interpreter = MLInterpreter(semantics: RustSemantics(), limits: limits, input: input)
        return interpreter.run(program)
    }
}

// MARK: - 見た目

enum RustProfile {
    static let keywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
        "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
        "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
        "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"
    ]

    static let profile = MLLanguageProfile(
        languageID: "rust",
        comments: [.line("//"), .block(open: "/*", close: "*/", nesting: true)],
        strings: [MLLanguageProfile.StringStyle(quote: "\""),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators + ["=>", "::", "..=", "->"],
        newlineTerminatesStatement: false,
        usesSemicolons: true,
        functionSyntax: .keyword,
        functionKeywords: ["fn"],
        variableKeywords: ["let": true],
        typeKeywords: ["struct": .structType, "enum": .enumType, "trait": .interfaceType],
        ignorableModifiers: ["pub", "const", "static", "unsafe", "extern", "async", "#"],
        lambdaArrows: ["->"],
        nullLiterals: [],
        selfKeywords: ["self"])
}

final class RustLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: RustProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        let start = location
        // 生文字列 `r"..."` / `r#"..."#`
        if peek() == "r", peek(1) == "\"" || peek(1) == "#" {
            let saved = position
            advance()
            var hashes = 0
            while peek() == "#" {
                hashes += 1
                advance()
            }
            if peek() == "\"" {
                advance()
                var text = ""
                let closing = "\"" + String(repeating: "#", count: hashes)
                while !isAtEnd {
                    if lookahead(closing) {
                        _ = match(closing)
                        break
                    }
                    if let character = advance() { text.append(character) }
                }
                return MLToken(kind: .stringLiteral, text: text, location: start,
                               stringValue: text)
            }
            // 生文字列ではなかったので戻す。
            while position > saved { retreat() }
        }
        // `'a` はライフタイム、`'x'` は文字リテラル。
        if peek() == "'" {
            if let next = peek(1), MLLexerBase.isIdentifierStart(next), peek(2) != "'" {
                advance()
                let name = readIdentifier()
                return MLToken(kind: .punctuation, text: "'" + name, location: start)
            }
        }
        // 数値の型接尾辞 (`1u32`, `2.5f64`)。
        if let character = peek(), character.isNumber {
            var token = readNumber(allowsUnderscoreSeparator: true)
            if let next = peek(), next == "i" || next == "u" || next == "f" {
                let saved = position
                let suffix = readIdentifier()
                if ["i8", "i16", "i32", "i64", "i128", "isize",
                    "u8", "u16", "u32", "u64", "u128", "usize",
                    "f32", "f64"].contains(suffix) {
                    if suffix.hasPrefix("f"), token.kind == .integerLiteral {
                        token = MLToken(kind: .floatLiteral, text: token.text,
                                        location: token.location,
                                        doubleValue: Double(token.intValue ?? 0))
                    }
                } else {
                    while position > saved { retreat() }
                }
            }
            return token
        }
        return super.nextToken()
    }

    /// 1 文字戻す (生文字列の判定で使う)。
    private func retreat() {
        guard position > 0 else { return }
        setPosition(position - 1)
    }
}

final class RustParser: MLProfileParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: RustProfile.profile, diagnostics: diagnostics)
    }

    override func entryPointName() -> String? { "main" }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            skipAttributes()
            if isAtEnd { break }
            if check("use") || check("mod") || check("extern") || check("type") {
                advance()
                if check("{") { skipBalanced(open: "{", close: "}") }
                else { skipToStatementEnd() }
                continue
            }
            if check("impl") {
                statements.append(contentsOf: try parseImpl())
                continue
            }
            while profile.ignorableModifiers.contains(current.text), current.text != "#" {
                advance()
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

    private func skipAttributes() {
        while check("#") {
            advance()
            _ = match("!")
            if check("[") { skipBalanced(open: "[", close: "]") }
        }
    }

    /// `impl Foo { fn bar(&self) { } }` をクラスのメソッドとして取り込む。
    private func parseImpl() throws -> [MLStmt] {
        try expect("impl")
        skipGenericParameters()
        var typeName = try parseTypeName()
        // `impl Trait for Type`
        if match("for") { typeName = try parseTypeName() }
        if check("where") { while !isAtEnd, !check("{") { advance() } }
        typeName = MLInterpreter.baseTypeName(typeName)

        try expect("{", "impl の本体")
        var methods: [MLFunctionDecl] = []
        var initializers: [MLFunctionDecl] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            skipAttributes()
            if check("}") { break }
            while profile.ignorableModifiers.contains(current.text), current.text != "#" {
                advance()
            }
            if check("type") {
                skipToStatementEnd()
                continue
            }
            guard check("fn") else {
                advance()
                continue
            }
            let method = try parseRustFunction(ownerTypeName: typeName)
            if method.isInitializer { initializers.append(method) }
            else { methods.append(method) }
        }
        try expect("}", "impl の終わり")

        let declaration = MLTypeDecl(kind: .classType, name: typeName,
                                     methods: methods, initializers: initializers,
                                     location: current.location)
        return [.typeDecl(declaration)]
    }

    override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        skipAttributes()
        if isAtEnd { return nil }
        let location = current.location

        if check("impl") { return .block(try parseImpl(), location) }
        if check("use") || check("mod") || check("type") || check("extern") {
            advance()
            if check("{") { skipBalanced(open: "{", close: "}") }
            else { skipToStatementEnd() }
            return .noop(location)
        }
        if check("let") { return try parseLet() }
        if check("struct") || check("enum") || check("trait") || check("union") {
            return .typeDecl(try parseRustTypeDeclaration())
        }
        if check("fn") { return .funcDecl(try parseRustFunction(ownerTypeName: nil)) }
        if check("loop") {
            advance()
            return .whileStmt(condition: .literal(.bool(true), location),
                              body: try parseBlock(), label: nil, location)
        }
        if check("match") {
            let expression = try parseMatchExpression()
            consumeStatementEnd()
            return .expression(expression, location)
        }
        if check("'"), current.text.hasPrefix("'") {
            // ラベル付きループ `'outer: loop { }`
            let label = String(advance().text.dropFirst())
            try expect(":", "ラベル")
            if check("loop") {
                advance()
                return .whileStmt(condition: .literal(.bool(true), location),
                                  body: try parseBlock(), label: label, location)
            }
            return try parseLabeledStatement(label: label)
        }
        if current.text.hasPrefix("'"), current.text.count > 1, peek(1).is(":") {
            let label = String(advance().text.dropFirst())
            advance()
            if check("loop") {
                advance()
                return .whileStmt(condition: .literal(.bool(true), location),
                                  body: try parseBlock(), label: label, location)
            }
            return try parseLabeledStatement(label: label)
        }
        return try super.parseStatement()
    }

    override func matchOptionalLabel() -> String? {
        guard current.text.hasPrefix("'"), current.text.count > 1 else { return nil }
        return String(advance().text.dropFirst())
    }

    /// `struct Point { x: i32 }` / `struct Wrapper(i32);` / `enum Shape { Circle(f64) }`
    private func parseRustTypeDeclaration() throws -> MLTypeDecl {
        let location = current.location
        let keyword = advance().text
        let name = try expectIdentifier("型名")
        skipGenericParameters()
        if check("where") { while !isAtEnd, !check("{"), !check(";") { advance() } }

        if keyword == "enum" {
            try expect("{", "enum の本体")
            var cases: [MLCaseDecl] = []
            while !isAtEnd, !check("}") {
                skipStatementSeparators()
                skipAttributes()
                if check("}") { break }
                let caseName = try expectIdentifier("列挙のケース")
                var associatedTypes: [String] = []
                var associatedNames: [String] = []
                if check("(") {
                    advance()
                    while !isAtEnd, !check(")") {
                        associatedTypes.append(try parseTypeName())
                        if !match(",") { break }
                    }
                    try expect(")", "列挙のケース")
                } else if check("{") {
                    advance()
                    while !isAtEnd, !check("}") {
                        let field = try expectIdentifier("フィールド名")
                        try expect(":", "フィールドの型")
                        associatedTypes.append(try parseTypeName())
                        associatedNames.append(field)
                        if !match(",") { break }
                    }
                    try expect("}", "列挙のケース")
                }
                var rawValue: MLExpr?
                if match("=") { rawValue = try parseExpression() }
                cases.append(MLCaseDecl(name: caseName, associatedTypes: associatedTypes,
                                        associatedNames: associatedNames, rawValue: rawValue))
                if !match(",") { break }
            }
            skipStatementSeparators()
            try expect("}", "enum の終わり")
            return MLTypeDecl(kind: .enumType, name: name, cases: cases, location: location)
        }

        if keyword == "trait" {
            var methods: [MLFunctionDecl] = []
            try expect("{", "trait の本体")
            while !isAtEnd, !check("}") {
                skipStatementSeparators()
                skipAttributes()
                if check("}") { break }
                while profile.ignorableModifiers.contains(current.text),
                      current.text != "#" { advance() }
                if check("type") {
                    skipToStatementEnd()
                    continue
                }
                guard check("fn") else {
                    advance()
                    continue
                }
                methods.append(try parseRustFunction(ownerTypeName: name))
            }
            try expect("}", "trait の終わり")
            return MLTypeDecl(kind: .interfaceType, name: name, methods: methods,
                              location: location)
        }

        // struct / union
        var properties: [MLPropertyDecl] = []
        if check("(") {
            // タプル構造体。
            advance()
            var index = 0
            while !isAtEnd, !check(")") {
                while profile.ignorableModifiers.contains(current.text),
                      current.text != "#" { advance() }
                let fieldType = try parseTypeName()
                properties.append(MLPropertyDecl(name: String(index), typeName: fieldType))
                index += 1
                if !match(",") { break }
            }
            try expect(")", "タプル構造体")
            consumeStatementEnd()
        } else if check("{") {
            advance()
            while !isAtEnd, !check("}") {
                skipStatementSeparators()
                skipAttributes()
                if check("}") { break }
                while profile.ignorableModifiers.contains(current.text),
                      current.text != "#" { advance() }
                let field = try expectIdentifier("フィールド名")
                try expect(":", "フィールドの型")
                let fieldType = try parseTypeName()
                properties.append(MLPropertyDecl(name: field, typeName: fieldType))
                if !match(",") { break }
            }
            skipStatementSeparators()
            try expect("}", "struct の終わり")
        } else {
            consumeStatementEnd()
        }
        return MLTypeDecl(kind: .structType, name: name, properties: properties,
                          location: location)
    }

    /// `let mut x: i32 = 5;` / `let (a, b) = t;` / `let Some(v) = opt else { }`
    private func parseLet() throws -> MLStmt {
        let location = current.location
        try expect("let")
        let isMutable = match("mut")
        let pattern = try parsePattern()
        var typeName: String?
        if match(":") { typeName = try parseTypeName() }
        var value: MLExpr?
        if match("=") { value = try parseExpression() }
        if check("else") {
            advance()
            _ = try parseBlock()
        }
        consumeStatementEnd()
        return .varDecl(pattern: pattern, typeName: typeName, value: value,
                        isConstant: !isMutable, location)
    }

    private func parseRustFunction(ownerTypeName: String?) throws -> MLFunctionDecl {
        let location = current.location
        try expect("fn", "関数宣言")
        let name = try expectIdentifier("関数名")
        skipGenericParameters()
        try expect("(", "引数の始まり")
        var parameters: [MLParameter] = []
        var takesSelf = false
        while !isAtEnd, !check(")") {
            _ = match("&")
            if current.text.hasPrefix("'") { advance() }
            _ = match("mut")
            if check("self") {
                advance()
                takesSelf = true
                if !match(",") { break }
                continue
            }
            let pattern = try parsePattern()
            var parameterType: String?
            if match(":") { parameterType = try parseTypeName() }
            let parameterName: String
            if case .binding(let bound) = pattern { parameterName = bound }
            else { parameterName = "#arg\(parameters.count)" }
            parameters.append(MLParameter(name: parameterName, typeName: parameterType,
                                          pattern: pattern))
            if !match(",") { break }
        }
        try expect(")", "引数の終わり")
        var returnTypeName: String?
        if match("->") { returnTypeName = try parseTypeName() }
        if check("where") { while !isAtEnd, !check("{"), !check(";") { advance() } }
        var body: [MLStmt] = []
        if check("{") { body = try parseBlock() } else { consumeStatementEnd() }

        // `Foo::new()` は生成関数だが Rust では普通の関連関数なので、
        // コンストラクタ扱いにはせず静的メソッドのままにする。
        return MLFunctionDecl(name: name, parameters: parameters, body: body,
                              returnTypeName: returnTypeName,
                              isStatic: ownerTypeName != nil && !takesSelf,
                              isInitializer: false, location: location)
    }

    override func skipGenericParameters() {
        guard check("<") else { return }
        var depth = 0
        repeat {
            if check("<") { depth += 1 }
            else if check(">") { depth -= 1 }
            else if check(">>") { depth -= 2 }
            advance()
        } while !isAtEnd && depth > 0
    }

    /// Rust の型は `Vec<i32>` `&str` `[i32; 3]` `Option<T>` など。
    override func parseTypeName() throws -> String {
        var text = ""
        while match("&") { }
        if current.text.hasPrefix("'") { advance() }
        _ = match("mut")
        _ = match("dyn")
        if check("[") {
            advance()
            let inner = try parseTypeName()
            if match(";") { _ = try parseExpression() }
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
            try expect(")", "タプルの型")
            if parts.isEmpty { return "Unit" }
            return parts.count == 1 ? parts[0] : "Tuple<\(parts.joined(separator: ","))>"
        }
        if check("impl") { advance() }
        text = try expectIdentifier("型名")
        while check("::"), peek(1).kind == .identifier {
            advance()
            text = advance().text
        }
        if check("<") {
            var depth = 0
            var generic = ""
            repeat {
                if check("<") { depth += 1 }
                else if check(">") { depth -= 1 }
                else if check(">>") { depth -= 2 }
                generic += advance().text
            } while !isAtEnd && depth > 0
            text += generic
        }
        if check("+") {
            // トレイト境界はひとまず無視する。
            while match("+") {
                if current.text.hasPrefix("'") { advance() }
                else { _ = try? parseTypeName() }
            }
        }
        return text
    }

    /// Rust の `match` は式。
    private func parseMatchExpression() throws -> MLExpr {
        let location = current.location
        try expect("match")
        let subject = try parseExpression(stopAtBrace: true)
        try expect("{", "match の本体")
        var arms: [MLMatchArm] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            var patterns: [MLPattern] = [try parseRustPattern()]
            while match("|") { patterns.append(try parseRustPattern()) }
            var guardCondition: MLExpr?
            if match("if") { guardCondition = try parseExpression(stopAtBrace: true) }
            try expect("=>", "match の分岐")
            var body: [MLStmt] = []
            if check("{") {
                body = try parseBlock()
            } else {
                let value = try parseExpression()
                body = [.expression(value, value.location)]
            }
            _ = match(",")
            let isDefault = patterns.count == 1 && isWildcard(patterns[0])
            arms.append(MLMatchArm(patterns: patterns, guardCondition: guardCondition,
                                   body: body, isDefault: isDefault))
        }
        try expect("}", "match の終わり")
        return .match(subject: subject, arms: arms, location)
    }

    private func isWildcard(_ pattern: MLPattern) -> Bool {
        if case .wildcard = pattern { return true }
        return false
    }

    private func parseRustPattern() throws -> MLPattern {
        if match("_") { return .wildcard }
        if match("&") { return try parseRustPattern() }
        _ = match("ref")
        let isMutable = match("mut")
        _ = isMutable

        if check("(") {
            advance()
            var items: [MLPattern] = []
            while !isAtEnd, !check(")") {
                items.append(try parseRustPattern())
                if !match(",") { break }
            }
            try expect(")", "タプルのパターン")
            return items.count == 1 ? items[0] : .tuple(items)
        }
        if check("[") {
            advance()
            var items: [MLPattern] = []
            var restIndex: Int?
            var restName: String?
            while !isAtEnd, !check("]") {
                if check("..") {
                    advance()
                    restIndex = items.count
                } else {
                    let item = try parseRustPattern()
                    if case .named(let name, let inner) = item, isRest(inner) {
                        restIndex = items.count
                        restName = name
                    } else {
                        items.append(item)
                    }
                }
                if !match(",") { break }
            }
            try expect("]", "スライスのパターン")
            return .list(items, restIndex: restIndex, restName: restName)
        }

        // 数値・文字列リテラルと範囲。
        if current.kind == .integerLiteral || current.kind == .floatLiteral
            || current.kind == .stringLiteral || current.kind == .charLiteral
            || check("-") {
            let lower = try parseExpression(stopAtBrace: true)
            if check("..=") || check("..") {
                let isClosed = current.text == "..="
                advance()
                let upper = try parseExpression(stopAtBrace: true)
                return .range(lower: lower, upper: upper, isClosed: isClosed)
            }
            if case .literal(let value, _) = lower { return .literal(value) }
            return .expression(lower)
        }
        if profile.trueLiterals.contains(current.text) {
            advance()
            return .literal(.bool(true))
        }
        if profile.falseLiterals.contains(current.text) {
            advance()
            return .literal(.bool(false))
        }

        guard current.kind == .identifier else {
            let expression = try parseExpression(stopAtBrace: true)
            return .expression(expression)
        }
        var name = advance().text
        // `Option::Some(x)` / `Color::Red`
        while check("::"), peek(1).kind == .identifier {
            advance()
            name = advance().text
        }
        if check("(") {
            advance()
            var positional: [MLPattern] = []
            while !isAtEnd, !check(")") {
                positional.append(try parseRustPattern())
                if !match(",") { break }
            }
            try expect(")", "パターンの引数")
            return .constructor(name: name, positional: positional, named: [])
        }
        if check("{") {
            advance()
            var named: [(String, MLPattern)] = []
            while !isAtEnd, !check("}") {
                if match("..") { break }
                let field = try expectIdentifier("フィールドのパターン")
                if match(":") {
                    named.append((field, try parseRustPattern()))
                } else {
                    named.append((field, .binding(field)))
                }
                if !match(",") { break }
            }
            try expect("}", "パターンの終わり")
            return .constructor(name: name, positional: [], named: named)
        }
        if match("@") {
            return .named(name, try parseRustPattern())
        }
        // 大文字始まりは列挙のケースとみなす。
        if let first = name.first, first.isUppercase {
            return .constructor(name: name, positional: [], named: [])
        }
        return name == "_" ? .wildcard : .binding(name)
    }

    private func isRest(_ pattern: MLPattern) -> Bool {
        if case .wildcard = pattern { return true }
        return false
    }

    override func parsePattern() throws -> MLPattern {
        try parseRustPattern()
    }

    /// 借用 `&x` と参照外し `*x` は実行時の値を変えないので素通りさせる。
    override func parseUnary(stopAtBrace: Bool) throws -> MLExpr {
        if check("&") || check("&&") {
            advance()
            _ = match("mut")
            return try parseUnary(stopAtBrace: stopAtBrace)
        }
        if check("*") {
            let location = advance().location
            return .dereference(try parseUnary(stopAtBrace: stopAtBrace), location)
        }
        return try super.parseUnary(stopAtBrace: stopAtBrace)
    }

    /// `if`, `match`, ブロックはすべて式。
    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if check("match") { return try parseMatchExpression() }
        if check("if") {
            let statement = try parseIf()
            return statementAsExpression(statement, location: location)
        }
        if check("loop") {
            advance()
            let body = try parseBlock()
            return .block([.whileStmt(condition: .literal(.bool(true), location), body: body,
                                      label: nil, location)], location)
        }
        if check("unsafe") {
            advance()
            return .block(try parseBlock(), location)
        }
        if check("{"), !stopAtBrace {
            return .block(try parseBlock(), location)
        }
        // クロージャ `|x| x + 1` / `move |x, y| { ... }`
        if check("move"), peek(1).is("|") {
            advance()
        }
        if check("|") || check("||") {
            return try parseClosure(location: location)
        }
        if check("&") || check("&&") {
            // 借用は実行時には何もしない。
            advance()
            _ = match("mut")
            return try parseUnary(stopAtBrace: stopAtBrace)
        }
        if check("*") {
            advance()
            return try parseUnary(stopAtBrace: stopAtBrace)
        }
        if check("(") {
            advance()
            if check(")") {
                advance()
                return .literal(.unit, location)
            }
            var items: [MLExpr] = []
            var isTuple = false
            repeat {
                if check(")") { break }
                items.append(try parseExpression())
                if check(",") { isTuple = true }
            } while match(",")
            try expect(")", "括弧の終わり")
            return items.count == 1 && !isTuple ? items[0] : .tupleLiteral(items, location)
        }
        if check("[") {
            advance()
            var items: [MLExpr] = []
            if !check("]") {
                let first = try parseExpression()
                if match(";") {
                    // `[0; 10]`
                    let count = try parseExpression()
                    try expect("]", "配列リテラル")
                    return .call(callee: .name("#repeatArray", location),
                                 arguments: [MLArgument(value: first),
                                             MLArgument(value: count)], location)
                }
                items.append(first)
                while match(",") {
                    if check("]") { break }
                    items.append(try parseExpression())
                }
            }
            try expect("]", "配列リテラル")
            return .listLiteral(items, spreadIndices: [], location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    private func statementAsExpression(_ statement: MLStmt,
                                       location: SourceLocation) -> MLExpr {
        guard case .ifStmt(let condition, let then, let otherwise, _) = statement else {
            return .block([statement], location)
        }
        let thenValue = MLExpr.block(then, location)
        let elseValue = otherwise.map { MLExpr.block($0, location) }
        return .ifExpr(condition: condition, then: thenValue, otherwise: elseValue, location)
    }

    private func parseClosure(location: SourceLocation) throws -> MLExpr {
        var parameters: [MLParameter] = []
        if match("||") {
            // 引数なし。
        } else {
            try expect("|", "クロージャ")
            while !isAtEnd, !check("|") {
                _ = match("mut")
                let pattern = try parseRustPattern()
                var typeName: String?
                if match(":") { typeName = try parseTypeName() }
                let name: String
                if case .binding(let bound) = pattern { name = bound }
                else { name = "#arg\(parameters.count)" }
                parameters.append(MLParameter(name: name, typeName: typeName, pattern: pattern))
                if !match(",") { break }
            }
            try expect("|", "クロージャ")
        }
        if match("->") { _ = try parseTypeName() }
        var body: [MLStmt]
        if check("{") {
            body = try parseBlock()
        } else {
            let value = try parseExpression()
            body = [.expression(value, value.location)]
        }
        return .lambda(MLFunctionDecl(name: "", parameters: parameters, body: body,
                                      location: location), location)
    }

    /// `Vec::new()` / `String::from("x")` / `x.iter().map(...)`  / `v?`
    override func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        var expression = try super.parsePostfix(stopAtBrace: stopAtBrace)
        while true {
            let location = current.location
            // マクロ呼び出し。
            if check("!"), case .name(let macroName, let nameLocation) = expression,
               peek(1).is("(") || peek(1).is("[") || peek(1).is("{") {
                advance()
                let arguments = try parseMacroArguments()
                expression = .call(callee: .name(macroName + "!", nameLocation),
                                   arguments: arguments, nameLocation)
                continue
            }
            if check("::") {
                advance()
                if check("<") {
                    skipGenericParameters()
                    continue
                }
                let name = try expectIdentifier("メンバー名")
                expression = .member(expression, name, isOptional: false, location)
                continue
            }
            if check("?") {
                advance()
                expression = .forceUnwrap(expression, location)
                continue
            }
            // 構造体リテラル `Point { x: 1, y: 2 }`
            if !stopAtBrace, check("{"), case .name(let typeName, _) = expression,
               let first = typeName.first, first.isUppercase, looksLikeStructLiteral() {
                advance()
                var arguments: [MLArgument] = []
                while !isAtEnd, !check("}") {
                    if match("..") {
                        _ = try parseExpression()
                        break
                    }
                    let field = try expectIdentifier("フィールド名")
                    if match(":") {
                        arguments.append(MLArgument(label: field, value: try parseExpression()))
                    } else {
                        arguments.append(MLArgument(label: field,
                                                     value: .name(field, location)))
                    }
                    if !match(",") { break }
                }
                try expect("}", "構造体リテラルの終わり")
                expression = .construct(typeName: typeName, arguments: arguments, location)
                continue
            }
            break
        }
        return expression
    }

    private func looksLikeStructLiteral() -> Bool {
        guard check("{") else { return false }
        if peek(1).is("}") { return true }
        return peek(1).kind == .identifier && (peek(2).is(":") || peek(2).is(",")
                                               || peek(2).is("}"))
    }

    /// `println!("{}", x)` / `vec![1, 2, 3]` のようなマクロ呼び出し。
    private func parseMacroArguments() throws -> [MLArgument] {
        let open = current.text
        let close = open == "(" ? ")" : (open == "[" ? "]" : "}")
        try expect(open, "マクロの引数")
        var arguments: [MLArgument] = []
        while !isAtEnd, !check(close) {
            let value = try parseExpression()
            // `vec![0; 10]` は「値と個数」の形。
            if match(";") {
                let count = try parseExpression()
                try expect(close, "マクロの終わり")
                return [MLArgument(value: value), MLArgument(value: count)]
            }
            arguments.append(MLArgument(value: value))
            if !match(",") { break }
        }
        try expect(close, "マクロの終わり")
        return arguments
    }

    override func precedence(of op: String) -> Int? {
        if op == "..=" { return 10 }
        if op == "as" { return 14 }
        return super.precedence(of: op)
    }

    override var memberAccessOperators: [String] { [".", "?.", "::"] }

    override func makeLexer(for text: String) -> MLProfileLexer {
        RustLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        RustParser(tokens: tokens, diagnostics: diagnostics)
    }
}
