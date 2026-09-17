import Foundation

/// 内蔵の R 処理系。
///
/// R の特徴である「すべてがベクトル」「添字は 1 から」「`<-` で代入」を
/// 再現している。四則演算は要素ごとに働く。
public enum MiniR: MiniLangEngine {
    public static var languageID: String { "r" }
    public static var displayName: String { "内蔵 R 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = RLexer(source: source, diagnostics: diagnostics).tokenize()
        return try RParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = RLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = RParser(tokens: tokens, diagnostics: diagnostics)
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
            let interpreter = MLInterpreter(semantics: RSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

enum RProfile {
    static let keywords: Set<String> = [
        "if", "else", "repeat", "while", "function", "for", "in", "next", "break",
        "TRUE", "FALSE", "NULL", "Inf", "NaN", "NA", "T", "F"
    ]

    static let profile = MLLanguageProfile(
        languageID: "r",
        comments: [.line("#")],
        strings: [MLLanguageProfile.StringStyle(quote: "\""),
                  MLLanguageProfile.StringStyle(quote: "'")],
        keywords: keywords,
        operators: ["<<-", "->>", "%/%", "%in%", "%%", "%o%", "%*%", "<-", "->", "<=",
                    ">=", "==", "!=", "&&", "||", "::", ":::", "...",
                    "+", "-", "*", "/", "^", "=", "<", ">", "!", "&", "|", "~", "?",
                    ":", ";", ",", ".", "(", ")", "[", "]", "{", "}", "$", "@", "\\"],
        newlineTerminatesStatement: true,
        usesSemicolons: true,
        identifierExtras: [".", "_"],
        allowsNumericSeparators: false,
        functionSyntax: .keyword,
        functionKeywords: [],
        variableKeywords: [:],
        typeKeywords: [:],
        ignorableModifiers: [],
        lambdaArrows: [],
        nullLiterals: ["NULL"],
        trueLiterals: ["TRUE", "T"],
        falseLiterals: ["FALSE", "F"],
        selfKeywords: [],
        assignmentOperators: ["<-", "=", "<<-"])
}

final class RLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: RProfile.profile, diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        // `%any%` の形をした演算子。
        if peek() == "%" {
            let start = location
            var text = "%"
            advance()
            while let character = peek(), character != "%" {
                text.append(character)
                advance()
            }
            if peek() == "%" {
                text.append("%")
                advance()
            }
            return MLToken(kind: .punctuation, text: text, location: start)
        }
        // `` `name` `` で囲んだ名前。
        if peek() == "`" {
            let start = location
            advance()
            var name = ""
            while let character = peek(), character != "`" {
                name.append(character)
                advance()
            }
            advance()
            return MLToken(kind: .identifier, text: name, location: start)
        }
        return super.nextToken()
    }
}

final class RParser: MLProfileParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: RProfile.profile, diagnostics: diagnostics)
    }

    override var supportsIfExpression: Bool { true }
    override var hasIncrementOperators: Bool { false }
    override var memberAccessOperators: [String] { ["$", "@"] }

    override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location

        if check("if") { return try parseRIf() }
        if check("while") {
            advance()
            try expect("(", "条件")
            let condition = try parseExpression()
            try expect(")", "条件の終わり")
            return .whileStmt(condition: condition, body: try parseBodyOrStatement(),
                              label: nil, location)
        }
        if check("repeat") {
            advance()
            return .whileStmt(condition: .literal(.bool(true), location),
                              body: try parseBodyOrStatement(), label: nil, location)
        }
        if check("for") {
            advance()
            try expect("(", "for の始まり")
            let name = try expectIdentifier("繰り返し変数")
            try expect("in", "for の in")
            let sequence = try parseExpression()
            try expect(")", "for の終わり")
            return .forIn(pattern: .binding(name), sequence: sequence,
                          body: try parseBodyOrStatement(), whereClause: nil, label: nil,
                          location)
        }
        if check("break") {
            advance()
            consumeStatementEnd()
            return .breakStmt(label: nil, location)
        }
        if check("next") {
            advance()
            consumeStatementEnd()
            return .continueStmt(label: nil, location)
        }
        if check("{") {
            return .block(try parseBraceBlock(), location)
        }

        let expression = try parseExpression()
        consumeStatementEnd()
        // `f <- function(x) ...` は関数宣言として扱う。
        if case .assign(let op, let target, let value, _) = expression, op == "=",
           case .name(let name, _) = target, case .lambda(let decl, _) = value {
            return .funcDecl(MLFunctionDecl(name: name, clauses: decl.clauses,
                                            location: decl.location))
        }
        return .expression(expression, location)
    }

    private func parseRIf() throws -> MLStmt {
        let location = current.location
        try expect("if", "if 文")
        try expect("(", "条件")
        let condition = try parseExpression()
        try expect(")", "条件の終わり")
        let then = try parseBodyOrStatement()
        var otherwise: [MLStmt]?
        // 改行をまたいで `else` が来ることもある。
        let saved = index
        skipStatementSeparators()
        if match("else") {
            otherwise = check("if") ? [try parseRIf()] : try parseBodyOrStatement()
        } else {
            index = saved
        }
        return .ifStmt(condition: condition, then: then, otherwise: otherwise, location)
    }

    override func parseIfExpression() throws -> MLExpr {
        let location = current.location
        let statement = try parseRIf()
        guard case .ifStmt(let condition, let then, let otherwise, _) = statement else {
            return .block([statement], location)
        }
        return .ifExpr(condition: condition, then: .block(then, location),
                       otherwise: otherwise.map { .block($0, location) }, location)
    }

    private func parseBodyOrStatement() throws -> [MLStmt] {
        skipStatementSeparators()
        if check("{") { return try parseBraceBlock() }
        guard let statement = try parseStatement() else { return [] }
        return [statement]
    }

    func parseBraceBlock() throws -> [MLStmt] {
        try expect("{", "ブロックの始まり")
        var body: [MLStmt] = []
        while !isAtEnd, !check("}") {
            skipStatementSeparators()
            if check("}") { break }
            let before = index
            if let statement = try parseStatement() { body.append(statement) }
            if index == before { advance() }
        }
        try expect("}", "ブロックの終わり")
        return body
    }

    // MARK: 式

    override func precedence(of op: String) -> Int? {
        switch op {
        case "%%", "%/%", "%in%", "%o%", "%*%": return 13
        case "^": return 15
        case ":": return 11
        case "&", "&&": return 3
        case "|", "||": return 2
        default: return super.precedence(of: op)
        }
    }

    override func isRightAssociative(_ op: String) -> Bool { op == "^" }

    /// `x <- 1` と `1 -> x` の両方を代入にする。
    override func parseAssignment(stopAtBrace: Bool) throws -> MLExpr {
        let left = try parseTernary(stopAtBrace: stopAtBrace)
        if check("->") || check("->>") {
            let location = current.location
            advance()
            let target = try parseAssignment(stopAtBrace: stopAtBrace)
            return .assign(op: "=", target: target, value: left, location)
        }
        guard profile.assignmentOperators.contains(current.text),
              current.kind == .punctuation else { return left }
        let location = current.location
        advance()
        let right = try parseAssignment(stopAtBrace: stopAtBrace)
        return .assign(op: "=", target: left, value: right, location)
    }

    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if check("if") { return try parseIfExpression() }
        if check("{") {
            return .block(try parseBraceBlock(), location)
        }
        if check("function") || check("\\") {
            advance()
            try expect("(", "引数の始まり")
            var parameters: [MLParameter] = []
            while !isAtEnd, !check(")") {
                if match("...") {
                    parameters.append(MLParameter(name: "...", isVariadic: true))
                } else {
                    let name = try expectIdentifier("引数名")
                    var defaultValue: MLExpr?
                    if match("=") { defaultValue = try parseExpression() }
                    parameters.append(MLParameter(name: name, defaultValue: defaultValue))
                }
                if !match(",") { break }
            }
            try expect(")", "引数の終わり")
            skipStatementSeparators()
            let body: [MLStmt]
            if check("{") {
                body = try parseBraceBlock()
            } else {
                body = [.returnStmt(try parseExpression(), location)]
            }
            return .lambda(MLFunctionDecl(name: "", parameters: parameters,
                                          body: liftedReturn(body), location: location),
                           location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    /// 本体の最後の式が戻り値になる。
    private func liftedReturn(_ body: [MLStmt]) -> [MLStmt] {
        guard case .expression(let value, let location)? = body.last else { return body }
        return body.dropLast() + [.returnStmt(value, location)]
    }

    /// `x[[1]]` は要素そのもの、`x$name` は名前つきの要素。
    override func parsePostfix(stopAtBrace: Bool) throws -> MLExpr {
        var expression = try super.parsePostfix(stopAtBrace: stopAtBrace)
        while check("[["), !isAtEnd {
            let location = advance().location
            let index = try parseExpression()
            try expect("]", "添字")
            try expect("]", "添字")
            expression = .subscriptExpr(expression, index: index, upper: nil, location)
        }
        return expression
    }

    override func parseArgument() throws -> MLArgument {
        // `f(n = 3)` の名前つき引数。
        if current.kind == .identifier, peek(1).is("="), !peek(1).is("==") {
            let label = advance().text
            advance()
            return MLArgument(label: label, value: try parseExpression())
        }
        return MLArgument(value: try parseExpression())
    }

    /// `$` のあとは裸の名前でもよい。
    override func makeLexer(for text: String) -> MLProfileLexer {
        RLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        RParser(tokens: tokens, diagnostics: diagnostics)
    }
}
