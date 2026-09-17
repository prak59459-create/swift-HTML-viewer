import Foundation

/// 内蔵の Dart 処理系。
public enum MiniDart: MiniLangEngine {
    public static var languageID: String { "dart" }
    public static var displayName: String { "内蔵 Dart 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = DartLexer(source: source, diagnostics: diagnostics).tokenize()
        return try DartParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = DartLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = DartParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: DartSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum DartProfile {
    static let keywords: Set<String> = [
        "abstract", "as", "assert", "async", "await", "break", "case", "catch", "class",
        "const", "continue", "covariant", "default", "deferred", "do", "dynamic", "else",
        "enum", "export", "extends", "extension", "external", "factory", "false",
        "final", "finally", "for", "get", "hide", "if", "implements", "import", "in",
        "interface", "is", "late", "library", "mixin", "new", "null", "on", "operator",
        "part", "required", "rethrow", "return", "set", "show", "static", "super",
        "switch", "sync", "this", "throw", "true", "try", "typedef", "var", "void",
        "while", "with", "yield", "int", "double", "num", "bool", "String", "List", "Map"
    ]

    static let profile = MLLanguageProfile(
        languageID: "dart",
        comments: [.line("//"), .block(open: "/*", close: "*/", nesting: true)],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", interpolationPrefix: "${",
                                                simpleVariablePrefix: "$", isMultiline: true),
                  MLLanguageProfile.StringStyle(quote: "'", interpolationPrefix: "${",
                                                simpleVariablePrefix: "$", isMultiline: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators.filter { $0 != "?:" }
            + ["??", "??=", "?.", "=>", "..", "~/", "~/="],
        functionSyntax: .both,
        functionKeywords: [],
        variableKeywords: ["var": false, "final": true, "const": true],
        typeKeywords: ["class": .classType, "enum": .enumType, "mixin": .interfaceType,
                       "extension": .interfaceType],
        ignorableModifiers: ["static", "final", "const", "abstract", "external", "covariant",
                             "late", "factory", "required", "async", "@"],
        lambdaArrows: ["=>"],
        nullLiterals: ["null"],
        selfKeywords: ["this"])
}

final class DartLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: DartProfile.profile, diagnostics: diagnostics)
    }
}

final class DartParser: MLProfileParser {
    private var insideFunctionBody = false

    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: DartProfile.profile, diagnostics: diagnostics)
    }

    override var enumCasesNeedKeyword: Bool { false }
    override var memberAccessOperators: [String] { [".", "?.", ".."] }
    /// Dart の後置 `!` は「null ではないと断言する」記号。
    override func isForceUnwrapContext() -> Bool { true }
    /// `catch (e)` は変数名だけを受け取る。
    override var catchBindsNameOnly: Bool { true }
    override func entryPointName() -> String? { "main" }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            if check("import") || check("library") || check("part") || check("export")
                || check("typedef") {
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
        while check("@") {
            advance()
            if current.kind == .identifier { advance() }
            if check("(") { skipBalanced(open: "(", close: ")") }
        }
        if check("import") || check("library") || check("part") || check("typedef") {
            skipToStatementEnd()
            return .noop(location)
        }
        if check("rethrow") {
            advance()
            consumeStatementEnd()
            return .throwStmt(.name("#lastError", location), location)
        }
        if looksLikeLocalDeclaration() {
            return try parseLocalDeclaration(consumesEnd: true)
        }
        return try super.parseStatement()
    }

    override func isFunctionDeclarationStart() -> Bool {
        insideFunctionBody ? false : super.isFunctionDeclarationStart()
    }

    override func parseTypeBody(kind: MLTypeDecl.Kind, typeName: String) throws -> TypeBody {
        let saved = insideFunctionBody
        insideFunctionBody = false
        defer { insideFunctionBody = saved }
        return try super.parseTypeBody(kind: kind, typeName: typeName)
    }

    override func parseTypeMethod(isStatic: Bool, isAbstract: Bool,
                                  typeName: String) throws -> MLFunctionDecl {
        let saved = insideFunctionBody
        insideFunctionBody = true
        defer { insideFunctionBody = saved }
        return try super.parseTypeMethod(isStatic: isStatic, isAbstract: isAbstract,
                                         typeName: typeName)
    }

    override func parseFunctionDeclaration() throws -> MLFunctionDecl {
        let saved = insideFunctionBody
        insideFunctionBody = true
        defer { insideFunctionBody = saved }
        let location = current.location
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
        var returnTypeName: String?
        if !peek(1).is("(") { returnTypeName = try parseTypeName() }
        let name = try expectIdentifier("関数名")
        skipGenericParameters()
        let parameters = try parseDartParameters()
        _ = match("async", "sync")
        _ = match("*")
        var body: [MLStmt] = []
        if match("=>") {
            let value = try parseExpression()
            body = [.returnStmt(value, value.location)]
            consumeStatementEnd()
        } else if check("{") {
            body = try parseBlock()
        } else {
            consumeStatementEnd()
        }
        return MLFunctionDecl(name: name, parameters: parameters, body: body,
                              returnTypeName: returnTypeName, isStatic: isStatic,
                              location: location)
    }

    /// Dart の引数は `{名前つき}` と `[省略可]` を持てる。
    private func parseDartParameters() throws -> [MLParameter] {
        try expect("(", "引数の始まり")
        var parameters: [MLParameter] = []
        while !isAtEnd, !check(")") {
            var isNamed = false
            if match("{") { isNamed = true }
            if match("[") { isNamed = false }
            if check(")") { break }
            while profile.ignorableModifiers.contains(current.text), current.text != "@" {
                advance()
            }
            // `this.x` の形 (コンストラクタの引数プロパティ)。
            if check("this"), peek(1).is(".") {
                advance()
                advance()
                let name = try expectIdentifier("引数名")
                var defaultValue: MLExpr?
                if match("=") || match(":") { defaultValue = try parseExpression() }
                parameters.append(MLParameter(label: isNamed ? name : nil, name: name,
                                              typeName: "#field", defaultValue: defaultValue))
                if !match(",") { _ = match("}", "]"); if !match(",") { break } }
                continue
            }
            var typeName: String?
            var name: String
            let saved = index
            if let parsed = try? parseTypeName(), current.kind == .identifier {
                typeName = parsed
                name = advance().text
            } else {
                index = saved
                name = try expectIdentifier("引数名")
            }
            var defaultValue: MLExpr?
            if match("=") || match(":") { defaultValue = try parseExpression() }
            if isNamed, defaultValue == nil { defaultValue = .literal(.unit, current.location) }
            parameters.append(MLParameter(label: isNamed ? name : nil, name: name,
                                          typeName: typeName, defaultValue: defaultValue))
            if match("}") || match("]") {
                if !match(",") { break }
                continue
            }
            if !match(",") { break }
        }
        _ = match("}")
        _ = match("]")
        try expect(")", "引数の終わり")
        return parameters
    }

    override func parseParameterList() throws -> [MLParameter] {
        try parseDartParameters()
    }

    /// `int x = 1;` / `var xs = <int>[];` / `final name = 'a';`
    private func looksLikeLocalDeclaration() -> Bool {
        var offset = 0
        while profile.ignorableModifiers.contains(peek(offset).text) { offset += 1 }
        let start = peek(offset)
        guard start.kind == .identifier || start.kind == .keyword else { return false }
        guard !nonTypeKeywords.contains(start.text) else { return false }
        if start.kind == .identifier, start.text.first?.isUppercase != true,
           !isKnownTypeName(start.text) { return false }
        offset += 1
        var depth = 0
        while true {
            let text = peek(offset).text
            if text == "<" { depth += 1; offset += 1; continue }
            if text == ">", depth > 0 { depth -= 1; offset += 1; continue }
            if depth > 0 { offset += 1; continue }
            if text == "?" { offset += 1; continue }
            break
        }
        guard peek(offset).kind == .identifier else { return false }
        let next = peek(offset + 1).text
        return next == "=" || next == ";" || next == ","
    }

    private func isKnownTypeName(_ text: String) -> Bool {
        ["int", "double", "num", "bool", "String", "List", "Map", "Set", "var", "dynamic",
         "void", "Object", "Iterable", "Function"].contains(text)
    }

    private func parseLocalDeclaration(consumesEnd: Bool) throws -> MLStmt {
        let location = current.location
        var isConstant = false
        while profile.ignorableModifiers.contains(current.text) {
            if current.text == "final" || current.text == "const" { isConstant = true }
            advance()
        }
        let typeName = try parseTypeName()
        var declarations: [MLStmt] = []
        repeat {
            let name = try expectIdentifier("変数名")
            var value: MLExpr?
            if match("=") { value = try parseExpression() }
            declarations.append(.varDecl(pattern: .binding(name), typeName: typeName,
                                          value: value, isConstant: isConstant, location))
        } while match(",")
        if consumesEnd { consumeStatementEnd() }
        return declarations.count == 1 ? declarations[0] : .block(declarations, location)
    }

    override func parseForInitializerDeclaration() throws -> MLStmt? {
        guard looksLikeLocalDeclaration() else { return nil }
        return try parseLocalDeclaration(consumesEnd: false)
    }

    override func parseForPattern() throws -> MLPattern {
        while profile.ignorableModifiers.contains(current.text) { advance() }
        _ = match("var", "final", "const")
        let saved = index
        if current.kind == .identifier || current.kind == .keyword {
            if (try? parseTypeName()) != nil, current.kind == .identifier {
                let name = advance().text
                if check("in") { return name == "_" ? .wildcard : .binding(name) }
            }
            index = saved
        }
        return try super.parseForPattern()
    }

    /// `(a, b) => expr` / `(a) { ... }`
    override func parseLambdaIfPresent(stopAtBrace: Bool) throws -> MLExpr? {
        let location = current.location
        if current.kind == .identifier, peek(1).is("=>") {
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
        guard peek(offset).is("=>") || peek(offset).is("{") else { return nil }
        let parameters = try parseDartParameters()
        if match("=>") {
            let value = try parseExpression()
            return .lambda(MLFunctionDecl(name: "", parameters: parameters,
                                          body: [.returnStmt(value, value.location)],
                                          location: location), location)
        }
        guard check("{") else { return nil }
        return .lambda(MLFunctionDecl(name: "", parameters: parameters,
                                      body: try parseBlock(), location: location), location)
    }

    /// `<int>[1, 2]` / `<String, int>{}` のような型つきリテラル。
    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if check("<") {
            let saved = index
            skipGenericParameters()
            if check("[") { return try parseListOrMapLiteral() }
            if check("{") {
                let value = try parseBraceLiteral()
                if case .mapLiteral(let pairs, _) = value, pairs.isEmpty {
                    return .mapLiteral([], location)
                }
                return value
            }
            index = saved
        }
        if check("{"), !stopAtBrace {
            return try parseBraceLiteral()
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    /// `{}` は空の Map、`{1, 2}` は Set (ここでは配列として扱う)。
    override func parseBraceLiteral() throws -> MLExpr {
        let location = current.location
        let saved = index
        try expect("{", "リテラル")
        if check("}") {
            advance()
            return .mapLiteral([], location)
        }
        // キーと値の組かどうかを先読みする。
        var offset = 0
        var depth = 0
        var isMap = false
        while !peek(offset).isEndOfFile {
            let text = peek(offset).text
            if text == "(" || text == "[" || text == "{" { depth += 1 }
            if text == ")" || text == "]" { depth -= 1 }
            if text == "}" {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0, text == ":" { isMap = true; break }
            if depth == 0, text == "," { break }
            offset += 1
        }
        index = saved
        if isMap { return try super.parseBraceLiteral() }
        // Set リテラル。
        try expect("{", "Set リテラル")
        var items: [MLExpr] = []
        while !isAtEnd, !check("}") {
            items.append(try parseExpression())
            if !match(",") { break }
        }
        try expect("}", "Set リテラルの終わり")
        return .listLiteral(items, spreadIndices: [], location)
    }

    override func precedence(of op: String) -> Int? {
        if op == "??" { return 9 }
        if op == "~/" { return 13 }
        return super.precedence(of: op)
    }

    override func parseTypeMember(into body: inout TypeBody, kind: MLTypeDecl.Kind,
                                  typeName: String) throws {
        // `Foo(this.x, this.y);` のような短いコンストラクタ。
        if current.text == typeName, peek(1).is("(") {
            let location = current.location
            advance()
            let parameters = try parseDartParameters()
            var initializerBody: [MLStmt] = []
            // `: x = 1, super(...)` の初期化リスト。
            var initializerList: [MLStmt] = []
            if match(":") {
                repeat {
                    let expression = try parseExpression()
                    initializerList.append(.expression(expression, expression.location))
                } while match(",")
            }
            if check("{") { initializerBody = try parseBlock() }
            else { consumeStatementEnd() }
            // `this.x` 形式の引数はフィールドに代入する。
            let assignments = parameters.filter { $0.typeName == "#field" }.map { parameter in
                MLStmt.expression(
                    .assign(op: "=",
                            target: .member(.selfRef(location), parameter.name,
                                            isOptional: false, location),
                            value: .name(parameter.name, location), location), location)
            }
            body.initializers.append(MLFunctionDecl(
                name: "init",
                parameters: parameters.map {
                    MLParameter(label: $0.label, name: $0.name, typeName: nil,
                                defaultValue: $0.defaultValue)
                },
                body: assignments + initializerList + initializerBody,
                isInitializer: true, location: location))
            return
        }
        try super.parseTypeMember(into: &body, kind: kind, typeName: typeName)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        DartLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        DartParser(tokens: tokens, diagnostics: diagnostics)
    }
}

// MARK: - 振る舞い

final class DartSemantics: MLSemantics {
    override var languageID: String { "dart" }
    override var displayName: String { "内蔵 Dart 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { true }
    /// Dart の `/` は常に double。
    override var divisionAlwaysProducesDouble: Bool { true }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        guard case .bool(let flag) = value.forced else {
            throw MLError.runtime("bool が必要です (\(typeName(of: value)) が渡されました)")
        }
        return flag
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "Null"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .string, .char: return "String"
        case .array: return "List"
        case .map: return "Map"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        // Dart は整数値の double を `1.0` と書く。
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == value.rounded(), Swift.abs(value) < 1e21 {
            return String(Int64(value)) + ".0"
        }
        return MLNumberFormatting.compactStyle(value)
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            return "[" + array.elements.map { display($0) }.joined(separator: ", ") + "]"
        case .map(let map):
            return "{" + map.pairs.map { "\(display($0.key.asValue)): \(display($0.value))" }
                .joined(separator: ", ") + "}"
        case .object(let object):
            if let caseName = object.caseName { return object.typeName + "." + caseName }
            if let interpreter = toStringInterpreter,
               object.classDeclaration?.findMethod("toString") != nil,
               let result = try? interpreter.callMethod(on: value, name: "toString",
                                                        arguments: [], location: .unknown),
               let text = result.asString {
                return text
            }
            return "Instance of '\(object.typeName)'"
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    private var toStringInterpreter: MLInterpreter?

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue { .unit }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        guard let typeName else { return value }
        if typeName.hasPrefix("double"), case .int(let number) = value.forced {
            return .double(Double(number))
        }
        return value
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        toStringInterpreter = interpreter
        switch op {
        case "+":
            if case .string = lhs.forced { return .string(display(lhs) + display(rhs)) }
            if let left = lhs.asArray, let right = rhs.asArray {
                return .array(MLArray(left.elements + right.elements))
            }
            return nil
        case "~/":
            guard let left = lhs.asDouble, let right = rhs.asDouble, right != 0 else {
                throw MLError.runtime("0 で割ることはできません")
            }
            return .int(Int64((left / right).rounded(.towardZero)))
        case "??":
            return lhs.isUnit ? rhs : lhs
        default:
            return nil
        }
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        toStringInterpreter = interpreter
        DartLibrary.install(into: environment, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        switch name {
        case "length":
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let text = value.asString { return .int(Int64(text.count)) }
            if let map = value.asMap { return .int(Int64(map.count)) }
        case "isEmpty":
            if let array = value.asArray { return .bool(array.elements.isEmpty) }
            if let text = value.asString { return .bool(text.isEmpty) }
            if let map = value.asMap { return .bool(map.isEmpty) }
        case "isNotEmpty":
            if let array = value.asArray { return .bool(!array.elements.isEmpty) }
            if let text = value.asString { return .bool(!text.isEmpty) }
            if let map = value.asMap { return .bool(!map.isEmpty) }
        case "first":
            if let array = value.asArray { return array.elements.first ?? .unit }
        case "last":
            if let array = value.asArray { return array.elements.last ?? .unit }
        case "keys":
            if let map = value.asMap { return .array(MLArray(map.keys.map { $0.asValue })) }
        case "values":
            if let map = value.asMap { return .array(MLArray(map.values)) }
        case "runtimeType":
            return .string(typeName(of: value))
        case "isEven":
            if let number = value.asInt { return .bool(number % 2 == 0) }
        case "isOdd":
            if let number = value.asInt { return .bool(number % 2 != 0) }
        default:
            break
        }
        return nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try DartLibrary.method(on: value, name: name, context: context, semantics: self)
    }
}

enum DartLibrary {
    static func install(into environment: MLEnvironment, semantics: DartSemantics) {
        environment.define("print", .function(.native("print", 0...1) { context in
            context.interpreter.write(
                (context.optionalArgument(0).map { semantics.display($0) } ?? "") + "\n")
            return .unit
        }), isConstant: true)

        let math = MLObject(typeName: "math")
        math.fields[.string("pi")] = .double(Double.pi)
        math.fields[.string("e")] = .double(M_E)
        for (name, implementation) in MLStdlib.mathFunctions {
            math.fields[.string(name)] = .function(.native(name, 1) { context in
                .double(implementation(try context.requireDouble(0, name)))
            })
        }
        math.fields[.string("pow")] = .function(.native("pow", 2) { context in
            .double(Foundation.pow(try context.requireDouble(0, "pow"),
                                   try context.requireDouble(1, "pow")))
        })
        math.fields[.string("max")] = .function(.native("max", 2) { context in
            try MLStdlib.reduceExtreme(context, keepSmaller: false)
        })
        math.fields[.string("min")] = .function(.native("min", 2) { context in
            try MLStdlib.reduceExtreme(context, keepSmaller: true)
        })
        environment.define("math", .object(math), isConstant: true)
        environment.define("Math", .object(math), isConstant: true)

        let intType = MLObject(typeName: "int")
        intType.fields[.string("parse")] = .function(.native("parse", 1) { context in
            let text = try context.requireString(0, "int.parse")
                .trimmingCharacters(in: .whitespaces)
            guard let value = Int64(text) else {
                throw MLError.runtime("int.parse: 数値に変換できません: \(text)")
            }
            return .int(value)
        })
        intType.fields[.string("tryParse")] = .function(.native("tryParse", 1) { context in
            guard let text = context.argument(0).asString,
                  let value = Int64(text.trimmingCharacters(in: .whitespaces)) else {
                return .unit
            }
            return .int(value)
        })
        environment.define("int", .object(intType), isConstant: true)

        let doubleType = MLObject(typeName: "double")
        doubleType.fields[.string("parse")] = .function(.native("parse", 1) { context in
            let text = try context.requireString(0, "double.parse")
                .trimmingCharacters(in: .whitespaces)
            guard let value = Double(text) else {
                throw MLError.runtime("double.parse: 数値に変換できません: \(text)")
            }
            return .double(value)
        })
        doubleType.fields[.string("infinity")] = .double(Double.infinity)
        environment.define("double", .object(doubleType), isConstant: true)

        environment.define("List", .object(makeListStatics()), isConstant: true)
        environment.define("Map", .object(makeMapStatics()), isConstant: true)
        environment.define("Set", .object(makeListStatics()), isConstant: true)
        environment.define("StringBuffer", .function(.native("StringBuffer", 0...1) { context in
            let object = MLObject(typeName: "StringBuffer")
            object.fields[.string("value")] = .string(context.optionalArgument(0)?.asString ?? "")
            return .object(object)
        }), isConstant: true)
        environment.define("Duration", .function(.native("Duration", 0...4) { _ in .unit }),
                           isConstant: true)

        for name in ["Exception", "StateError", "ArgumentError", "RangeError",
                     "FormatException", "UnsupportedError", "UnimplementedError"] {
            environment.define(name, .function(.native(name, 0...2) { context in
                let object = MLObject(typeName: name)
                object.fields[.string("message")] =
                    .string(context.optionalArgument(0).map { semantics.display($0) } ?? "")
                var ancestors: [MLValue] = [.string(name)]
                if name != "Exception" { ancestors.append(.string("Exception")) }
                ancestors.append(.string("Error"))
                object.fields[.string("#types")] = .array(MLArray(ancestors))
                return .object(object)
            }), isConstant: true)
        }
    }

    static func makeListStatics() -> MLObject {
        let object = MLObject(typeName: "List")
        object.fields[.string("filled")] = .function(.native("filled", 2...3) { context in
            let count = Int(try context.requireInt(0, "List.filled"))
            return .array(MLArray(Array(repeating: context.argument(1),
                                        count: Swift.max(0, count))))
        })
        object.fields[.string("from")] = .function(.native("from", 1...2) { context in
            guard let array = context.argument(0).asArray else { return .array(MLArray()) }
            return .array(MLArray(array.elements))
        })
        object.fields[.string("generate")] = .function(.native("generate", 2) { context in
            let count = Int(try context.requireInt(0, "List.generate"))
            let maker = try context.requireFunction(1, "List.generate")
            var elements: [MLValue] = []
            for index in 0..<Swift.max(0, count) {
                elements.append(try context.interpreter.callFunction(
                    maker, arguments: [.int(Int64(index))]))
            }
            return .array(MLArray(elements))
        })
        object.fields[.string("#call")] = .function(.native("List", 0...1) { _ in
            .array(MLArray())
        })
        return object
    }

    static func makeMapStatics() -> MLObject {
        let object = MLObject(typeName: "Map")
        object.fields[.string("from")] = .function(.native("from", 1) { context in
            guard let map = context.argument(0).asMap else { return .map(MLMap()) }
            return .map(map.copy())
        })
        object.fields[.string("#call")] = .function(.native("Map", 0...1) { _ in
            .map(MLMap())
        })
        return object
    }

    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: DartSemantics) throws -> MLValue? {
        if let object = receiver.asObject, object.typeName == "StringBuffer" {
            let current = object.fields[.string("value")]?.asString ?? ""
            switch name {
            case "write":
                object.fields[.string("value")] =
                    .string(current + semantics.display(context.argument(0)))
                return .unit
            case "writeln":
                object.fields[.string("value")] =
                    .string(current + semantics.display(context.argument(0)) + "\n")
                return .unit
            case "toString": return .string(current)
            default: return nil
            }
        }

        switch receiver.forced {
        case .string(let text):
            switch name {
            case "toUpperCase": return .string(text.uppercased())
            case "toLowerCase": return .string(text.lowercased())
            case "substring":
                let characters = Array(text)
                let start = Int(try context.requireInt(0, "substring"))
                let end = context.optionalArgument(1)?.asInt.map { Int($0) } ?? characters.count
                guard start >= 0, end <= characters.count, start <= end else {
                    throw MLError.runtime("substring: 範囲が不正です")
                }
                return .string(String(characters[start..<end]))
            case "toString": return .string(text)
            case "codeUnitAt":
                let characters = Array(text)
                let position = Int(try context.requireInt(0, "codeUnitAt"))
                guard position >= 0, position < characters.count else {
                    throw MLError.runtime("codeUnitAt: 範囲外です")
                }
                return .int(Int64(characters[position].unicodeScalars.first?.value ?? 0))
            default:
                return try MLStdlib.callMethod(on: .string(text), name: name, context: context)
            }
        case .array(let array):
            switch name {
            case "add":
                array.elements.append(context.argument(0))
                return .unit
            case "addAll":
                if let other = context.argument(0).asArray {
                    array.elements.append(contentsOf: other.elements)
                }
                return .unit
            case "removeAt":
                let position = Int(try context.requireInt(0, "removeAt"))
                guard position >= 0, position < array.count else {
                    throw MLError.runtime("removeAt: 範囲外です")
                }
                return array.elements.remove(at: position)
            case "toList", "toSet": return .array(MLArray(array.elements))
            case "sort":
                array.elements = try MLStdlib.stableSorted(
                    array.elements, interpreter: context.interpreter,
                    comparator: context.optionalArgument(0)?.asFunction)
                return .unit
            case "forEach", "map", "where", "reduce", "fold", "any", "every",
                 "contains", "indexOf", "join", "take", "skip", "expand", "toString":
                if name == "where" {
                    return try MLStdlib.callMethod(on: .array(array), name: "filter",
                                                   context: context)
                }
                if name == "expand" {
                    return try MLStdlib.callMethod(on: .array(array), name: "flatMap",
                                                   context: context)
                }
                if name == "toString" {
                    return .string(semantics.display(.array(array)))
                }
                return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
            default:
                return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
            }
        case .map(let map):
            switch name {
            case "putIfAbsent":
                guard let key = MLKey.from(context.argument(0)) else { return .unit }
                if let existing = map[key] { return existing }
                let producer = try context.requireFunction(1, "putIfAbsent")
                let value = try context.interpreter.callFunction(producer, arguments: [])
                map[key] = value
                return value
            case "containsKey":
                guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
                return .bool(map.contains(key))
            case "forEach":
                let body = try context.requireFunction(0, "forEach")
                for (key, value) in map.pairs {
                    _ = try context.interpreter.callFunction(body,
                                                             arguments: [key.asValue, value])
                }
                return .unit
            case "toString": return .string(semantics.display(.map(map)))
            default:
                return try MLStdlib.callMethod(on: .map(map), name: name, context: context)
            }
        case .int, .double:
            switch name {
            case "toStringAsFixed":
                let digits = Int(try context.requireInt(0, "toStringAsFixed"))
                return .string(MLNumberFormatting.fixed(receiver.asDouble ?? 0, digits: digits))
            case "toString": return .string(semantics.display(receiver))
            case "toInt": return .int(Int64(receiver.asDouble ?? 0))
            case "toDouble": return .double(receiver.asDouble ?? 0)
            case "abs":
                if case .int(let number) = receiver.forced {
                    return .int(number < 0 ? -number : number)
                }
                return .double(Swift.abs(receiver.asDouble ?? 0))
            case "round": return .int(Int64((receiver.asDouble ?? 0).rounded()))
            case "floor": return .int(Int64((receiver.asDouble ?? 0).rounded(.down)))
            case "ceil": return .int(Int64((receiver.asDouble ?? 0).rounded(.up)))
            default:
                return try MLStdlib.callMethod(on: receiver, name: name, context: context)
            }
        default:
            return nil
        }
    }
}
