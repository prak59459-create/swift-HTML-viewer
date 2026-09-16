import Foundation

/// 内蔵の Kotlin 処理系。
public enum MiniKotlin: MiniLangEngine {
    public static var languageID: String { "kotlin" }
    public static var displayName: String { "内蔵 Kotlin 処理系" }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            executeOnCurrentThread(source: source, input: input, limits: limits)
        }
    }

    static func executeOnCurrentThread(source: String, input: String,
                                       limits: MiniLangLimits) -> MiniLangExecution {
        let diagnostics = DiagnosticBag(source: source)
        let tokens = KotlinLexer(source: source, diagnostics: diagnostics).tokenize()
        let parser = KotlinParser(tokens: tokens, diagnostics: diagnostics)
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
        let interpreter = MLInterpreter(semantics: KotlinSemantics(), limits: limits,
                                        input: input)
        return interpreter.run(program)
    }
}

// MARK: - 見た目

enum KotlinProfile {
    static let keywords: Set<String> = [
        "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if",
        "in", "interface", "is", "null", "object", "package", "return", "super", "this",
        "throw", "true", "try", "typealias", "val", "var", "when", "while", "by", "catch",
        "constructor", "delegate", "dynamic", "field", "file", "finally", "get", "import",
        "init", "param", "property", "receiver", "set", "setparam", "where", "abstract",
        "actual", "annotation", "companion", "const", "crossinline", "data", "enum",
        "expect", "external", "final", "infix", "inline", "inner", "internal", "lateinit",
        "noinline", "open", "operator", "out", "override", "private", "protected",
        "public", "reified", "sealed", "suspend", "tailrec", "vararg"
    ]

    static let profile = MLLanguageProfile(
        languageID: "kotlin",
        comments: [.line("//"), .block(open: "/*", close: "*/", nesting: true)],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", interpolationPrefix: "${",
                                                simpleVariablePrefix: "$", isMultiline: true),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators + ["?:", "!!", "==="],
        newlineTerminatesStatement: true,
        usesSemicolons: true,
        functionSyntax: .keyword,
        functionKeywords: ["fun"],
        variableKeywords: ["var": false, "val": true],
        typeKeywords: ["class": .classType, "interface": .interfaceType,
                       "enum": .enumType, "object": .classType],
        ignorableModifiers: ["public", "private", "protected", "internal", "open",
                             "final", "abstract", "sealed", "data", "inline", "infix",
                             "operator", "override", "lateinit", "const", "suspend",
                             "tailrec", "vararg", "companion", "inner", "external",
                             "annotation", "expect", "actual", "@"],
        lambdaArrows: ["->"],
        nullLiterals: ["null"],
        selfKeywords: ["this"])
}

final class KotlinLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: KotlinProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        if let character = peek(), character.isNumber {
            var token = readNumber(allowsUnderscoreSeparator: true)
            if let suffix = peek(), "lLfFuU".contains(suffix) {
                advance()
                if "fF".contains(suffix), token.kind == .integerLiteral {
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

final class KotlinParser: MLProfileParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: KotlinProfile.profile, diagnostics: diagnostics)
    }

    override func entryPointName() -> String? { "main" }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        // トップレベルに `fun main()` があればそれを開始点にする。
        let hasMain = statements.contains { statement in
            if case .funcDecl(let decl) = statement { return decl.name == "main" }
            return false
        }
        return MLProgram(statements: statements, entryPoint: hasMain ? "main" : nil)
    }

    /// Kotlin の `?:` (エルビス) は `??` と同じ扱い。
    override func precedence(of op: String) -> Int? {
        if op == "?:" { return 9 }
        if op == "===" || op == "!==" { return 7 }
        if op == "!in" { return 8 }
        if op == "downTo" || op == "until" || op == "step" || op == "to" { return 10 }
        return super.precedence(of: op)
    }

    override func parseBinary(minimumPrecedence: Int, stopAtBrace: Bool) throws -> MLExpr {
        var left = try super.parseBinary(minimumPrecedence: minimumPrecedence,
                                         stopAtBrace: stopAtBrace)
        // `1 until 10` / `10 downTo 1` / `a to b` のような中置関数。
        while current.kind == .identifier,
              ["until", "downTo", "step", "to"].contains(current.text),
              !current.precededByNewline {
            let op = advance().text
            let location = current.location
            let right = try super.parseBinary(minimumPrecedence: 11, stopAtBrace: stopAtBrace)
            switch op {
            case "until": left = .range(lower: left, upper: right, isClosed: false,
                                        step: nil, location)
            case "downTo": left = .range(lower: left, upper: right, isClosed: true,
                                         step: .literal(.int(-1), location), location)
            case "step":
                if case .range(let lower, let upper, let isClosed, _, let rangeLocation) = left {
                    left = .range(lower: lower, upper: upper, isClosed: isClosed,
                                  step: right, rangeLocation)
                }
            default: left = .tupleLiteral([left, right], location)
            }
        }
        return left
    }

    override func allowsTrailingClosure(after expression: MLExpr) -> Bool { true }

    override func parseTrailingClosure() throws -> MLExpr {
        let location = current.location
        try expect("{", "ラムダ")
        // `{ x, y -> ... }`
        var parameters: [MLParameter] = []
        let saved = index
        var offset = 0
        var depth = 0
        var hasArrow = false
        while !peek(offset).isEndOfFile {
            let text = peek(offset).text
            if text == "{" || text == "(" { depth += 1 }
            if text == "}" || text == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0, text == "->" { hasArrow = true; break }
            if depth == 0, text == ";" { break }
            if depth == 0, peek(offset).precededByNewline, offset > 0 { break }
            offset += 1
        }
        if hasArrow {
            while !check("->") {
                let name = try expectIdentifier("ラムダの引数")
                if match(":") { _ = try parseTypeName() }
                parameters.append(MLParameter(name: name))
                if !match(",") { break }
            }
            try expect("->", "ラムダ")
        } else {
            index = saved
        }
        var body: [MLStmt] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            let before = index
            if let statement = try parseStatement() { body.append(statement) }
            if index == before { advance() }
        }
        try expect("}", "ラムダの終わり")
        let decl = MLFunctionDecl(name: "", parameters: parameters, body: body,
                                  usesImplicitArguments: parameters.isEmpty, location: location)
        return .lambda(decl, location)
    }

    /// `{ ... }` が式に来たらラムダ。
    override func parseBraceLiteral() throws -> MLExpr {
        try parseTrailingClosure()
    }

    /// `when` は値も返す。
    override func parseSwitch(label: String?) throws -> MLStmt {
        let location = current.location
        try expect("when")
        var subject: MLExpr?
        if match("(") {
            subject = try parseExpression()
            try expect(")", "when の対象")
        }
        let arms = try parseWhenBody(hasSubject: subject != nil)
        return .matchStmt(subject: subject ?? .literal(.bool(true), location),
                          arms: arms, label: label, location)
    }

    private func parseWhenBody(hasSubject: Bool) throws -> [MLMatchArm] {
        try expect("{", "when の本体")
        var arms: [MLMatchArm] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            var patterns: [MLPattern] = []
            var isDefault = false
            if check("else") {
                advance()
                isDefault = true
            } else {
                repeat {
                    if hasSubject {
                        if match("in") {
                            let range = try parseExpression(stopAtBrace: true)
                            patterns.append(.expression(range))
                        } else if match("is") {
                            let typeName = try parseTypeName()
                            patterns.append(.typed(.wildcard, typeName: typeName))
                        } else {
                            patterns.append(.expression(try parseExpression(stopAtBrace: true)))
                        }
                    } else {
                        // 条件式として書く形 (`when { x > 3 -> ... }`)。
                        patterns.append(.literal(.bool(true)))
                        let condition = try parseExpression(stopAtBrace: true)
                        arms.append(MLMatchArm(patterns: [.literal(.bool(true))],
                                               guardCondition: condition,
                                               body: try parseWhenArmBody()))
                        patterns.removeAll()
                        break
                    }
                } while match(",")
            }
            if patterns.isEmpty && !isDefault { continue }
            try expect("->", "when の分岐")
            arms.append(MLMatchArm(patterns: patterns, body: try parseWhenArmBody(),
                                   isDefault: isDefault))
        }
        try expect("}", "when の終わり")
        return arms
    }

    private func parseWhenArmBody() throws -> [MLStmt] {
        if check("->") { advance() }
        if check("{") { return try parseBlock() }
        let location = current.location
        let value = try parseExpression()
        return [.expression(value, location)]
    }

    override func isForceUnwrapContext() -> Bool { check("!!") }

    override func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        var expression = try super.parsePostfix(stopAtBrace: stopAtBrace)
        while check("!!") {
            let location = advance().location
            expression = .forceUnwrap(expression, location)
        }
        return expression
    }

    /// Kotlin の関数は `fun f(x: Int): Int = expr` とも書ける。
    override func parseFunctionDeclaration() throws -> MLFunctionDecl {
        let location = current.location
        var isStatic = false
        while profile.ignorableModifiers.contains(current.text) {
            if current.text == "@" {
                advance()
                if current.kind == .identifier { advance() }
                if check("(") { skipBalanced(open: "(", close: ")") }
                continue
            }
            if current.text == "companion" { isStatic = true }
            advance()
        }
        try expect("fun", "関数宣言")
        skipGenericParameters()
        var name = try expectIdentifier("関数名")
        // 拡張関数 `fun String.shout()` は受け手を第 1 引数にする。
        var receiverName: String?
        if check(".") {
            advance()
            receiverName = name
            name = try expectIdentifier("関数名")
        }
        _ = receiverName
        skipGenericParameters()
        var parameters = try parseParameterList()
        if receiverName != nil {
            parameters.insert(MLParameter(name: "this"), at: 0)
        }
        var returnTypeName: String?
        if match(":") { returnTypeName = try parseTypeName() }
        var body: [MLStmt] = []
        if match("=") {
            let value = try parseExpression()
            body = [.returnStmt(value, value.location)]
        } else if check("{") {
            body = try parseBlock()
        }
        return MLFunctionDecl(name: name, parameters: parameters, body: body,
                              returnTypeName: returnTypeName, isStatic: isStatic,
                              location: location)
    }

    override func parseParameter() throws -> MLParameter {
        while profile.ignorableModifiers.contains(current.text) {
            if current.text == "@" {
                advance()
                if current.kind == .identifier { advance() }
                continue
            }
            advance()
        }
        var isVariadic = false
        if match("vararg") { isVariadic = true }
        // 主コンストラクタの `val` / `var`。
        _ = match("val", "var")
        let name = try expectIdentifier("引数名")
        var typeName: String?
        if match(":") { typeName = try parseTypeName() }
        var defaultValue: MLExpr?
        if match("=") { defaultValue = try parseExpression() }
        return MLParameter(label: name, name: name, typeName: typeName,
                           defaultValue: defaultValue, isVariadic: isVariadic)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        KotlinLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        KotlinParser(tokens: tokens, diagnostics: diagnostics)
    }
}

// MARK: - 振る舞い

final class KotlinSemantics: MLSemantics {
    override var languageID: String { "kotlin" }
    override var displayName: String { "内蔵 Kotlin 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { true }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        guard case .bool(let flag) = value.forced else {
            throw MLError.runtime("Boolean が必要です (\(typeName(of: value)) が渡されました)")
        }
        return flag
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
        case .bool: return "Boolean"
        case .int: return "Int"
        case .double: return "Double"
        case .char: return "Char"
        case .string: return "String"
        case .array: return "List"
        case .map: return "Map"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        MLNumberFormatting.javaStyle(value)
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return MLNumberFormatting.javaStyle(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            return "[" + array.elements.map { display($0) }.joined(separator: ", ") + "]"
        case .map(let map):
            return "{" + map.pairs.map { "\(display($0.key.asValue))=\(display($0.value))" }
                .joined(separator: ", ") + "}"
        case .tuple(let items):
            return "(" + items.map { display($0) }.joined(separator: ", ") + ")"
        case .range(let range):
            return "\(range.lower)..\(range.isClosed ? range.upper : range.upper - 1)"
        case .object(let object):
            if let caseName = object.caseName { return caseName }
            if let interpreter = toStringInterpreter,
               object.classDeclaration?.findMethod("toString") != nil,
               let result = try? interpreter.callMethod(on: value, name: "toString",
                                                        arguments: [], location: .unknown),
               let text = result.asString {
                return text
            }
            // data class は中身を見せる。
            if !object.fields.isEmpty {
                let items = object.fields.pairs.map { pair -> String in
                    let key = pair.key.asValue.asString ?? ""
                    return "\(key)=\(display(pair.value))"
                }
                return object.typeName + "(" + items.joined(separator: ", ") + ")"
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
        case "Int", "Long", "Short", "Byte": return .int(0)
        case "Double", "Float": return .double(0)
        case "Boolean": return .bool(false)
        default: return .unit
        }
    }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        if let typeName, ["Double", "Float"].contains(typeName),
           case .int(let number) = value.forced {
            return .double(Double(number))
        }
        return value
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        toStringInterpreter = interpreter
        switch op {
        case "?:":
            return lhs.isUnit ? rhs : lhs
        case "===":
            if let left = lhs.asObject, let right = rhs.asObject { return .bool(left === right) }
            if let left = lhs.asArray, let right = rhs.asArray { return .bool(left === right) }
            return .bool(areEqual(lhs, rhs))
        case "!==":
            if let left = lhs.asObject, let right = rhs.asObject { return .bool(left !== right) }
            return .bool(!areEqual(lhs, rhs))
        case "in", "!in":
            let contains: Bool
            if let array = rhs.asArray {
                contains = array.elements.contains { areEqual($0, lhs) }
            } else if let map = rhs.asMap, let key = MLKey.from(lhs) {
                contains = map.contains(key)
            } else if case .range(let range) = rhs.forced, let number = lhs.asInt {
                contains = range.isClosed ? (number >= range.lower && number <= range.upper)
                                          : (number >= range.lower && number < range.upper)
            } else if let text = rhs.asString, let needle = lhs.asString {
                contains = text.contains(needle)
            } else {
                contains = false
            }
            return .bool(op == "in" ? contains : !contains)
        case "+":
            if case .string = lhs.forced { return .string(display(lhs) + display(rhs)) }
        case "..":
            guard let low = lhs.asInt, let high = rhs.asInt else { return nil }
            return .range(MLRange(lower: low, upper: high, isClosed: true))
        default:
            break
        }
        return nil
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        toStringInterpreter = interpreter
        KotlinLibrary.install(into: environment, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        switch name {
        case "size":
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let map = value.asMap { return .int(Int64(map.count)) }
        case "length":
            if let text = value.asString { return .int(Int64(text.count)) }
        case "indices":
            if let array = value.asArray {
                return .range(MLRange(lower: 0, upper: Int64(array.count), isClosed: false))
            }
        case "lastIndex":
            if let array = value.asArray { return .int(Int64(array.count - 1)) }
        case "keys":
            if let map = value.asMap { return .array(MLArray(map.keys.map { $0.asValue })) }
        case "values":
            if let map = value.asMap { return .array(MLArray(map.values)) }
        case "first":
            if case .tuple(let items) = value.forced { return items.first ?? .unit }
        case "second":
            if case .tuple(let items) = value.forced, items.count > 1 { return items[1] }
        default:
            break
        }
        return nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try KotlinLibrary.method(on: value, name: name, context: context, semantics: self)
    }
}
