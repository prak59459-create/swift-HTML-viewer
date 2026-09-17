import Foundation

/// 内蔵の C++ 処理系。
///
/// テンプレートや参照は「動くのに必要な範囲」で扱い、
/// STL の主要なコンテナ・アルゴリズム・iostream を Swift 側で用意している。
public enum MiniCpp: MiniLangEngine {
    public static var languageID: String { "cpp" }
    public static var displayName: String { "内蔵 C++ 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = CppLexer(source: source, diagnostics: diagnostics).tokenize()
        return try CppParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
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
        let tokens = CppLexer(source: source, diagnostics: diagnostics).tokenize()
        let parser = CppParser(tokens: tokens, diagnostics: diagnostics)
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
        let semantics = CppSemantics()
        let interpreter = MLInterpreter(semantics: semantics, limits: limits, input: input)
        let result = interpreter.run(program)
        return result
    }
}

// MARK: - 見た目

enum CppProfile {
    static let keywords: Set<String> = [
        "alignas", "alignof", "and", "asm", "auto", "bool", "break", "case", "catch",
        "char", "class", "const", "constexpr", "continue", "decltype", "default",
        "delete", "do", "double", "else", "enum", "explicit", "export", "extern",
        "false", "float", "for", "friend", "goto", "if", "inline", "int", "long",
        "mutable", "namespace", "new", "noexcept", "not", "nullptr", "operator", "or",
        "private", "protected", "public", "register", "return", "short", "signed",
        "sizeof", "static", "struct", "switch", "template", "this", "throw", "true",
        "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void",
        "volatile", "while", "size_t", "string", "vector", "map", "set", "pair"
    ]

    static let profile = MLLanguageProfile(
        languageID: "cpp",
        comments: [.line("//"), .block(open: "/*", close: "*/", nesting: false)],
        strings: [MLLanguageProfile.StringStyle(quote: "\""),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators + ["<<", ">>", "->*", ".*", "::"],
        functionSyntax: .typeFirst,
        functionKeywords: [],
        variableKeywords: [:],
        typeKeywords: ["class": .classType, "struct": .classType, "enum": .enumType,
                       "union": .structType],
        ignorableModifiers: ["public", "private", "protected", "static", "const",
                             "constexpr", "inline", "virtual", "explicit", "friend",
                             "mutable", "extern", "register", "volatile", "noexcept",
                             "unsigned", "signed"],
        nullLiterals: ["nullptr", "NULL"],
        selfKeywords: ["this"])
}

final class CppLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: CppProfile.profile, diagnostics: diagnostics)
    }

    override func skipIgnorable() -> Bool {
        var sawNewline = super.skipIgnorable()
        // プリプロセッサ行は丸ごと読み飛ばす (`#include` など)。
        while column == 1, peek() == "#" {
            skipLineComment()
            sawNewline = true
            sawNewline = super.skipIgnorable() || sawNewline
        }
        return sawNewline
    }

    override func nextToken() -> MLToken? {
        if let character = peek(), character.isNumber {
            let token = readNumber(allowsUnderscoreSeparator: true)
            while let suffix = peek(), "uUlLfF".contains(suffix) { advance() }
            return token
        }
        return super.nextToken()
    }
}

final class CppParser: MLProfileParser {
    private var insideFunctionBody = false

    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: CppProfile.profile, diagnostics: diagnostics)
    }

    override func entryPointName() -> String? { "main" }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            if check("using") || check("typedef") {
                skipToStatementEnd()
                continue
            }
            if check("namespace") {
                advance()
                if current.kind == .identifier { advance() }
                if check("{") {
                    statements.append(contentsOf: try parseBlock())
                } else {
                    skipToStatementEnd()
                }
                continue
            }
            if check("template") {
                advance()
                skipGenericParameters()
                continue
            }
            if check("extern"), peek(1).kind == .stringLiteral {
                advance()
                advance()
                if check("{") {
                    statements.append(contentsOf: try parseBlock())
                    continue
                }
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

    override var nonTypeKeywords: Set<String> {
        super.nonTypeKeywords.union(["delete", "operator", "template", "typedef",
                                      "typename", "decltype", "cout", "cin", "endl"])
    }

    override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location

        if check("using") || check("typedef") {
            skipToStatementEnd()
            return .noop(location)
        }
        if check("template") {
            advance()
            skipGenericParameters()
            return try parseStatement()
        }
        if check("namespace") {
            advance()
            if current.kind == .identifier { advance() }
            if check("{") { return .block(try parseBlock(), location) }
            skipToStatementEnd()
            return .noop(location)
        }
        if current.kind == .identifier, peek(1).is(":"), isLoopKeyword(peek(2).text) {
            let label = advance().text
            advance()
            return try parseLabeledStatement(label: label)
        }
        if looksLikeDeclaration() {
            return try parseDeclaration(consumesEnd: true)
        }
        return try super.parseStatement()
    }

    override func isFunctionDeclarationStart() -> Bool {
        insideFunctionBody ? false : super.isFunctionDeclarationStart()
    }

    override var trailingFunctionQualifiers: Set<String> {
        ["const", "noexcept", "override", "final", "volatile", "&", "&&"]
    }

    override func parseFunctionDeclaration() throws -> MLFunctionDecl {
        let saved = insideFunctionBody
        insideFunctionBody = true
        defer { insideFunctionBody = saved }
        return try super.parseFunctionDeclaration()
    }

    override func parseTypeMethod(isStatic: Bool, isAbstract: Bool,
                                  typeName: String) throws -> MLFunctionDecl {
        let saved = insideFunctionBody
        insideFunctionBody = true
        defer { insideFunctionBody = saved }
        return try super.parseTypeMethod(isStatic: isStatic, isAbstract: isAbstract,
                                         typeName: typeName)
    }

    override func parseTypeBody(kind: MLTypeDecl.Kind, typeName: String) throws -> TypeBody {
        let saved = insideFunctionBody
        insideFunctionBody = false
        defer { insideFunctionBody = saved }
        var body = try super.parseTypeBody(kind: kind, typeName: typeName)
        consumeStatementEnd()
        // `public:` のようなアクセス指定子だけの文は取り除く。
        body.statements = body.statements.filter { statement in
            if case .noop = statement { return false }
            return true
        }
        return body
    }

    override func parseTypeMember(into body: inout TypeBody, kind: MLTypeDecl.Kind,
                                  typeName: String) throws {
        // `public:` / `private:` / `protected:`
        if ["public", "private", "protected"].contains(current.text), peek(1).is(":") {
            advance()
            advance()
            return
        }
        if check("template") {
            advance()
            skipGenericParameters()
            return
        }
        // デストラクタ。
        if check("~") {
            advance()
            _ = try? expectIdentifier("デストラクタ")
            if check("(") { skipBalanced(open: "(", close: ")") }
            if check("{") { _ = try parseBlock() } else { skipToStatementEnd() }
            return
        }
        try super.parseTypeMember(into: &body, kind: kind, typeName: typeName)
    }

    /// `int x = 1;` `vector<int> v;` `const string& s = t;` を見分ける。
    private func looksLikeDeclaration() -> Bool {
        var offset = 0
        while profile.ignorableModifiers.contains(peek(offset).text) { offset += 1 }
        let start = peek(offset)
        guard start.kind == .identifier || start.kind == .keyword else { return false }
        guard !nonTypeKeywords.contains(start.text) else { return false }
        // 型として通りそうな語かどうか。
        if start.kind == .identifier, start.text.first?.isUppercase != true,
           !isKnownTypeName(start.text) {
            return false
        }
        offset += 1
        var depth = 0
        while true {
            let text = peek(offset).text
            if text == "<" { depth += 1; offset += 1; continue }
            if text == ">", depth > 0 { depth -= 1; offset += 1; continue }
            if text == ">>", depth > 0 { depth -= 2; offset += 1; continue }
            if depth > 0 { offset += 1; continue }
            if text == "::", peek(offset + 1).kind == .identifier { offset += 2; continue }
            if text == "*" || text == "&" || text == "&&" { offset += 1; continue }
            break
        }
        guard peek(offset).kind == .identifier else { return false }
        let next = peek(offset + 1).text
        if next == "=" || next == ";" || next == "," || next == "[" { return true }
        // `vector<int> v(10, 0);` は宣言だが `int f(int n) { }` は関数定義。
        // 対応する閉じ括弧の次が `;` かどうかで見分ける。
        if next == "(" || next == "{" {
            let open = next
            let close = next == "(" ? ")" : "}"
            var depth = 0
            var scan = offset + 1
            repeat {
                let text = peek(scan).text
                if text == open { depth += 1 }
                else if text == close { depth -= 1 }
                scan += 1
            } while depth > 0 && !peek(scan).isEndOfFile
            return peek(scan).is(";") || peek(scan).is(",")
        }
        return false
    }

    private func isKnownTypeName(_ text: String) -> Bool {
        ["int", "long", "short", "char", "bool", "float", "double", "void", "auto",
         "size_t", "string", "vector", "map", "set", "pair", "unsigned", "signed",
         "wstring", "int64_t", "int32_t", "uint64_t", "uint32_t", "deque", "list",
         "queue", "stack", "array", "unordered_map", "unordered_set", "ostream",
         "istream", "stringstream", "ostringstream"].contains(text)
    }

    private func parseDeclaration(consumesEnd: Bool) throws -> MLStmt {
        let location = current.location
        while profile.ignorableModifiers.contains(current.text) { advance() }
        let typeName = try parseCppTypeName()
        var declarations: [MLStmt] = []
        repeat {
            while match("*", "&", "&&") {}
            let name = try expectIdentifier("変数名")
            var fullType = typeName
            var arraySize: MLExpr?
            while check("[") {
                advance()
                if !check("]") { arraySize = try parseExpression() }
                try expect("]", "配列の宣言")
                fullType = "Array<\(fullType)>"
            }
            var value: MLExpr?
            if match("=") {
                value = check("{") ? .listLiteral(try parseArrayInitializer(),
                                                  spreadIndices: [], location)
                                   : try parseExpression()
            } else if check("{") {
                value = .listLiteral(try parseArrayInitializer(), spreadIndices: [], location)
            } else if check("(") {
                // `vector<int> v(10, 0);` のようなコンストラクタ呼び出し。
                let arguments = try parseArgumentList()
                value = .construct(typeName: typeName, arguments: arguments, location)
            } else if let arraySize {
                value = .call(callee: .name("#newArray", location),
                              arguments: [MLArgument(value: arraySize),
                                          MLArgument(value: .literal(.string(typeName),
                                                                     location))],
                              location)
            }
            declarations.append(.varDecl(pattern: .binding(name), typeName: fullType,
                                          value: value, isConstant: false, location))
        } while match(",")
        if consumesEnd { consumeStatementEnd() }
        return declarations.count == 1 ? declarations[0] : .block(declarations, location)
    }

    override func parseForInitializerDeclaration() throws -> MLStmt? {
        guard looksLikeDeclaration() else { return nil }
        return try parseDeclaration(consumesEnd: false)
    }

    /// `for (auto x : xs)`
    override func parseForPattern() throws -> MLPattern {
        while profile.ignorableModifiers.contains(current.text) { advance() }
        let saved = index
        if current.kind == .identifier || current.kind == .keyword {
            if (try? parseCppTypeName()) != nil {
                while match("*", "&", "&&") {}
                if current.kind == .identifier {
                    let name = advance().text
                    if check(":") { return name == "_" ? .wildcard : .binding(name) }
                }
            }
            index = saved
        }
        return try super.parseForPattern()
    }

    private func parseCppTypeName() throws -> String {
        var text = ""
        while profile.ignorableModifiers.contains(current.text) { advance() }
        guard current.kind == .identifier || current.kind == .keyword else {
            throw report("型名が必要です")
        }
        text = advance().text
        // `long long` / `unsigned int`
        while ["long", "int", "short", "char", "double"].contains(current.text),
              ["long", "short", "unsigned", "signed", "int"].contains(text) {
            text += " " + advance().text
        }
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
        return text
    }

    override func parseTypeName() throws -> String {
        try parseCppTypeName()
    }

    /// C++ のラムダ `[](int x) { return x; }` / `[&](auto x) { ... }`
    override func parseLambdaIfPresent(stopAtBrace: Bool) throws -> MLExpr? {
        guard check("[") else { return nil }
        // `[` のあとが捕捉リストで、対応する `]` の次が `(` か `{` ならラムダ。
        var offset = 1
        var depth = 1
        while depth > 0, !peek(offset).isEndOfFile {
            if peek(offset).is("[") { depth += 1 }
            if peek(offset).is("]") { depth -= 1 }
            offset += 1
        }
        guard peek(offset).is("(") || peek(offset).is("{") else { return nil }
        let location = current.location
        skipBalanced(open: "[", close: "]")
        var parameters: [MLParameter] = []
        if check("(") {
            try expect("(", "ラムダの引数")
            while !isAtEnd, !check(")") {
                while profile.ignorableModifiers.contains(current.text) { advance() }
                _ = try? parseCppTypeName()
                while match("*", "&", "&&") {}
                let name = current.kind == .identifier ? advance().text
                                                       : "#arg\(parameters.count)"
                parameters.append(MLParameter(name: name))
                if !match(",") { break }
            }
            try expect(")", "ラムダの引数")
        }
        if check("mutable") { advance() }
        if match("->") { _ = try? parseCppTypeName() }
        let body = try parseBlock()
        return .lambda(MLFunctionDecl(name: "", parameters: parameters, body: body,
                                      location: location), location)
    }

    /// `std::cout << x << std::endl;` を出力として解釈する。
    override func parseBinary(minimumPrecedence: Int, stopAtBrace: Bool) throws -> MLExpr {
        let left = try super.parseBinary(minimumPrecedence: minimumPrecedence,
                                         stopAtBrace: stopAtBrace)
        return left
    }

    override func precedence(of op: String) -> Int? {
        super.precedence(of: op)
    }

    override func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        var expression = try super.parsePostfix(stopAtBrace: stopAtBrace)
        while check("::") {
            let location = advance().location
            let name = try expectIdentifier("メンバー名")
            expression = .member(expression, name, isOptional: false, location)
        }
        return expression
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        // `{1, 2, 3}` の初期化リスト。
        if check("{"), !stopAtBrace {
            return .listLiteral(try parseArrayInitializer(), spreadIndices: [], location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    override var memberAccessOperators: [String] { [".", "?.", "->", "::"] }

    override func makeLexer(for text: String) -> MLProfileLexer {
        CppLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        CppParser(tokens: tokens, diagnostics: diagnostics)
    }
}
