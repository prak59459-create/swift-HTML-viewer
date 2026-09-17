import Foundation

/// 内蔵の OCaml 処理系。
///
/// 関数適用は並べ書き (`f x y`) で、引数が足りなければ部分適用になる。
/// `let ... in`、`match ... with`、バリアント型、レコードに対応する。
public enum MiniOCaml: MiniLangEngine {
    public static var languageID: String { "ocaml" }
    public static var displayName: String { "内蔵 OCaml 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = OCamlLexer(source: source, diagnostics: diagnostics).tokenize()
        return try OCamlParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = OCamlLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = OCamlParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: OCamlSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum OCamlProfile {
    static let keywords: Set<String> = [
        "and", "as", "assert", "begin", "class", "do", "done", "downto", "else", "end",
        "exception", "external", "for", "fun", "function", "functor", "if", "in",
        "include", "inherit", "let", "match", "method", "module", "mutable", "new",
        "of", "open", "or", "rec", "sig", "struct", "then", "to", "try", "type", "val",
        "when", "while", "with", "not", "mod", "land", "lor", "lxor", "lsl", "lsr",
        "true", "false"
    ]

    static let profile = MLLanguageProfile(
        languageID: "ocaml",
        comments: [.block(open: "(*", close: "*)", nesting: true)],
        strings: [MLLanguageProfile.StringStyle(quote: "\""),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: ["|>", "->", "<-", "::", ";;", "&&", "||", "<>", "==", "!=", "<=",
                    ">=", "+.", "-.", "*.", "/.", "**", "@@", "@",
                    "+", "-", "*", "/", "=", "<", ">", "!", "^", "|", "&", "~",
                    "?", ":", ";", ",", ".", "(", ")", "[", "]", "{", "}", "_"],
        newlineTerminatesStatement: false,
        usesSemicolons: false,
        identifierExtras: ["'", "_"],
        functionSyntax: .keyword,
        functionKeywords: [],
        variableKeywords: [:],
        typeKeywords: [:],
        nullLiterals: [],
        selfKeywords: [],
        assignmentOperators: ["<-"])
}

final class OCamlLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: OCamlProfile.profile, diagnostics: diagnostics)
    }
}

final class OCamlParser: MLProfileParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: OCamlProfile.profile, diagnostics: diagnostics)
    }

    override var hasIncrementOperators: Bool { false }
    override var memberAccessOperators: [String] { ["."] }

    // MARK: プログラム

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipTopLevelSeparators()
            if isAtEnd { break }
            let before = index
            statements.append(contentsOf: try parseTopLevelItem())
            if index == before { advance() }
        }
        return MLProgram(statements: statements)
    }

    private func skipTopLevelSeparators() {
        while !isAtEnd, check(";;") || check(";") { advance() }
    }

    private func parseTopLevelItem() throws -> [MLStmt] {
        let location = current.location
        if check("open") || check("module") || check("exception") {
            // 実行に影響しない宣言は読み飛ばす。
            advance()
            while !isAtEnd, !check(";;"), !check("let"), !check("type") { advance() }
            return [.noop(location)]
        }
        if check("type") { return try parseTypeDefinition() }
        if check("let") { return try parseTopLevelLet() }
        let expression = try parseExpression()
        return [.expression(expression, location)]
    }

    /// `type shape = Circle of float | Rect of float * float`
    /// `type point = { x : int; y : int }`
    private func parseTypeDefinition() throws -> [MLStmt] {
        let location = current.location
        try expect("type", "型の定義")
        // 型引数は読み飛ばす。
        while check("'") || (current.kind == .identifier && peek(1).kind == .identifier
                              && !peek(1).is("=")) {
            advance()
        }
        let name = try expectIdentifier("型名")
        try expect("=", "型の定義")

        // レコード。
        if check("{") {
            advance()
            var properties: [MLPropertyDecl] = []
            while !isAtEnd, !check("}") {
                _ = match("mutable")
                let field = try expectIdentifier("フィールド名")
                if match(":") { skipTypeExpression() }
                properties.append(MLPropertyDecl(name: field))
                if !match(";") { break }
            }
            try expect("}", "レコードの終わり")
            return [.typeDecl(MLTypeDecl(kind: .structType, name: name,
                                         properties: properties, location: location))]
        }

        // バリアント。
        var cases: [MLCaseDecl] = []
        _ = match("|")
        repeat {
            guard current.kind == .identifier else { break }
            let caseName = advance().text
            var associated: [String] = []
            if match("of") {
                repeat {
                    associated.append(readTypeAtom())
                } while match("*")
            }
            cases.append(MLCaseDecl(name: caseName, associatedTypes: associated))
        } while match("|")
        return [.typeDecl(MLTypeDecl(kind: .enumType, name: name, cases: cases,
                                     location: location))]
    }

    /// 型の書き方を 1 つぶん読み飛ばして名前を返す。
    private func readTypeAtom() -> String {
        var name = ""
        if match("(") {
            var depth = 1
            while !isAtEnd, depth > 0 {
                if check("(") { depth += 1 }
                if check(")") { depth -= 1 }
                advance()
            }
            return "tuple"
        }
        if current.kind == .identifier || current.kind == .keyword {
            name = advance().text
        }
        // `int list` のような後置の型構成子。
        while current.kind == .identifier, !peek(1).is("="), !check("of") {
            name = advance().text
        }
        return name
    }

    private func skipTypeExpression() {
        var depth = 0
        while !isAtEnd {
            if check("(") || check("[") { depth += 1 }
            if check(")") || check("]") {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0, check(";") || check("}") || check("=") { break }
            advance()
        }
    }

    /// `let [rec] name args = body [in body]`
    private func parseTopLevelLet() throws -> [MLStmt] {
        let location = current.location
        try expect("let", "let 束縛")
        _ = match("rec")
        let binding = try parseLetBinding(location: location)
        // `let ... in ...` は式になる。
        if match("in") {
            let body = try parseExpression()
            return [.expression(.block(binding + [.expression(body, location)], location),
                                location)]
        }
        // `and` でつながる同時定義。
        var result = binding
        while match("and") {
            result += try parseLetBinding(location: current.location)
        }
        return result
    }

    /// 1 つの束縛 (関数か変数)。
    private func parseLetBinding(location: SourceLocation) throws -> [MLStmt] {
        // `let () = ...` や `let _ = ...` は値を捨てる。
        if check("(") , peek(1).is(")") {
            advance()
            advance()
            try expect("=", "let 束縛")
            return [.expression(try parseExpression(), location)]
        }
        // パターン束縛 (`let (a, b) = ...`)。
        if check("(") || check("[") {
            let pattern = try parsePattern()
            try expect("=", "let 束縛")
            let value = try parseExpression()
            return [.varDecl(pattern: pattern, typeName: nil, value: value,
                             isConstant: true, location)]
        }
        let name = try expectIdentifier("名前")
        var parameters: [MLParameter] = []
        while !isAtEnd, !check("="), !check(":") {
            parameters.append(try parseOCamlParameter())
        }
        if match(":") { skipTypeExpression() }
        try expect("=", "let 束縛")
        let body = try parseExpression()

        if parameters.isEmpty {
            return [.varDecl(pattern: .binding(name), typeName: nil, value: body,
                             isConstant: true, location)]
        }
        return [.funcDecl(MLFunctionDecl(name: name, parameters: parameters,
                                         body: [.returnStmt(body, location)],
                                         isCurried: true, location: location))]
    }

    private func parseOCamlParameter() throws -> MLParameter {
        if match("(") {
            // `(x : int)` のように型を書くことがある。
            let pattern = try parsePattern()
            if match(":") { skipTypeExpression() }
            try expect(")", "引数の終わり")
            if case .binding(let name) = pattern { return MLParameter(name: name) }
            return MLParameter(name: "", pattern: pattern)
        }
        if check("_") {
            advance()
            return MLParameter(name: "_")
        }
        let name = try expectIdentifier("引数名")
        return MLParameter(name: name)
    }

    // MARK: 式

    override func precedence(of op: String) -> Int? {
        switch op {
        // `|` は match の分岐の区切りなので、演算子にしない。
        case "|", "&", "in", "and", "with", "then", "else": return nil
        case "|>": return 6
        case "^", "@": return 12
        case "=", "<>": return 7
        case "+.", "-.": return 12
        case "*.", "/.", "mod", "land", "lor", "lxor": return 13
        case "::": return 11
        case "lsl", "lsr": return 11
        case "**": return 15
        default: return super.precedence(of: op)
        }
    }

    override func isRightAssociative(_ op: String) -> Bool {
        op == "::" || op == "**" || op == "@"
    }

    override func parseExpression(stopAtBrace: Bool = false) throws -> MLExpr {
        let location = current.location
        if check("let") {
            let statements = try parseLetExpression()
            return .block(statements, location)
        }
        if check("if") { return try parseOCamlIf() }
        if check("match") { return try parseMatch() }
        if check("function") { return try parseFunctionKeyword() }
        if check("fun") { return try parseFun() }
        if check("try") { return try parseOCamlTry() }
        // `e1; e2` は順に実行して最後の値を返す。
        var expression = try parseBinary(minimumPrecedence: 0, stopAtBrace: stopAtBrace)
        if check(";"), !check(";;") {
            var statements: [MLStmt] = [.expression(expression, location)]
            while match(";") {
                if isAtEnd || check(";;") || check("in") || check("}") || check(")") { break }
                statements.append(.expression(try parseExpression(stopAtBrace: stopAtBrace),
                                              location))
            }
            expression = .block(statements, location)
        }
        return expression
    }

    /// `let x = e1 in e2`
    private func parseLetExpression() throws -> [MLStmt] {
        let location = current.location
        try expect("let", "let 式")
        _ = match("rec")
        var statements = try parseLetBinding(location: location)
        while match("and") { statements += try parseLetBinding(location: location) }
        try expect("in", "let 式")
        let body = try parseExpression()
        statements.append(.expression(body, location))
        return statements
    }

    private func parseOCamlIf() throws -> MLExpr {
        let location = current.location
        try expect("if", "if 式")
        let condition = try parseExpression()
        try expect("then", "if 式")
        let then = try parseExpression()
        var otherwise = MLExpr.literal(.unit, location)
        if match("else") { otherwise = try parseExpression() }
        return .ifExpr(condition: condition, then: then, otherwise: otherwise, location)
    }

    /// `match x with | p -> e | ...`
    private func parseMatch() throws -> MLExpr {
        let location = current.location
        try expect("match", "match 式")
        let subject = try parseExpression()
        try expect("with", "match 式")
        return .match(subject: subject, arms: try parseMatchArms(), location)
    }

    /// `function | p -> e | ...` は 1 引数の関数。
    private func parseFunctionKeyword() throws -> MLExpr {
        let location = current.location
        try expect("function", "function 式")
        let arms = try parseMatchArms()
        let body = MLExpr.match(subject: .name("#arg0", location), arms: arms, location)
        return .lambda(MLFunctionDecl(name: "", parameters: [MLParameter(name: "#arg0")],
                                      body: [.returnStmt(body, location)],
                                      location: location), location)
    }

    private func parseMatchArms() throws -> [MLMatchArm] {
        var arms: [MLMatchArm] = []
        _ = match("|")
        repeat {
            var patterns: [MLPattern] = [try parsePattern()]
            while match("|") { patterns.append(try parsePattern()) }
            var guardCondition: MLExpr?
            if match("when") { guardCondition = try parseExpression() }
            try expect("->", "match の分岐")
            let body = try parseArmBody()
            let isDefault = patterns.count == 1 && isWildcard(patterns[0])
            arms.append(MLMatchArm(patterns: isDefault ? [] : patterns,
                                   guardCondition: guardCondition,
                                   body: [.expression(body, body.location)],
                                   isDefault: isDefault))
        } while match("|")
        return arms
    }

    /// 分岐の本体 (次の `|` まで)。
    private func parseArmBody() throws -> MLExpr {
        let location = current.location
        if check("let") { return .block(try parseLetExpression(), location) }
        if check("if") { return try parseOCamlIf() }
        if check("match") { return try parseMatch() }
        if check("fun") { return try parseFun() }
        var expression = try parseBinary(minimumPrecedence: 0, stopAtBrace: false)
        if check(";"), !check(";;") {
            var statements: [MLStmt] = [.expression(expression, location)]
            while match(";") {
                if isAtEnd || check("|") || check(";;") { break }
                statements.append(.expression(try parseBinary(minimumPrecedence: 0,
                                                              stopAtBrace: false),
                                              location))
            }
            expression = .block(statements, location)
        }
        return expression
    }

    private func isWildcard(_ pattern: MLPattern) -> Bool {
        if case .wildcard = pattern { return true }
        return false
    }

    private func parseFun() throws -> MLExpr {
        let location = current.location
        try expect("fun", "fun 式")
        var parameters: [MLParameter] = []
        while !isAtEnd, !check("->") { parameters.append(try parseOCamlParameter()) }
        try expect("->", "fun の本体")
        let body = try parseExpression()
        return .lambda(MLFunctionDecl(name: "", parameters: parameters,
                                      body: [.returnStmt(body, location)],
                                      isCurried: true, location: location), location)
    }

    private func parseOCamlTry() throws -> MLExpr {
        let location = current.location
        try expect("try", "try 式")
        let body = try parseExpression()
        try expect("with", "try 式")
        var catches: [MLCatchClause] = []
        _ = match("|")
        repeat {
            let pattern = try parsePattern()
            try expect("->", "with の分岐")
            let handler = try parseArmBody()
            catches.append(MLCatchClause(pattern: pattern,
                                         body: [.expression(handler, location)]))
        } while match("|")
        return .block([.tryStmt(body: [.expression(body, location)], catches: catches,
                                finallyBody: nil, location)], location)
    }

    /// 関数適用は並べ書き。`f x y` を 1 回の呼び出しにまとめる。
    override func parseUnary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if check("-") , !peek(1).precededByNewline {
            advance()
            return .unary(op: "-", operand: try parseUnary(stopAtBrace: stopAtBrace),
                          isPostfix: false, location)
        }
        if check("not") {
            advance()
            return .unary(op: "!", operand: try parseUnary(stopAtBrace: stopAtBrace),
                          isPostfix: false, location)
        }
        if check("!") {
            advance()
            return .dereference(try parseUnary(stopAtBrace: stopAtBrace), location)
        }
        let callee = try parsePostfix(stopAtBrace: stopAtBrace)
        var arguments: [MLArgument] = []
        while canStartAtom() {
            arguments.append(MLArgument(value: try parsePostfix(stopAtBrace: stopAtBrace)))
        }
        guard !arguments.isEmpty else { return callee }
        // `Rect (3.0, 4.0)` は構成子に 2 つの値を渡す書き方。
        if case .name(let name, _) = callee, let first = name.first, first.isUppercase,
           arguments.count == 1, case .tupleLiteral(let items, _) = arguments[0].value {
            return .call(callee: callee, arguments: items.map { MLArgument(value: $0) },
                         location)
        }
        return .call(callee: callee, arguments: arguments, location)
    }

    /// OCaml では `[` は添字ではなくリストなので、後置は `.` だけにする。
    override func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        var expression = try parsePrimary(stopAtBrace: stopAtBrace)
        while !isAtEnd {
            let location = current.location
            guard check("."), peek(1).kind == .identifier else { break }
            advance()
            let name = advance().text
            expression = .member(expression, name, isOptional: false, location)
        }
        return expression
    }

    /// 次の字句が引数になりうるか。
    private func canStartAtom() -> Bool {
        if isAtEnd { return false }
        switch current.kind {
        case .identifier, .integerLiteral, .floatLiteral, .stringLiteral, .charLiteral,
             .interpolatedString:
            return true
        case .keyword:
            return ["true", "false", "fun", "function", "begin"].contains(current.text)
        case .punctuation:
            return current.text == "(" || current.text == "[" || current.text == "{"
        default:
            return false
        }
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if check("begin") {
            advance()
            let body = try parseExpression()
            _ = match("end")
            return body
        }
        // レコード `{ x = 1; y = 2 }`
        if check("{") {
            advance()
            var pairs: [(key: MLExpr, value: MLExpr)] = []
            while !isAtEnd, !check("}") {
                let field = try expectIdentifier("フィールド名")
                try expect("=", "レコード")
                pairs.append((key: .literal(.string(field), location),
                              value: try parseBinary(minimumPrecedence: 0,
                                                     stopAtBrace: false)))
                if !match(";") { break }
            }
            try expect("}", "レコードの終わり")
            return .mapLiteral(pairs, location)
        }
        // 単位値・組。
        if check("(") {
            advance()
            if match(")") { return .literal(.unit, location) }
            var items: [MLExpr] = [try parseExpression()]
            while match(",") { items.append(try parseExpression()) }
            try expect(")", "括弧の終わり")
            if items.count == 1 { return items[0] }
            return .tupleLiteral(items, location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    /// `[1; 2; 3]` のリスト。
    override func parseListOrMapLiteral() throws -> MLExpr {
        let location = current.location
        try expect("[", "リスト")
        var items: [MLExpr] = []
        while !isAtEnd, !check("]") {
            items.append(try parseBinary(minimumPrecedence: 0, stopAtBrace: false))
            if !match(";") && !match(",") { break }
        }
        try expect("]", "リストの終わり")
        return .listLiteral(items, spreadIndices: [], location)
    }

    // MARK: パターン

    override func parsePattern() throws -> MLPattern {
        var pattern = try parsePrimaryPattern()
        // `h :: t` の分解。
        while check("::") {
            advance()
            pattern = .cons(head: pattern, tail: try parsePrimaryPattern())
        }
        if match("as") {
            let name = try expectIdentifier("as の名前")
            pattern = .named(name, pattern)
        }
        return pattern
    }

    override func parsePrimaryPattern() throws -> MLPattern {
        let location = current.location
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
                if !match(";") && !match(",") { break }
            }
            try expect("]", "リストのパターン")
            return .list(items, restIndex: nil, restName: nil)
        }
        if current.kind == .identifier {
            let name = advance().text
            // 大文字で始まる名前は構成子。
            if let first = name.first, first.isUppercase {
                var positional: [MLPattern] = []
                if check("(") {
                    advance()
                    repeat {
                        positional.append(try parsePattern())
                    } while match(",")
                    try expect(")", "構成子のパターン")
                } else if canStartPatternAtom() {
                    positional.append(try parsePrimaryPattern())
                }
                return .constructor(name: name, positional: positional, named: [])
            }
            return name == "_" ? .wildcard : .binding(name)
        }
        _ = location
        return try super.parsePrimaryPattern()
    }

    private func canStartPatternAtom() -> Bool {
        if isAtEnd { return false }
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
        OCamlLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        OCamlParser(tokens: tokens, diagnostics: diagnostics)
    }
}
