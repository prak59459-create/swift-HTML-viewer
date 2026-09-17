import Foundation

/// 内蔵の Haskell 処理系。
///
/// 字下げでまとまりを表す言語なので `MLIndentParser` を土台にしている。
/// 同じ名前の等式を並べて書く定義、ガード、`where`、`do` 記法、
/// リスト内包表記に対応する。評価は正格 (遅延評価はしない)。
public enum MiniHaskell: MiniLangEngine {
    public static var languageID: String { "haskell" }
    public static var displayName: String { "内蔵 Haskell 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = HaskellLexer(source: source, diagnostics: diagnostics).tokenize()
        return try HaskellParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = HaskellLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = HaskellParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: HaskellSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum HaskellProfile {
    static let keywords: Set<String> = [
        "case", "class", "data", "default", "deriving", "do", "else", "foreign", "if",
        "import", "in", "infix", "infixl", "infixr", "instance", "let", "module",
        "newtype", "of", "then", "type", "where"
    ]

    static let profile = MLLanguageProfile(
        languageID: "haskell",
        comments: [.line("--"), .block(open: "{-", close: "-}", nesting: true)],
        strings: [MLLanguageProfile.StringStyle(quote: "\""),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: ["<-", "->", "=>", "::", "..", "++", "&&", "||", "==", "/=", "<=",
                    ">=", "<>", "<$>", "<*>", ">>=", ">>", "!!", "$", ".",
                    "+", "-", "*", "/", "=", "<", ">", "!", "^", "|", "&", "~", "@",
                    ":", ";", ",", "(", ")", "[", "]", "{", "}", "\\", "_", "%"],
        newlineTerminatesStatement: true,
        usesSemicolons: true,
        identifierExtras: ["'", "_"],
        functionSyntax: .keyword,
        functionKeywords: [],
        variableKeywords: [:],
        typeKeywords: [:],
        nullLiterals: [],
        trueLiterals: ["True"],
        falseLiterals: ["False"],
        selfKeywords: [],
        assignmentOperators: [])
}

final class HaskellLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: HaskellProfile.profile, diagnostics: diagnostics)
    }
}

final class HaskellParser: MLIndentParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: HaskellProfile.profile, diagnostics: diagnostics)
    }

    override var blockIntroducer: String? { nil }
    override var hasIncrementOperators: Bool { false }
    override var memberAccessOperators: [String] { [] }

    // MARK: プログラム

    override func parseProgram() throws -> MLProgram {
        var declarations: [String: MLFunctionDecl] = [:]
        var order: [String] = []
        var statements: [MLStmt] = []

        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            let before = index

            if check("module") {
                while !isAtEnd, !check("where") { advance() }
                _ = match("where")
                continue
            }
            if check("import") {
                skipLogicalLine()
                continue
            }
            if check("data") || check("newtype") || check("type") {
                if let declaration = try parseDataDeclaration() {
                    statements.append(declaration)
                }
                continue
            }
            // 型注釈 (`fib :: Int -> Int`) は読み飛ばす。
            if current.kind == .identifier, peek(1).is("::") {
                skipLogicalLine()
                continue
            }
            let binding = try parseBinding()
            switch binding {
            case .function(let decl):
                if let existing = declarations[decl.name] {
                    existing.clauses.append(contentsOf: decl.clauses)
                } else {
                    declarations[decl.name] = decl
                    order.append(decl.name)
                }
            case .value(let statement):
                statements.append(statement)
            }
            if index == before { advance() }
        }

        var result: [MLStmt] = []
        for name in order {
            guard let decl = declarations[name] else { continue }
            result.append(.funcDecl(decl))
        }
        result += statements
        return MLProgram(statements: result,
                         entryPoint: declarations["main"] != nil ? "main" : nil)
    }

    /// 同じ論理行 (字下げが続くかぎり) を読み飛ばす。
    private func skipLogicalLine() {
        guard !isAtEnd else { return }
        let column = current.location.column
        advance()
        while !isAtEnd {
            if current.precededByNewline, current.location.column <= column { break }
            advance()
        }
    }

    enum Binding {
        case function(MLFunctionDecl)
        case value(MLStmt)
    }

    /// `data Shape = Circle Double | Rect Double Double`
    private func parseDataDeclaration() throws -> MLStmt? {
        let location = current.location
        let isAlias = check("type")
        advance()
        let name = try expectIdentifier("型名")
        // 型引数は読み飛ばす。
        while current.kind == .identifier, !check("=") { advance() }
        guard match("=") else {
            skipLogicalLine()
            return nil
        }
        if isAlias {
            skipLogicalLine()
            return nil
        }
        // レコード構文は使わず、位置引数だけ読む。
        var cases: [MLCaseDecl] = []
        repeat {
            guard current.kind == .identifier else { break }
            let caseName = advance().text
            var associated: [String] = []
            while !isAtEnd, !current.precededByNewline,
                  current.kind == .identifier || check("[") || check("(") {
                if check("[") || check("(") {
                    skipBalancedBrackets()
                    associated.append("value")
                    continue
                }
                associated.append(advance().text)
            }
            cases.append(MLCaseDecl(name: caseName, associatedTypes: associated))
        } while match("|")
        // `deriving (Show)` は読み飛ばす。
        if check("deriving") { skipLogicalLine() }
        return .typeDecl(MLTypeDecl(kind: .enumType, name: name, cases: cases,
                                    location: location))
    }

    private func skipBalancedBrackets() {
        let open = current.text
        let close = open == "[" ? "]" : ")"
        var depth = 0
        repeat {
            if check(open) { depth += 1 }
            if check(close) { depth -= 1 }
            advance()
        } while !isAtEnd && depth > 0
    }

    /// `name pat... = body` / `name pat... | guard = body` / `x = value`
    private func parseBinding() throws -> Binding {
        let location = current.location
        // パターン束縛 (`(a, b) = ...`)。
        if check("(") || check("[") {
            let pattern = try parsePattern()
            try expect("=", "束縛")
            let value = try parseExpression()
            return .value(.varDecl(pattern: pattern, typeName: nil, value: value,
                                   isConstant: true, location))
        }
        let name = try expectIdentifier("名前")
        var parameters: [MLParameter] = []
        while !isAtEnd, !check("="), !check("|") {
            parameters.append(try parseHaskellParameter())
        }

        var clauses: [MLFunctionClause] = []
        if check("|") {
            // ガードつきの等式。ガードごとに 1 つの節にする。
            while match("|") {
                var condition: MLExpr?
                if current.kind == .identifier, current.text == "otherwise" {
                    advance()
                } else {
                    condition = try parseExpression()
                }
                try expect("=", "ガードの本体")
                var body = try parseExpression()
                let helpers = try parseWhereClause()
                if !helpers.isEmpty {
                    body = .block(helpers + [.expression(body, location)], location)
                }
                clauses.append(MLFunctionClause(parameters: parameters,
                                                guardCondition: condition,
                                                body: [.returnStmt(body, location)]))
                skipStatementSeparators()
            }
        } else {
            try expect("=", "束縛")
            var body = try parseExpression()
            let helpers = try parseWhereClause()
            if !helpers.isEmpty {
                body = .block(helpers + [.expression(body, location)], location)
            }
            if parameters.isEmpty {
                // `main = do ...` のような値の束縛も関数にしておく。
                if name == "main" {
                    return .function(MLFunctionDecl(name: name, parameters: [],
                                                    body: [.returnStmt(body, location)],
                                                    location: location))
                }
                return .value(.varDecl(pattern: .binding(name), typeName: nil, value: body,
                                       isConstant: true, location))
            }
            clauses.append(MLFunctionClause(parameters: parameters,
                                            body: [.returnStmt(body, location)]))
        }
        return .function(MLFunctionDecl(name: name, clauses: clauses, isCurried: true,
                                        location: location))
    }

    private func parseHaskellParameter() throws -> MLParameter {
        let pattern = try parsePattern()
        if case .binding(let name) = pattern { return MLParameter(name: name) }
        if case .wildcard = pattern { return MLParameter(name: "_") }
        return MLParameter(name: "", pattern: pattern)
    }

    /// `where` に続く補助定義。
    private func parseWhereClause() throws -> [MLStmt] {
        let saved = index
        skipStatementSeparators()
        guard match("where") else {
            index = saved
            return []
        }
        let column = isAtEnd ? 0 : current.location.column
        var statements: [MLStmt] = []
        var declarations: [String: MLFunctionDecl] = [:]
        var order: [String] = []
        while !isAtEnd, current.location.column >= column {
            skipStatementSeparators()
            if isAtEnd || current.location.column < column { break }
            let before = index
            switch try parseBinding() {
            case .function(let decl):
                if let existing = declarations[decl.name] {
                    existing.clauses.append(contentsOf: decl.clauses)
                } else {
                    declarations[decl.name] = decl
                    order.append(decl.name)
                }
            case .value(let statement):
                statements.append(statement)
            }
            if index == before { advance() }
        }
        var result: [MLStmt] = []
        for name in order {
            guard let decl = declarations[name] else { continue }
            result.append(.funcDecl(decl))
        }
        return result + statements
    }

    // MARK: 式

    override func precedence(of op: String) -> Int? {
        switch op {
        // `|` はガードと内包表記の区切りなので、演算子にしない。
        case "|", "&", "..": return nil
        case "$": return 1
        case ".": return 14
        case "++": return 12
        case "==", "/=": return 7
        case "!!": return 14
        case ":": return 11
        case "^": return 15
        case ">>=", ">>": return 5
        default: return super.precedence(of: op)
        }
    }

    override func isRightAssociative(_ op: String) -> Bool {
        op == "$" || op == ":" || op == "++" || op == "." || op == "^"
    }

    override func parseExpression(stopAtBrace: Bool = false) throws -> MLExpr {
        let location = current.location
        if check("let") { return try parseLetExpression() }
        if check("if") { return try parseHaskellIf() }
        if check("case") { return try parseCase() }
        if check("do") { return try parseDo() }
        if check("\\") { return try parseLambda() }
        _ = location
        return try parseBinary(minimumPrecedence: 0, stopAtBrace: stopAtBrace)
    }

    private func parseLetExpression() throws -> MLExpr {
        let location = current.location
        try expect("let", "let 式")
        let column = isAtEnd ? 0 : current.location.column
        var statements: [MLStmt] = []
        while !isAtEnd, current.location.column >= column, !check("in") {
            skipStatementSeparators()
            if isAtEnd || check("in") || current.location.column < column { break }
            let before = index
            switch try parseBinding() {
            case .function(let decl): statements.append(.funcDecl(decl))
            case .value(let statement): statements.append(statement)
            }
            if index == before { advance() }
        }
        skipStatementSeparators()
        guard match("in") else { return .block(statements, location) }
        let body = try parseExpression()
        statements.append(.expression(body, location))
        return .block(statements, location)
    }

    private func parseHaskellIf() throws -> MLExpr {
        let location = current.location
        try expect("if", "if 式")
        let condition = try parseExpression()
        skipStatementSeparators()
        try expect("then", "if 式")
        let then = try parseExpression()
        skipStatementSeparators()
        var otherwise = MLExpr.literal(.unit, location)
        if match("else") { otherwise = try parseExpression() }
        return .ifExpr(condition: condition, then: then, otherwise: otherwise, location)
    }

    /// `case x of` + 字下げした分岐。
    private func parseCase() throws -> MLExpr {
        let location = current.location
        try expect("case", "case 式")
        let subject = try parseExpression()
        try expect("of", "case 式")
        let column = isAtEnd ? 0 : current.location.column
        var arms: [MLMatchArm] = []
        while !isAtEnd, current.location.column >= column {
            skipStatementSeparators()
            if isAtEnd || current.location.column < column { break }
            let before = index
            let pattern = try parsePattern()
            var guardCondition: MLExpr?
            if match("|") { guardCondition = try parseExpression() }
            try expect("->", "case の分岐")
            let body = try parseExpression()
            let isDefault = isWildcard(pattern) && guardCondition == nil
            arms.append(MLMatchArm(patterns: isDefault ? [] : [pattern],
                                   guardCondition: guardCondition,
                                   body: [.expression(body, body.location)],
                                   isDefault: isDefault))
            if index == before { advance() }
        }
        return .match(subject: subject, arms: arms, location)
    }

    private func isWildcard(_ pattern: MLPattern) -> Bool {
        if case .wildcard = pattern { return true }
        return false
    }

    /// `do` 記法。順に実行し、最後の式が値になる。
    private func parseDo() throws -> MLExpr {
        let location = current.location
        try expect("do", "do 記法")
        let column = isAtEnd ? 0 : current.location.column
        var statements: [MLStmt] = []
        while !isAtEnd, current.location.column >= column {
            skipStatementSeparators()
            if isAtEnd || current.location.column < column { break }
            let before = index
            // `x <- expr` の束縛。
            if current.kind == .identifier, peek(1).is("<-") {
                let name = advance().text
                advance()
                let value = try parseExpression()
                statements.append(.varDecl(pattern: .binding(name), typeName: nil,
                                           value: value, isConstant: true, location))
                if index == before { advance() }
                continue
            }
            if check("let") {
                advance()
                let letColumn = isAtEnd ? 0 : current.location.column
                while !isAtEnd, current.location.column >= letColumn {
                    skipStatementSeparators()
                    if isAtEnd || current.location.column < letColumn { break }
                    let inner = index
                    switch try parseBinding() {
                    case .function(let decl): statements.append(.funcDecl(decl))
                    case .value(let statement): statements.append(statement)
                    }
                    if index == inner { advance() }
                }
                continue
            }
            let expression = try parseExpression()
            statements.append(.expression(expression, expression.location))
            if index == before { advance() }
        }
        return .block(statements, location)
    }

    private func parseLambda() throws -> MLExpr {
        let location = current.location
        try expect("\\", "ラムダ式")
        var parameters: [MLParameter] = []
        while !isAtEnd, !check("->") { parameters.append(try parseHaskellParameter()) }
        try expect("->", "ラムダの本体")
        let body = try parseExpression()
        return .lambda(MLFunctionDecl(name: "", parameters: parameters,
                                      body: [.returnStmt(body, location)],
                                      isCurried: true, location: location), location)
    }

    /// 関数適用は並べ書き。
    override func parseUnary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if check("-") {
            advance()
            return .unary(op: "-", operand: try parseUnary(stopAtBrace: stopAtBrace),
                          isPostfix: false, location)
        }
        if check("\\") { return try parseLambda() }
        if check("if") { return try parseHaskellIf() }
        if check("case") { return try parseCase() }
        if check("do") { return try parseDo() }
        if check("let") { return try parseLetExpression() }

        let callee = try parsePostfix(stopAtBrace: stopAtBrace)
        var arguments: [MLArgument] = []
        while canStartAtom() {
            arguments.append(MLArgument(value: try parsePostfix(stopAtBrace: stopAtBrace)))
        }
        guard !arguments.isEmpty else { return callee }
        return .call(callee: callee, arguments: arguments, location)
    }

    /// 次の字句が引数になりうるか (行が変わったら終わり)。
    private func canStartAtom() -> Bool {
        if isAtEnd { return false }
        if current.precededByNewline { return false }
        switch current.kind {
        case .identifier, .integerLiteral, .floatLiteral, .stringLiteral, .charLiteral,
             .interpolatedString:
            return true
        case .keyword:
            return ["True", "False"].contains(current.text)
        case .punctuation:
            return current.text == "(" || current.text == "["
        default:
            return false
        }
    }

    /// Haskell に後置はない (`.` は関数合成)。
    override func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        try parsePrimary(stopAtBrace: stopAtBrace)
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if check("(") {
            advance()
            if match(")") { return .literal(.unit, location) }
            // 演算子の部分適用 `(> 3)` / `(+ 1)` / `(+)`
            if current.kind == .punctuation, precedence(of: current.text) != nil,
               !check("("), !check("["), !check("-") {
                let op = advance().text
                if match(")") {
                    return .lambda(MLFunctionDecl(
                        name: "", parameters: [MLParameter(name: "#a"),
                                               MLParameter(name: "#b")],
                        body: [.returnStmt(.binary(op: op, lhs: .name("#a", location),
                                                   rhs: .name("#b", location), location),
                                           location)],
                        isCurried: true, location: location), location)
                }
                let rhs = try parseExpression()
                try expect(")", "括弧の終わり")
                return .lambda(MLFunctionDecl(
                    name: "", parameters: [MLParameter(name: "#a")],
                    body: [.returnStmt(.binary(op: op, lhs: .name("#a", location),
                                               rhs: rhs, location), location)],
                    location: location), location)
            }
            var items: [MLExpr] = [try parseExpression()]
            while match(",") { items.append(try parseExpression()) }
            try expect(")", "括弧の終わり")
            if items.count == 1 { return items[0] }
            return .tupleLiteral(items, location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    /// `[1, 2, 3]` / `[1..10]` / `[x * 2 | x <- xs, x > 3]`
    override func parseListOrMapLiteral() throws -> MLExpr {
        let location = current.location
        try expect("[", "リスト")
        if match("]") { return .listLiteral([], spreadIndices: [], location) }
        let first = try parseExpression()
        // 範囲。
        if match("..") {
            if match("]") {
                return .range(lower: first, upper: .literal(.int(1_000_000), location),
                              isClosed: false, step: nil, location)
            }
            let upper = try parseExpression()
            try expect("]", "範囲の終わり")
            return .range(lower: first, upper: upper, isClosed: true, step: nil, location)
        }
        // 内包表記。
        if match("|") {
            var clauses: [MLComprehension.Clause] = []
            var filters: [MLExpr] = []
            repeat {
                let saved = index
                if let pattern = try? parsePattern(), match("<-") {
                    clauses.append(MLComprehension.Clause(
                        pattern: pattern, sequence: try parseExpression()))
                } else {
                    index = saved
                    filters.append(try parseExpression())
                }
            } while match(",")
            try expect("]", "内包表記の終わり")
            return .comprehension(MLComprehension(element: first, clauses: clauses,
                                                  filters: filters), location)
        }
        var items: [MLExpr] = [first]
        while match(",") {
            items.append(try parseExpression())
        }
        try expect("]", "リストの終わり")
        return .listLiteral(items, spreadIndices: [], location)
    }

    // MARK: パターン

    override func parsePattern() throws -> MLPattern {
        var pattern = try parsePrimaryPattern()
        while check(":") {
            advance()
            pattern = .cons(head: pattern, tail: try parsePrimaryPattern())
        }
        if match("@") {
            let name = try expectIdentifier("as の名前")
            pattern = .named(name, pattern)
        }
        return pattern
    }

    override func parsePrimaryPattern() throws -> MLPattern {
        if check("_") {
            advance()
            return .wildcard
        }
        if check("(") {
            advance()
            if match(")") { return .literal(.unit) }
            var items: [MLPattern] = [try parsePattern()]
            while match(",") { items.append(try parsePattern()) }
            try expect(")", "パターンの終わり")
            return items.count == 1 ? items[0] : .tuple(items)
        }
        if check("[") {
            advance()
            var items: [MLPattern] = []
            while !isAtEnd, !check("]") {
                items.append(try parsePattern())
                if !match(",") { break }
            }
            try expect("]", "リストのパターン")
            return .list(items, restIndex: nil, restName: nil)
        }
        if current.kind == .identifier {
            let name = advance().text
            if let first = name.first, first.isUppercase {
                var positional: [MLPattern] = []
                while canStartPatternAtom() {
                    positional.append(try parsePrimaryPattern())
                }
                return .constructor(name: name, positional: positional, named: [])
            }
            return name == "_" ? .wildcard : .binding(name)
        }
        return try super.parsePrimaryPattern()
    }

    private func canStartPatternAtom() -> Bool {
        if isAtEnd || current.precededByNewline { return false }
        switch current.kind {
        case .identifier, .integerLiteral, .floatLiteral, .stringLiteral, .charLiteral:
            return true
        case .punctuation:
            return current.text == "(" || current.text == "[" || current.text == "_"
        default:
            return false
        }
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        HaskellLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        HaskellParser(tokens: tokens, diagnostics: diagnostics)
    }
}
