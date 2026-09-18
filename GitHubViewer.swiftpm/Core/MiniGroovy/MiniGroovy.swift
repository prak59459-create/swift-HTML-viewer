import Foundation

/// 内蔵の Groovy 処理系。
///
/// Java によく似た文法に、動的型・クロージャ・GString を足した言語。
public enum MiniGroovy: MiniLangEngine {
    public static var languageID: String { "groovy" }
    public static var displayName: String { "内蔵 Groovy 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = GroovyLexer(source: source, diagnostics: diagnostics).tokenize()
        return try GroovyParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = GroovyLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = GroovyParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: GroovySemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum GroovyProfile {
    static let keywords: Set<String> = [
        "abstract", "as", "assert", "boolean", "break", "byte", "case", "catch", "char",
        "class", "const", "continue", "def", "default", "do", "double", "else", "enum",
        "extends", "false", "final", "finally", "float", "for", "goto", "if",
        "implements", "import", "in", "instanceof", "int", "interface", "long", "native",
        "new", "null", "package", "private", "protected", "public", "return", "short",
        "static", "strictfp", "super", "switch", "synchronized", "this", "throw",
        "throws", "trait", "transient", "true", "try", "void", "volatile", "while",
        "var", "it"
    ]

    static let profile = MLLanguageProfile(
        languageID: "groovy",
        comments: [.line("//"), .block(open: "/*", close: "*/", nesting: false)],
        strings: [
            // `"..."` は補間できる GString、`'...'` はただの文字列。
            MLLanguageProfile.StringStyle(quote: "\"", interpolationPrefix: "${",
                                          simpleVariablePrefix: "$", isMultiline: true),
            MLLanguageProfile.StringStyle(quote: "'", isMultiline: true)
        ],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators + ["<=>", "?:", "?.", "==~", "*.",
                                                        "..<", "**"],
        newlineTerminatesStatement: true,
        functionSyntax: .both,
        functionKeywords: ["def"],
        variableKeywords: ["def": false, "var": false],
        typeKeywords: ["class": .classType, "interface": .interfaceType,
                       "enum": .enumType, "trait": .interfaceType],
        ignorableModifiers: ["public", "private", "protected", "static", "final",
                             "abstract", "synchronized", "native", "transient",
                             "volatile", "strictfp", "@"],
        nullLiterals: ["null"],
        selfKeywords: ["this"])
}

final class GroovyLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: GroovyProfile.profile, diagnostics: diagnostics)
    }
}

final class GroovyParser: MLProfileParser {
    private var insideMethodBody = false

    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: GroovyProfile.profile, diagnostics: diagnostics)
    }

    override var enumCasesNeedKeyword: Bool { false }
    override var memberAccessOperators: [String] { [".", "?.", "*."] }
    override var catchBindsNameOnly: Bool { false }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            if check("package") || check("import") {
                skipToStatementEnd()
                continue
            }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        return MLProgram(statements: statements)
    }

    override func isFunctionDeclarationStart() -> Bool {
        if insideMethodBody { return false }
        if check("def"), peek(1).kind == .identifier, peek(2).is("(") { return true }
        return super.isFunctionDeclarationStart()
    }

    override func parseTypeBody(kind: MLTypeDecl.Kind, typeName: String) throws -> TypeBody {
        let saved = insideMethodBody
        insideMethodBody = false
        defer { insideMethodBody = saved }
        return try super.parseTypeBody(kind: kind, typeName: typeName)
    }

    override func parseTypeMethod(isStatic: Bool, isAbstract: Bool,
                                  typeName: String) throws -> MLFunctionDecl {
        let saved = insideMethodBody
        insideMethodBody = true
        defer { insideMethodBody = saved }
        return try super.parseTypeMethod(isStatic: isStatic, isAbstract: isAbstract,
                                         typeName: typeName)
    }

    override func parseFunctionDeclaration() throws -> MLFunctionDecl {
        let saved = insideMethodBody
        insideMethodBody = true
        defer { insideMethodBody = saved }
        return try super.parseFunctionDeclaration()
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
        if check("package") || check("import") {
            skipToStatementEnd()
            return .noop(location)
        }
        // `println "x"` のように括弧を省いた呼び出し。
        if let command = try parseCommandCall() { return command }
        if check("assert") {
            advance()
            let condition = try parseExpression()
            if match(":") { _ = try parseExpression() }
            consumeStatementEnd()
            return .expression(.call(callee: .name("assert", location),
                                     arguments: [MLArgument(value: condition)], location),
                               location)
        }
        // `int x = 1` のように型が先に来る宣言。
        if looksLikeTypedDeclaration() {
            return try parseTypedDeclaration(consumesEnd: true)
        }
        return try super.parseStatement()
    }

    /// `def` は変数宣言にも関数宣言にも使うので、関数のときは変数として扱わない。
    override func matchedVariableKeyword() -> String? {
        if check("def"), peek(1).kind == .identifier, peek(2).is("(") { return nil }
        return super.matchedVariableKeyword()
    }

    /// 括弧を省いた呼び出し (`println "x"` / `print a, b`)。
    private func parseCommandCall() throws -> MLStmt? {
        guard current.kind == .identifier else { return nil }
        let next = peek(1)
        guard !next.precededByNewline else { return nil }
        // 引数が始まりそうな形かどうか。
        let startsArgument: Bool
        switch next.kind {
        case .stringLiteral, .interpolatedString, .integerLiteral, .floatLiteral,
             .charLiteral:
            startsArgument = true
        case .identifier:
            // `a b` は命令呼び出し、`int x` は宣言なので型名は除く。
            startsArgument = !isKnownTypeName(current.text)
                && !nonTypeKeywords.contains(current.text)
        case .keyword:
            startsArgument = ["true", "false", "null", "new", "this"].contains(next.text)
        default:
            // `m["k"]` は添字なので命令呼び出しとはみなさない。
            startsArgument = false
        }
        guard startsArgument else { return nil }

        let location = current.location
        let saved = index
        let name = advance().text
        do {
            var arguments: [MLArgument] = []
            repeat {
                arguments.append(MLArgument(value: try parseExpression()))
            } while match(",")
            consumeStatementEnd()
            return .expression(.call(callee: .name(name, location), arguments: arguments,
                                     location), location)
        } catch {
            index = saved
            return nil
        }
    }

    private func looksLikeTypedDeclaration() -> Bool {
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
            if text == "[", peek(offset + 1).is("]") { offset += 2; continue }
            break
        }
        guard peek(offset).kind == .identifier else { return false }
        if peek(offset + 1).precededByNewline { return true }
        let next = peek(offset + 1).text
        return next == "=" || next == ";" || next == ","
    }

    private func isKnownTypeName(_ text: String) -> Bool {
        ["int", "long", "short", "byte", "char", "boolean", "float", "double", "void",
         "String", "List", "Map", "Set", "Object", "BigDecimal", "BigInteger"]
            .contains(text)
    }

    private func parseTypedDeclaration(consumesEnd: Bool) throws -> MLStmt {
        let location = current.location
        while profile.ignorableModifiers.contains(current.text) { advance() }
        let typeName = try parseTypeName()
        var declarations: [MLStmt] = []
        repeat {
            let name = try expectIdentifier("変数名")
            var value: MLExpr?
            if match("=") { value = try parseExpression() }
            declarations.append(.varDecl(pattern: .binding(name), typeName: typeName,
                                          value: value, isConstant: false, location))
        } while match(",")
        if consumesEnd { consumeStatementEnd() }
        return declarations.count == 1 ? declarations[0] : .group(declarations, location)
    }

    override func parseForInitializerDeclaration() throws -> MLStmt? {
        guard looksLikeTypedDeclaration() else { return nil }
        return try parseTypedDeclaration(consumesEnd: false)
    }

    override func parseForPattern() throws -> MLPattern {
        while profile.ignorableModifiers.contains(current.text) { advance() }
        _ = match("def", "var")
        let saved = index
        if current.kind == .identifier || current.kind == .keyword {
            if (try? parseTypeName()) != nil, current.kind == .identifier {
                let name = advance().text
                if check("in") || check(":") { return name == "_" ? .wildcard : .binding(name) }
            }
            index = saved
        }
        return try super.parseForPattern()
    }

    /// Groovy のクロージャ `{ it * 2 }` / `{ a, b -> a + b }`
    override func allowsTrailingClosure(after expression: MLExpr) -> Bool { true }

    override func parseTrailingClosure() throws -> MLExpr {
        try parseClosure()
    }

    override func parseBraceLiteral() throws -> MLExpr {
        try parseClosure()
    }

    private func parseClosure() throws -> MLExpr {
        let location = current.location
        try expect("{", "クロージャ")
        var parameters: [MLParameter] = []
        // `a, b ->` の形なら引数として読む。
        var offset = 0
        var depth = 0
        var hasArrow = false
        while !peek(offset).isEndOfFile {
            let text = peek(offset).text
            if text == "{" || text == "(" || text == "[" { depth += 1 }
            if text == "}" || text == ")" || text == "]" {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0, text == "->" { hasArrow = true; break }
            if depth == 0, text == ";" { break }
            offset += 1
        }
        if hasArrow {
            while !check("->") {
                // `int a` のように型が付くこともある。型は名前の直前にだけ現れる。
                if (current.kind == .identifier || current.kind == .keyword),
                   peek(1).kind == .identifier {
                    _ = try? parseTypeName()
                }
                if current.kind == .identifier {
                    parameters.append(MLParameter(name: advance().text))
                }
                if match("=") { _ = try parseExpression() }
                if !match(",") { break }
            }
            try expect("->", "クロージャ")
        }
        var body: [MLStmt] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            let before = index
            if let statement = try parseStatement() { body.append(statement) }
            if index == before { advance() }
        }
        try expect("}", "クロージャの終わり")
        return .lambda(MLFunctionDecl(name: "", parameters: parameters, body: body,
                                      usesImplicitArguments: parameters.isEmpty,
                                      location: location), location)
    }

    /// `[1, 2, 3]` と `[a: 1, b: 2]` (Groovy の Map リテラル)。
    override func parseListOrMapLiteral() throws -> MLExpr {
        let location = current.location
        try expect("[", "リテラル")
        if check(":") {
            advance()
            try expect("]", "空の Map")
            return .mapLiteral([], location)
        }
        if check("]") {
            advance()
            return .listLiteral([], spreadIndices: [], location)
        }
        var items: [MLExpr] = []
        var pairs: [(key: MLExpr, value: MLExpr)] = []
        var isMap = false
        repeat {
            if check("]") { break }
            // `key: value` の形かどうか。
            if (current.kind == .identifier || current.kind == .stringLiteral),
               peek(1).is(":") {
                let key = current.kind == .stringLiteral
                    ? MLExpr.literal(.string(advance().stringValue ?? ""), location)
                    : MLExpr.literal(.string(advance().text), location)
                advance()
                isMap = true
                pairs.append((key: key, value: try parseExpression()))
                continue
            }
            let first = try parseExpression()
            if match(":") {
                isMap = true
                pairs.append((key: first, value: try parseExpression()))
            } else {
                items.append(first)
            }
        } while match(",")
        try expect("]", "リテラルの終わり")
        return isMap ? .mapLiteral(pairs, location)
                     : .listLiteral(items, spreadIndices: [], location)
    }

    override func precedence(of op: String) -> Int? {
        if op == "?:" { return 9 }
        if op == "<=>" { return 8 }
        if op == "in" { return 8 }
        return super.precedence(of: op)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        GroovyLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        GroovyParser(tokens: tokens, diagnostics: diagnostics)
    }
}

// MARK: - 振る舞い

final class GroovySemantics: MLSemantics {
    override var languageID: String { "groovy" }
    override var displayName: String { "内蔵 Groovy 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { true }
    /// Groovy の `/` は整数同士でも小数になる (BigDecimal)。
    override var divisionAlwaysProducesDouble: Bool { true }
    /// Groovy は「空でなければ真」。
    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .bool(let flag): return flag
        case .unit: return false
        case .int(let number): return number != 0
        case .double(let number): return number != 0
        case .string(let text): return !text.isEmpty
        case .array(let array): return !array.elements.isEmpty
        case .map(let map): return !map.isEmpty
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
        case .bool: return "Boolean"
        case .int: return "Integer"
        case .double: return "BigDecimal"
        case .string, .char: return "String"
        case .array: return "ArrayList"
        case .map: return "LinkedHashMap"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        MLNumberFormatting.compactStyle(value)
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return MLNumberFormatting.compactStyle(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            return "[" + array.elements.map { display($0) }.joined(separator: ", ") + "]"
        case .map(let map):
            if map.isEmpty { return "[:]" }
            return "[" + map.pairs.map { "\(display($0.key.asValue)):\(display($0.value))" }
                .joined(separator: ", ") + "]"
        case .object(let object):
            if let caseName = object.caseName { return caseName }
            if let interpreter = toStringInterpreter,
               object.classDeclaration?.findMethod("toString") != nil,
               let result = try? interpreter.callMethod(on: value, name: "toString",
                                                        arguments: [], location: .unknown),
               let text = result.asString {
                return text
            }
            return object.typeName + "@" + String(UInt(bitPattern:
                ObjectIdentifier(object).hashValue) & 0xfffffff, radix: 16)
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    private var toStringInterpreter: MLInterpreter?

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue {
        guard let typeName else { return .unit }
        switch typeName {
        case "int", "long", "short", "byte": return .int(0)
        case "double", "float": return .double(0)
        case "boolean": return .bool(false)
        default: return .unit
        }
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        toStringInterpreter = interpreter
        switch op {
        case "?:":
            return try isTruthy(lhs) ? lhs : rhs
        case "<=>":
            guard let order = compare(lhs, rhs) else { return .unit }
            return .int(Int64(order))
        case "+":
            if case .string = lhs.forced { return .string(display(lhs) + display(rhs)) }
            if let left = lhs.asArray, let right = rhs.asArray {
                return .array(MLArray(left.elements + right.elements))
            }
            if let left = lhs.asArray { return .array(MLArray(left.elements + [rhs])) }
            return nil
        case "*":
            // `"ab" * 3` は繰り返し。
            if case .string(let text) = lhs.forced, let count = rhs.asInt {
                return .string(count > 0 ? String(repeating: text, count: Int(count)) : "")
            }
            return nil
        case "in":
            if let array = rhs.asArray {
                return .bool(array.elements.contains { areEqual($0, lhs) })
            }
            if let map = rhs.asMap, let key = MLKey.from(lhs) { return .bool(map.contains(key)) }
            if let text = rhs.asString, let needle = lhs.asString {
                return .bool(text.contains(needle))
            }
            return .bool(false)
        default:
            return nil
        }
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        toStringInterpreter = interpreter
        GroovyLibrary.install(into: environment, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        switch name {
        case "size":
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let map = value.asMap { return .int(Int64(map.count)) }
        case "length":
            if let text = value.asString { return .int(Int64(text.count)) }
            if let array = value.asArray { return .int(Int64(array.count)) }
        case "class": return .string(typeName(of: value))
        case "keySet", "keys":
            if let map = value.asMap { return .array(MLArray(map.keys.map { $0.asValue })) }
        case "values":
            if let map = value.asMap { return .array(MLArray(map.values)) }
        case "first":
            if let array = value.asArray { return array.elements.first ?? .unit }
        case "last":
            if let array = value.asArray { return array.elements.last ?? .unit }
        default:
            // Map のキーは `.名前` でも引ける。
            if let map = value.asMap, let stored = map[.string(name)] { return stored }
        }
        return nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try GroovyLibrary.method(on: value, name: name, context: context, semantics: self)
    }
}

enum GroovyLibrary {
    static func install(into environment: MLEnvironment, semantics: GroovySemantics) {
        environment.define("println", .function(.native("println", 0...8) { context in
            let text = context.arguments.map { semantics.display($0) }.joined(separator: " ")
            context.interpreter.write(text + "\n")
            return .unit
        }), isConstant: true)
        environment.define("print", .function(.native("print", 0...8) { context in
            context.interpreter.write(context.arguments.map { semantics.display($0) }
                .joined(separator: " "))
            return .unit
        }), isConstant: true)
        environment.define("printf", .function(.native("printf", 1...16) { context in
            let pattern = try context.requireString(0, "printf")
            var rest = Array(context.arguments.dropFirst())
            if rest.count == 1, let array = rest[0].asArray { rest = array.elements }
            context.interpreter.write(try MLStdlib.format(pattern, arguments: rest,
                                                          semantics: semantics))
            return .unit
        }), isConstant: true)
        environment.define("sprintf", .function(.native("sprintf", 1...16) { context in
            let pattern = try context.requireString(0, "sprintf")
            var rest = Array(context.arguments.dropFirst())
            if rest.count == 1, let array = rest[0].asArray { rest = array.elements }
            return .string(try MLStdlib.format(pattern, arguments: rest, semantics: semantics))
        }), isConstant: true)
        environment.define("assert", .function(.native("assert", 1) { context in
            if try !semantics.isTruthy(context.argument(0)) {
                throw MLError.runtime("assert: 条件が成り立ちません")
            }
            return .unit
        }), isConstant: true)

        let math = MLObject(typeName: "Math")
        math.fields[.string("PI")] = .double(Double.pi)
        math.fields[.string("E")] = .double(M_E)
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
        math.fields[.string("abs")] = .function(.native("abs", 1) { context in
            switch context.argument(0) {
            case .int(let value): return .int(value < 0 ? -value : value)
            default: return .double(Swift.abs(context.argument(0).asDouble ?? 0))
            }
        })
        environment.define("Math", .object(math), isConstant: true)

        for name in ["ArrayList", "LinkedList", "HashSet", "List"] {
            environment.define(name, .function(.native(name, 0...1) { context in
                guard let source = context.optionalArgument(0)?.asArray else {
                    return .array(MLArray())
                }
                return .array(MLArray(source.elements))
            }), isConstant: true)
        }
        for name in ["HashMap", "LinkedHashMap", "TreeMap", "Map"] {
            environment.define(name, .function(.native(name, 0...1) { context in
                guard let source = context.optionalArgument(0)?.asMap else {
                    return .map(MLMap())
                }
                return .map(source.copy())
            }), isConstant: true)
        }
        environment.define("StringBuilder", .function(.native("StringBuilder", 0...1) { context in
            let object = MLObject(typeName: "StringBuilder")
            object.fields[.string("value")] = .string(context.optionalArgument(0)?.asString ?? "")
            return .object(object)
        }), isConstant: true)
        for name in ["Exception", "RuntimeException", "IllegalArgumentException",
                     "IllegalStateException"] {
            environment.define(name, .function(.native(name, 0...1) { context in
                let object = MLObject(typeName: name)
                object.fields[.string("message")] =
                    .string(context.optionalArgument(0)?.asString ?? "")
                object.fields[.string("#types")] = .array(MLArray(
                    [.string(name), .string("RuntimeException"), .string("Exception")]))
                return .object(object)
            }), isConstant: true)
        }
    }

    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: GroovySemantics) throws -> MLValue? {
        let interpreter = context.interpreter
        if let object = receiver.asObject, object.typeName == "StringBuilder" {
            let current = object.fields[.string("value")]?.asString ?? ""
            if name == "append" {
                object.fields[.string("value")] =
                    .string(current + semantics.display(context.argument(0)))
                return receiver
            }
            if name == "toString" { return .string(current) }
            return try MLStdlib.callMethod(on: .string(current), name: name, context: context)
        }

        switch receiver.forced {
        case .array(let array):
            switch name {
            case "each":
                let body = try context.requireFunction(0, "each")
                for element in array.elements {
                    _ = try interpreter.callFunction(body, arguments: [element])
                }
                return receiver
            case "eachWithIndex":
                let body = try context.requireFunction(0, "eachWithIndex")
                for (index, element) in array.elements.enumerated() {
                    _ = try interpreter.callFunction(body,
                                                     arguments: [element, .int(Int64(index))])
                }
                return receiver
            case "collect":
                return try MLStdlib.callMethod(on: .array(array), name: "map", context: context)
            case "findAll":
                return try MLStdlib.callMethod(on: .array(array), name: "filter",
                                               context: context)
            case "inject":
                return try MLStdlib.callMethod(on: .array(array), name: "reduce",
                                               context: context)
            case "sum":
                return try MLStdlib.callMethod(on: .array(array), name: "sum", context: context)
            case "sort":
                array.elements = try MLStdlib.stableSorted(
                    array.elements, interpreter: interpreter,
                    comparator: context.optionalArgument(0)?.asFunction,
                    byKey: context.optionalArgument(0)?.asFunction?.declaredArity == 1)
                return .array(array)
            case "toSorted":
                return .array(MLArray(try MLStdlib.stableSorted(
                    array.elements, interpreter: interpreter,
                    comparator: context.optionalArgument(0)?.asFunction)))
            case "join":
                return try MLStdlib.callMethod(on: .array(array), name: "join", context: context)
            case "toString":
                return .string(semantics.display(.array(array)))
            case "add", "push", "leftShift":
                array.elements.append(context.argument(0))
                return .bool(true)
            case "get":
                let position = Int(try context.requireInt(0, "get"))
                guard position >= 0, position < array.count else {
                    throw MLError.runtime("get: 範囲外です")
                }
                return array.elements[position]
            default:
                return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
            }
        case .map(let map):
            switch name {
            case "each":
                let body = try context.requireFunction(0, "each")
                for (key, value) in map.pairs {
                    if body.declaredArity >= 2 {
                        _ = try interpreter.callFunction(body, arguments: [key.asValue, value])
                    } else {
                        _ = try interpreter.callFunction(
                            body, arguments: [.tuple([key.asValue, value])])
                    }
                }
                return receiver
            case "toString": return .string(semantics.display(.map(map)))
            case "containsKey":
                guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
                return .bool(map.contains(key))
            case "put":
                guard let key = MLKey.from(context.argument(0)) else { return .unit }
                let previous = map[key]
                map[key] = context.argument(1)
                return previous ?? .unit
            default:
                return try MLStdlib.callMethod(on: .map(map), name: name, context: context)
            }
        case .string(let text):
            switch name {
            case "toString": return .string(text)
            case "toInteger":
                guard let value = Int64(text.trimmingCharacters(in: .whitespaces)) else {
                    throw MLError.runtime("toInteger: 数値に変換できません: \(text)")
                }
                return .int(value)
            case "eachWithIndex":
                let body = try context.requireFunction(0, "eachWithIndex")
                for (index, character) in text.enumerated() {
                    _ = try interpreter.callFunction(
                        body, arguments: [.string(String(character)), .int(Int64(index))])
                }
                return receiver
            case "toUpperCase": return .string(text.uppercased())
            case "toLowerCase": return .string(text.lowercased())
            default:
                return try MLStdlib.callMethod(on: .string(text), name: name, context: context)
            }
        case .int, .double:
            switch name {
            case "times":
                let body = try context.requireFunction(0, "times")
                for index in 0..<Swift.max(0, Int(receiver.asInt ?? 0)) {
                    _ = try interpreter.callFunction(body, arguments: [.int(Int64(index))])
                }
                return .unit
            case "upto":
                let limit = try context.requireInt(0, "upto")
                let body = try context.requireFunction(1, "upto")
                var value = receiver.asInt ?? 0
                while value <= limit {
                    _ = try interpreter.callFunction(body, arguments: [.int(value)])
                    value += 1
                }
                return .unit
            case "toString": return .string(semantics.display(receiver))
            case "intdiv":
                let divisor = try context.requireInt(0, "intdiv")
                guard divisor != 0 else { throw MLError.runtime("0 で割ることはできません") }
                return .int((receiver.asInt ?? 0) / divisor)
            case "toInteger": return .int(receiver.asInt ?? Int64(receiver.asDouble ?? 0))
            default:
                return try MLStdlib.callMethod(on: receiver, name: name, context: context)
            }
        default:
            return nil
        }
    }
}
