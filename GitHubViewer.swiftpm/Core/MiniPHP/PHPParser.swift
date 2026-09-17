import Foundation

/// PHP のトークン列を AST にする再帰下降パーサ。
struct PHPParser {
    private let tokens: [PHPToken]
    private var index = 0
    private let diagnostics: DiagnosticBag

    init(tokens: [PHPToken], diagnostics: DiagnosticBag) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }

    // MARK: - トークン操作

    private var current: PHPToken {
        index < tokens.count ? tokens[index] : PHPToken(kind: .endOfFile, location: .unknown)
    }

    private func peek(_ offset: Int) -> PHPToken {
        let position = index + offset
        return position < tokens.count ? tokens[position] : PHPToken(kind: .endOfFile, location: .unknown)
    }

    private var isAtEnd: Bool {
        if case .endOfFile = current.kind { return true }
        return index >= tokens.count
    }

    @discardableResult
    private mutating func advance() -> PHPToken {
        let token = current
        if index < tokens.count { index += 1 }
        return token
    }

    private mutating func match(_ symbol: String) -> Bool {
        if current.isOperator(symbol) {
            advance()
            return true
        }
        return false
    }

    private mutating func matchKeyword(_ keyword: String) -> Bool {
        if current.isKeyword(keyword) {
            advance()
            return true
        }
        return false
    }

    @discardableResult
    private mutating func expect(_ symbol: String, _ context: String) throws -> PHPToken {
        guard current.isOperator(symbol) else {
            diagnostics.error("\(context)に '\(symbol)' が必要です (見つかったのは \(current.text))。",
                              at: current.location)
            throw AbortCompilation()
        }
        return advance()
    }

    private mutating func synchronize() {
        while !isAtEnd {
            if current.isOperator(";") || current.isOperator("}") {
                advance()
                return
            }
            advance()
        }
    }

    // MARK: - 入口

    mutating func parseProgram() -> [PHPStmt] {
        var statements: [PHPStmt] = []
        while !isAtEnd {
            do {
                if let statement = try parseStatement() {
                    statements.append(statement)
                }
            } catch {
                synchronize()
            }
        }
        return statements
    }

    /// 文字列の中の `{$...}` を解析するために使う。
    static func parseExpressionSource(_ source: String, diagnostics: DiagnosticBag,
                                      at location: SourceLocation) -> PHPExpr? {
        var lexer = PHPLexer(source: "<?php " + source + ";", diagnostics: diagnostics)
        var parser = PHPParser(tokens: lexer.tokenize(), diagnostics: diagnostics)
        return try? parser.parseExpression()
    }

    // MARK: - 文

    private mutating func parseStatement() throws -> PHPStmt? {
        let location = current.location

        if case .inlineHTML(let html) = current.kind {
            advance()
            return .inlineHTML(html, location)
        }
        if match(";") { return nil }
        if current.isOperator("{") {
            advance()
            let body = try parseBlockUntilBrace()
            return .block(body, location)
        }

        if let keyword = current.identifier?.lowercased() {
            switch keyword {
            case "echo", "print":
                advance()
                var values: [PHPExpr] = [try parseExpression()]
                while match(",") { values.append(try parseExpression()) }
                _ = match(";")
                return .echo(values, location)

            case "if":
                return try parseIf()

            case "while":
                advance()
                try expect("(", "while の条件の前")
                let condition = try parseExpression()
                try expect(")", "while の条件の後ろ")
                let body = try parseStatementBlock(endKeyword: "endwhile")
                return .whileStmt(condition, body, location)

            case "do":
                advance()
                let body = try parseStatementBlock(endKeyword: nil)
                guard matchKeyword("while") else {
                    diagnostics.error("do の後ろに while が必要です。", at: current.location)
                    throw AbortCompilation()
                }
                try expect("(", "while の条件の前")
                let condition = try parseExpression()
                try expect(")", "while の条件の後ろ")
                _ = match(";")
                return .doWhile(body, condition, location)

            case "for":
                advance()
                try expect("(", "for の前")
                var initial: [PHPExpr] = []
                if !current.isOperator(";") {
                    repeat { initial.append(try parseExpression()) } while match(",")
                }
                try expect(";", "for の初期化の後ろ")
                var condition: [PHPExpr] = []
                if !current.isOperator(";") {
                    repeat { condition.append(try parseExpression()) } while match(",")
                }
                try expect(";", "for の条件の後ろ")
                var step: [PHPExpr] = []
                if !current.isOperator(")") {
                    repeat { step.append(try parseExpression()) } while match(",")
                }
                try expect(")", "for の後ろ")
                let body = try parseStatementBlock(endKeyword: "endfor")
                return .forStmt(initial: initial, condition: condition, step: step, body: body, location)

            case "foreach":
                return try parseForeach()

            case "switch":
                return try parseSwitch()

            case "break", "continue":
                advance()
                var levels = 1
                if case .integer(let value) = current.kind {
                    levels = Int(value)
                    advance()
                }
                _ = match(";")
                return keyword == "break" ? .breakStmt(levels, location) : .continueStmt(levels, location)

            case "return":
                advance()
                if match(";") { return .returnStmt(nil, location) }
                let value = try parseExpression()
                _ = match(";")
                return .returnStmt(value, location)

            case "function":
                // 無名関数を式として使う場合は式文として扱う
                if peek(1).isOperator("(") { break }
                advance()
                let declaration = try parseFunctionDeclaration(location: location)
                return .functionDeclaration(declaration)

            case "class":
                advance()
                return .classDeclaration(try parseClassDeclaration(location: location))

            case "global":
                advance()
                var names: [String] = []
                repeat {
                    if case .variable(let name) = current.kind {
                        names.append(name)
                        advance()
                    }
                } while match(",")
                _ = match(";")
                return .globalStmt(names, location)

            case "unset":
                advance()
                try expect("(", "unset の前")
                var targets: [PHPExpr] = []
                if !current.isOperator(")") {
                    repeat { targets.append(try parseExpression()) } while match(",")
                }
                try expect(")", "unset の後ろ")
                _ = match(";")
                return .unsetStmt(targets, location)

            default:
                break
            }
        }

        let expression = try parseExpression()
        _ = match(";")
        return .expression(expression, location)
    }

    private mutating func parseBlockUntilBrace() throws -> [PHPStmt] {
        var statements: [PHPStmt] = []
        while !current.isOperator("}"), !isAtEnd {
            do {
                if let statement = try parseStatement() { statements.append(statement) }
            } catch {
                synchronize()
                if current.isOperator("}") { break }
            }
        }
        try expect("}", "ブロックの終わり")
        return statements
    }

    /// `{ ... }` か 1 文、または `: ... endwhile;` 形式。
    private mutating func parseStatementBlock(endKeyword: String?) throws -> [PHPStmt] {
        if match("{") {
            return try parseBlockUntilBrace()
        }
        if let endKeyword, match(":") {
            var statements: [PHPStmt] = []
            while !current.isKeyword(endKeyword), !isAtEnd {
                if let statement = try parseStatement() { statements.append(statement) }
            }
            _ = matchKeyword(endKeyword)
            _ = match(";")
            return statements
        }
        if let statement = try parseStatement() { return [statement] }
        return []
    }

    private mutating func parseIf() throws -> PHPStmt {
        let location = current.location
        advance() // if
        try expect("(", "if の条件の前")
        let condition = try parseExpression()
        try expect(")", "if の条件の後ろ")

        var branches: [(condition: PHPExpr, body: [PHPStmt])] = []
        var elseBody: [PHPStmt]?

        // 代替構文 (`if (...): ... endif;`)
        if current.isOperator(":") {
            advance()
            var body: [PHPStmt] = []
            while !current.isKeyword("endif"), !current.isKeyword("else"), !current.isKeyword("elseif"), !isAtEnd {
                if let statement = try parseStatement() { body.append(statement) }
            }
            branches.append((condition, body))
            while current.isKeyword("elseif") {
                advance()
                try expect("(", "elseif の条件の前")
                let nextCondition = try parseExpression()
                try expect(")", "elseif の条件の後ろ")
                _ = match(":")
                var nextBody: [PHPStmt] = []
                while !current.isKeyword("endif"), !current.isKeyword("else"), !current.isKeyword("elseif"), !isAtEnd {
                    if let statement = try parseStatement() { nextBody.append(statement) }
                }
                branches.append((nextCondition, nextBody))
            }
            if matchKeyword("else") {
                _ = match(":")
                var body: [PHPStmt] = []
                while !current.isKeyword("endif"), !isAtEnd {
                    if let statement = try parseStatement() { body.append(statement) }
                }
                elseBody = body
            }
            _ = matchKeyword("endif")
            _ = match(";")
            return .ifStmt(branches: branches, elseBody: elseBody, location)
        }

        branches.append((condition, try parseStatementBlock(endKeyword: nil)))

        while true {
            if current.isKeyword("elseif") {
                advance()
                try expect("(", "elseif の条件の前")
                let nextCondition = try parseExpression()
                try expect(")", "elseif の条件の後ろ")
                branches.append((nextCondition, try parseStatementBlock(endKeyword: nil)))
                continue
            }
            if current.isKeyword("else"), peek(1).isKeyword("if") {
                advance()
                advance()
                try expect("(", "else if の条件の前")
                let nextCondition = try parseExpression()
                try expect(")", "else if の条件の後ろ")
                branches.append((nextCondition, try parseStatementBlock(endKeyword: nil)))
                continue
            }
            if current.isKeyword("else") {
                advance()
                elseBody = try parseStatementBlock(endKeyword: nil)
            }
            break
        }
        return .ifStmt(branches: branches, elseBody: elseBody, location)
    }

    private mutating func parseForeach() throws -> PHPStmt {
        let location = current.location
        advance() // foreach
        try expect("(", "foreach の前")
        let subject = try parseExpression()
        guard matchKeyword("as") else {
            diagnostics.error("foreach には as が必要です。", at: current.location)
            throw AbortCompilation()
        }

        var byReference = match("&")
        var firstName = ""
        if case .variable(let name) = current.kind {
            firstName = name
            advance()
        } else {
            diagnostics.error("foreach の変数が必要です。", at: current.location)
            throw AbortCompilation()
        }

        var keyVariable: String?
        var valueVariable = firstName
        if match("=>") {
            keyVariable = firstName
            byReference = match("&")
            if case .variable(let name) = current.kind {
                valueVariable = name
                advance()
            } else {
                diagnostics.error("foreach の値の変数が必要です。", at: current.location)
                throw AbortCompilation()
            }
        }
        try expect(")", "foreach の後ろ")
        let body = try parseStatementBlock(endKeyword: "endforeach")
        return .foreachStmt(subject: subject, keyVariable: keyVariable, valueVariable: valueVariable,
                            byReference: byReference, body: body, location)
    }

    private mutating func parseSwitch() throws -> PHPStmt {
        let location = current.location
        advance() // switch
        try expect("(", "switch の前")
        let subject = try parseExpression()
        try expect(")", "switch の後ろ")
        try expect("{", "switch の本体の前")

        var cases: [(value: PHPExpr?, body: [PHPStmt])] = []
        var currentValue: PHPExpr?
        var currentBody: [PHPStmt] = []
        var started = false

        while !current.isOperator("}"), !isAtEnd {
            if current.isKeyword("case") {
                if started { cases.append((currentValue, currentBody)) }
                advance()
                currentValue = try parseExpression()
                _ = match(":") || match(";")
                currentBody = []
                started = true
                continue
            }
            if current.isKeyword("default") {
                if started { cases.append((currentValue, currentBody)) }
                advance()
                _ = match(":") || match(";")
                currentValue = nil
                currentBody = []
                started = true
                continue
            }
            guard started else {
                diagnostics.error("switch の中は case か default から始めてください。", at: current.location)
                throw AbortCompilation()
            }
            if let statement = try parseStatement() { currentBody.append(statement) }
        }
        if started { cases.append((currentValue, currentBody)) }
        try expect("}", "switch の本体の終わり")
        return .switchStmt(subject: subject, cases: cases, location)
    }

    // MARK: - 関数とクラス

    private mutating func parseFunctionDeclaration(location: SourceLocation,
                                                   isStatic: Bool = false) throws -> PHPFunctionDeclaration {
        _ = match("&")
        guard let name = current.identifier else {
            diagnostics.error("関数名が必要です。", at: current.location)
            throw AbortCompilation()
        }
        advance()
        let parameters = try parseParameterList()
        try skipReturnType()
        try expect("{", "関数の本体の前")
        let body = try parseBlockUntilBrace()
        return PHPFunctionDeclaration(name: name, parameters: parameters, body: body,
                                      isStatic: isStatic, location: location)
    }

    private mutating func parseParameterList() throws -> [PHPParameter] {
        try expect("(", "引数リストの前")
        var parameters: [PHPParameter] = []
        while !current.isOperator(")"), !isAtEnd {
            skipTypeHint()
            let byReference = match("&")
            let isVariadic = match("...")
            guard case .variable(let name) = current.kind else {
                diagnostics.error("引数の変数名が必要です (見つかったのは \(current.text))。", at: current.location)
                throw AbortCompilation()
            }
            advance()
            var defaultValue: PHPExpr?
            if match("=") {
                defaultValue = try parseExpression()
            }
            parameters.append(PHPParameter(name: name, defaultValue: defaultValue,
                                           isVariadic: isVariadic, byReference: byReference))
            if !match(",") { break }
        }
        try expect(")", "引数リストの後ろ")
        return parameters
    }

    /// `int`, `?string`, `array`, `int|string` などの型宣言を読み飛ばす。
    private mutating func skipTypeHint() {
        _ = match("?")
        guard current.identifier != nil else { return }
        let next = peek(1)
        var looksLikeType = false
        if case .variable = next.kind { looksLikeType = true }
        if next.isOperator("&") || next.isOperator("...") || next.isOperator("|") { looksLikeType = true }
        guard looksLikeType else { return }
        advance()
        while current.isOperator("|") {
            advance()
            _ = match("?")
            if current.identifier != nil { advance() }
        }
    }

    private mutating func skipReturnType() throws {
        if match(":") {
            _ = match("?")
            while current.identifier != nil || current.isOperator("|") { advance() }
        }
    }

    private mutating func parseClassDeclaration(location: SourceLocation) throws -> PHPClassDeclaration {
        guard let name = current.identifier else {
            diagnostics.error("クラス名が必要です。", at: current.location)
            throw AbortCompilation()
        }
        advance()

        var parentName: String?
        if matchKeyword("extends") {
            parentName = current.identifier
            advance()
        }
        if matchKeyword("implements") {
            while current.identifier != nil || current.isOperator(",") { advance() }
        }
        try expect("{", "クラスの本体の前")

        var properties: [(name: String, defaultValue: PHPExpr?)] = []
        var methods: [String: PHPFunctionDeclaration] = [:]
        var constants: [(name: String, value: PHPExpr)] = []

        while !current.isOperator("}"), !isAtEnd {
            var isStatic = false
            // 修飾子
            while let keyword = current.identifier?.lowercased(),
                  ["public", "private", "protected", "final", "abstract", "readonly", "static", "var"]
                    .contains(keyword) {
                if keyword == "static" { isStatic = true }
                advance()
            }

            if current.isKeyword("const") {
                advance()
                repeat {
                    guard let constantName = current.identifier else { break }
                    advance()
                    try expect("=", "定数の値の前")
                    constants.append((constantName, try parseExpression()))
                } while match(",")
                _ = match(";")
                continue
            }

            if current.isKeyword("function") {
                let methodLocation = current.location
                advance()
                let method = try parseFunctionDeclaration(location: methodLocation, isStatic: isStatic)
                methods[method.name.lowercased()] = method
                continue
            }

            // プロパティ (型宣言つきもある)
            skipTypeHint()
            if case .variable(let propertyName) = current.kind {
                advance()
                var defaultValue: PHPExpr?
                if match("=") { defaultValue = try parseExpression() }
                properties.append((propertyName, defaultValue))
                while match(",") {
                    if case .variable(let extraName) = current.kind {
                        advance()
                        var extraDefault: PHPExpr?
                        if match("=") { extraDefault = try parseExpression() }
                        properties.append((extraName, extraDefault))
                    }
                }
                _ = match(";")
                continue
            }

            diagnostics.error("クラスの中で解釈できない書き方です (\(current.text))。", at: current.location)
            advance()
        }
        try expect("}", "クラスの本体の終わり")
        return PHPClassDeclaration(name: name, parentName: parentName, properties: properties,
                                   methods: methods, constants: constants, location: location)
    }

    // MARK: - 式

    mutating func parseExpression() throws -> PHPExpr {
        try parseAssignment()
    }

    private static let assignmentOperators = ["=", "+=", "-=", "*=", "/=", ".=", "%=", "**=",
                                              "??=", "|=", "&=", "^=", "<<=", ">>="]

    private mutating func parseAssignment() throws -> PHPExpr {
        let left = try parseTernary()
        if case .op(let symbol) = current.kind, PHPParser.assignmentOperators.contains(symbol) {
            let location = current.location
            advance()
            _ = match("&") // 参照代入は値代入として扱う
            let right = try parseAssignment()
            return .assign(symbol, left, right, location)
        }
        return left
    }

    private mutating func parseTernary() throws -> PHPExpr {
        var condition = try parseCoalesce()
        while current.isOperator("?") {
            let location = current.location
            advance()
            if match(":") {
                let otherwise = try parseAssignment()
                condition = .ternary(condition, nil, otherwise, location)
                continue
            }
            let then = try parseAssignment()
            try expect(":", "三項演算子の ':'")
            let otherwise = try parseAssignment()
            condition = .ternary(condition, then, otherwise, location)
        }
        return condition
    }

    private mutating func parseCoalesce() throws -> PHPExpr {
        let left = try parseLogicalOr()
        if current.isOperator("??") {
            let location = current.location
            advance()
            let right = try parseCoalesce()
            return .binary("??", left, right, location)
        }
        return left
    }

    private mutating func parseLogicalOr() throws -> PHPExpr {
        var left = try parseLogicalAnd()
        while current.isOperator("||") || current.isKeyword("or") {
            let location = current.location
            advance()
            let right = try parseLogicalAnd()
            left = .binary("||", left, right, location)
        }
        return left
    }

    private mutating func parseLogicalAnd() throws -> PHPExpr {
        var left = try parseComparison()
        while current.isOperator("&&") || current.isKeyword("and") {
            let location = current.location
            advance()
            let right = try parseComparison()
            left = .binary("&&", left, right, location)
        }
        return left
    }

    private static let comparisonOperators = ["===", "!==", "==", "!=", "<>", "<=>", "<=", ">=", "<", ">"]

    private mutating func parseComparison() throws -> PHPExpr {
        var left = try parseInstanceOf()
        while case .op(let symbol) = current.kind, PHPParser.comparisonOperators.contains(symbol) {
            let location = current.location
            advance()
            let right = try parseInstanceOf()
            left = .binary(symbol == "<>" ? "!=" : symbol, left, right, location)
        }
        return left
    }

    private mutating func parseInstanceOf() throws -> PHPExpr {
        let left = try parseAdditive()
        guard current.isKeyword("instanceof") else { return left }
        let location = current.location
        advance()
        if let className = current.identifier {
            advance()
            return .binary("instanceof", left, .constant(className, location), location)
        }
        let right = try parseAdditive()
        return .binary("instanceof", left, right, location)
    }

    private mutating func parseAdditive() throws -> PHPExpr {
        var left = try parseMultiplicative()
        while current.isOperator("+") || current.isOperator("-") || current.isOperator(".")
                || current.isOperator("|") || current.isOperator("^") || current.isOperator("&")
                || current.isOperator("<<") || current.isOperator(">>") {
            guard case .op(let symbol) = current.kind else { break }
            let location = current.location
            advance()
            let right = try parseMultiplicative()
            left = .binary(symbol, left, right, location)
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> PHPExpr {
        var left = try parsePower()
        while current.isOperator("*") || current.isOperator("/") || current.isOperator("%") {
            guard case .op(let symbol) = current.kind else { break }
            let location = current.location
            advance()
            let right = try parsePower()
            left = .binary(symbol, left, right, location)
        }
        return left
    }

    /// `**` は右結合で、単項マイナスより強く結びつく (-2 ** 2 は -4)。
    private mutating func parsePower() throws -> PHPExpr {
        let left = try parseUnary()
        guard current.isOperator("**") else { return left }
        let location = current.location
        advance()
        let right = try parsePower()
        return .binary("**", left, right, location)
    }

    private static let castTypes = ["int", "integer", "float", "double", "string", "bool", "boolean", "array"]

    private mutating func parseUnary() throws -> PHPExpr {
        let location = current.location

        if current.isOperator("!") {
            advance()
            return .unary("!", try parsePower(), location)
        }
        if current.isOperator("-") {
            advance()
            return .unary("-", try parsePower(), location)
        }
        if current.isOperator("+") {
            advance()
            return .unary("+", try parsePower(), location)
        }
        if current.isOperator("~") {
            advance()
            return .unary("~", try parsePower(), location)
        }
        if current.isOperator("@") {
            advance()
            return try parseUnary()
        }
        if current.isOperator("++") || current.isOperator("--") {
            let isIncrement = current.isOperator("++")
            advance()
            let target = try parseUnary()
            return .increment(target, isIncrement: isIncrement, isPrefix: true, location)
        }
        // 型変換 `(int)$x`
        if current.isOperator("("), let name = peek(1).identifier?.lowercased(),
           PHPParser.castTypes.contains(name), peek(2).isOperator(")") {
            advance()
            advance()
            advance()
            return .cast(name, try parseUnary(), location)
        }
        if current.isKeyword("new") {
            advance()
            guard let className = current.identifier else {
                diagnostics.error("new の後ろにクラス名が必要です。", at: current.location)
                throw AbortCompilation()
            }
            advance()
            var arguments: [PHPExpr] = []
            if match("(") {
                while !current.isOperator(")"), !isAtEnd {
                    arguments.append(try parseExpression())
                    if !match(",") { break }
                }
                try expect(")", "引数の後ろ")
            }
            return try parsePostfix(.newObject(className, arguments, location))
        }
        if current.isKeyword("print") {
            advance()
            return .call("print", [try parseExpression()], location)
        }
        if current.isKeyword("clone") {
            advance()
            return .call("clone", [try parseUnary()], location)
        }

        return try parsePostfix(try parsePrimary())
    }

    private mutating func parsePostfix(_ start: PHPExpr) throws -> PHPExpr {
        var expression = start
        while true {
            let location = current.location
            if match("[") {
                if match("]") {
                    expression = .index(expression, nil, location)
                    continue
                }
                let indexExpression = try parseExpression()
                try expect("]", "添字の後ろ")
                expression = .index(expression, indexExpression, location)
            } else if match("{") {
                let indexExpression = try parseExpression()
                try expect("}", "添字の後ろ")
                expression = .index(expression, indexExpression, location)
            } else if current.isOperator("->") || current.isOperator("?->") {
                advance()
                guard let name = current.identifier else {
                    diagnostics.error("-> の後ろにプロパティ名かメソッド名が必要です。", at: current.location)
                    throw AbortCompilation()
                }
                advance()
                if match("(") {
                    var arguments: [PHPExpr] = []
                    while !current.isOperator(")"), !isAtEnd {
                        arguments.append(try parseExpression())
                        if !match(",") { break }
                    }
                    try expect(")", "引数の後ろ")
                    expression = .methodCall(expression, name, arguments, location)
                } else {
                    expression = .property(expression, name, location)
                }
            } else if current.isOperator("(") {
                advance()
                var arguments: [PHPExpr] = []
                while !current.isOperator(")"), !isAtEnd {
                    arguments.append(try parseExpression())
                    if !match(",") { break }
                }
                try expect(")", "引数の後ろ")
                if case .constant(let name, _) = expression {
                    expression = .call(name, arguments, location)
                } else {
                    expression = .callValue(expression, arguments, location)
                }
            } else if current.isOperator("++") || current.isOperator("--") {
                let isIncrement = current.isOperator("++")
                advance()
                expression = .increment(expression, isIncrement: isIncrement, isPrefix: false, location)
            } else {
                return expression
            }
        }
    }

    private mutating func parsePrimary() throws -> PHPExpr {
        let location = current.location
        switch current.kind {
        case .integer(let value):
            advance()
            return .literal(.integer(value), location)
        case .number(let value):
            advance()
            return .literal(.number(value), location)
        case .singleQuoted(let text):
            advance()
            return .literal(.text(text.replacingOccurrences(of: "\u{1}", with: "$")), location)
        case .doubleQuoted(let text):
            advance()
            return interpolate(text, at: location)
        case .variable(let name):
            advance()
            if name == "this" { return .thisReference(location) }
            return .variable(name, location)
        case .op("("):
            advance()
            let inner = try parseExpression()
            try expect(")", "括弧の後ろ")
            return inner
        case .op("["):
            advance()
            return try parseArrayLiteral(closing: "]", location: location)
        case .op("&"):
            advance()
            return try parseUnary()
        case .identifier(let name):
            let lowered = name.lowercased()
            if lowered == "true" { advance(); return .literal(.boolean(true), location) }
            if lowered == "false" { advance(); return .literal(.boolean(false), location) }
            if lowered == "null" { advance(); return .literal(.null, location) }
            if lowered == "array", peek(1).isOperator("(") {
                advance()
                advance()
                return try parseArrayLiteral(closing: ")", location: location)
            }
            if lowered == "isset" {
                advance()
                try expect("(", "isset の前")
                var targets: [PHPExpr] = []
                while !current.isOperator(")"), !isAtEnd {
                    targets.append(try parseExpression())
                    if !match(",") { break }
                }
                try expect(")", "isset の後ろ")
                return .issetCheck(targets, location)
            }
            if lowered == "empty" {
                advance()
                try expect("(", "empty の前")
                let target = try parseExpression()
                try expect(")", "empty の後ろ")
                return .emptyCheck(target, location)
            }
            if lowered == "function" || lowered == "fn" {
                advance()
                _ = match("&")
                let parameters = try parseParameterList()
                var captured: [String] = []
                if matchKeyword("use") {
                    try expect("(", "use の前")
                    while !current.isOperator(")"), !isAtEnd {
                        _ = match("&")
                        if case .variable(let name) = current.kind {
                            captured.append(name)
                            advance()
                        }
                        if !match(",") { break }
                    }
                    try expect(")", "use の後ろ")
                }
                try skipReturnType()
                if lowered == "fn" {
                    // アロー関数: `fn($x) => 式`
                    try expect("=>", "アロー関数の =>")
                    let body = try parseExpression()
                    let declaration = PHPFunctionDeclaration(name: "{closure}", parameters: parameters,
                                                             body: [.returnStmt(body, location)],
                                                             location: location)
                    return .closure(declaration, [], location)
                }
                try expect("{", "クロージャの本体の前")
                let body = try parseBlockUntilBrace()
                let declaration = PHPFunctionDeclaration(name: "{closure}", parameters: parameters,
                                                         body: body, location: location)
                return .closure(declaration, captured, location)
            }

            advance()
            // クラス定数・静的メソッド
            if current.isOperator("::") {
                advance()
                guard let member = current.identifier else {
                    diagnostics.error(":: の後ろに名前が必要です。", at: current.location)
                    throw AbortCompilation()
                }
                advance()
                if match("(") {
                    var arguments: [PHPExpr] = []
                    while !current.isOperator(")"), !isAtEnd {
                        arguments.append(try parseExpression())
                        if !match(",") { break }
                    }
                    try expect(")", "引数の後ろ")
                    return .staticCall(name, member, arguments, location)
                }
                return .classConstant(name, member, location)
            }
            return .constant(name, location)
        default:
            diagnostics.error("式が必要です (見つかったのは \(current.text))。", at: location)
            throw AbortCompilation()
        }
    }

    private mutating func parseArrayLiteral(closing: String, location: SourceLocation) throws -> PHPExpr {
        var items: [(key: PHPExpr?, value: PHPExpr)] = []
        while !current.isOperator(closing), !isAtEnd {
            let first = try parseExpression()
            if match("=>") {
                let value = try parseExpression()
                items.append((first, value))
            } else {
                items.append((nil, first))
            }
            if !match(",") { break }
        }
        try expect(closing, "配列の終わり")
        return .arrayLiteral(items, location)
    }

    // MARK: - 文字列の変数展開

    /// `"合計は $total 円"` や `"{$items['a']}"` を、結合する式に分解する。
    private func interpolate(_ text: String, at location: SourceLocation) -> PHPExpr {
        var parts: [PHPExpr] = []
        var literal = ""
        let characters = Array(text)
        var index = 0

        func flush() {
            if !literal.isEmpty {
                parts.append(.literal(.text(literal.replacingOccurrences(of: "\u{1}", with: "$")), location))
                literal = ""
            }
        }

        while index < characters.count {
            let character = characters[index]

            // {$ ... }
            if character == "{", index + 1 < characters.count, characters[index + 1] == "$" {
                var depth = 1
                var inner = ""
                index += 1
                while index < characters.count {
                    let current = characters[index]
                    if current == "{" { depth += 1 }
                    if current == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    inner.append(current)
                    index += 1
                }
                index += 1
                flush()
                if let expression = PHPParser.parseExpressionSource(inner, diagnostics: diagnostics,
                                                                    at: location) {
                    parts.append(expression)
                }
                continue
            }

            // $name, $name[...], $name->prop
            if character == "$", index + 1 < characters.count,
               characters[index + 1].isLetter || characters[index + 1] == "_" {
                var source = "$"
                index += 1
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    source.append(characters[index])
                    index += 1
                }
                // 添字 (引用符なしのキーも許す)
                if index < characters.count, characters[index] == "[" {
                    var inner = ""
                    index += 1
                    while index < characters.count, characters[index] != "]" {
                        inner.append(characters[index])
                        index += 1
                    }
                    index += 1
                    let trimmed = inner.trimmingCharacters(in: .whitespaces)
                    let isQuoted = trimmed.hasPrefix("'") || trimmed.hasPrefix("\"")
                    let isNumeric = Int(trimmed) != nil
                    let isVariable = trimmed.hasPrefix("$")
                    source += "[" + (isQuoted || isNumeric || isVariable ? trimmed : "'\(trimmed)'") + "]"
                } else if index + 1 < characters.count, characters[index] == "-", characters[index + 1] == ">" {
                    var lookahead = index + 2
                    var property = ""
                    while lookahead < characters.count,
                          characters[lookahead].isLetter || characters[lookahead].isNumber
                            || characters[lookahead] == "_" {
                        property.append(characters[lookahead])
                        lookahead += 1
                    }
                    if !property.isEmpty {
                        source += "->" + property
                        index = lookahead
                    }
                }
                flush()
                if let expression = PHPParser.parseExpressionSource(source, diagnostics: diagnostics,
                                                                    at: location) {
                    parts.append(expression)
                }
                continue
            }

            literal.append(character)
            index += 1
        }
        flush()

        if parts.isEmpty { return .literal(.text(""), location) }
        if parts.count == 1, case .literal = parts[0] { return parts[0] }
        return .interpolated(parts, location)
    }
}
