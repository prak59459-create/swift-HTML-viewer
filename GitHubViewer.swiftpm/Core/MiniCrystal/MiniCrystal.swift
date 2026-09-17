import Foundation

/// 内蔵の Crystal 処理系。
///
/// Ruby によく似た文法を持つ静的型付け言語。型注釈は読み飛ばし、
/// Ruby 風のブロック・シンボル・メソッド呼び出しを再現している。
public enum MiniCrystal: MiniLangEngine {
    public static var languageID: String { "crystal" }
    public static var displayName: String { "内蔵 Crystal 処理系" }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = CrystalLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = CrystalParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: CrystalSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum CrystalProfile {
    static let keywords: Set<String> = [
        "abstract", "alias", "as", "begin", "break", "case", "class", "def", "do",
        "else", "elsif", "end", "ensure", "enum", "extend", "false", "for", "fun",
        "if", "include", "instance_sizeof", "is_a?", "lib", "macro", "module", "next",
        "nil", "of", "out", "pointerof", "private", "protected", "require", "rescue",
        "return", "select", "self", "sizeof", "struct", "super", "then", "true", "type",
        "typeof", "uninitialized", "union", "unless", "until", "when", "while", "with",
        "yield", "property", "getter", "setter", "in"
    ]

    static let profile = MLLanguageProfile(
        languageID: "crystal",
        comments: [.line("#")],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", interpolationPrefix: "#{",
                                                isMultiline: false),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators + ["<=>", "===", "=~", "**", "..",
                                                        "...", "->", "&.", "||=", "&&="],
        newlineTerminatesStatement: true,
        usesSemicolons: true,
        identifierExtras: ["?", "!"],
        functionSyntax: .keyword,
        functionKeywords: ["def"],
        variableKeywords: [:],
        typeKeywords: ["class": .classType, "struct": .structType, "module": .moduleType,
                       "enum": .enumType],
        ignorableModifiers: ["private", "protected", "abstract", "@"],
        nullLiterals: ["nil"],
        selfKeywords: ["self"])
}

final class CrystalLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: CrystalProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        let start = location
        // `@name` はインスタンス変数、`@@name` はクラス変数。
        if peek() == "@" {
            var prefix = "@"
            advance()
            if peek() == "@" {
                prefix += "@"
                advance()
            }
            if let next = peek(), MLLexerBase.isIdentifierStart(next) {
                let name = readIdentifier(extraCharacters: ["?", "!"])
                return MLToken(kind: .identifier, text: prefix + name, location: start)
            }
            return MLToken(kind: .punctuation, text: prefix, location: start)
        }
        // `:name` はシンボル。
        if peek() == ":", let next = peek(1), MLLexerBase.isIdentifierStart(next) {
            advance()
            let name = readIdentifier(extraCharacters: ["?", "!"])
            return MLToken(kind: .symbol, text: name, location: start)
        }
        return super.nextToken()
    }
}

final class CrystalParser: MLEndBlockParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: CrystalProfile.profile, diagnostics: diagnostics)
    }

    override var blockTerminators: Set<String> { ["end"] }
    override var branchKeywords: Set<String> { ["else", "elsif"] }
    override var thenKeywords: Set<String> { ["then"] }
    override var blockOpener: String? { nil }
    override var supportsIfExpression: Bool { true }
    override var hasIncrementOperators: Bool { false }
    override var memberAccessOperators: [String] { [".", "&."] }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            if check("require") || check("include") || check("extend") {
                skipToStatementEnd()
                continue
            }
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

        if check("require") || check("include") || check("extend") || check("alias") {
            skipToStatementEnd()
            return .noop(location)
        }
        if check("def") { return .funcDecl(try parseCrystalMethod()) }
        if check("unless") {
            advance()
            let condition = try parseExpression(stopAtBrace: true)
            _ = match("then")
            let body = try parseStatements(until: ["else", "end"])
            var otherwise: [MLStmt]?
            if match("else") { otherwise = try parseStatements(until: ["end"]) }
            _ = match("end")
            return .ifStmt(condition: .unary(op: "!", operand: condition, isPostfix: false,
                                             location),
                           then: body, otherwise: otherwise, location)
        }
        if check("until") {
            advance()
            let condition = try parseExpression(stopAtBrace: true)
            _ = match("do")
            let body = try parseBlock()
            return .whileStmt(condition: .unary(op: "!", operand: condition,
                                                isPostfix: false, location),
                              body: body, label: nil, location)
        }
        if check("case") { return try parseCase() }
        if check("next") {
            advance()
            consumeStatementEnd()
            return .continueStmt(label: nil, location)
        }
        if check("begin") {
            advance()
            let body = try parseStatements(until: ["rescue", "ensure", "end"])
            if check("rescue") || check("ensure") {
                return try finishRescue(body: body, location: location)
            }
            _ = match("end")
            return .block(body, location)
        }
        if let kind = matchedTypeKeyword() {
            return .typeDecl(try parseCrystalType(kind: kind))
        }

        // 括弧を省いた呼び出し (`puts "x"` / `raise "boom"`)。
        if let command = try parseCommandCall() {
            return try applyModifiers(to: command, location: location)
        }

        // 後置の修飾子 (`puts x if cond`) に対応する。
        let statement = try super.parseStatement()
        return try applyModifiers(to: statement, location: location)
    }

    /// 文の先頭にある括弧なし呼び出し。
    private func parseCommandCall() throws -> MLStmt? {
        guard current.kind == .identifier else { return nil }
        guard !CrystalParser.notCommands.contains(current.text) else { return nil }
        let next = peek(1)
        // 引数のない `puts` は改行だけを出す。
        if CrystalParser.zeroArgumentCommands.contains(current.text),
           next.precededByNewline || next.is(";") || next.isEndOfFile {
            let location = advance().location
            consumeStatementEnd()
            return .expression(.call(callee: .name("puts", location), arguments: [],
                                     location), location)
        }
        guard !next.precededByNewline else { return nil }
        let startsArgument: Bool
        switch next.kind {
        case .stringLiteral, .interpolatedString, .integerLiteral, .floatLiteral,
             .charLiteral:
            startsArgument = true
        case .identifier:
            // `a b` は呼び出し。`x = 1` などは別の分岐で拾う。
            startsArgument = true
        case .keyword:
            startsArgument = ["true", "false", "nil", "self"].contains(next.text)
        case .punctuation:
            // `@ivar` や `:symbol` は引数になりうる。`x + 1` などは違う。
            startsArgument = next.text == "@" || next.text == ":"
        default:
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
            var call = MLExpr.call(callee: .name(name, location), arguments: arguments,
                                   location)
            // `xs.each do |x| ... end` のように後ろにブロックが続くこともある。
            if check("do") || (check("{") && !current.precededByNewline) {
                let closure = try parseTrailingClosure()
                call = .call(callee: .name(name, location),
                             arguments: arguments + [MLArgument(value: closure)], location)
            }
            return .expression(call, location)
        } catch {
            index = saved
            return nil
        }
    }

    /// 演算子としても定義できるメソッド名。
    static let operatorMethodNames: Set<String> = [
        "+", "-", "*", "/", "//", "%", "**", "==", "!=", "<", "<=", ">", ">=", "<=>",
        "===", "<<", ">>", "&", "|", "^", "~", "!", "[]", "[]="
    ]

    /// `def` のあとのメソッド名 (演算子も名前になる)。
    private func parseMethodName() throws -> String {
        if current.kind == .identifier { return advance().text }
        if check("[") {
            advance()
            try expect("]", "添字メソッド名")
            if check("="), !peek(1).is("=") {
                advance()
                return "[]="
            }
            return "[]"
        }
        if CrystalParser.operatorMethodNames.contains(current.text) {
            return advance().text
        }
        return try expectIdentifier("メソッド名")
    }

    /// 引数なしでも呼び出しになる命令。
    private static let zeroArgumentCommands: Set<String> = ["puts"]

    /// 呼び出しに見えても呼び出しではない語。
    private static let notCommands: Set<String> = [
        "end", "then", "do", "else", "elsif", "when", "rescue", "ensure"
    ]

    /// `expr if cond` / `expr unless cond` / `expr while cond`
    private func applyModifiers(to statement: MLStmt?,
                                location: SourceLocation) throws -> MLStmt? {
        guard var result = statement else { return nil }
        while !isAtEnd, !current.precededByNewline {
            if check("if") {
                advance()
                let condition = try parseExpression()
                result = .ifStmt(condition: condition, then: [result], otherwise: nil,
                                 location)
                continue
            }
            if check("unless") {
                advance()
                let condition = try parseExpression()
                result = .ifStmt(condition: .unary(op: "!", operand: condition,
                                                   isPostfix: false, location),
                                 then: [result], otherwise: nil, location)
                continue
            }
            if check("while") {
                advance()
                let condition = try parseExpression()
                result = .whileStmt(condition: condition, body: [result], label: nil,
                                    location)
                continue
            }
            break
        }
        consumeStatementEnd()
        return result
    }

    /// `def name(args) ... end`
    private func parseCrystalMethod() throws -> MLFunctionDecl {
        let location = current.location
        try expect("def", "メソッド定義")
        var isStatic = false
        if check("self"), peek(1).is(".") {
            advance()
            advance()
            isStatic = true
        }
        var name = try parseMethodName()
        // 代入メソッド (`def name=(value)`)。
        if check("=") , !peek(1).is("=") , !current.precededByNewline,
           !CrystalParser.operatorMethodNames.contains(name) {
            advance()
            name += "="
        }
        var parameters: [MLParameter] = []
        /// `def initialize(@name)` は、そのまま `@name` に入れる短縮形。
        var fieldAssignments: [MLStmt] = []
        if check("(") {
            advance()
            while !isAtEnd, !check(")") {
                var isVariadic = false
                if match("*") { isVariadic = true }
                var parameterName = try expectIdentifier("引数名")
                if parameterName.hasPrefix("@") {
                    let field = String(parameterName.dropFirst())
                    parameterName = field
                    fieldAssignments.append(
                        .expression(.assign(op: "=",
                                            target: .member(.selfRef(location), field,
                                                            isOptional: false, location),
                                            value: .name(field, location), location),
                                    location))
                }
                if match(":") { _ = try? parseCrystalTypeName() }
                var defaultValue: MLExpr?
                if match("=") { defaultValue = try parseExpression() }
                parameters.append(MLParameter(name: parameterName,
                                              defaultValue: defaultValue,
                                              isVariadic: isVariadic))
                if !match(",") { break }
            }
            try expect(")", "引数の終わり")
        }
        if match(":") { _ = try? parseCrystalTypeName() }
        let body = fieldAssignments + (try parseStatements(until: ["end", "rescue",
                                                                  "ensure"]))
        if check("rescue") || check("ensure") {
            let wrapped = try finishRescue(body: body, location: location)
            return MLFunctionDecl(name: name, parameters: parameters, body: [wrapped],
                                  isStatic: isStatic,
                                  isInitializer: name == "initialize", location: location)
        }
        _ = match("end")
        return MLFunctionDecl(name: name, parameters: parameters, body: body,
                              isStatic: isStatic, isInitializer: name == "initialize",
                              location: location)
    }

    private func finishRescue(body: [MLStmt], location: SourceLocation) throws -> MLStmt {
        var catches: [MLCatchClause] = []
        var finallyBody: [MLStmt]?
        while check("rescue") {
            advance()
            var binding: String?
            var typeName: String?
            if current.kind == .identifier, !current.precededByNewline {
                binding = advance().text
                if match(":") { typeName = try? parseCrystalTypeName() }
            }
            let clauseBody = try parseStatements(until: ["rescue", "ensure", "end"])
            catches.append(MLCatchClause(typeName: typeName, binding: binding,
                                         body: clauseBody))
        }
        if check("ensure") {
            advance()
            finallyBody = try parseStatements(until: ["end"])
        }
        _ = match("end")
        return .tryStmt(body: body, catches: catches, finallyBody: finallyBody, location)
    }

    /// `case x when 1 then ... else ... end`
    private func parseCase() throws -> MLStmt {
        let location = current.location
        try expect("case")
        let subject = check("when") ? MLExpr.literal(.bool(true), location)
                                    : try parseExpression(stopAtBrace: true)
        var arms: [MLMatchArm] = []
        while !isAtEnd, !check("end") {
            skipStatementSeparators()
            if check("end") { break }
            if check("else") {
                advance()
                arms.append(MLMatchArm(patterns: [], body: try parseStatements(until: ["end"]),
                                       isDefault: true))
                break
            }
            try expect("when", "case の分岐")
            var patterns: [MLPattern] = []
            repeat {
                if check("then") { break }
                let expression = try parseExpression(stopAtBrace: true)
                if case .literal(let value, _) = expression { patterns.append(.literal(value)) }
                else { patterns.append(.expression(expression)) }
            } while match(",")
            _ = match("then")
            arms.append(MLMatchArm(patterns: patterns,
                                   body: try parseStatements(until: ["when", "else", "end"])))
        }
        _ = match("end")
        return .matchStmt(subject: subject, arms: arms, label: nil, location)
    }

    /// `class Foo < Bar ... end`
    private func parseCrystalType(kind: MLTypeDecl.Kind) throws -> MLTypeDecl {
        let location = current.location
        while profile.ignorableModifiers.contains(current.text) { advance() }
        advance()   // class / struct / module / enum
        let name = try expectIdentifier("型名")
        var superclassName: String?
        if match("<") { superclassName = try expectIdentifier("親クラス名") }

        var properties: [MLPropertyDecl] = []
        var methods: [MLFunctionDecl] = []
        var initializers: [MLFunctionDecl] = []
        var cases: [MLCaseDecl] = []

        while !isAtEnd, !check("end") {
            skipStatementSeparators()
            if check("end") { break }
            while profile.ignorableModifiers.contains(current.text), current.text != "@" {
                advance()
            }
            if check("def") {
                let method = try parseCrystalMethod()
                if method.isInitializer { initializers.append(method) }
                else { methods.append(method) }
                continue
            }
            // `property x : Int32` / `getter y` は自動のアクセサ。
            if check("property") || check("getter") || check("setter") {
                advance()
                repeat {
                    guard current.kind == .identifier || current.kind == .symbol else { break }
                    let fieldName = advance().text
                    if match(":") { _ = try? parseCrystalTypeName() }
                    var defaultValue: MLExpr?
                    if match("=") { defaultValue = try parseExpression() }
                    properties.append(MLPropertyDecl(name: fieldName,
                                                     defaultValue: defaultValue))
                } while match(",")
                consumeStatementEnd()
                continue
            }
            if kind == .enumType, current.kind == .identifier {
                let caseName = advance().text
                var rawValue: MLExpr?
                if match("=") { rawValue = try parseExpression() }
                cases.append(MLCaseDecl(name: caseName, rawValue: rawValue))
                consumeStatementEnd()
                continue
            }
            // `@x : Int32` のようなインスタンス変数の宣言。
            if current.kind == .identifier, current.text.hasPrefix("@") {
                let fieldName = String(advance().text.dropFirst())
                if match(":") { _ = try? parseCrystalTypeName() }
                var defaultValue: MLExpr?
                if match("=") { defaultValue = try parseExpression() }
                properties.append(MLPropertyDecl(name: fieldName, defaultValue: defaultValue))
                consumeStatementEnd()
                continue
            }
            let before = index
            _ = try parseStatement()
            if index == before { advance() }
        }
        _ = match("end")
        return MLTypeDecl(kind: kind == .moduleType ? .classType : kind, name: name,
                          superclassName: superclassName, properties: properties,
                          methods: methods, initializers: initializers, cases: cases,
                          location: location)
    }

    private func parseCrystalTypeName() throws -> String {
        guard current.kind == .identifier || current.kind == .keyword else { return "Any" }
        var text = advance().text
        if check("(") { skipBalanced(open: "(", close: ")") }
        while check("::"), peek(1).kind == .identifier {
            advance()
            text = advance().text
        }
        while match("?") {}
        while check("|") , peek(1).kind == .identifier {
            advance()
            _ = advance()
        }
        return text
    }

    override func parseTypeName() throws -> String {
        try parseCrystalTypeName()
    }

    /// `[1, 2, 3]` と `{"a" => 1}` と `{1, 2}` (タプル)。
    override func parseBraceLiteral() throws -> MLExpr {
        let location = current.location
        try expect("{", "リテラル")
        if check("}") {
            advance()
            return .mapLiteral([], location)
        }
        let first = try parseExpression()
        if match("=>") {
            var pairs: [(key: MLExpr, value: MLExpr)] = [(key: first,
                                                          value: try parseExpression())]
            while match(",") {
                if check("}") { break }
                let key = try parseExpression()
                try expect("=>", "Hash リテラル")
                pairs.append((key: key, value: try parseExpression()))
            }
            _ = match("of")
            try expect("}", "Hash リテラルの終わり")
            return .mapLiteral(pairs, location)
        }
        var items: [MLExpr] = [first]
        while match(",") {
            if check("}") { break }
            items.append(try parseExpression())
        }
        try expect("}", "タプルの終わり")
        return .tupleLiteral(items, location)
    }

    override func parseListOrMapLiteral() throws -> MLExpr {
        let location = current.location
        try expect("[", "配列リテラル")
        var items: [MLExpr] = []
        while !isAtEnd, !check("]") {
            skipStatementSeparators()
            if check("]") { break }
            items.append(try parseExpression())
            if !match(",") { break }
        }
        skipStatementSeparators()
        try expect("]", "配列リテラルの終わり")
        // `[] of Int32` の型注釈は読み飛ばす。
        if match("of") { _ = try? parseCrystalTypeName() }
        return .listLiteral(items, spreadIndices: [], location)
    }

    /// Ruby 風のブロック `xs.each do |x| ... end` / `xs.map { |x| x * 2 }`
    override func allowsTrailingClosure(after expression: MLExpr) -> Bool { true }

    override func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        var expression = CrystalParser.rewritingNew(try super.parsePostfix(
            stopAtBrace: stopAtBrace))
        // `do |x| ... end` のブロック。
        while check("do"), !stopAtBrace {
            let location = advance().location
            let closure = try parseBlockBody(terminator: "end")
            if case .call(let callee, let arguments, let callLocation) = expression {
                expression = .call(callee: callee,
                                   arguments: arguments + [MLArgument(value: closure)],
                                   callLocation)
            } else {
                expression = .call(callee: expression,
                                   arguments: [MLArgument(value: closure)], location)
            }
        }
        return expression
    }

    override func parseTrailingClosure() throws -> MLExpr {
        try expect("{", "ブロック")
        return try parseBlockBody(terminator: "}")
    }

    /// `Point.new(1, 2)` を生成式に直す (呼び出しの連なりの奥まで見る)。
    static func rewritingNew(_ expression: MLExpr) -> MLExpr {
        switch expression {
        case .call(let callee, let arguments, let location):
            if case .member(let receiver, "new", _, _) = callee,
               case .name(let typeName, _) = receiver,
               let first = typeName.first, first.isUppercase {
                return .construct(typeName: typeName, arguments: arguments, location)
            }
            return .call(callee: rewritingNew(callee), arguments: arguments, location)
        case .member(let receiver, let name, let isOptional, let location):
            return .member(rewritingNew(receiver), name, isOptional: isOptional, location)
        case .subscriptExpr(let receiver, let index, let upper, let location):
            return .subscriptExpr(rewritingNew(receiver), index: index, upper: upper,
                                  location)
        default:
            return expression
        }
    }

    private func parseBlockBody(terminator: String) throws -> MLExpr {
        let location = current.location
        var parameters: [MLParameter] = []
        if match("|") {
            while !isAtEnd, !check("|") {
                let name = try expectIdentifier("ブロックの引数")
                parameters.append(MLParameter(name: name))
                if !match(",") { break }
            }
            try expect("|", "ブロックの引数")
        }
        let body = try parseStatements(until: [terminator])
        _ = match(terminator)
        return .lambda(MLFunctionDecl(name: "", parameters: parameters, body: body,
                                      location: location), location)
    }

    /// `x.is_a?(Int32)` / `->(x) { }`
    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if let token = matchKind(.symbol) {
            return .literal(.symbol(token.text), location)
        }
        // `@name` / `@@name` は自分自身のフィールド。
        if current.kind == .identifier, current.text.hasPrefix("@") {
            let field = String(advance().text.drop(while: { $0 == "@" }))
            return .member(.selfRef(location), field, isOptional: false, location)
        }
        if check("->") {
            advance()
            var parameters: [MLParameter] = []
            if match("(") {
                while !isAtEnd, !check(")") {
                    let name = try expectIdentifier("引数名")
                    if match(":") { _ = try? parseCrystalTypeName() }
                    parameters.append(MLParameter(name: name))
                    if !match(",") { break }
                }
                try expect(")", "引数の終わり")
            }
            if match(":") { _ = try? parseCrystalTypeName() }
            if check("{") {
                advance()
                let body = try parseStatements(until: ["}"])
                _ = match("}")
                return .lambda(MLFunctionDecl(name: "", parameters: parameters, body: body,
                                              location: location), location)
            }
            let body = try parseStatements(until: ["end"])
            _ = match("end")
            return .lambda(MLFunctionDecl(name: "", parameters: parameters, body: body,
                                          location: location), location)
        }
        if check("if") { return try parseIfExpression() }
        if check("case") {
            let statement = try parseCase()
            guard case .matchStmt(let subject, let arms, _, _) = statement else {
                return .block([statement], location)
            }
            return .match(subject: subject, arms: arms, location)
        }
        // 添字の中の `-1` は末尾からの位置なので、そのまま通す。
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    override func precedence(of op: String) -> Int? {
        if op == "<=>" || op == "===" { return 7 }
        if op == "**" { return 15 }
        return super.precedence(of: op)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        CrystalLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        CrystalParser(tokens: tokens, diagnostics: diagnostics)
    }
}
