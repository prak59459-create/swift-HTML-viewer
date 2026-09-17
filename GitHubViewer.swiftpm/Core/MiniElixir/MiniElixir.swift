import Foundation

/// 内蔵の Elixir 処理系。
///
/// `do` … `end` でブロックを閉じるので `MLEndBlockParser` を土台にしている。
/// パターンで分かれる複数の関数節、パイプ演算子、アトム・タプル・マップに
/// 対応する。
public enum MiniElixir: MiniLangEngine {
    public static var languageID: String { "elixir" }
    public static var displayName: String { "内蔵 Elixir 処理系" }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = ElixirLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = ElixirParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: ElixirSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum ElixirProfile {
    static let keywords: Set<String> = [
        "def", "defp", "defmodule", "defstruct", "defmacro", "do", "end", "fn", "if",
        "unless", "else", "case", "cond", "when", "and", "or", "not", "in", "nil",
        "true", "false", "receive", "after", "rescue", "catch", "try", "raise", "import",
        "alias", "require", "use", "for", "with", "quote", "unquote", "__MODULE__"
    ]

    static let profile = MLLanguageProfile(
        languageID: "elixir",
        comments: [.line("#")],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", interpolationPrefix: "#{",
                                                isMultiline: true),
                  MLLanguageProfile.StringStyle(quote: "'", interpolationPrefix: "#{")],
        keywords: keywords,
        operators: ["|>", "<>", "===", "!==", "++", "--", "..", "=~", "->", "=>", "<-",
                    "==", "!=", "<=", ">=", "&&", "||", "//", "::", "&",
                    "+", "-", "*", "/", "=", "<", ">", "!", "|", "^", "~",
                    "?", ":", ";", ",", ".", "(", ")", "[", "]", "{", "}", "%", "@"],
        newlineTerminatesStatement: true,
        usesSemicolons: true,
        identifierExtras: ["?", "!"],
        functionSyntax: .keyword,
        functionKeywords: ["def", "defp"],
        variableKeywords: [:],
        typeKeywords: [:],
        ignorableModifiers: [],
        lambdaArrows: ["->"],
        nullLiterals: ["nil"],
        selfKeywords: [],
        assignmentOperators: ["="])
}

final class ElixirLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: ElixirProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        let start = location
        // `:atom` / `:"quoted atom"`
        if peek() == ":", let next = peek(1) {
            if MLLexerBase.isIdentifierStart(next) {
                advance()
                let name = readIdentifier(extraCharacters: ["?", "!"])
                return MLToken(kind: .symbol, text: name, location: start)
            }
            if next == "\"" {
                advance()
                advance()
                var name = ""
                while let character = peek(), character != "\"" {
                    name.append(character)
                    advance()
                }
                advance()
                return MLToken(kind: .symbol, text: name, location: start)
            }
        }
        // `&1` のような捕捉引数は `_1` という名前にする。
        if peek() == "&", let next = peek(1), next.isNumber {
            advance()
            var digits = ""
            while let character = peek(), character.isNumber {
                digits.append(character)
                advance()
            }
            return MLToken(kind: .identifier, text: "_" + digits, location: start)
        }
        // `@attribute` はモジュール属性 (定数として扱う)。
        if peek() == "@", let next = peek(1), MLLexerBase.isIdentifierStart(next) {
            advance()
            let name = readIdentifier()
            return MLToken(kind: .identifier, text: "@" + name, location: start)
        }
        return super.nextToken()
    }
}

final class ElixirParser: MLEndBlockParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: ElixirProfile.profile, diagnostics: diagnostics)
    }

    override var blockTerminators: Set<String> { ["end"] }
    override var branchKeywords: Set<String> { ["else"] }
    override var thenKeywords: Set<String> { ["do"] }
    override var blockOpener: String? { "do" }
    override var supportsIfExpression: Bool { true }
    override var hasIncrementOperators: Bool { false }
    override var memberAccessOperators: [String] { ["."] }

    // MARK: 文

    override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location

        if check("import") || check("alias") || check("require") || check("use") {
            skipToStatementEnd()
            return .noop(location)
        }
        if check("defmodule") { return .typeDecl(try parseModule()) }
        if check("def") || check("defp") { return .funcDecl(try parseFunction()) }
        if check("defstruct") {
            skipToStatementEnd()
            return .noop(location)
        }
        if check("if") || check("unless") { return try parseElixirIf() }
        if check("case") {
            let expression = try parseCase()
            return .expression(expression, location)
        }
        if check("cond") {
            let expression = try parseCond()
            return .expression(expression, location)
        }
        if check("for") {
            let expression = try parseComprehension()
            return .expression(expression, location)
        }
        if check("try") { return try parseElixirTry() }
        if check("raise") {
            advance()
            let value = try parseExpression(stopAtBrace: true)
            consumeStatementEnd()
            return .throwStmt(value, location)
        }

        let expression = try parseExpression()
        consumeStatementEnd()
        return .expression(expression, location)
    }

    /// `defmodule Name do ... end`
    private func parseModule() throws -> MLTypeDecl {
        let location = current.location
        try expect("defmodule", "モジュール")
        var name = try expectIdentifier("モジュール名")
        while match(".") { name += "." + (try expectIdentifier("モジュール名")) }
        _ = match("do")

        var methods: [MLFunctionDecl] = []
        var properties: [MLPropertyDecl] = []
        var nested: [MLTypeDecl] = []
        while !isAtEnd, !check("end") {
            skipStatementSeparators()
            if check("end") { break }
            if check("def") || check("defp") {
                let decl = try parseFunction()
                // 同じ名前の節はひとまとめにする (パターンで選び分けるため)。
                if let existing = methods.first(where: { $0.name == decl.name }) {
                    existing.clauses.append(contentsOf: decl.clauses)
                } else {
                    methods.append(decl)
                }
                continue
            }
            if check("defmodule") {
                nested.append(try parseModule())
                continue
            }
            if current.kind == .identifier, current.text.hasPrefix("@"),
               !peek(1).precededByNewline {
                let attribute = String(advance().text.dropFirst())
                let value = try parseExpression(stopAtBrace: true)
                properties.append(MLPropertyDecl(name: attribute, defaultValue: value,
                                                 isConstant: true, isStatic: true))
                consumeStatementEnd()
                continue
            }
            let before = index
            if try parseStatement() != nil { }
            if index == before { advance() }
        }
        _ = match("end")
        // モジュールの関数はすべて静的メソッドにする。
        let staticMethods = methods.map { decl in
            MLFunctionDecl(name: decl.name, clauses: decl.clauses,
                           returnTypeName: decl.returnTypeName, isStatic: true,
                           location: decl.location)
        }
        return MLTypeDecl(kind: .moduleType, name: name, properties: properties,
                          methods: staticMethods, nestedTypes: nested, location: location)
    }

    /// `def name(args) do ... end` と `def name(args), do: expr`
    private func parseFunction() throws -> MLFunctionDecl {
        let location = current.location
        advance()   // def / defp
        let name = try expectIdentifier("関数名")
        var parameters: [MLParameter] = []
        if match("(") {
            while !isAtEnd, !check(")") {
                parameters.append(try parseElixirParameter())
                if !match(",") { break }
            }
            try expect(")", "引数の終わり")
        }
        var guardCondition: MLExpr?
        if match("when") { guardCondition = try parseExpression(stopAtBrace: true) }

        var body: [MLStmt]
        if match(",") {
            try expect("do", "do:")
            try expect(":", "do:")
            let value = try parseExpression()
            body = [.returnStmt(value, location)]
            consumeStatementEnd()
        } else {
            _ = match("do")
            body = try parseStatements(until: ["end", "rescue", "after"])
            if check("rescue") || check("after") {
                body = [try finishRescue(body: body, location: location)]
            }
            _ = match("end")
            body = liftedReturn(body)
        }
        return MLFunctionDecl(name: name,
                              clauses: [MLFunctionClause(parameters: parameters,
                                                         guardCondition: guardCondition,
                                                         body: body)],
                              location: location)
    }

    /// 引数はパターンでも書ける (`def fact(0)`)。
    private func parseElixirParameter() throws -> MLParameter {
        let pattern = try parsePattern()
        if case .binding(let name) = pattern {
            var defaultValue: MLExpr?
            if match("\\\\") || match("\\") { defaultValue = try parseExpression() }
            return MLParameter(name: name, defaultValue: defaultValue)
        }
        return MLParameter(name: "", pattern: pattern)
    }

    private func finishRescue(body: [MLStmt], location: SourceLocation) throws -> MLStmt {
        var catches: [MLCatchClause] = []
        var finallyBody: [MLStmt]?
        if match("rescue") {
            var binding: String?
            if current.kind == .identifier, peek(1).is("->") {
                binding = advance().text
                advance()
            }
            catches.append(MLCatchClause(binding: binding,
                                         body: try parseStatements(until: ["after", "end"])))
        }
        if match("after") { finallyBody = try parseStatements(until: ["end"]) }
        return .tryStmt(body: body, catches: catches, finallyBody: finallyBody, location)
    }

    private func parseElixirIf() throws -> MLStmt {
        let location = current.location
        let isUnless = check("unless")
        advance()
        var condition = try parseExpression(stopAtBrace: true)
        if isUnless {
            condition = .unary(op: "!", operand: condition, isPostfix: false, location)
        }
        // `if x, do: a, else: b`
        if match(",") {
            try expect("do", "do:")
            try expect(":", "do:")
            let then = try parseExpression()
            var otherwise: [MLStmt]?
            if match(",") {
                try expect("else", "else:")
                try expect(":", "else:")
                otherwise = [.expression(try parseExpression(), location)]
            }
            consumeStatementEnd()
            return .ifStmt(condition: condition, then: [.expression(then, location)],
                           otherwise: otherwise, location)
        }
        _ = match("do")
        let then = try parseStatements(until: ["else", "end"])
        var otherwise: [MLStmt]?
        if match("else") { otherwise = try parseStatements(until: ["end"]) }
        _ = match("end")
        return .ifStmt(condition: condition, then: then, otherwise: otherwise, location)
    }

    override func parseIfExpression() throws -> MLExpr {
        let location = current.location
        let statement = try parseElixirIf()
        guard case .ifStmt(let condition, let then, let otherwise, _) = statement else {
            return .block([statement], location)
        }
        return .ifExpr(condition: condition, then: .block(then, location),
                       otherwise: otherwise.map { .block($0, location) }, location)
    }

    /// `case x do pattern -> body end`
    private func parseCase() throws -> MLExpr {
        let location = current.location
        try expect("case", "case 式")
        let subject = try parseExpression(stopAtBrace: true)
        _ = match("do")
        var arms: [MLMatchArm] = []
        while !isAtEnd, !check("end") {
            skipStatementSeparators()
            if check("end") { break }
            var patterns: [MLPattern] = [try parsePattern()]
            while match(",") { patterns.append(try parsePattern()) }
            var guardCondition: MLExpr?
            if match("when") { guardCondition = try parseExpression(stopAtBrace: true) }
            try expect("->", "case の分岐")
            let body = try parseArmBody()
            let isDefault = patterns.count == 1 && isWildcard(patterns[0])
            arms.append(MLMatchArm(patterns: isDefault ? [] : patterns,
                                   guardCondition: guardCondition, body: body,
                                   isDefault: isDefault))
        }
        _ = match("end")
        return .match(subject: subject, arms: arms, location)
    }

    private func isWildcard(_ pattern: MLPattern) -> Bool {
        if case .wildcard = pattern { return true }
        return false
    }

    /// `cond do cond1 -> body end`
    private func parseCond() throws -> MLExpr {
        let location = current.location
        try expect("cond", "cond 式")
        _ = match("do")
        var branches: [(MLExpr, [MLStmt])] = []
        while !isAtEnd, !check("end") {
            skipStatementSeparators()
            if check("end") { break }
            let condition = try parseExpression(stopAtBrace: true)
            try expect("->", "cond の分岐")
            branches.append((condition, try parseArmBody()))
        }
        _ = match("end")

        var result = MLExpr.literal(.unit, location)
        for (condition, body) in branches.reversed() {
            result = .ifExpr(condition: condition, then: .block(body, location),
                             otherwise: result, location)
        }
        return result
    }

    /// 分岐の本体 (次の分岐か `end` まで)。
    private func parseArmBody() throws -> [MLStmt] {
        var body: [MLStmt] = []
        while !isAtEnd, !check("end") {
            skipStatementSeparators()
            if isAtEnd || check("end") { break }
            if startsNewArm() { break }
            let before = index
            if let statement = try parseStatement() { body.append(statement) }
            if index == before { advance() }
        }
        return body
    }

    /// 次の分岐が始まるところか (`pattern ->` を先読みする)。
    private func startsNewArm() -> Bool {
        guard current.precededByNewline else { return false }
        var cursor = index
        var depth = 0
        while cursor < tokens.count {
            let token = tokens[cursor]
            if token.isEndOfFile { return false }
            if ["(", "[", "{"].contains(token.text) { depth += 1 }
            if [")", "]", "}"].contains(token.text) { depth -= 1 }
            if depth == 0, token.text == "->" { return true }
            if depth == 0, token.text == "end" || token.text == "do" { return false }
            if cursor > index, token.precededByNewline { return false }
            cursor += 1
        }
        return false
    }

    /// `for x <- list, do: expr`
    private func parseComprehension() throws -> MLExpr {
        let location = current.location
        try expect("for", "内包表記")
        var clauses: [MLComprehension.Clause] = []
        var filters: [MLExpr] = []
        repeat {
            if check("do") { break }
            let saved = index
            if let pattern = try? parsePattern(), match("<-") {
                clauses.append(MLComprehension.Clause(pattern: pattern,
                                                      sequence: try parseExpression(
                                                        stopAtBrace: true)))
            } else {
                index = saved
                if check("do") { break }
                filters.append(try parseExpression(stopAtBrace: true))
            }
        } while match(",")

        var element = MLExpr.literal(.unit, location)
        if match("do") {
            if match(":") {
                element = try parseExpression()
            } else {
                let body = try parseStatements(until: ["end"])
                _ = match("end")
                element = .block(body, location)
            }
        }
        return .comprehension(MLComprehension(element: element, clauses: clauses,
                                              filters: filters), location)
    }

    private func parseElixirTry() throws -> MLStmt {
        let location = current.location
        try expect("try", "try 式")
        _ = match("do")
        let body = try parseStatements(until: ["rescue", "after", "end"])
        let statement = try finishRescue(body: body, location: location)
        _ = match("end")
        return statement
    }

    /// 本体の最後の式が戻り値。
    private func liftedReturn(_ body: [MLStmt]) -> [MLStmt] {
        guard case .expression(let value, let location)? = body.last else { return body }
        return body.dropLast() + [.returnStmt(value, location)]
    }

    // MARK: パターン

    /// `|` はリストの残りを表すので、選択パターンとして読まない。
    override func parsePattern() throws -> MLPattern {
        try parsePrimaryPattern()
    }

    override func parsePrimaryPattern() throws -> MLPattern {
        let location = current.location
        if let token = matchKind(.symbol) { return .literal(.symbol(token.text)) }
        if check("{") {
            advance()
            var items: [MLPattern] = []
            while !isAtEnd, !check("}") {
                items.append(try parsePattern())
                if !match(",") { break }
            }
            try expect("}", "タプルの終わり")
            return .tuple(items)
        }
        if check("[") {
            advance()
            var items: [MLPattern] = []
            var restName: String?
            while !isAtEnd, !check("]") {
                items.append(try parsePattern())
                // `[H|T]` の残りの部分。
                if match("|") {
                    restName = try expectIdentifier("残りの名前")
                    break
                }
                if !match(",") { break }
            }
            try expect("]", "リストの終わり")
            if let restName {
                return .list(items, restIndex: items.count, restName: restName)
            }
            return .list(items, restIndex: nil, restName: nil)
        }
        if check("%"), peek(1).is("{") {
            advance()
            advance()
            var pairs: [(key: MLExpr, value: MLPattern)] = []
            while !isAtEnd, !check("}") {
                let key: MLExpr
                if let token = matchKind(.symbol) {
                    key = .literal(.symbol(token.text), location)
                } else if current.kind == .identifier, peek(1).is(":") {
                    let name = advance().text
                    advance()
                    key = .literal(.symbol(name), location)
                    pairs.append((key: key, value: try parsePattern()))
                    if !match(",") { break }
                    continue
                } else {
                    key = try parseExpression(stopAtBrace: true)
                }
                _ = match("=>")
                pairs.append((key: key, value: try parsePattern()))
                if !match(",") { break }
            }
            try expect("}", "マップの終わり")
            return .map(pairs)
        }
        return try super.parsePrimaryPattern()
    }

    // MARK: 式

    override func precedence(of op: String) -> Int? {
        switch op {
        case "|>": return 6
        case "<>", "++", "--": return 12
        case "and": return 3
        case "or": return 2
        case "in": return 8
        default: return super.precedence(of: op)
        }
    }

    /// `x |> f(y)` は `f(x, y)` にする。
    override func parseBinary(minimumPrecedence: Int, stopAtBrace: Bool) throws -> MLExpr {
        var left = try super.parseBinary(minimumPrecedence: minimumPrecedence,
                                         stopAtBrace: stopAtBrace)
        left = ElixirParser.rewritingPipes(left)
        return left
    }

    /// `|>` の二項演算を呼び出しに直す。
    static func rewritingPipes(_ expression: MLExpr) -> MLExpr {
        guard case .binary(let op, let lhs, let rhs, let location) = expression,
              op == "|>" else { return expression }
        let piped = rewritingPipes(lhs)
        switch rhs {
        case .call(let callee, let arguments, let callLocation):
            return .call(callee: callee, arguments: [MLArgument(value: piped)] + arguments,
                         callLocation)
        default:
            return .call(callee: rhs, arguments: [MLArgument(value: piped)], location)
        }
    }

    /// 引数の `&` は展開ではなく捕捉なので、共通処理に任せない。
    override func parseArgument() throws -> MLArgument {
        var label: String?
        if (current.kind == .identifier || current.kind == .keyword), peek(1).is(":"),
           !peek(2).is(":"), !peek(1).precededByNewline {
            label = advance().text
            advance()
        }
        return MLArgument(label: label, value: try parseExpression())
    }

    /// `&` は捕捉の記号なので、参照演算子として読まれる前に横取りする。
    override func parseUnary(stopAtBrace: Bool) throws -> MLExpr {
        guard check("&") else { return try super.parseUnary(stopAtBrace: stopAtBrace) }
        let location = current.location
        advance()
        if check("(") {
            advance()
            let body = try parseExpression()
            try expect(")", "捕捉の終わり")
            return .lambda(MLFunctionDecl(name: "", parameters: [],
                                          body: [.returnStmt(body, location)],
                                          usesImplicitArguments: true,
                                          location: location), location)
        }
        // `&Module.fun/1` は関数そのもの。
        let target = try super.parseUnary(stopAtBrace: stopAtBrace)
        if match("/") { _ = try? parseExpression() }
        return target
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if let token = matchKind(.symbol) {
            return .literal(.symbol(token.text), location)
        }
        if check("case") { return try parseCase() }
        if check("cond") { return try parseCond() }
        if check("for") { return try parseComprehension() }
        if check("if") || check("unless") { return try parseIfExpression() }
        if check("fn") {
            advance()
            var parameters: [MLParameter] = []
            while !isAtEnd, !check("->") {
                parameters.append(try parseElixirParameter())
                if !match(",") { break }
            }
            try expect("->", "fn の本体")
            let body = try parseStatements(until: ["end"])
            _ = match("end")
            return .lambda(MLFunctionDecl(name: "", parameters: parameters,
                                          body: liftedReturn(body), location: location),
                           location)
        }
        // タプル `{1, 2}`
        if check("{") {
            advance()
            var items: [MLExpr] = []
            while !isAtEnd, !check("}") {
                skipStatementSeparators()
                if check("}") { break }
                items.append(try parseExpression())
                if !match(",") { break }
            }
            skipStatementSeparators()
            try expect("}", "タプルの終わり")
            return .tupleLiteral(items, location)
        }
        // マップ `%{a: 1}`
        if check("%"), peek(1).is("{") {
            advance()
            advance()
            var pairs: [(key: MLExpr, value: MLExpr)] = []
            while !isAtEnd, !check("}") {
                skipStatementSeparators()
                if check("}") { break }
                let key: MLExpr
                if current.kind == .identifier, peek(1).is(":") {
                    key = .literal(.symbol(advance().text), location)
                    advance()
                } else {
                    key = try parseExpression()
                    _ = match("=>")
                }
                pairs.append((key: key, value: try parseExpression()))
                if !match(",") { break }
            }
            skipStatementSeparators()
            try expect("}", "マップの終わり")
            return .mapLiteral(pairs, location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    /// `[a: 1, b: 2]` のキーワードリストはマップとして読む。
    override func parseListOrMapLiteral() throws -> MLExpr {
        let location = current.location
        try expect("[", "リスト")
        var items: [MLExpr] = []
        var pairs: [(key: MLExpr, value: MLExpr)] = []
        while !isAtEnd, !check("]") {
            skipStatementSeparators()
            if check("]") { break }
            if current.kind == .identifier, peek(1).is(":"), !peek(1).precededByNewline {
                let name = advance().text
                advance()
                pairs.append((key: .literal(.symbol(name), location),
                              value: try parseExpression()))
            } else {
                items.append(try parseExpression())
            }
            if !match(",") { break }
        }
        skipStatementSeparators()
        try expect("]", "リストの終わり")
        if !pairs.isEmpty && items.isEmpty { return .mapLiteral(pairs, location) }
        return .listLiteral(items, spreadIndices: [], location)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        ElixirLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        ElixirParser(tokens: tokens, diagnostics: diagnostics)
    }
}
