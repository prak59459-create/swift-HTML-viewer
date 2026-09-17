import Foundation

/// 内蔵の Erlang 処理系。
///
/// 大文字で始まる名前が変数、小文字で始まる名前がアトム。関数は
/// `名前(引数) -> 本体.` の形で、`;` で区切って複数の節を書ける。
public enum MiniErlang: MiniLangEngine {
    public static var languageID: String { "erlang" }
    public static var displayName: String { "内蔵 Erlang 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = ErlangLexer(source: source, diagnostics: diagnostics).tokenize()
        return try ErlangParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = ErlangLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = ErlangParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: ErlangSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum ErlangProfile {
    static let keywords: Set<String> = [
        "after", "and", "andalso", "band", "begin", "bnot", "bor", "bsl", "bsr", "bxor",
        "case", "catch", "cond", "div", "end", "fun", "if", "let", "not", "of", "or",
        "orelse", "receive", "rem", "try", "when", "xor", "maybe", "else"
    ]

    static let profile = MLLanguageProfile(
        languageID: "erlang",
        comments: [.line("%")],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", allowsEscapes: true)],
        keywords: keywords,
        operators: ["=:=", "=/=", "=<", "/=", "==", "++", "--", "->", "<-", "<=", ">=",
                    "=>", ":=",
                    "||", "::", "|", "#", "!", ">>", "<<",
                    "+", "-", "*", "/", "=", "<", ">", "?", ":", ";", ",", ".",
                    "(", ")", "[", "]", "{", "}", "_"],
        newlineTerminatesStatement: false,
        usesSemicolons: false,
        allowsNumericSeparators: true,
        functionSyntax: .keyword,
        functionKeywords: [],
        variableKeywords: [:],
        typeKeywords: [:],
        nullLiterals: [],
        trueLiterals: [],
        falseLiterals: [],
        selfKeywords: [],
        assignmentOperators: ["="])
}

final class ErlangLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: ErlangProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        // `'quoted atom'`
        if peek() == "'" {
            let start = location
            advance()
            var name = ""
            while let character = peek(), character != "'" {
                name.append(character)
                advance()
            }
            advance()
            return MLToken(kind: .symbol, text: name, location: start)
        }
        // `$a` は文字コード。
        if peek() == "$", let next = peek(1) {
            let start = location
            advance()
            advance()
            return MLToken(kind: .charLiteral, text: String(next), location: start,
                           stringValue: String(next))
        }
        return super.nextToken()
    }
}

final class ErlangParser: MLProfileParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: ErlangProfile.profile, diagnostics: diagnostics)
    }

    override var hasIncrementOperators: Bool { false }
    override var memberAccessOperators: [String] { [] }

    /// 名前が変数か (大文字か `_` で始まる)。
    private func isVariableName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return first.isUppercase || first == "_"
    }

    // MARK: プログラム

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        var declarations: [String: MLFunctionDecl] = [:]
        var order: [String] = []

        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            // `-module(x).` のような属性は読み飛ばす。
            if check("-") {
                while !isAtEnd, !check(".") { advance() }
                _ = match(".")
                continue
            }
            let before = index
            let decl = try parseFunction()
            if let existing = declarations[decl.name] {
                existing.clauses.append(contentsOf: decl.clauses)
            } else {
                declarations[decl.name] = decl
                order.append(decl.name)
            }
            if index == before { advance() }
        }

        for name in order {
            guard let decl = declarations[name] else { continue }
            statements.append(.funcDecl(decl))
        }
        // `main/0` があれば開始点にする。
        let entry = declarations["main"] != nil ? "main" : (order.first ?? nil)
        return MLProgram(statements: statements, entryPoint: entry)
    }

    /// `name(Args) [when Guard] -> Body [; ...].`
    private func parseFunction() throws -> MLFunctionDecl {
        let location = current.location
        let name = try expectIdentifier("関数名")
        var clauses: [MLFunctionClause] = []
        repeat {
            var parameters: [MLParameter] = []
            if match("(") {
                while !isAtEnd, !check(")") {
                    parameters.append(try parseErlangParameter())
                    if !match(",") { break }
                }
                try expect(")", "引数の終わり")
            }
            var guardCondition: MLExpr?
            if match("when") { guardCondition = try parseGuardSequence() }
            try expect("->", "関数の本体")
            let body = try parseBody(until: [";", "."], asReturn: true)
            clauses.append(MLFunctionClause(parameters: parameters,
                                            guardCondition: guardCondition, body: body))
            if match(";") {
                // 次の節。名前は同じはず。
                if current.kind == .identifier, peek(1).is("(") { advance() }
                continue
            }
            break
        } while true
        _ = match(".")
        return MLFunctionDecl(name: name, clauses: clauses, location: location)
    }

    private func parseErlangParameter() throws -> MLParameter {
        let pattern = try parsePattern()
        if case .binding(let name) = pattern { return MLParameter(name: name) }
        if case .wildcard = pattern { return MLParameter(name: "_") }
        return MLParameter(name: "", pattern: pattern)
    }

    /// `when A > 1, B < 2` のガード (`,` は and、`;` は or)。
    private func parseGuardSequence() throws -> MLExpr {
        var result = try parseExpression()
        while check(",") {
            let location = current.location
            advance()
            result = .binary(op: "&&", lhs: result, rhs: try parseExpression(), location)
        }
        return result
    }

    /// `,` で区切られた式の並び。最後の式が値になる。
    ///
    /// 関数の本体では最後を `return` に直すが、case や if の分岐では
    /// そのままにする (`return` にすると外側の関数まで抜けてしまう)。
    private func parseBody(until stops: Set<String>, asReturn: Bool = false) throws
        -> [MLStmt] {
        var statements: [MLStmt] = []
        while !isAtEnd {
            let location = current.location
            let expression = try parseExpression()
            statements.append(.expression(expression, location))
            if match(",") { continue }
            break
        }
        guard asReturn, case .expression(let value, let location)? = statements.last else {
            return statements
        }
        return statements.dropLast() + [.returnStmt(value, location)]
    }

    // MARK: パターン

    /// `|` はリストの残りを表すので、選択パターンとして読まない。
    override func parsePattern() throws -> MLPattern {
        try parsePrimaryPattern()
    }

    override func parsePrimaryPattern() throws -> MLPattern {
        let location = current.location
        if let token = matchKind(.symbol) { return .literal(.symbol(token.text)) }
        if check("_") {
            advance()
            return .wildcard
        }
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
        if current.kind == .identifier {
            let name = advance().text
            if isVariableName(name) {
                return name == "_" ? .wildcard : .binding(name)
            }
            // 小文字で始まる名前はアトム。
            return .literal(.symbol(name))
        }
        _ = location
        return try super.parsePrimaryPattern()
    }

    // MARK: 式

    override func precedence(of op: String) -> Int? {
        switch op {
        case "=:=", "=/=", "==", "/=": return 7
        case "=<", "<", ">", ">=": return 8
        case "++", "--": return 12
        case "andalso", "and": return 3
        case "orelse", "or": return 2
        case "div", "rem", "band": return 13
        case "bor", "bxor": return 4
        case "bsl", "bsr": return 11
        default: return super.precedence(of: op)
        }
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if let token = matchKind(.symbol) {
            return .literal(.symbol(token.text), location)
        }
        if check("case") { return try parseCase() }
        if check("if") { return try parseErlangIf() }
        if check("begin") {
            advance()
            let body = try parseBody(until: ["end"])
            _ = match("end")
            return .block(body, location)
        }
        if check("try") { return try parseErlangTry() }
        if check("fun") { return try parseFun() }
        // タプル。
        if check("{") {
            advance()
            var items: [MLExpr] = []
            while !isAtEnd, !check("}") {
                items.append(try parseExpression())
                if !match(",") { break }
            }
            try expect("}", "タプルの終わり")
            return .tupleLiteral(items, location)
        }
        // マップ `#{a => 1}`
        if check("#"), peek(1).is("{") {
            advance()
            advance()
            var pairs: [(key: MLExpr, value: MLExpr)] = []
            while !isAtEnd, !check("}") {
                let key = try parseExpression()
                _ = match("=>") || match(":=")
                pairs.append((key: key, value: try parseExpression()))
                if !match(",") { break }
            }
            try expect("}", "マップの終わり")
            return .mapLiteral(pairs, location)
        }
        // 識別子: 変数・アトム・関数呼び出し・モジュール呼び出し。
        if current.kind == .identifier {
            let name = advance().text
            if isVariableName(name) { return .name(name, location) }
            // `module:function(...)`
            if match(":") {
                let function = try expectIdentifier("関数名")
                var arguments: [MLArgument] = []
                if check("(") { arguments = try parseArgumentList() }
                return .call(callee: .member(.name(name, location), function,
                                             isOptional: false, location),
                             arguments: arguments, location)
            }
            if check("(") {
                let arguments = try parseArgumentList()
                return .call(callee: .name(name, location), arguments: arguments, location)
            }
            // それ以外はアトム。
            if name == "true" { return .literal(.bool(true), location) }
            if name == "false" { return .literal(.bool(false), location) }
            return .literal(.symbol(name), location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    /// `[H|T]` のリスト。
    override func parseListOrMapLiteral() throws -> MLExpr {
        let location = current.location
        try expect("[", "リスト")
        var items: [MLExpr] = []
        var tail: MLExpr?
        while !isAtEnd, !check("]") {
            if match("|") {
                tail = try parseExpression()
                break
            }
            items.append(try parseExpression())
            if !match(",") { break }
        }
        try expect("]", "リストの終わり")
        guard let tail else { return .listLiteral(items, spreadIndices: [], location) }
        return .call(callee: .name("#cons", location),
                     arguments: [MLArgument(value: .listLiteral(items, spreadIndices: [],
                                                                location)),
                                 MLArgument(value: tail)], location)
    }

    /// `case X of Pattern -> Body; ... end`
    private func parseCase() throws -> MLExpr {
        let location = current.location
        try expect("case", "case 式")
        let subject = try parseExpression()
        try expect("of", "case 式")
        var arms: [MLMatchArm] = []
        repeat {
            // Erlang の case は 1 つの分岐に 1 つのパターン (`;` は分岐の区切り)。
            let patterns: [MLPattern] = [try parsePattern()]
            var guardCondition: MLExpr?
            if match("when") { guardCondition = try parseGuardSequence() }
            try expect("->", "case の分岐")
            let body = try parseBody(until: [";", "end"])
            let isDefault = patterns.count == 1 && isWildcard(patterns[0])
            arms.append(MLMatchArm(patterns: isDefault ? [] : patterns,
                                   guardCondition: guardCondition, body: body,
                                   isDefault: isDefault))
        } while match(";")
        try expect("end", "case の終わり")
        return .match(subject: subject, arms: arms, location)
    }

    private func isWildcard(_ pattern: MLPattern) -> Bool {
        if case .wildcard = pattern { return true }
        return false
    }

    /// `if Guard -> Body; ... end`
    private func parseErlangIf() throws -> MLExpr {
        let location = current.location
        try expect("if", "if 式")
        var branches: [(MLExpr, [MLStmt])] = []
        repeat {
            let condition = try parseGuardSequence()
            try expect("->", "if の分岐")
            branches.append((condition, try parseBody(until: [";", "end"])))
        } while match(";")
        try expect("end", "if の終わり")

        var result = MLExpr.literal(.symbol("nomatch"), location)
        for (condition, body) in branches.reversed() {
            result = .ifExpr(condition: condition, then: .block(body, location),
                             otherwise: result, location)
        }
        return result
    }

    private func parseErlangTry() throws -> MLExpr {
        let location = current.location
        try expect("try", "try 式")
        let body = try parseBody(until: ["catch", "after", "end"])
        var catches: [MLCatchClause] = []
        var finallyBody: [MLStmt]?
        if match("catch") {
            repeat {
                let pattern = try parsePattern()
                // `error:Reason` のような書き方は種類を読み飛ばす。
                var actual = pattern
                if match(":") { actual = try parsePattern() }
                try expect("->", "catch の分岐")
                catches.append(MLCatchClause(pattern: actual,
                                             body: try parseBody(until: [";", "after",
                                                                         "end"])))
            } while match(";")
        }
        if match("after") { finallyBody = try parseBody(until: ["end"]) }
        try expect("end", "try の終わり")
        return .block([.tryStmt(body: body, catches: catches, finallyBody: finallyBody,
                                location)], location)
    }

    /// `fun(X) -> X end` / `fun Name/1`
    private func parseFun() throws -> MLExpr {
        let location = current.location
        try expect("fun", "fun 式")
        if current.kind == .identifier, !check("(") {
            let name = advance().text
            if match(":") {
                let function = try expectIdentifier("関数名")
                _ = match("/")
                if current.kind == .integerLiteral { advance() }
                return .member(.name(name, location), function, isOptional: false, location)
            }
            _ = match("/")
            if current.kind == .integerLiteral { advance() }
            return .name(name, location)
        }
        var clauses: [MLFunctionClause] = []
        repeat {
            var parameters: [MLParameter] = []
            if match("(") {
                while !isAtEnd, !check(")") {
                    parameters.append(try parseErlangParameter())
                    if !match(",") { break }
                }
                try expect(")", "引数の終わり")
            }
            var guardCondition: MLExpr?
            if match("when") { guardCondition = try parseGuardSequence() }
            try expect("->", "fun の本体")
            clauses.append(MLFunctionClause(parameters: parameters,
                                            guardCondition: guardCondition,
                                            body: try parseBody(until: [";", "end"],
                                                                asReturn: true)))
        } while match(";")
        try expect("end", "fun の終わり")
        return .lambda(MLFunctionDecl(name: "", clauses: clauses, location: location),
                       location)
    }

    /// `lists:seq(...)` の `lists:` を名前つき引数と間違えないようにする。
    override func parseArgument() throws -> MLArgument {
        MLArgument(value: try parseExpression())
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        ErlangLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        ErlangParser(tokens: tokens, diagnostics: diagnostics)
    }
}
