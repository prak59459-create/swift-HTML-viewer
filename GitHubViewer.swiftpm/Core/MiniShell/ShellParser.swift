import Foundation

/// シェルの構文解析。単語の並びをコマンド呼び出しに組み替える。
final class ShellParser {
    private let tokens: [MLToken]
    private var index = 0
    private let diagnostics: DiagnosticBag

    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }

    // MARK: 字句の出し入れ

    private var current: MLToken { tokens[Swift.min(index, tokens.count - 1)] }
    private var isAtEnd: Bool { current.kind == .endOfFile }

    private func peek(_ offset: Int = 1) -> MLToken {
        tokens[Swift.min(index + offset, tokens.count - 1)]
    }

    @discardableResult
    private func advance() -> MLToken {
        let token = current
        if index < tokens.count - 1 { index += 1 }
        return token
    }

    private func check(_ text: String) -> Bool {
        !isAtEnd && current.kind != .stringLiteral && current.kind != .interpolatedString
            && current.text == text
    }

    @discardableResult
    private func match(_ texts: String...) -> Bool {
        for text in texts where check(text) {
            advance()
            return true
        }
        return false
    }

    private func expect(_ text: String, _ context: String) throws {
        guard check(text) else {
            diagnostics.error("\(text) が必要です (\(context))", at: current.location)
            throw AbortCompilation()
        }
        advance()
    }

    /// 改行と `;` を読み飛ばす。
    private func skipSeparators() {
        while !isAtEnd, current.kind == .newline || check(";") || check("&") {
            advance()
        }
    }

    private var isSeparator: Bool {
        isAtEnd || current.kind == .newline || check(";") || check("&")
    }

    // MARK: プログラム

    func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipSeparators()
            if isAtEnd { break }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        return MLProgram(statements: statements)
    }

    /// `done` などのブロック終端まで文を読む。
    private func parseStatements(until stops: Set<String>) throws -> [MLStmt] {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipSeparators()
            if isAtEnd || stops.contains(current.text) { break }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        return statements
    }

    // MARK: 文

    private func parseStatement() throws -> MLStmt? {
        skipSeparators()
        if isAtEnd { return nil }
        let location = current.location

        if check("if") { return try parseIf() }
        if check("while") || check("until") { return try parseWhile() }
        if check("for") { return try parseFor() }
        if check("case") { return try parseCase() }
        if check("function") || isFunctionDefinition() { return .funcDecl(try parseFunction()) }
        if check("return") {
            advance()
            var value: MLExpr = .literal(.int(0), location)
            if !isSeparator { value = try parseWord() }
            return .returnStmt(value, location)
        }
        if check("break") {
            advance()
            if !isSeparator { advance() }
            return .breakStmt(label: nil, location)
        }
        if check("continue") {
            advance()
            if !isSeparator { advance() }
            return .continueStmt(label: nil, location)
        }
        if check("{") {
            advance()
            let body = try parseStatements(until: ["}"])
            _ = match("}")
            return .block(body, location)
        }
        if check("local") || check("declare") {
            advance()
            // `local` は関数の有効範囲に入れる (ブロックに閉じ込めない)。
            var declarations: [MLStmt] = []
            while !isSeparator {
                if let (name, value) = try splitAssignment() {
                    declarations.append(.expression(
                        .assign(op: "=", target: .name(name, location), value: value,
                                location), location))
                    continue
                }
                advance()
            }
            if declarations.count == 1 { return declarations[0] }
            return .block(declarations, location)
        }

        return .expression(try parseList(), location)
    }

    /// `name() {` の形かどうか。
    private func isFunctionDefinition() -> Bool {
        guard current.kind == .identifier else { return false }
        return peek(1).text == "(" && peek(2).text == ")"
    }

    private func parseFunction() throws -> MLFunctionDecl {
        let location = current.location
        _ = match("function")
        let name = advance().text
        if match("(") { _ = match(")") }
        skipSeparators()
        try expect("{", "関数の本体")
        let body = try parseStatements(until: ["}"])
        _ = match("}")
        return MLFunctionDecl(name: name,
                              parameters: [MLParameter(name: "#argv", isVariadic: true)],
                              body: body, location: location)
    }

    private func parseIf() throws -> MLStmt {
        let location = current.location
        try expect("if", "if 文")
        let condition = try parseList()
        skipSeparators()
        try expect("then", "if 文")
        let then = try parseStatements(until: ["elif", "else", "fi"])
        var otherwise: [MLStmt]?
        if check("elif") {
            otherwise = [try parseElif()]
        } else if match("else") {
            otherwise = try parseStatements(until: ["fi"])
        }
        _ = match("fi")
        return .ifStmt(condition: condition, then: then, otherwise: otherwise, location)
    }

    private func parseElif() throws -> MLStmt {
        let location = current.location
        try expect("elif", "elif")
        let condition = try parseList()
        skipSeparators()
        try expect("then", "elif")
        let then = try parseStatements(until: ["elif", "else", "fi"])
        var otherwise: [MLStmt]?
        if check("elif") {
            otherwise = [try parseElif()]
        } else if match("else") {
            otherwise = try parseStatements(until: ["fi"])
        }
        return .ifStmt(condition: condition, then: then, otherwise: otherwise, location)
    }

    private func parseWhile() throws -> MLStmt {
        let location = current.location
        let isUntil = check("until")
        advance()
        var condition = try parseList()
        if isUntil {
            condition = .unary(op: "!", operand: condition, isPostfix: false, location)
        }
        skipSeparators()
        try expect("do", "while 文")
        let body = try parseStatements(until: ["done"])
        _ = match("done")
        return .whileStmt(condition: condition, body: body, label: nil, location)
    }

    private func parseFor() throws -> MLStmt {
        let location = current.location
        try expect("for", "for 文")
        // `for ((i = 0; i < 5; i++))`
        if check("((") {
            advance()
            let text = readUntilArithmeticEnd()
            let parts = text.split(separator: ";", omittingEmptySubsequences: false)
                .map(String.init)
            let initializer = parts.count > 0 && !parts[0].trimmed.isEmpty
                ? [MLStmt.expression(try arithmetic(parts[0], location: location), location)]
                : []
            let condition = parts.count > 1 && !parts[1].trimmed.isEmpty
                ? try arithmeticCondition(parts[1], location: location) : nil
            let step = parts.count > 2 && !parts[2].trimmed.isEmpty
                ? [MLStmt.expression(try arithmetic(parts[2], location: location), location)]
                : []
            skipSeparators()
            try expect("do", "for 文")
            let body = try parseStatements(until: ["done"])
            _ = match("done")
            return .forClassic(initializer: initializer, condition: condition, step: step,
                               body: body, label: nil, location)
        }
        let name = advance().text
        var sequence: MLExpr = .name("#argv", location)
        if match("in") {
            var words: [MLExpr] = []
            while !isSeparator, !check("do") { words.append(try parseWord()) }
            sequence = .call(callee: .name("#words", location),
                             arguments: words.map { MLArgument(value: $0) }, location)
        }
        skipSeparators()
        try expect("do", "for 文")
        let body = try parseStatements(until: ["done"])
        _ = match("done")
        return .forIn(pattern: .binding(name), sequence: sequence, body: body,
                      whereClause: nil, label: nil, location)
    }

    private func parseCase() throws -> MLStmt {
        let location = current.location
        try expect("case", "case 文")
        let subject = try parseWord()
        skipSeparators()
        try expect("in", "case 文")
        var arms: [MLMatchArm] = []
        while !isAtEnd, !check("esac") {
            skipSeparators()
            if check("esac") { break }
            _ = match("(")
            var patterns: [MLPattern] = []
            var isDefault = false
            repeat {
                if check(")") { break }
                let word = advance()
                let text = word.stringValue ?? word.text
                if text == "*" { isDefault = true }
                else { patterns.append(.expression(.literal(.string(text), location))) }
            } while match("|")
            _ = match(")")
            let body = try parseStatements(until: [";;", "esac"])
            _ = match(";;")
            arms.append(MLMatchArm(patterns: isDefault ? [] : patterns, body: body,
                                   isDefault: isDefault))
        }
        _ = match("esac")
        return .matchStmt(subject: subject, arms: arms, label: nil, location)
    }

    // MARK: コマンドの並び

    /// `a && b || c` のつながり。
    private func parseList() throws -> MLExpr {
        var left = try parsePipeline()
        while check("&&") || check("||") {
            let location = current.location
            let op = advance().text
            skipSeparators()
            let right = try parsePipeline()
            // 直前のコマンドが成功 (終了状態 0) かどうかで分岐する。
            left = .call(callee: .name(op == "&&" ? "#andThen" : "#orElse", location),
                         arguments: [MLArgument(value: left),
                                     MLArgument(value: .lambda(
                                        MLFunctionDecl(name: "", parameters: [],
                                                       body: [.returnStmt(right, location)],
                                                       location: location), location))],
                         location)
        }
        return left
    }

    /// `a | b` のパイプ。
    private func parsePipeline() throws -> MLExpr {
        var negated = false
        if check("!") {
            advance()
            negated = true
        }
        var stages: [MLExpr] = [try parseCommand()]
        let location = current.location
        while check("|") {
            advance()
            skipSeparators()
            stages.append(try parseCommand())
        }
        var result: MLExpr
        if stages.count == 1 {
            result = stages[0]
        } else {
            let lambdas = stages.map { stage in
                MLArgument(value: .lambda(MLFunctionDecl(name: "", parameters: [],
                                                         body: [.returnStmt(stage, location)],
                                                         location: location), location))
            }
            result = .call(callee: .name("#pipeline", location), arguments: lambdas, location)
        }
        if negated {
            result = .call(callee: .name("#not", location),
                           arguments: [MLArgument(value: result)], location)
        }
        return result
    }

    /// 1 つのコマンド (前置の代入も含む)。
    private func parseCommand() throws -> MLExpr {
        let location = current.location

        // `(( expr ))` は算術評価。
        if check("((") {
            advance()
            let text = readUntilArithmeticEnd()
            return .call(callee: .name("#status", location),
                         arguments: [MLArgument(value: try arithmeticCondition(
                            text, location: location) ?? .literal(.bool(true), location))],
                         location)
        }
        // `[[ ... ]]` と `[ ... ]` は test。
        if check("[[") {
            advance()
            var words: [MLExpr] = []
            while !isAtEnd, !check("]]") { words.append(try parseWord()) }
            _ = match("]]")
            return .call(callee: .name("#test", location),
                         arguments: words.map { MLArgument(value: $0) }, location)
        }

        // 前置の代入 (`X=1 command` / `X=1`)。
        var assignments: [MLExpr] = []
        while let (name, value) = try splitAssignment() {
            assignments.append(.assign(op: "=", target: .name(name, location), value: value,
                                       location))
            if isSeparator || check("|") || check("&&") || check("||") {
                // 代入だけの文。
                var result = assignments[0]
                for extra in assignments.dropFirst() {
                    result = .block([.expression(result, location),
                                     .expression(extra, location)], location)
                }
                return .block([.expression(result, location),
                               .expression(.literal(.int(0), location), location)], location)
            }
        }

        var words: [MLExpr] = []
        while !isAtEnd, !isSeparator, !check("|"), !check("&&"), !check("||"),
              !check(";;"), !check("then"), !check("do"), !check("done"), !check("fi"),
              !check("esac"), !check("}") {
            // 出力の向き先は読み飛ばす。
            if check(">") || check(">>") || check("<") {
                advance()
                if !isSeparator { advance() }
                continue
            }
            words.append(try parseWord())
        }
        guard !words.isEmpty else { return .literal(.int(0), location) }

        var command = MLExpr.call(callee: .name("#run", location),
                                  arguments: words.map { MLArgument(value: $0) }, location)
        // 前置の代入があれば、コマンドの前に実行する。
        if !assignments.isEmpty {
            var statements = assignments.map { MLStmt.expression($0, location) }
            statements.append(.returnStmt(command, location))
            command = .call(callee: .lambda(MLFunctionDecl(name: "", parameters: [],
                                                           body: statements,
                                                           location: location), location),
                            arguments: [], location)
        }
        return command
    }

    /// `NAME=` に続く単語を代入として読む。
    private func splitAssignment() throws -> (String, MLExpr)? {
        guard !isAtEnd, current.kind == .identifier, current.text.hasSuffix("="),
              current.text.count > 1 else { return nil }
        let token = current
        let name = String(token.text.dropLast())
        guard isValidName(name) else { return nil }
        advance()
        // `arr=(1 2 3)` の配列。
        if check("(") {
            advance()
            var items: [MLExpr] = []
            while !isAtEnd, !check(")") { items.append(try parseWord()) }
            _ = match(")")
            return (name, .listLiteral(items, spreadIndices: [], token.location))
        }
        // 値が続かなければ空文字。
        if isSeparator || check("|") || check("&&") || check("||") {
            return (name, .literal(.string(""), token.location))
        }
        return (name, try parseWord())
    }

    private func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: 単語

    /// 単語 1 つを式にする。
    private func parseWord() throws -> MLExpr {
        let token = advance()
        switch token.kind {
        case .interpolatedString:
            return try interpolation(token.pieces, location: token.location)
        case .stringLiteral:
            return .literal(.string(token.stringValue ?? token.text), token.location)
        default:
            return .literal(.string(token.text), token.location)
        }
    }

    /// 展開を含む単語を式にする。
    private func interpolation(_ pieces: [MLStringPiece],
                               location: SourceLocation) throws -> MLExpr {
        var parts: [MLExpr] = []
        for piece in pieces {
            if !piece.isExpression {
                parts.append(.literal(.string(piece.text), piece.location))
                continue
            }
            parts.append(try expansion(piece.text, location: piece.location))
        }
        if parts.count == 1 { return parts[0] }
        return .interpolation(parts, location)
    }

    /// `$name` / `${...}` / `$(...)` / `$((...))` を式にする。
    private func expansion(_ text: String, location: SourceLocation) throws -> MLExpr {
        if text.hasPrefix("#capture("), text.hasSuffix(")") {
            let inner = String(text.dropFirst("#capture(".count).dropLast())
            let program = try subProgram(inner)
            return .call(callee: .name("#capture", location),
                         arguments: [MLArgument(value: .lambda(
                            MLFunctionDecl(name: "", parameters: [], body: program,
                                           location: location), location))],
                         location)
        }
        if text.hasPrefix("#arith("), text.hasSuffix(")") {
            let inner = String(text.dropFirst("#arith(".count).dropLast())
            return try arithmetic(inner, location: location)
        }
        if text.hasPrefix("#param("), text.hasSuffix(")") {
            let inner = String(text.dropFirst("#param(".count).dropLast())
            return try parameter(inner, location: location)
        }
        if text.hasPrefix("#special("), text.hasSuffix(")") {
            let inner = String(text.dropFirst("#special(".count).dropLast())
            switch inner {
            case "?": return .name("?", location)
            case "#": return .call(callee: .name("#argc", location), arguments: [], location)
            default: return .name("#argv", location)
            }
        }
        if text.hasPrefix("#arg("), text.hasSuffix(")") {
            let inner = String(text.dropFirst("#arg(".count).dropLast())
            return .call(callee: .name("#arg", location),
                         arguments: [MLArgument(value: .literal(.int(Int64(inner) ?? 0),
                                                                location))],
                         location)
        }
        // `name[index]` の添字つき。
        if let open = text.firstIndex(of: "["), text.hasSuffix("]") {
            let name = String(text[text.startIndex..<open])
            let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            if inner == "@" || inner == "*" { return .name(name, location) }
            return .subscriptExpr(.name(name, location),
                                  index: try arithmetic(inner, location: location),
                                  upper: nil, location)
        }
        return .name(text, location)
    }

    /// `${name:-default}` のような書き方。
    private func parameter(_ text: String, location: SourceLocation) throws -> MLExpr {
        if text.hasPrefix("#") {
            let name = String(text.dropFirst())
            return .call(callee: .name("#length", location),
                         arguments: [MLArgument(value: try expansion(name,
                                                                     location: location))],
                         location)
        }
        if let range = text.range(of: ":-") {
            let name = String(text[text.startIndex..<range.lowerBound])
            let fallback = String(text[range.upperBound...])
            return .call(callee: .name("#default", location),
                         arguments: [MLArgument(value: .name(name, location)),
                                     MLArgument(value: .literal(.string(fallback),
                                                                location))],
                         location)
        }
        if let hash = text.firstIndex(of: "#"), hash != text.startIndex {
            // `${name#prefix}` は前を削る。
            let name = String(text[text.startIndex..<hash])
            let pattern = String(text[text.index(after: hash)...])
            return .call(callee: .name("#trimPrefix", location),
                         arguments: [MLArgument(value: .name(name, location)),
                                     MLArgument(value: .literal(.string(pattern),
                                                                location))],
                         location)
        }
        return try expansion(text, location: location)
    }

    /// `$(( ... ))` の中身を式として読む。
    private func arithmetic(_ text: String, location: SourceLocation) throws -> MLExpr {
        let lexer = ShellArithmeticLexer(source: text, diagnostics: diagnostics)
        let parser = ShellArithmeticParser(tokens: lexer.tokenize(), diagnostics: diagnostics)
        return try parser.parseExpression()
    }

    /// 算術の条件 (0 以外なら真)。
    private func arithmeticCondition(_ text: String,
                                     location: SourceLocation) throws -> MLExpr? {
        guard !text.trimmed.isEmpty else { return nil }
        let expression = try arithmetic(text, location: location)
        return .call(callee: .name("#truthy", location),
                     arguments: [MLArgument(value: expression)], location)
    }

    /// `((` の対応する `))` まで読む。
    private func readUntilArithmeticEnd() -> String {
        var parts: [String] = []
        var depth = 1
        while !isAtEnd {
            if check("((") { depth += 1 }
            if check("))") {
                depth -= 1
                if depth == 0 {
                    advance()
                    break
                }
            }
            if check(")") {
                // `))` が 2 つの `)` に分かれることもある。
                advance()
                if check(")") {
                    advance()
                    break
                }
                parts.append(")")
                continue
            }
            let token = advance()
            parts.append(token.kind == .stringLiteral ? (token.stringValue ?? token.text)
                                                      : token.text)
        }
        return parts.joined(separator: " ")
    }

    /// コマンド置換の中身を解析する。
    private func subProgram(_ text: String) throws -> [MLStmt] {
        let lexer = ShellLexer(source: text, diagnostics: diagnostics)
        let parser = ShellParser(tokens: lexer.tokenize(), diagnostics: diagnostics)
        return try parser.parseProgram().statements
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// `$(( ))` の中だけで使う、C 風の字句解析。
final class ShellArithmeticLexer: MLProfileLexer {
    static let profile = MLLanguageProfile(
        languageID: "shell-arith",
        comments: [],
        strings: [MLLanguageProfile.StringStyle(quote: "\"")],
        keywords: [],
        operators: MLLanguageProfile.cStyleOperators,
        newlineTerminatesStatement: false,
        usesSemicolons: true,
        variableKeywords: [:],
        typeKeywords: [:],
        nullLiterals: [],
        trueLiterals: [],
        falseLiterals: [],
        selfKeywords: [])

    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: ShellArithmeticLexer.profile,
                   diagnostics: diagnostics)
    }

    override func nextToken() -> MLToken? {
        // `$name` も名前として読む。
        if peek() == "$", let next = peek(1), MLLexerBase.isIdentifierStart(next) {
            let start = location
            advance()
            return MLToken(kind: .identifier, text: readIdentifier(), location: start)
        }
        return super.nextToken()
    }
}

/// `$(( ))` の中の式を読む。
final class ShellArithmeticParser: MLProfileParser {
    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: ShellArithmeticLexer.profile,
                   diagnostics: diagnostics)
    }

    func parseExpression() throws -> MLExpr {
        try parseExpression(stopAtBrace: false)
    }
}
