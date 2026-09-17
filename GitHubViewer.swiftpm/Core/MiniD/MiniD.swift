import Foundation

/// 内蔵の D 処理系。
///
/// C++ に近い文法に、`auto`・`foreach`・スライス・`writeln` などを足した言語。
public enum MiniD: MiniLangEngine {
    public static var languageID: String { "d" }
    public static var displayName: String { "内蔵 D 処理系" }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = DLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = DParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: DSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum DProfile {
    static let keywords: Set<String> = [
        "abstract", "alias", "align", "asm", "assert", "auto", "bool", "break", "byte",
        "case", "cast", "catch", "char", "class", "const", "continue", "dchar",
        "default", "delegate", "do", "double", "else", "enum", "export", "extern",
        "false", "final", "finally", "float", "for", "foreach", "foreach_reverse",
        "function", "goto", "if", "immutable", "import", "in", "inout", "int",
        "interface", "invariant", "is", "lazy", "long", "mixin", "module", "new",
        "null", "out", "override", "package", "pragma", "private", "protected",
        "public", "pure", "real", "ref", "return", "scope", "shared", "short",
        "static", "string", "struct", "super", "switch", "synchronized", "template",
        "this", "throw", "true", "try", "typeid", "typeof", "ubyte", "uint", "ulong",
        "union", "unittest", "ushort", "version", "void", "wchar", "while", "with",
        "size_t"
    ]

    static let profile = MLLanguageProfile(
        languageID: "d",
        comments: [.line("//"), .block(open: "/*", close: "*/", nesting: false),
                   .block(open: "/+", close: "+/", nesting: true)],
        strings: [MLLanguageProfile.StringStyle(quote: "\""),
                  MLLanguageProfile.StringStyle(quote: "`", allowsEscapes: false),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators + ["~", "~=", "^^", "..", "=>"],
        functionSyntax: .typeFirst,
        functionKeywords: [],
        variableKeywords: [:],
        typeKeywords: ["class": .classType, "struct": .structType, "enum": .enumType,
                       "interface": .interfaceType, "union": .structType],
        ignorableModifiers: ["public", "private", "protected", "package", "static",
                             "const", "immutable", "shared", "final", "override",
                             "abstract", "pure", "nothrow", "ref", "scope", "extern",
                             "export", "align", "@"],
        nullLiterals: ["null"],
        selfKeywords: ["this"])
}

final class DLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: DProfile.profile, diagnostics: diagnostics)
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

final class DParser: MLProfileParser {
    private var insideFunctionBody = false

    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: DProfile.profile, diagnostics: diagnostics)
    }

    override var enumCasesNeedKeyword: Bool { false }
    override func entryPointName() -> String? { "main" }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            if check("import") || check("module") || check("alias") || check("version")
                || check("pragma") || check("unittest") {
                if check("unittest") {
                    advance()
                    if check("{") { skipBalanced(open: "{", close: "}") }
                    continue
                }
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
        }
        if check("import") || check("module") || check("alias") || check("pragma") {
            skipToStatementEnd()
            return .noop(location)
        }
        if check("foreach") || check("foreach_reverse") {
            return try parseForeach(reversed: current.text == "foreach_reverse")
        }
        if check("writeln") || check("write") || check("writefln") || check("writef") {
            // 括弧なしでは使えないので、通常の式として読む。
        }
        if looksLikeDeclaration() {
            return try parseDeclaration(consumesEnd: true)
        }
        return try super.parseStatement()
    }

    /// `foreach (x; xs)` / `foreach (i, x; xs)` / `foreach (i; 0 .. 10)`
    private func parseForeach(reversed: Bool) throws -> MLStmt {
        let location = current.location
        advance()
        try expect("(", "foreach の始まり")
        var names: [String] = []
        repeat {
            while profile.ignorableModifiers.contains(current.text) { advance() }
            let saved = index
            if (try? parseTypeName()) != nil, current.kind == .identifier {
                names.append(advance().text)
            } else {
                index = saved
                names.append(try expectIdentifier("foreach の変数"))
            }
        } while match(",")
        try expect(";", "foreach の区切り")
        var sequence = try parseExpression()
        if match("..") {
            let upper = try parseExpression()
            sequence = .range(lower: sequence, upper: upper, isClosed: false,
                              step: nil, location)
        }
        try expect(")", "foreach の終わり")
        let body = try parseStatementAsBlock()

        if reversed {
            sequence = .call(callee: .member(sequence, "reversed", isOptional: false,
                                             location),
                             arguments: [], location)
        }
        if names.count >= 2 {
            // 添字つきの繰り返し。
            let enumerated = MLExpr.call(
                callee: .name("#enumerate", location),
                arguments: [MLArgument(value: sequence)], location)
            let pattern = MLPattern.tuple(names.map { $0 == "_" ? .wildcard : .binding($0) })
            return .forIn(pattern: pattern, sequence: enumerated, body: body,
                          whereClause: nil, label: nil, location)
        }
        let name = names.first ?? "_"
        return .forIn(pattern: name == "_" ? .wildcard : .binding(name),
                      sequence: sequence, body: body, whereClause: nil,
                      label: nil, location)
    }

    override func isFunctionDeclarationStart() -> Bool {
        insideFunctionBody ? false : super.isFunctionDeclarationStart()
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
        body.statements = body.statements.filter { statement in
            if case .noop = statement { return false }
            return true
        }
        return body
    }

    override func parseTypeMember(into body: inout TypeBody, kind: MLTypeDecl.Kind,
                                  typeName: String) throws {
        if ["public", "private", "protected", "package"].contains(current.text),
           peek(1).is(":") {
            advance()
            advance()
            return
        }
        if check("~"), peek(1).is("this") {
            advance()
            advance()
            if check("(") { skipBalanced(open: "(", close: ")") }
            if check("{") { _ = try parseBlock() } else { skipToStatementEnd() }
            return
        }
        // `this(int x) { }` はコンストラクタ。
        if check("this"), peek(1).is("(") {
            let location = current.location
            advance()
            let parameters = try parseParameterList()
            skipThrowsClause()
            let methodBody = check("{") ? try parseBlock() : []
            body.initializers.append(MLFunctionDecl(name: "init", parameters: parameters,
                                                    body: methodBody, isInitializer: true,
                                                    location: location))
            return
        }
        try super.parseTypeMember(into: &body, kind: kind, typeName: typeName)
    }

    override var trailingFunctionQualifiers: Set<String> {
        ["const", "pure", "nothrow", "immutable", "shared", "@safe", "@trusted",
         "@system", "@nogc", "@property", "@"]
    }

    private func looksLikeDeclaration() -> Bool {
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
            if text == "!" , peek(offset + 1).is("(") { offset += 1; continue }
            if text == "(" { depth += 1; offset += 1; continue }
            if text == ")" , depth > 0 { depth -= 1; offset += 1; continue }
            if depth > 0 { offset += 1; continue }
            if text == "[" {
                // 配列・連想配列の型。
                var bracket = 0
                repeat {
                    if peek(offset).is("[") { bracket += 1 }
                    if peek(offset).is("]") { bracket -= 1 }
                    offset += 1
                } while bracket > 0 && !peek(offset).isEndOfFile
                continue
            }
            if text == "*" { offset += 1; continue }
            break
        }
        guard peek(offset).kind == .identifier else { return false }
        let next = peek(offset + 1).text
        return next == "=" || next == ";" || next == ","
    }

    private func isKnownTypeName(_ text: String) -> Bool {
        ["int", "long", "short", "byte", "ubyte", "uint", "ulong", "ushort", "char",
         "wchar", "dchar", "bool", "float", "double", "real", "void", "auto", "string",
         "size_t", "immutable", "const"].contains(text)
    }

    private func parseDeclaration(consumesEnd: Bool) throws -> MLStmt {
        let location = current.location
        while profile.ignorableModifiers.contains(current.text) { advance() }
        let typeName = try parseDTypeName()
        var declarations: [MLStmt] = []
        repeat {
            let name = try expectIdentifier("変数名")
            var value: MLExpr?
            if match("=") { value = try parseExpression() }
            declarations.append(.varDecl(pattern: .binding(name), typeName: typeName,
                                          value: value, isConstant: false, location))
        } while match(",")
        if consumesEnd { consumeStatementEnd() }
        return declarations.count == 1 ? declarations[0] : .block(declarations, location)
    }

    override func parseForInitializerDeclaration() throws -> MLStmt? {
        guard looksLikeDeclaration() else { return nil }
        return try parseDeclaration(consumesEnd: false)
    }

    /// `int[]` `int[string]` `Foo!(int)` などを名前として読む。
    private func parseDTypeName() throws -> String {
        while profile.ignorableModifiers.contains(current.text) { advance() }
        guard current.kind == .identifier || current.kind == .keyword else {
            throw report("型名が必要です")
        }
        var text = advance().text
        // テンプレート引数 `Foo!(int)` / `Foo!int`
        if check("!") {
            advance()
            if check("(") { skipBalanced(open: "(", close: ")") }
            else if current.kind == .identifier || current.kind == .keyword { advance() }
        }
        while check("."), peek(1).kind == .identifier {
            advance()
            text = advance().text
        }
        while check("[") {
            advance()
            if check("]") {
                advance()
                text = "Array<\(text)>"
                continue
            }
            // `int[string]` は連想配列。
            if (try? parseDTypeName()) != nil, check("]") {
                advance()
                text = "Map<\(text)>"
                continue
            }
            _ = try? parseExpression()
            _ = match("]")
            text = "Array<\(text)>"
        }
        while match("*") { text = "Pointer<\(text)>" }
        return text
    }

    override func parseTypeName() throws -> String {
        try parseDTypeName()
    }

    /// `xs[1 .. $]` の `$` は「その値の長さ」。
    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        if check("$"), let receiver = subscriptReceiver {
            let location = advance().location
            return .member(receiver, "length", isOptional: false, location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    override func precedence(of op: String) -> Int? {
        if op == "~" { return 12 }
        if op == "^^" { return 15 }
        return super.precedence(of: op)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        DLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        DParser(tokens: tokens, diagnostics: diagnostics)
    }
}

// MARK: - 振る舞い

final class DSemantics: MLSemantics {
    override var languageID: String { "d" }
    override var displayName: String { "内蔵 D 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { true }
    override var usesValueSemantics: Bool { false }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .bool(let flag): return flag
        case .int(let number): return number != 0
        case .double(let number): return number != 0
        case .unit: return false
        case .string(let text): return !text.isEmpty
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .string, .char: return "string"
        case .array: return "array"
        case .map: return "associative array"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        // D の writeln は既定で有効数字 6 桁。
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        var text = String(format: "%g", value)
        if text.contains("e") {
            text = text.replacingOccurrences(of: "e+0", with: "e+")
                .replacingOccurrences(of: "e-0", with: "e-")
        }
        return text
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
            // D の連想配列はキー順に並べて表示する。
            let sorted = map.pairs.sorted { (compare($0.key.asValue, $1.key.asValue) ?? 0) < 0 }
            return "[" + sorted.map { "\(display($0.key.asValue)):\(display($0.value))" }
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
            let items = object.fields.values.map { display($0) }
            return object.typeName + "(" + items.joined(separator: ", ") + ")"
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    private var toStringInterpreter: MLInterpreter?

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue {
        guard let typeName else { return .unit }
        if typeName.hasPrefix("Array") { return .array(MLArray()) }
        if typeName.hasPrefix("Map") { return .map(MLMap()) }
        switch typeName {
        case "int", "long", "short", "byte", "uint", "ulong", "ushort", "ubyte", "size_t":
            return .int(0)
        case "double", "float", "real": return .double(0)
        case "bool": return .bool(false)
        case "string": return .string("")
        case "char": return .char("\0")
        default: return .unit
        }
    }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        if let typeName, ["double", "float", "real"].contains(typeName),
           case .int(let number) = value.forced {
            return .double(Double(number))
        }
        return value
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        toStringInterpreter = interpreter
        switch op {
        case "~":
            // 連結演算子。
            if let left = lhs.asArray, let right = rhs.asArray {
                return .array(MLArray(left.elements + right.elements))
            }
            if let left = lhs.asArray { return .array(MLArray(left.elements + [rhs])) }
            return .string(display(lhs) + display(rhs))
        case "^^":
            return MLOperations.power(lhs.asDouble ?? 0, rhs.asDouble ?? 0,
                                      preferInteger: lhs.asInt != nil && rhs.asInt != nil)
        case "in":
            if let map = rhs.asMap, let key = MLKey.from(lhs) {
                return map.contains(key) ? (map[key] ?? .bool(true)) : .unit
            }
            return .unit
        case "+":
            if case .string = lhs.forced { return .string(display(lhs) + display(rhs)) }
            return nil
        default:
            return nil
        }
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        toStringInterpreter = interpreter
        DLibrary.install(into: environment, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        switch name {
        case "length":
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let text = value.asString { return .int(Int64(text.count)) }
            if let map = value.asMap { return .int(Int64(map.count)) }
        case "keys":
            if let map = value.asMap { return .array(MLArray(map.keys.map { $0.asValue })) }
        case "values":
            if let map = value.asMap { return .array(MLArray(map.values)) }
        case "dup":
            if let array = value.asArray { return .array(MLArray(array.elements)) }
        case "empty":
            if let array = value.asArray { return .bool(array.elements.isEmpty) }
        case "front":
            if let array = value.asArray { return array.elements.first ?? .unit }
        case "back":
            if let array = value.asArray { return array.elements.last ?? .unit }
        default:
            break
        }
        return nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try DLibrary.method(on: value, name: name, context: context, semantics: self)
    }
}

enum DLibrary {
    static func install(into environment: MLEnvironment, semantics: DSemantics) {
        environment.define("writeln", .function(.native("writeln", 0...16) { context in
            context.interpreter.write(
                context.arguments.map { semantics.display($0) }.joined() + "\n")
            return .unit
        }), isConstant: true)
        environment.define("write", .function(.native("write", 0...16) { context in
            context.interpreter.write(context.arguments.map { semantics.display($0) }.joined())
            return .unit
        }), isConstant: true)
        environment.define("writefln", .function(.native("writefln", 1...16) { context in
            let pattern = try context.requireString(0, "writefln")
            context.interpreter.write(try MLStdlib.format(
                pattern, arguments: Array(context.arguments.dropFirst()),
                semantics: semantics) + "\n")
            return .unit
        }), isConstant: true)
        environment.define("writef", .function(.native("writef", 1...16) { context in
            let pattern = try context.requireString(0, "writef")
            context.interpreter.write(try MLStdlib.format(
                pattern, arguments: Array(context.arguments.dropFirst()),
                semantics: semantics))
            return .unit
        }), isConstant: true)
        environment.define("format", .function(.native("format", 1...16) { context in
            let pattern = try context.requireString(0, "format")
            return .string(try MLStdlib.format(pattern,
                                               arguments: Array(context.arguments.dropFirst()),
                                               semantics: semantics))
        }), isConstant: true)
        environment.define("to", .function(.native("to", 1) { context in
            context.argument(0)
        }), isConstant: true)
        environment.define("#enumerate", .function(.native("#enumerate", 1) { context in
            let items = try MLOperations.iterate(context.argument(0), semantics: semantics)
            return .array(MLArray(items.enumerated()
                .map { .tuple([.int(Int64($0.offset)), $0.element]) }))
        }), isConstant: true)
        environment.define("assert", .function(.native("assert", 1...2) { context in
            if try !semantics.isTruthy(context.argument(0)) {
                throw MLError.runtime("assert: 条件が成り立ちません")
            }
            return .unit
        }), isConstant: true)

        for (name, implementation) in MLStdlib.mathFunctions {
            environment.define(name, .function(.native(name, 1) { context in
                .double(implementation(try context.requireDouble(0, name)))
            }), isConstant: true)
        }
        environment.define("pow", .function(.native("pow", 2) { context in
            .double(Foundation.pow(try context.requireDouble(0, "pow"),
                                   try context.requireDouble(1, "pow")))
        }), isConstant: true)
        environment.define("abs", .function(.native("abs", 1) { context in
            switch context.argument(0) {
            case .int(let value): return .int(value < 0 ? -value : value)
            default: return .double(Swift.abs(context.argument(0).asDouble ?? 0))
            }
        }), isConstant: true)
        environment.define("max", .function(.native("max", 1...8) { context in
            try MLStdlib.reduceExtreme(context, keepSmaller: false)
        }), isConstant: true)
        environment.define("min", .function(.native("min", 1...8) { context in
            try MLStdlib.reduceExtreme(context, keepSmaller: true)
        }), isConstant: true)
        environment.define("sort", .function(.native("sort", 1...2) { context in
            guard let array = context.argument(0).asArray else { return context.argument(0) }
            array.elements = try MLStdlib.stableSorted(
                array.elements, interpreter: context.interpreter,
                comparator: context.optionalArgument(1)?.asFunction)
            return .array(array)
        }), isConstant: true)
        environment.define("reverse", .function(.native("reverse", 1) { context in
            guard let array = context.argument(0).asArray else { return context.argument(0) }
            array.elements.reverse()
            return .array(array)
        }), isConstant: true)
        environment.define("iota", .function(.native("iota", 1...3) { context in
            let start = context.arguments.count >= 2 ? (context.argument(0).asInt ?? 0) : 0
            let end = context.arguments.count >= 2 ? (context.argument(1).asInt ?? 0)
                                                   : (context.argument(0).asInt ?? 0)
            let step = context.optionalArgument(2)?.asInt ?? 1
            var values: [MLValue] = []
            var current = start
            while step > 0 ? current < end : current > end {
                values.append(.int(current))
                current += step
            }
            return .array(MLArray(values))
        }), isConstant: true)
        environment.define("readln", .function(.native("readln", 0...0) { context in
            guard let line = context.interpreter.input.nextLine() else { return .string("") }
            return .string(line + "\n")
        }), isConstant: true)
        for name in ["Exception", "Error"] {
            environment.define(name, .function(.native(name, 0...1) { context in
                let object = MLObject(typeName: name)
                object.fields[.string("msg")] =
                    .string(context.optionalArgument(0)?.asString ?? "")
                object.fields[.string("#types")] =
                    .array(MLArray([.string("Exception"), .string("Error"),
                                    .string("Throwable")]))
                return .object(object)
            }), isConstant: true)
        }
    }

    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: DSemantics) throws -> MLValue? {
        switch receiver.forced {
        case .array(let array):
            switch name {
            case "sort":
                array.elements = try MLStdlib.stableSorted(
                    array.elements, interpreter: context.interpreter,
                    comparator: context.optionalArgument(0)?.asFunction)
                return .array(array)
            case "reversed":
                return .array(MLArray(array.elements.reversed()))
            case "dup", "array", "idup": return .array(MLArray(array.elements))
            case "map", "filter", "reduce", "sum", "join", "canFind", "count":
                if name == "canFind" {
                    return try MLStdlib.callMethod(on: .array(array), name: "contains",
                                                   context: context)
                }
                return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
            case "length": return .int(Int64(array.count))
            default:
                return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
            }
        case .string(let text):
            switch name {
            case "toUpper": return .string(text.uppercased())
            case "toLower": return .string(text.lowercased())
            case "strip": return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "idup", "dup": return .string(text)
            case "to": return .string(text)
            default:
                return try MLStdlib.callMethod(on: .string(text), name: name, context: context)
            }
        case .object(let object):
            if object.classDeclaration == nil, name == "msg" || name == "message" {
                return object.fields[.string("msg")] ?? .string("")
            }
            return nil
        default:
            return try MLStdlib.callMethod(on: receiver, name: name, context: context)
        }
    }
}
