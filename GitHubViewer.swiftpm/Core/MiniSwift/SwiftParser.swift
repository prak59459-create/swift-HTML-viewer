import Foundation

/// Swift のトークン列を AST にする再帰下降パーサ。
struct SwiftParser {
    private let tokens: [SwiftToken]
    private var index = 0
    private let diagnostics: DiagnosticBag
    /// 条件式の中では `{` を末尾クロージャと解釈しない。
    private var allowsTrailingClosure = true

    init(tokens: [SwiftToken], diagnostics: DiagnosticBag) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }

    // MARK: - トークン操作

    private var current: SwiftToken {
        index < tokens.count ? tokens[index] : SwiftToken(kind: .endOfFile, location: .unknown, startsLine: false)
    }

    private func peek(_ offset: Int) -> SwiftToken {
        let position = index + offset
        return position < tokens.count ? tokens[position]
            : SwiftToken(kind: .endOfFile, location: .unknown, startsLine: false)
    }

    private var isAtEnd: Bool {
        if case .endOfFile = current.kind { return true }
        return index >= tokens.count
    }

    @discardableResult
    private mutating func advance() -> SwiftToken {
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
    private mutating func expect(_ symbol: String, _ context: String) throws -> SwiftToken {
        guard current.isOperator(symbol) else {
            diagnostics.error("\(context)に '\(symbol)' が必要です (見つかったのは \(current.text))。",
                              at: current.location)
            throw AbortCompilation()
        }
        return advance()
    }

    private mutating func expectIdentifier(_ context: String) throws -> String {
        guard let name = current.identifier else {
            diagnostics.error("\(context)に名前が必要です (見つかったのは \(current.text))。", at: current.location)
            throw AbortCompilation()
        }
        advance()
        return name
    }

    private mutating func synchronize() {
        while !isAtEnd {
            if current.isOperator("}") || current.startsLine { return }
            advance()
        }
    }

    // MARK: - 入口

    mutating func parseProgram() -> [SwiftStmt] {
        var statements: [SwiftStmt] = []
        while !isAtEnd {
            do {
                if let statement = try parseStatement() { statements.append(statement) }
            } catch {
                synchronize()
                if !isAtEnd, current.isOperator("}") { advance() }
            }
        }
        return statements
    }

    static func parseExpressionSource(_ source: String, diagnostics: DiagnosticBag) -> SwiftExpr? {
        var lexer = SwiftLexer(source: source, diagnostics: diagnostics)
        var parser = SwiftParser(tokens: lexer.tokenize(), diagnostics: diagnostics)
        return try? parser.parseExpression()
    }

    // MARK: - 文

    private mutating func parseStatement() throws -> SwiftStmt? {
        let location = current.location
        if match(";") { return nil }

        if let keyword = current.identifier {
            switch keyword {
            case "let", "var":
                return try parseVariableDeclaration()
            case "func":
                advance()
                return .functionDeclaration(try parseFunctionDeclaration(location: location))
            case "struct", "class", "enum":
                advance()
                let kind: SwiftTypeDeclaration.Kind = keyword == "struct" ? .structure
                    : (keyword == "class" ? .classType : .enumeration)
                return .typeDeclaration(try parseTypeDeclaration(kind: kind, location: location))
            case "if":
                return try parseIf()
            case "guard":
                advance()
                let conditions = try parseConditionList()
                guard matchKeyword("else") else {
                    diagnostics.error("guard には else が必要です。", at: current.location)
                    throw AbortCompilation()
                }
                let body = try parseBlock()
                return .guardStmt(conditions: conditions, elseBody: body, location)
            case "while":
                advance()
                let conditions = try parseConditionList()
                let body = try parseBlock()
                if conditions.count == 1, case .expression(let condition) = conditions[0] {
                    return .whileStmt(condition, body, location)
                }
                return .whileLet(conditions: conditions, body: body, location)
            case "repeat":
                advance()
                let body = try parseBlock()
                guard matchKeyword("while") else {
                    diagnostics.error("repeat の後ろに while が必要です。", at: current.location)
                    throw AbortCompilation()
                }
                let condition = try parseExpression()
                return .repeatWhile(body, condition, location)
            case "for":
                return try parseForIn()
            case "switch":
                return try parseSwitch()
            case "break":
                advance()
                return .breakStmt(location)
            case "continue":
                advance()
                return .continueStmt(location)
            case "return":
                advance()
                if current.isOperator("}") || current.startsLine {
                    return .returnStmt(nil, location)
                }
                return .returnStmt(try parseExpression(), location)
            case "import":
                advance()
                _ = try? expectIdentifier("モジュール名")
                return nil
            case "typealias":
                advance()
                _ = try? expectIdentifier("型の別名")
                _ = match("=")
                _ = try? parseTypeName()
                return nil
            case "extension", "protocol":
                diagnostics.error("\(keyword) にはまだ対応していません。", at: location)
                throw AbortCompilation()
            default:
                break
            }
        }

        let expression = try parseExpression()
        return .expression(expression, location)
    }

    private mutating func parseVariableDeclaration() throws -> SwiftStmt {
        let location = current.location
        let isConstant = current.isKeyword("let")
        advance()
        let name = try expectIdentifier("変数")
        var typeName: String?
        if match(":") {
            typeName = try parseTypeName()
        }
        var value: SwiftExpr?
        if match("=") {
            value = try parseExpression()
        }
        return .variableDeclaration(name: name, typeName: typeName, value: value,
                                    isConstant: isConstant, location)
    }

    /// 型の書き方を文字列として読み取る (`[Int]`, `[String: Int]`, `Int?`, `(Int) -> Int`)。
    private mutating func parseTypeName() throws -> String {
        // @escaping などの属性は読み飛ばす
        while current.isOperator("@") {
            advance()
            _ = try? expectIdentifier("属性")
        }
        var text = ""
        if match("[") {
            text = "["
            text += try parseTypeName()
            if match(":") {
                text += ": " + (try parseTypeName())
            }
            try expect("]", "型の後ろ")
            text += "]"
        } else if current.isOperator("(") {
            advance()
            var parts: [String] = []
            while !current.isOperator(")"), !isAtEnd {
                // `(min: Int, max: Int)` のようなラベル付きタプル
                if current.identifier != nil, peek(1).isOperator(":") {
                    let label = try expectIdentifier("タプルの要素名")
                    _ = match(":")
                    parts.append(label + ": " + (try parseTypeName()))
                } else {
                    parts.append(try parseTypeName())
                }
                if !match(",") { break }
            }
            try expect(")", "型の後ろ")
            text = "(" + parts.joined(separator: ", ") + ")"
            if match("->") {
                text += " -> " + (try parseTypeName())
            }
        } else {
            text = try expectIdentifier("型")
            if match("<") {
                var parts: [String] = []
                while !current.isOperator(">"), !isAtEnd {
                    parts.append(try parseTypeName())
                    if !match(",") { break }
                }
                _ = match(">")
                text += "<" + parts.joined(separator: ", ") + ">"
            }
            if match("->") {
                text += " -> " + (try parseTypeName())
            }
        }
        while match("?") { text += "?" }
        while match("!") { text += "!" }
        return text
    }

    private mutating func parseBlock() throws -> [SwiftStmt] {
        try expect("{", "ブロックの始まり")
        var statements: [SwiftStmt] = []
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

    /// `if`/`while`/`guard` の条件 (末尾クロージャを許さない)。
    private mutating func parseConditionExpression() throws -> SwiftExpr {
        let saved = allowsTrailingClosure
        allowsTrailingClosure = false
        defer { allowsTrailingClosure = saved }
        return try parseExpression()
    }

    private mutating func parseConditionList() throws -> [SwiftCondition] {
        var conditions: [SwiftCondition] = []
        repeat {
            if current.isKeyword("let") || current.isKeyword("var") {
                let isConstant = current.isKeyword("let")
                advance()
                let name = try expectIdentifier("束縛する変数")
                if match("=") {
                    let value = try parseConditionExpression()
                    conditions.append(.optionalBinding(name: name, value: value, isConstant: isConstant))
                } else {
                    // `if let x` (短縮形)
                    conditions.append(.optionalBinding(name: name,
                                                       value: .identifier(name, current.location),
                                                       isConstant: isConstant))
                }
                continue
            }
            conditions.append(.expression(try parseConditionExpression()))
        } while match(",")
        return conditions
    }

    private mutating func parseIf() throws -> SwiftStmt {
        let location = current.location
        advance() // if
        let conditions = try parseConditionList()
        let body = try parseBlock()
        var elseBody: [SwiftStmt]?
        if matchKeyword("else") {
            if current.isKeyword("if") {
                elseBody = [try parseIf()]
            } else {
                elseBody = try parseBlock()
            }
        }
        return .ifStmt(conditions: conditions, body: body, elseBody: elseBody, location)
    }

    private mutating func parseForIn() throws -> SwiftStmt {
        let location = current.location
        advance() // for
        var variable = "_"
        if current.isOperator("(") {
            // for (index, value) in ... → タプルの分解
            advance()
            var names: [String] = []
            while !current.isOperator(")"), !isAtEnd {
                if current.isOperator("_") {
                    advance()
                    names.append("_")
                } else {
                    names.append(try expectIdentifier("変数"))
                }
                if !match(",") { break }
            }
            try expect(")", "変数の後ろ")
            variable = names.joined(separator: ",")
        } else if current.isOperator("_") {
            advance()
        } else {
            variable = try expectIdentifier("変数")
        }
        guard matchKeyword("in") else {
            diagnostics.error("for には in が必要です。", at: current.location)
            throw AbortCompilation()
        }
        let sequence = try parseConditionExpression()
        var whereClause: SwiftExpr?
        if matchKeyword("where") {
            whereClause = try parseConditionExpression()
        }
        let body = try parseBlock()
        return .forIn(variable: variable, sequence: sequence, whereClause: whereClause, body: body, location)
    }

    private mutating func parseSwitch() throws -> SwiftStmt {
        let location = current.location
        advance() // switch
        let subject = try parseConditionExpression()
        try expect("{", "switch の本体の前")

        var cases: [SwiftSwitchCase] = []
        while !current.isOperator("}"), !isAtEnd {
            if matchKeyword("case") {
                var patterns: [SwiftPattern] = []
                repeat {
                    patterns.append(try parsePattern())
                } while match(",")
                var whereClause: SwiftExpr?
                if matchKeyword("where") {
                    whereClause = try parseConditionExpression()
                }
                try expect(":", "case の後ろ")
                let body = try parseCaseBody()
                cases.append(SwiftSwitchCase(patterns: patterns, whereClause: whereClause,
                                             body: body, isDefault: false))
                continue
            }
            if matchKeyword("default") {
                try expect(":", "default の後ろ")
                let body = try parseCaseBody()
                cases.append(SwiftSwitchCase(patterns: [], whereClause: nil, body: body, isDefault: true))
                continue
            }
            diagnostics.error("switch の中は case か default から始めてください。", at: current.location)
            throw AbortCompilation()
        }
        try expect("}", "switch の本体の終わり")
        return .switchStmt(subject: subject, cases: cases, location)
    }

    private mutating func parseCaseBody() throws -> [SwiftStmt] {
        var statements: [SwiftStmt] = []
        while !current.isKeyword("case"), !current.isKeyword("default"), !current.isOperator("}"), !isAtEnd {
            if let statement = try parseStatement() { statements.append(statement) }
        }
        return statements
    }

    private mutating func parsePattern() throws -> SwiftPattern {
        if current.isOperator("_") {
            advance()
            return .wildcard
        }
        if current.isKeyword("let") || current.isKeyword("var") {
            advance()
            let name = try expectIdentifier("束縛する変数")
            return .binding(name)
        }
        if current.isOperator(".") {
            advance()
            let name = try expectIdentifier("列挙のケース")
            var binding: String?
            if match("(") {
                if current.isKeyword("let") || current.isKeyword("var") { advance() }
                binding = try expectIdentifier("束縛する変数")
                try expect(")", "ケースの後ろ")
            }
            return .enumCase(name, binding: binding)
        }
        let saved = allowsTrailingClosure
        allowsTrailingClosure = false
        defer { allowsTrailingClosure = saved }
        return .expression(try parseExpression())
    }

    // MARK: - 関数と型

    private mutating func parseFunctionDeclaration(location: SourceLocation,
                                                   isMutating: Bool = false,
                                                   isStatic: Bool = false) throws -> SwiftFunctionDeclaration {
        let name = try expectIdentifier("関数")
        // ジェネリクスは読み飛ばす
        if match("<") {
            while !current.isOperator(">"), !isAtEnd { advance() }
            _ = match(">")
        }
        let parameters = try parseParameterList()
        var returnTypeName: String?
        if match("->") {
            returnTypeName = try parseTypeName()
        }
        if current.isKeyword("throws") || current.isKeyword("rethrows") { advance() }
        if match("->") { returnTypeName = try parseTypeName() }
        let body = try parseBlock()
        return SwiftFunctionDeclaration(name: name, parameters: parameters, returnTypeName: returnTypeName,
                                        body: body, isMutating: isMutating, isStatic: isStatic,
                                        isInitializer: name == "init", location: location)
    }

    private mutating func parseParameterList() throws -> [SwiftParameter] {
        try expect("(", "引数リストの前")
        var parameters: [SwiftParameter] = []
        while !current.isOperator(")"), !isAtEnd {
            var label: String?
            var name: String
            if current.isOperator("_") {
                advance()
                label = nil
                name = try expectIdentifier("引数")
            } else {
                let first = try expectIdentifier("引数")
                if let second = current.identifier, !current.isOperator(":") {
                    advance()
                    label = first
                    name = second
                } else {
                    label = first
                    name = first
                }
            }
            var typeName: String?
            var isInout = false
            if match(":") {
                if current.isKeyword("inout") {
                    advance()
                    isInout = true
                }
                typeName = try parseTypeName()
            }
            var isVariadic = false
            if match("...") { isVariadic = true }
            var defaultValue: SwiftExpr?
            if match("=") { defaultValue = try parseExpression() }
            parameters.append(SwiftParameter(label: label, name: name, typeName: typeName,
                                             defaultValue: defaultValue, isVariadic: isVariadic,
                                             isInout: isInout))
            if !match(",") { break }
        }
        try expect(")", "引数リストの後ろ")
        return parameters
    }

    private mutating func parseTypeDeclaration(kind: SwiftTypeDeclaration.Kind,
                                               location: SourceLocation) throws -> SwiftTypeDeclaration {
        let name = try expectIdentifier("型")
        if match("<") {
            while !current.isOperator(">"), !isAtEnd { advance() }
            _ = match(">")
        }
        var parentName: String?
        if match(":") {
            parentName = try expectIdentifier("親の型")
            while match(",") { _ = try expectIdentifier("準拠する型") }
        }
        try expect("{", "型の本体の前")

        var properties: [SwiftPropertyDeclaration] = []
        var methods: [SwiftFunctionDeclaration] = []
        var initializers: [SwiftFunctionDeclaration] = []
        var enumCases: [(name: String, rawValue: SwiftExpr?)] = []

        while !current.isOperator("}"), !isAtEnd {
            var isStatic = false
            var isMutating = false
            while let keyword = current.identifier,
                  ["public", "private", "internal", "fileprivate", "final", "open", "override",
                   "static", "class", "mutating", "lazy", "required", "convenience"].contains(keyword) {
                if keyword == "static" || keyword == "class" { isStatic = true }
                if keyword == "mutating" { isMutating = true }
                // `class func` の `class` だけを修飾子として扱う (型宣言の class は上で処理済み)
                advance()
            }

            if current.isKeyword("case"), kind == .enumeration {
                advance()
                repeat {
                    let caseName = try expectIdentifier("列挙のケース")
                    var rawValue: SwiftExpr?
                    if match("=") { rawValue = try parseExpression() }
                    // 関連値は読み飛ばす
                    if match("(") {
                        while !current.isOperator(")"), !isAtEnd { advance() }
                        _ = match(")")
                    }
                    enumCases.append((caseName, rawValue))
                } while match(",")
                continue
            }

            if current.isKeyword("init") {
                let initLocation = current.location
                advance()
                _ = match("?")
                let parameters = try parseParameterList()
                if current.isKeyword("throws") { advance() }
                let body = try parseBlock()
                initializers.append(SwiftFunctionDeclaration(name: "init", parameters: parameters,
                                                             returnTypeName: nil, body: body,
                                                             isMutating: true, isStatic: false,
                                                             isInitializer: true, location: initLocation))
                continue
            }

            if current.isKeyword("func") {
                let methodLocation = current.location
                advance()
                methods.append(try parseFunctionDeclaration(location: methodLocation,
                                                            isMutating: isMutating, isStatic: isStatic))
                continue
            }

            if current.isKeyword("let") || current.isKeyword("var") {
                let isConstant = current.isKeyword("let")
                advance()
                let propertyName = try expectIdentifier("プロパティ")
                var typeName: String?
                if match(":") { typeName = try parseTypeName() }
                var defaultValue: SwiftExpr?
                var getter: [SwiftStmt]?
                if match("=") {
                    defaultValue = try parseExpression()
                } else if current.isOperator("{") {
                    // 計算プロパティ (get のみ対応)
                    advance()
                    if current.isKeyword("get") {
                        advance()
                        getter = try parseBlock()
                        if current.isKeyword("set") {
                            advance()
                            if match("(") { _ = try expectIdentifier("引数"); try expect(")", "引数の後ろ") }
                            _ = try parseBlock()
                        }
                        try expect("}", "計算プロパティの終わり")
                    } else {
                        var statements: [SwiftStmt] = []
                        while !current.isOperator("}"), !isAtEnd {
                            if let statement = try parseStatement() { statements.append(statement) }
                        }
                        try expect("}", "計算プロパティの終わり")
                        getter = statements
                    }
                }
                properties.append(SwiftPropertyDeclaration(name: propertyName, typeName: typeName,
                                                           defaultValue: defaultValue,
                                                           isConstant: isConstant, isStatic: isStatic,
                                                           getter: getter))
                continue
            }

            diagnostics.error("型の中で解釈できない書き方です (\(current.text))。", at: current.location)
            advance()
        }
        try expect("}", "型の本体の終わり")

        return SwiftTypeDeclaration(kind: kind, name: name, parentName: parentName, properties: properties,
                                    methods: methods, initializers: initializers, enumCases: enumCases,
                                    location: location)
    }

    // MARK: - 式

    mutating func parseExpression() throws -> SwiftExpr {
        try parseAssignment()
    }

    private static let assignmentOperators = ["=", "+=", "-=", "*=", "/=", "%="]

    private mutating func parseAssignment() throws -> SwiftExpr {
        let left = try parseTernary()
        if case .op(let symbol) = current.kind, SwiftParser.assignmentOperators.contains(symbol) {
            let location = current.location
            advance()
            let right = try parseAssignment()
            return .assign(symbol, left, right, location)
        }
        return left
    }

    private mutating func parseTernary() throws -> SwiftExpr {
        let condition = try parseCoalesce()
        guard current.isOperator("?") else { return condition }
        let location = current.location
        advance()
        let then = try parseTernary()
        try expect(":", "三項演算子の ':'")
        let otherwise = try parseTernary()
        return .ternary(condition, then, otherwise, location)
    }

    private mutating func parseCoalesce() throws -> SwiftExpr {
        let left = try parseLogicalOr()
        guard current.isOperator("??") else { return left }
        let location = current.location
        advance()
        let right = try parseCoalesce()
        return .binary("??", left, right, location)
    }

    private mutating func parseLogicalOr() throws -> SwiftExpr {
        var left = try parseLogicalAnd()
        while current.isOperator("||") {
            let location = current.location
            advance()
            left = .binary("||", left, try parseLogicalAnd(), location)
        }
        return left
    }

    private mutating func parseLogicalAnd() throws -> SwiftExpr {
        var left = try parseComparison()
        while current.isOperator("&&") {
            let location = current.location
            advance()
            left = .binary("&&", left, try parseComparison(), location)
        }
        return left
    }

    private static let comparisonOperators = ["==", "!=", "<", ">", "<=", ">=", "===", "!=="]

    private mutating func parseComparison() throws -> SwiftExpr {
        var left = try parseRange()
        while true {
            if case .op(let symbol) = current.kind, SwiftParser.comparisonOperators.contains(symbol) {
                let location = current.location
                advance()
                left = .binary(symbol == "===" ? "==" : (symbol == "!==" ? "!=" : symbol),
                               left, try parseRange(), location)
                continue
            }
            if current.isKeyword("is") {
                let location = current.location
                advance()
                let typeName = try parseTypeName()
                left = .typeCheck(left, typeName: typeName, location)
                continue
            }
            if current.isKeyword("as") {
                let location = current.location
                advance()
                let isOptional = match("?")
                _ = match("!")
                let typeName = try parseTypeName()
                left = .typeCast(left, typeName: typeName, isOptional: isOptional, location)
                continue
            }
            return left
        }
    }

    private mutating func parseRange() throws -> SwiftExpr {
        let left = try parseAdditive()
        if current.isOperator("...") || current.isOperator("..<") {
            let isClosed = current.isOperator("...")
            let location = current.location
            advance()
            let right = try parseAdditive()
            return .rangeExpression(left, right, isClosed: isClosed, location)
        }
        return left
    }

    private mutating func parseAdditive() throws -> SwiftExpr {
        var left = try parseMultiplicative()
        while current.isOperator("+") || current.isOperator("-") {
            guard case .op(let symbol) = current.kind else { break }
            let location = current.location
            advance()
            left = .binary(symbol, left, try parseMultiplicative(), location)
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> SwiftExpr {
        var left = try parseUnary()
        while current.isOperator("*") || current.isOperator("/") || current.isOperator("%") {
            guard case .op(let symbol) = current.kind else { break }
            let location = current.location
            advance()
            left = .binary(symbol, left, try parseUnary(), location)
        }
        return left
    }

    private mutating func parseUnary() throws -> SwiftExpr {
        let location = current.location
        if current.isOperator("!") {
            advance()
            return .unary("!", try parseUnary(), location)
        }
        if current.isOperator("-") {
            advance()
            return .unary("-", try parseUnary(), location)
        }
        if current.isOperator("+") {
            advance()
            return try parseUnary()
        }
        if current.isKeyword("try") {
            advance()
            _ = match("?")
            _ = match("!")
            return try parseUnary()
        }
        // inout 引数の `&x`
        if current.isOperator("&") {
            advance()
            return .unary("&", try parseUnary(), location)
        }
        return try parsePostfix(try parsePrimary())
    }

    private mutating func parsePostfix(_ start: SwiftExpr) throws -> SwiftExpr {
        var expression = start
        while true {
            let location = current.location
            if current.isOperator(".") || current.isOperator("?.") {
                let isOptional = current.isOperator("?.")
                advance()
                if case .integer(let number) = current.kind {
                    // タプルの `.0`
                    advance()
                    expression = .member(expression, String(number), isOptional: isOptional, location)
                    continue
                }
                let name = try expectIdentifier("メンバー")
                expression = .member(expression, name, isOptional: isOptional, location)
                continue
            }
            if current.isOperator("(") {
                advance()
                let arguments = try parseArgumentList()
                expression = .call(expression, arguments, location)
                continue
            }
            if current.isOperator("[") {
                advance()
                let indexExpression = try parseExpression()
                try expect("]", "添字の後ろ")
                expression = .index(expression, indexExpression, location)
                continue
            }
            if current.isOperator("!") {
                advance()
                expression = .forceUnwrap(expression, location)
                continue
            }
            // 末尾クロージャ
            if current.isOperator("{"), allowsTrailingClosure, canTakeTrailingClosure(expression) {
                let closure = try parseClosure()
                if case .call(let callee, var arguments, let callLocation) = expression {
                    arguments.append((label: nil, value: closure))
                    expression = .call(callee, arguments, callLocation)
                } else {
                    expression = .call(expression, [(label: nil, value: closure)], location)
                }
                continue
            }
            return expression
        }
    }

    private func canTakeTrailingClosure(_ expression: SwiftExpr) -> Bool {
        switch expression {
        case .call, .member, .identifier: return true
        default: return false
        }
    }

    private mutating func parseArgumentList() throws -> [(label: String?, value: SwiftExpr)] {
        let saved = allowsTrailingClosure
        allowsTrailingClosure = true
        defer { allowsTrailingClosure = saved }

        var arguments: [(label: String?, value: SwiftExpr)] = []
        while !current.isOperator(")"), !isAtEnd {
            var label: String?
            if let name = current.identifier, peek(1).isOperator(":") {
                label = name
                advance()
                advance()
            }
            // `reduce(0, +)` のように、演算子そのものを関数として渡す書き方
            if case .op(let symbol) = current.kind,
               ["+", "-", "*", "/", "%", "<", ">", "<=", ">=", "==", "!="].contains(symbol),
               peek(1).isOperator(")") || peek(1).isOperator(",") {
                advance()
                arguments.append((label: label, value: .identifier(symbol, current.location)))
                if !match(",") { break }
                continue
            }
            arguments.append((label: label, value: try parseExpression()))
            if !match(",") { break }
        }
        try expect(")", "引数の後ろ")
        return arguments
    }

    private mutating func parseClosure() throws -> SwiftExpr {
        let location = current.location
        try expect("{", "クロージャの始まり")
        let saved = allowsTrailingClosure
        allowsTrailingClosure = true
        defer { allowsTrailingClosure = saved }

        var parameters: [SwiftParameter] = []
        var usesShorthand = true

        // `(a, b) in` / `a, b in` / `[weak self] in` を読む
        let checkpoint = index
        var foundIn = false
        var depth = 0
        var lookahead = index
        while lookahead < tokens.count {
            let token = tokens[lookahead]
            if token.isOperator("{") { depth += 1 }
            if token.isOperator("}") {
                if depth == 0 { break }
                depth -= 1
            }
            if token.isKeyword("in"), depth == 0 {
                foundIn = true
                break
            }
            if token.startsLine, lookahead > index { break }
            lookahead += 1
        }

        if foundIn {
            usesShorthand = false
            if match("[") {
                while !current.isOperator("]"), !isAtEnd { advance() }
                _ = match("]")
            }
            let hasParentheses = match("(")
            while !current.isKeyword("in"), !isAtEnd {
                if current.isOperator(")") {
                    advance()
                    continue
                }
                if current.isOperator(","), true {
                    advance()
                    continue
                }
                if current.isOperator("->") {
                    advance()
                    _ = try parseTypeName()
                    continue
                }
                let name = current.isOperator("_") ? "_" : try expectIdentifier("クロージャの引数")
                if current.isOperator("_") { advance() }
                var typeName: String?
                if match(":") { typeName = try parseTypeName() }
                parameters.append(SwiftParameter(label: nil, name: name, typeName: typeName,
                                                 defaultValue: nil, isVariadic: false, isInout: false))
            }
            _ = hasParentheses
            _ = matchKeyword("in")
        } else {
            index = checkpoint
        }

        var body: [SwiftStmt] = []
        while !current.isOperator("}"), !isAtEnd {
            if let statement = try parseStatement() { body.append(statement) }
        }
        try expect("}", "クロージャの終わり")

        // 本体が式ひとつだけなら、その値を返すものとして扱う
        if body.count == 1, case .expression(let expression, let expressionLocation) = body[0] {
            body = [.returnStmt(expression, expressionLocation)]
        }

        let declaration = SwiftFunctionDeclaration(name: "{closure}", parameters: parameters,
                                                   returnTypeName: nil, body: body,
                                                   usesShorthandArguments: usesShorthand && parameters.isEmpty,
                                                   location: location)
        return .closure(declaration, location)
    }

    private mutating func parsePrimary() throws -> SwiftExpr {
        let location = current.location
        switch current.kind {
        case .integer(let value):
            advance()
            return .literal(.integer(value), location)
        case .double(let value):
            advance()
            return .literal(.double(value), location)
        case .string(let segments):
            advance()
            return makeStringExpression(segments, at: location)
        case .op("("):
            advance()
            // タプルか括弧
            var items: [(label: String?, value: SwiftExpr)] = []
            let saved = allowsTrailingClosure
            allowsTrailingClosure = true
            while !current.isOperator(")"), !isAtEnd {
                var label: String?
                if let name = current.identifier, peek(1).isOperator(":") {
                    label = name
                    advance()
                    advance()
                }
                items.append((label: label, value: try parseExpression()))
                if !match(",") { break }
            }
            allowsTrailingClosure = saved
            try expect(")", "括弧の後ろ")
            if items.count == 1, items[0].label == nil { return items[0].value }
            return .tupleLiteral(items, location)
        case .op("["):
            advance()
            return try parseCollectionLiteral(location: location)
        case .op("{"):
            return try parseClosure()
        case .op("."):
            advance()
            let name = try expectIdentifier("メンバー")
            return .implicitMember(name, location)
        case .op("_"):
            advance()
            return .identifier("_", location)
        case .identifier(let name):
            advance()
            switch name {
            case "true": return .literal(.boolean(true), location)
            case "false": return .literal(.boolean(false), location)
            case "nil": return .literal(.none, location)
            case "self": return .selfExpression(location)
            case "super": return .identifier("super", location)
            default: return .identifier(name, location)
            }
        default:
            diagnostics.error("式が必要です (見つかったのは \(current.text))。", at: location)
            throw AbortCompilation()
        }
    }

    private mutating func parseCollectionLiteral(location: SourceLocation) throws -> SwiftExpr {
        if match(":") {
            try expect("]", "空の辞書の後ろ")
            return .dictionaryLiteral([], location)
        }
        if match("]") {
            return .arrayLiteral([], location)
        }
        let first = try parseExpression()
        if match(":") {
            var pairs: [(key: SwiftExpr, value: SwiftExpr)] = [(first, try parseExpression())]
            while match(",") {
                if current.isOperator("]") { break }
                let key = try parseExpression()
                try expect(":", "辞書の値の前")
                pairs.append((key, try parseExpression()))
            }
            try expect("]", "辞書の終わり")
            return .dictionaryLiteral(pairs, location)
        }
        var values = [first]
        while match(",") {
            if current.isOperator("]") { break }
            values.append(try parseExpression())
        }
        try expect("]", "配列の終わり")
        return .arrayLiteral(values, location)
    }

    private mutating func makeStringExpression(_ segments: [SwiftStringSegment],
                                               at location: SourceLocation) -> SwiftExpr {
        if segments.isEmpty { return .literal(.string(""), location) }
        if segments.count == 1, case .text(let text) = segments[0] {
            return .literal(.string(text), location)
        }
        var parts: [SwiftExpr] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                parts.append(.literal(.string(text), location))
            case .expression(let source):
                if let expression = SwiftParser.parseExpressionSource(source, diagnostics: diagnostics) {
                    parts.append(expression)
                }
            }
        }
        return .interpolation(parts, location)
    }
}
