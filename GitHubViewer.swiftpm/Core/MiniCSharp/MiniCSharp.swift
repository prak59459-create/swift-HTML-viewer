import Foundation

/// 内蔵の C# 処理系。
public enum MiniCSharp: MiniLangEngine {
    public static var languageID: String { "csharp" }
    public static var displayName: String { "内蔵 C# 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = CSharpLexer(source: source, diagnostics: diagnostics).tokenize()
        return try CSharpParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
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
        let tokens = CSharpLexer(source: source, diagnostics: diagnostics).tokenize()
        let parser = CSharpParser(tokens: tokens, diagnostics: diagnostics)
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
        let interpreter = MLInterpreter(semantics: CSharpSemantics(), limits: limits,
                                        input: input)
        return interpreter.run(program)
    }
}

// MARK: - 見た目

enum CSharpProfile {
    static let keywords: Set<String> = [
        "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char",
        "checked", "class", "const", "continue", "decimal", "default", "delegate", "do",
        "double", "else", "enum", "event", "explicit", "extern", "false", "finally",
        "fixed", "float", "for", "foreach", "goto", "if", "implicit", "in", "int",
        "interface", "internal", "is", "lock", "long", "namespace", "new", "null",
        "object", "operator", "out", "override", "params", "private", "protected",
        "public", "readonly", "ref", "return", "sbyte", "sealed", "short", "sizeof",
        "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true",
        "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using",
        "virtual", "void", "volatile", "while", "var", "record", "when", "yield"
    ]

    static let profile = MLLanguageProfile(
        languageID: "csharp",
        comments: [.line("//"), .block(open: "/*", close: "*/", nesting: false)],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", isMultiline: true),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators + ["=>", "??=", "?["],
        functionSyntax: .typeFirst,
        functionKeywords: [],
        variableKeywords: ["var": false],
        typeKeywords: ["class": .classType, "interface": .interfaceType,
                       "enum": .enumType, "struct": .structType, "record": .structType],
        ignorableModifiers: ["public", "private", "protected", "internal", "static",
                             "readonly", "sealed", "virtual", "override", "abstract",
                             "extern", "unsafe", "partial", "const", "new", "async",
                             "volatile", "[", "@"],
        nullLiterals: ["null"],
        selfKeywords: ["this"])
}

final class CSharpLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: CSharpProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        let start = location
        // 補間文字列 `$"..."` と逐語的文字列 `@"..."`。
        if peek() == "$", peek(1) == "\"" {
            advance()
            advance()
            let pieces = readInterpolatedString(terminator: "\"", interpolationPrefix: "{",
                                                simpleVariablePrefix: nil)
            if pieces.allSatisfy({ !$0.isExpression }) {
                let text = pieces.map { $0.text }.joined()
                return MLToken(kind: .stringLiteral, text: text, location: start,
                               stringValue: text)
            }
            return MLToken(kind: .interpolatedString, text: "", location: start, pieces: pieces)
        }
        if peek() == "@", peek(1) == "\"" {
            advance()
            advance()
            var text = ""
            while let character = peek() {
                if character == "\"" {
                    advance()
                    if peek() == "\"" {
                        text.append("\"")
                        advance()
                        continue
                    }
                    break
                }
                text.append(character)
                advance()
            }
            return MLToken(kind: .stringLiteral, text: text, location: start, stringValue: text)
        }
        // 数値の接尾辞。
        if let character = peek(), character.isNumber {
            var token = readNumber(allowsUnderscoreSeparator: true)
            if let suffix = peek(), "lLfFdDmMuU".contains(suffix) {
                advance()
                if "fFdDmM".contains(suffix), token.kind == .integerLiteral {
                    token = MLToken(kind: .floatLiteral, text: token.text,
                                    location: token.location,
                                    doubleValue: Double(token.intValue ?? 0))
                }
                if let second = peek(), "lLuU".contains(second) { advance() }
            }
            return token
        }
        return super.nextToken()
    }
}

final class CSharpParser: MLProfileParser {
    private var insideMethodBody = false

    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: CSharpProfile.profile, diagnostics: diagnostics)
    }

    override var enumCasesNeedKeyword: Bool { false }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            // `namespace Foo { ... }` は中身だけ取り出す。
            if check("namespace") {
                advance()
                _ = try? parseTypeName()
                if check("{") {
                    statements.append(contentsOf: try parseBlock())
                } else {
                    consumeStatementEnd()
                }
                continue
            }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        var entryType: String?
        for statement in statements {
            guard case .typeDecl(let decl) = statement else { continue }
            if decl.methods.contains(where: { $0.isStatic && $0.name == "Main" }) {
                entryType = decl.name
                break
            }
        }
        return MLProgram(statements: statements,
                         entryPoint: entryType == nil ? nil : "Main",
                         entryTypeName: entryType)
    }

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

    override func parseTypeBody(kind: MLTypeDecl.Kind, typeName: String) throws -> TypeBody {
        let saved = insideMethodBody
        insideMethodBody = false
        defer { insideMethodBody = saved }
        return try super.parseTypeBody(kind: kind, typeName: typeName)
    }

    override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location

        // 属性 `[Serializable]` は読み飛ばす。
        while check("["), peek(1).kind == .identifier, peek(1).text.first?.isUppercase == true,
              !insideMethodBody {
            skipBalanced(open: "[", close: "]")
        }
        if current.kind == .identifier, peek(1).is(":"), isLoopKeyword(peek(2).text) {
            let label = advance().text
            advance()
            return try parseLabeledStatement(label: label)
        }
        if looksLikeLocalVariable() {
            return try parseLocalVariable(location: location, consumesEnd: true)
        }
        return try super.parseStatement()
    }

    /// C# の `foreach (var x in xs)`。
    override func parseForPattern() throws -> MLPattern {
        while profile.ignorableModifiers.contains(current.text) { advance() }
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

    override func parseForInitializerDeclaration() throws -> MLStmt? {
        guard looksLikeLocalVariable() else { return nil }
        return try parseLocalVariable(location: current.location, consumesEnd: false)
    }

    private func isPrimitiveTypeName(_ text: String) -> Bool {
        ["int", "long", "short", "byte", "sbyte", "uint", "ulong", "ushort", "char",
         "bool", "float", "double", "decimal", "string", "object", "var", "void"]
            .contains(text)
    }

    private func looksLikeLocalVariable() -> Bool {
        var offset = 0
        while profile.ignorableModifiers.contains(peek(offset).text) { offset += 1 }
        let start = peek(offset)
        guard start.kind == .identifier || isPrimitiveTypeName(start.text) else { return false }
        if !isPrimitiveTypeName(start.text), start.text.first?.isUppercase != true {
            return false
        }
        offset += 1
        var depth = 0
        while true {
            let text = peek(offset).text
            if text == "<" { depth += 1; offset += 1; continue }
            if text == ">", depth > 0 { depth -= 1; offset += 1; continue }
            if depth > 0 { offset += 1; continue }
            if text == "[", peek(offset + 1).is("]") { offset += 2; continue }
            if text == "?" { offset += 1; continue }
            if text == ".", peek(offset + 1).kind == .identifier,
               !peek(offset + 2).is("(") { offset += 2; continue }
            break
        }
        guard peek(offset).kind == .identifier else { return false }
        let next = peek(offset + 1).text
        return next == "=" || next == ";" || next == ","
    }

    private func parseLocalVariable(location: SourceLocation,
                                    consumesEnd: Bool) throws -> MLStmt {
        while profile.ignorableModifiers.contains(current.text) { advance() }
        let typeName = try parseTypeName()
        var declarations: [MLStmt] = []
        repeat {
            let name = try expectIdentifier("変数名")
            var value: MLExpr?
            if match("=") {
                value = check("{") ? .listLiteral(try parseArrayInitializer(),
                                                  spreadIndices: [], location)
                                   : try parseExpression()
            }
            declarations.append(.varDecl(pattern: .binding(name), typeName: typeName,
                                          value: value, isConstant: false, location))
        } while match(",")
        if consumesEnd { consumeStatementEnd() }
        return declarations.count == 1 ? declarations[0] : .group(declarations, location)
    }

    /// C# のラムダ `x => expr` / `(a, b) => { ... }`。
    override func parseLambdaIfPresent(stopAtBrace: Bool) throws -> MLExpr? {
        let location = current.location
        if current.kind == .identifier, peek(1).is("=>") {
            let name = advance().text
            advance()
            return .lambda(try parseLambdaBody(parameters: [MLParameter(name: name)],
                                               location: location), location)
        }
        if check("(") {
            var offset = 1
            var depth = 1
            while depth > 0, !peek(offset).isEndOfFile {
                if peek(offset).is("(") { depth += 1 }
                if peek(offset).is(")") { depth -= 1 }
                offset += 1
            }
            guard peek(offset).is("=>") else { return nil }
            advance()
            var parameters: [MLParameter] = []
            while !check(")") {
                var name = try expectIdentifier("ラムダの引数")
                if current.kind == .identifier { name = advance().text }
                parameters.append(MLParameter(name: name))
                if !match(",") { break }
            }
            _ = match(")")
            _ = match("=>")
            return .lambda(try parseLambdaBody(parameters: parameters, location: location),
                           location)
        }
        if check("delegate") {
            advance()
            let parameters = check("(") ? try parseParameterList() : []
            let body = try parseBlock()
            return .lambda(MLFunctionDecl(name: "", parameters: parameters, body: body,
                                          location: location), location)
        }
        return nil
    }

    private func parseLambdaBody(parameters: [MLParameter],
                                 location: SourceLocation) throws -> MLFunctionDecl {
        if check("{") {
            return MLFunctionDecl(name: "", parameters: parameters, body: try parseBlock(),
                                  location: location)
        }
        let value = try parseExpression()
        return MLFunctionDecl(name: "", parameters: parameters,
                              body: [.returnStmt(value, value.location)], location: location)
    }

    /// `int Value { get; set; }` のような自動プロパティ。
    override func parseAccessors() throws -> ([MLStmt]?, [MLStmt]?, String?) {
        let saved = index
        try expect("{", "アクセサ")
        var sawAutoGet = false
        var sawAutoSet = false
        var isAuto = true
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            if check("get") || check("set") || check("init") {
                let isGetter = current.text == "get"
                advance()
                if check(";") {
                    advance()
                    if isGetter { sawAutoGet = true } else { sawAutoSet = true }
                    continue
                }
                isAuto = false
                break
            }
            isAuto = false
            break
        }
        if isAuto, sawAutoGet || sawAutoSet {
            try expect("}", "アクセサの終わり")
            // 自動プロパティはただの保存された値として扱う。
            return (nil, nil, nil)
        }
        index = saved
        return try super.parseAccessors()
    }

    override var memberAccessOperators: [String] { [".", "?.", "::"] }

    override func makeLexer(for text: String) -> MLProfileLexer {
        CSharpLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        CSharpParser(tokens: tokens, diagnostics: diagnostics)
    }
}

// MARK: - 振る舞い

final class CSharpSemantics: MLSemantics {
    override var languageID: String { "csharp" }
    override var displayName: String { "内蔵 C# 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { true }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        guard case .bool(let flag) = value.forced else {
            throw MLError.runtime("bool が必要です (\(typeName(of: value)) が渡されました)")
        }
        return flag
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .char: return "char"
        case .string: return "string"
        case .array: return "Array"
        case .map: return "Dictionary"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    /// C# の `double.ToString()` は末尾の `.0` を付けない。
    override func formatDouble(_ value: Double) -> String {
        MLNumberFormatting.compactStyle(value)
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return ""
        case .bool(let flag): return flag ? "True" : "False"
        case .double(let number): return MLNumberFormatting.compactStyle(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .int(let number): return String(number)
        case .array(let array):
            return "[" + array.elements.map { display($0) }.joined(separator: ", ") + "]"
        case .object(let object):
            if let caseName = object.caseName { return caseName }
            if object.typeName == "StringBuilder" {
                return object.fields[.string("value")]?.asString ?? ""
            }
            if let interpreter = toStringInterpreter,
               object.classDeclaration?.findMethod("ToString") != nil,
               let result = try? interpreter.callMethod(on: value, name: "ToString",
                                                        arguments: [],
                                                        location: .unknown),
               let text = result.asString {
                return text
            }
            return object.typeName
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    private var toStringInterpreter: MLInterpreter?

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue {
        guard let typeName else { return .unit }
        switch typeName {
        case "int", "long", "short", "byte", "uint", "ulong", "ushort", "sbyte": return .int(0)
        case "double", "float", "decimal": return .double(0)
        case "bool": return .bool(false)
        case "char": return .char("\0")
        default: return .unit
        }
    }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        guard let typeName else { return value }
        if ["double", "float", "decimal"].contains(typeName), case .int(let number) = value.forced {
            return .double(Double(number))
        }
        return value
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        toStringInterpreter = interpreter
        if op == "+" {
            if case .string = lhs.forced { return .string(display(lhs) + display(rhs)) }
            if case .string = rhs.forced { return .string(display(lhs) + display(rhs)) }
        }
        if case .char(let left) = lhs.forced, rhs.asInt != nil, op.count == 1,
           "+-*/%".contains(op) {
            let leftValue = Int64(left.unicodeScalars.first?.value ?? 0)
            return try MLOperations.arithmetic(op: op, lhs: .int(leftValue), rhs: rhs,
                                               semantics: self)
        }
        return nil
    }

    /// C# の 0 除算は `DivideByZeroException`。
    override func divideIntegers(_ lhs: Int64, _ rhs: Int64) throws -> MLValue {
        guard rhs != 0 else {
            throw MLError.thrown(.object(CSharpLibrary.exception(
                "DivideByZeroException", "Attempted to divide by zero.")))
        }
        return .int(lhs / rhs)
    }

    override func moduloIntegers(_ lhs: Int64, _ rhs: Int64) throws -> MLValue {
        guard rhs != 0 else {
            throw MLError.thrown(.object(CSharpLibrary.exception(
                "DivideByZeroException", "Attempted to divide by zero.")))
        }
        return .int(lhs % rhs)
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        toStringInterpreter = interpreter
        CSharpLibrary.install(into: environment, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        switch name {
        case "Length", "Count":
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let map = value.asMap { return .int(Int64(map.count)) }
            if let text = value.asString { return .int(Int64(text.count)) }
        case "Keys":
            if let map = value.asMap { return .array(MLArray(map.keys.map { $0.asValue })) }
        case "Values":
            if let map = value.asMap { return .array(MLArray(map.values)) }
        default:
            break
        }
        return nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try CSharpLibrary.method(on: value, name: name, context: context, semantics: self)
    }
}
