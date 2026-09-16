import Foundation

/// Java の見た目。
enum JavaProfile {
    static let keywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
        "class", "const", "continue", "default", "do", "double", "else", "enum",
        "extends", "final", "finally", "float", "for", "goto", "if", "implements",
        "import", "instanceof", "int", "interface", "long", "native", "new", "package",
        "private", "protected", "public", "return", "short", "static", "strictfp",
        "super", "switch", "synchronized", "this", "throw", "throws", "transient",
        "try", "void", "volatile", "while", "true", "false", "null", "var", "record"
    ]

    static let profile = MLLanguageProfile(
        languageID: "java",
        comments: [.line("//"), .block(open: "/*", close: "*/", nesting: false)],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", isMultiline: true),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators,
        newlineTerminatesStatement: false,
        usesSemicolons: true,
        functionSyntax: .typeFirst,
        functionKeywords: [],
        variableKeywords: ["var": false],
        typeKeywords: ["class": .classType, "interface": .interfaceType,
                       "enum": .enumType, "record": .structType],
        ignorableModifiers: ["public", "private", "protected", "static", "final",
                             "abstract", "synchronized", "native", "transient",
                             "volatile", "strictfp", "default", "@"],
        lambdaArrows: ["->"],
        nullLiterals: ["null"],
        selfKeywords: ["this"])
}

final class JavaLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: JavaProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        // `123L` / `1.5f` のような接尾辞を数値の一部として食べる。
        if let character = peek(), character.isNumber {
            var token = readNumber(allowsUnderscoreSeparator: true)
            if let suffix = peek(), "lLfFdD".contains(suffix) {
                advance()
                if "fFdD".contains(suffix), token.kind == .integerLiteral {
                    token = MLToken(kind: .floatLiteral, text: token.text,
                                    location: token.location,
                                    doubleValue: Double(token.intValue ?? 0))
                }
            }
            return token
        }
        return super.nextToken()
    }
}

final class JavaParser: MLProfileParser {
    /// `Main` クラスの `main` を開始点にする。
    private var mainClassName: String?

    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: JavaProfile.profile, diagnostics: diagnostics)
    }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        // `public static void main(String[] args)` を持つクラスを探す。
        var entryType: String?
        for statement in statements {
            guard case .typeDecl(let decl) = statement else { continue }
            if decl.methods.contains(where: { $0.isStatic && $0.name == "main" }) {
                entryType = decl.name
                break
            }
        }
        return MLProgram(statements: statements,
                         entryPoint: entryType == nil ? nil : "main",
                         entryTypeName: entryType)
    }

    override func entryPointName() -> String? { mainClassName == nil ? nil : "main" }

    /// Java のラムダ `(a, b) -> expr` / `x -> expr` / `Type::method`。
    override func parseLambdaIfPresent(stopAtBrace: Bool) throws -> MLExpr? {
        let location = current.location
        // `x -> ...`
        if current.kind == .identifier, peek(1).is("->") {
            let name = advance().text
            advance()
            return .lambda(try parseLambdaBody(parameters: [MLParameter(name: name)],
                                               location: location), location)
        }
        // `(a, b) -> ...` / `() -> ...`
        if check("(") {
            let saved = index
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
            while !check(")") {
                // 型注釈つきでも書ける。
                var name = try expectIdentifier("ラムダの引数")
                if current.kind == .identifier { name = advance().text }
                parameters.append(MLParameter(name: name))
                if !match(",") { break }
            }
            guard match(")"), match("->") else {
                index = saved
                return nil
            }
            return .lambda(try parseLambdaBody(parameters: parameters, location: location),
                           location)
        }
        return nil
    }

    private func parseLambdaBody(parameters: [MLParameter],
                                 location: SourceLocation) throws -> MLFunctionDecl {
        if check("{") {
            let body = try parseBlock()
            return MLFunctionDecl(name: "", parameters: parameters, body: body,
                                  location: location)
        }
        let value = try parseExpression()
        return MLFunctionDecl(name: "", parameters: parameters,
                              body: [.returnStmt(value, value.location)], location: location)
    }

    /// `int[] a = {1, 2, 3};` のような初期化にも対応する。
    override func parseVariableDeclaration(keyword: String, location: SourceLocation,
                                           consumesEnd: Bool = true) throws -> MLStmt {
        try super.parseVariableDeclaration(keyword: keyword, location: location,
                                           consumesEnd: consumesEnd)
    }

    /// Java の文は「型 名前 = 値;」の形も取る。
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

        // アノテーションは読み飛ばす。
        while check("@") {
            advance()
            if current.kind == .identifier { advance() }
            if check("(") { skipBalanced(open: "(", close: ")") }
        }

        if looksLikeLocalVariable() {
            return try parseLocalVariable(location: location)
        }
        return try super.parseStatement()
    }

    /// `int x = 1;` `String[] a;` `List<Integer> xs = ...` を見分ける。
    private func looksLikeLocalVariable() -> Bool {
        var offset = 0
        while profile.ignorableModifiers.contains(peek(offset).text) { offset += 1 }
        let start = peek(offset)
        guard start.kind == .identifier || isPrimitiveTypeName(start.text) else { return false }
        // 型名が大文字始まりか基本型でないと、ただの式である可能性が高い。
        if !isPrimitiveTypeName(start.text), start.text.first?.isUppercase != true,
           start.text != "var" {
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
            if text == "[", peek(offset + 1).is("]") { offset += 2; continue }
            if text == ".", peek(offset + 1).kind == .identifier { offset += 2; continue }
            break
        }
        guard peek(offset).kind == .identifier else { return false }
        let next = peek(offset + 1).text
        return next == "=" || next == ";" || next == "," || peek(offset + 1).is("[")
    }

    private func isPrimitiveTypeName(_ text: String) -> Bool {
        ["int", "long", "short", "byte", "char", "boolean", "float", "double", "void", "var"]
            .contains(text)
    }

    /// Java にメソッドの入れ子は無いので、本体の中では宣言として読まない。
    private var insideMethodBody = false

    override func isFunctionDeclarationStart() -> Bool {
        insideMethodBody ? false : super.isFunctionDeclarationStart()
    }

    override func parseTypeMethod(isStatic: Bool, isAbstract: Bool,
                                  typeName: String) throws -> MLFunctionDecl {
        let saved = insideMethodBody
        insideMethodBody = true
        defer { insideMethodBody = saved }
        return try super.parseTypeMethod(isStatic: isStatic, isAbstract: isAbstract,
                                         typeName: typeName)
    }

    override var enumCasesNeedKeyword: Bool { false }

    override func parseTypeBody(kind: MLTypeDecl.Kind, typeName: String) throws -> TypeBody {
        let saved = insideMethodBody
        insideMethodBody = false
        defer { insideMethodBody = saved }
        return try super.parseTypeBody(kind: kind, typeName: typeName)
    }

    override func parseForInitializerDeclaration() throws -> MLStmt? {
        guard looksLikeLocalVariable() else { return nil }
        return try parseLocalVariable(location: current.location, consumesEnd: false)
    }

    private func parseLocalVariable(location: SourceLocation,
                                    consumesEnd: Bool = true) throws -> MLStmt {
        while profile.ignorableModifiers.contains(current.text) { advance() }
        let typeName = try parseTypeName()
        var declarations: [MLStmt] = []
        repeat {
            let name = try expectIdentifier("変数名")
            var fullType = typeName
            while check("["), peek(1).is("]") {
                advance(); advance()
                fullType = "Array<\(fullType)>"
            }
            var value: MLExpr?
            if match("=") {
                value = check("{") ? .listLiteral(try parseArrayInitializer(),
                                                  spreadIndices: [], location)
                                   : try parseExpression()
            }
            declarations.append(.varDecl(pattern: .binding(name), typeName: fullType,
                                          value: value, isConstant: false, location))
        } while match(",")
        if consumesEnd { consumeStatementEnd() }
        return declarations.count == 1 ? declarations[0] : .block(declarations, location)
    }

    /// `for (String s : list)` を読む。
    override func parseForPattern() throws -> MLPattern {
        while profile.ignorableModifiers.contains(current.text) { advance() }
        let saved = index
        // 型が先に来る形を試す。
        if current.kind == .identifier || isPrimitiveTypeName(current.text) {
            if (try? parseTypeName()) != nil, current.kind == .identifier {
                let name = advance().text
                if check(":") { return name == "_" ? .wildcard : .binding(name) }
            }
            index = saved
        }
        return try super.parseForPattern()
    }

    override var memberAccessOperators: [String] { [".", "?.", "::"] }

    override func makeLexer(for text: String) -> MLProfileLexer {
        JavaLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        JavaParser(tokens: tokens, diagnostics: diagnostics)
    }
}
