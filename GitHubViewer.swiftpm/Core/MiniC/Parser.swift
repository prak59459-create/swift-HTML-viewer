import Foundation

/// トークン列を AST に変換する再帰下降パーサ。
struct Parser {
    private let tokens: [Token]
    private var index = 0
    private let diagnostics: DiagnosticBag

    /// typedef された名前 (型名として扱うために覚えておく)。
    private var typedefNames: Set<String> = []
    /// enum 定数 (定数式の評価に使う)。
    private var enumConstants: [String: Int64] = [:]
    /// 無名構造体に付ける名前の連番。
    private var anonymousCounter = 0

    init(tokens: [Token], diagnostics: DiagnosticBag) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }

    // MARK: - トークン操作

    private var current: Token {
        index < tokens.count ? tokens[index] : Token(kind: .endOfFile, location: .unknown, isAtLineStart: false)
    }

    private func peek(_ offset: Int) -> Token {
        let position = index + offset
        return position < tokens.count ? tokens[position]
            : Token(kind: .endOfFile, location: .unknown, isAtLineStart: false)
    }

    private var isAtEnd: Bool {
        if case .endOfFile = current.kind { return true }
        return index >= tokens.count
    }

    @discardableResult
    private mutating func advance() -> Token {
        let token = current
        if index < tokens.count { index += 1 }
        return token
    }

    private mutating func match(_ punctuator: Punctuator) -> Bool {
        if current.isPunctuator(punctuator) {
            advance()
            return true
        }
        return false
    }

    private mutating func match(_ keyword: Keyword) -> Bool {
        if current.isKeyword(keyword) {
            advance()
            return true
        }
        return false
    }

    @discardableResult
    private mutating func expect(_ punctuator: Punctuator, _ context: String) throws -> Token {
        guard current.isPunctuator(punctuator) else {
            diagnostics.error("\(context)に '\(punctuator.rawValue)' が必要です (見つかったのは \(current.text))。",
                              at: current.location)
            throw AbortCompilation()
        }
        return advance()
    }

    private mutating func expectIdentifier(_ context: String) throws -> (String, SourceLocation) {
        guard let name = current.identifier else {
            diagnostics.error("\(context)に名前が必要です (見つかったのは \(current.text))。", at: current.location)
            throw AbortCompilation()
        }
        let location = current.location
        advance()
        return (name, location)
    }

    /// エラーからの復帰: 次の ';' か '}' まで読み飛ばす。
    private mutating func synchronize() {
        while !isAtEnd {
            if current.isPunctuator(.semicolon) {
                advance()
                return
            }
            if current.isPunctuator(.rightBrace) {
                advance()
                return
            }
            advance()
        }
    }

    // MARK: - 入口

    mutating func parseTranslationUnit() -> TranslationUnit {
        var declarations: [TopLevelDeclaration] = []
        while !isAtEnd {
            do {
                if let declaration = try parseTopLevelDeclaration() {
                    declarations.append(declaration)
                }
            } catch {
                synchronize()
            }
        }
        return TranslationUnit(declarations: declarations)
    }

    // MARK: - 宣言

    private mutating func parseTopLevelDeclaration() throws -> TopLevelDeclaration? {
        if current.isPunctuator(.semicolon) {
            advance()
            return nil
        }

        let startLocation = current.location

        if current.isKeyword(.typedef) {
            advance()
            let (specifier, _) = try parseDeclarationSpecifiers()
            let declarator = try parseDeclarator(context: "typedef")
            let type = TypeName(specifier: specifier, pointerDepth: declarator.pointerDepth,
                                arrayCounts: declarator.arrayCounts, location: startLocation)
            try expect(.semicolon, "typedef の終わり")
            typedefNames.insert(declarator.name)
            return .typedefDefinition(name: declarator.name, type: type, startLocation)
        }

        let (specifier, isStatic) = try parseDeclarationSpecifiers()

        // struct / enum の定義だけの行
        if current.isPunctuator(.semicolon) {
            advance()
            switch specifier {
            case .structure(let name):
                return .structDefinition(pendingStructs[name] ?? StructDefinition(name: name, members: [],
                                                                                  location: startLocation))
            case .enumeration(let name):
                return .enumDefinition(pendingEnums[name] ?? EnumDefinition(name: name, constants: [],
                                                                            location: startLocation))
            default:
                return nil
            }
        }

        var declarations: [VariableDeclaration] = []
        repeat {
            let declarator = try parseDeclarator(context: "宣言")
            let type = TypeName(specifier: specifier, pointerDepth: declarator.pointerDepth,
                                arrayCounts: declarator.arrayCounts, location: declarator.location)

            // 関数
            if current.isPunctuator(.leftParen) {
                let function = try parseFunctionRest(name: declarator.name, returnType: type,
                                                     location: declarator.location)
                return .function(function)
            }

            var initializer: Initializer?
            if match(.assign) {
                initializer = try parseInitializer()
            }
            declarations.append(VariableDeclaration(name: declarator.name, type: type,
                                                    initializer: initializer, isStatic: isStatic,
                                                    location: declarator.location))
        } while match(.comma)

        try expect(.semicolon, "宣言の終わり")
        // struct 定義と変数宣言が同じ行にある場合も、変数宣言として返す
        // (struct 本体は parseDeclarationSpecifiers の中で登録済み)
        return .globalVariables(declarations, startLocation)
    }

    private mutating func parseFunctionRest(name: String, returnType: TypeName,
                                            location: SourceLocation) throws -> FunctionDeclaration {
        try expect(.leftParen, "引数リストの始まり")
        var parameters: [FunctionParameter] = []
        var isVariadic = false

        if !current.isPunctuator(.rightParen) {
            if current.isKeyword(.void), peek(1).isPunctuator(.rightParen) {
                advance()
            } else {
                repeat {
                    if current.isPunctuator(.ellipsis) {
                        advance()
                        isVariadic = true
                        break
                    }
                    let parameterLocation = current.location
                    let (specifier, _) = try parseDeclarationSpecifiers()
                    let declarator = try parseDeclarator(context: "引数", allowAnonymous: true)
                    let type = TypeName(specifier: specifier, pointerDepth: declarator.pointerDepth,
                                        arrayCounts: declarator.arrayCounts, location: parameterLocation)
                    parameters.append(FunctionParameter(name: declarator.name, type: type,
                                                        location: parameterLocation))
                } while match(.comma)
            }
        }
        try expect(.rightParen, "引数リストの終わり")

        if match(.semicolon) {
            return FunctionDeclaration(name: name, returnType: returnType, parameters: parameters,
                                       isVariadic: isVariadic, body: nil, location: location)
        }

        let body = try parseCompoundStatement()
        guard case .compound(let statements, _) = body else {
            return FunctionDeclaration(name: name, returnType: returnType, parameters: parameters,
                                       isVariadic: isVariadic, body: [], location: location)
        }
        return FunctionDeclaration(name: name, returnType: returnType, parameters: parameters,
                                   isVariadic: isVariadic, body: statements, location: location)
    }

    // MARK: - 型指定

    /// 解析済みの struct / enum 定義 (宣言だけの行で使う)。
    private var pendingStructs: [String: StructDefinition] = [:]
    private var pendingEnums: [String: EnumDefinition] = [:]
    /// 解析中に見つけた struct / enum の定義 (呼び出し側が回収する)。
    private(set) var collectedStructs: [StructDefinition] = []
    private(set) var collectedEnums: [EnumDefinition] = []

    private func isTypeSpecifierStart(_ token: Token) -> Bool {
        switch token.kind {
        case .keyword(let keyword):
            switch keyword {
            case .void, .char, .short, .int, .long, .float, .double, .signed, .unsigned,
                 .structKeyword, .union, .enumKeyword, .constKeyword, .volatile,
                 .staticKeyword, .externKeyword, .typedef:
                return true
            default:
                return false
            }
        case .identifier(let name):
            return typedefNames.contains(name)
        default:
            return false
        }
    }

    private mutating func parseDeclarationSpecifiers() throws -> (TypeSpecifier, isStatic: Bool) {
        var keywords: [Keyword] = []
        var specifier: TypeSpecifier?
        var isStatic = false

        loop: while true {
            switch current.kind {
            case .keyword(let keyword):
                switch keyword {
                case .constKeyword, .volatile, .externKeyword:
                    advance()
                case .staticKeyword:
                    isStatic = true
                    advance()
                case .void, .char, .short, .int, .long, .float, .double, .signed, .unsigned:
                    keywords.append(keyword)
                    advance()
                case .structKeyword, .union:
                    let isUnion = keyword == .union
                    let keywordLocation = current.location
                    advance()
                    if isUnion {
                        diagnostics.error("union にはまだ対応していません (struct として解釈すると値が壊れます)。",
                                          at: keywordLocation)
                    }
                    specifier = try parseStructSpecifier()
                    break loop
                case .enumKeyword:
                    advance()
                    specifier = try parseEnumSpecifier()
                    break loop
                default:
                    break loop
                }
            case .identifier(let name) where specifier == nil && keywords.isEmpty && typedefNames.contains(name):
                advance()
                specifier = .typedefName(name)
                break loop
            default:
                break loop
            }
        }

        if let specifier {
            return (specifier, isStatic)
        }
        if keywords.isEmpty {
            diagnostics.error("型が必要です (見つかったのは \(current.text))。", at: current.location)
            throw AbortCompilation()
        }
        if keywords.contains(.double) || keywords.contains(.float) {
            return (.double, isStatic)
        }
        if keywords.contains(.void) {
            return (.void, isStatic)
        }
        let isUnsigned = keywords.contains(.unsigned)
        if keywords.contains(.char) {
            return (isUnsigned ? .uchar : .char, isStatic)
        }
        if keywords.contains(.long) {
            return (isUnsigned ? .ulong : .long, isStatic)
        }
        return (isUnsigned ? .uint : .int, isStatic)
    }

    private mutating func parseStructSpecifier() throws -> TypeSpecifier {
        var name: String
        let location = current.location
        if let identifier = current.identifier {
            name = identifier
            advance()
        } else {
            anonymousCounter += 1
            name = "匿名構造体\(anonymousCounter)"
        }

        guard current.isPunctuator(.leftBrace) else {
            return .structure(name)
        }
        advance()

        var members: [VariableDeclaration] = []
        while !current.isPunctuator(.rightBrace), !isAtEnd {
            let (memberSpecifier, _) = try parseDeclarationSpecifiers()
            repeat {
                let declarator = try parseDeclarator(context: "構造体のメンバー")
                let type = TypeName(specifier: memberSpecifier, pointerDepth: declarator.pointerDepth,
                                    arrayCounts: declarator.arrayCounts, location: declarator.location)
                members.append(VariableDeclaration(name: declarator.name, type: type, initializer: nil,
                                                   isStatic: false, location: declarator.location))
            } while match(.comma)
            try expect(.semicolon, "メンバー宣言の終わり")
        }
        try expect(.rightBrace, "構造体の終わり")

        let definition = StructDefinition(name: name, members: members, location: location)
        pendingStructs[name] = definition
        collectedStructs.append(definition)
        return .structure(name)
    }

    private mutating func parseEnumSpecifier() throws -> TypeSpecifier {
        var name: String
        let location = current.location
        if let identifier = current.identifier {
            name = identifier
            advance()
        } else {
            anonymousCounter += 1
            name = "匿名列挙\(anonymousCounter)"
        }

        guard current.isPunctuator(.leftBrace) else {
            return .enumeration(name)
        }
        advance()

        var constants: [(name: String, value: Int64)] = []
        var nextValue: Int64 = 0
        while !current.isPunctuator(.rightBrace), !isAtEnd {
            let (constantName, constantLocation) = try expectIdentifier("列挙定数")
            if match(.assign) {
                let expression = try parseConditionalExpression()
                if let value = foldConstant(expression) {
                    nextValue = value
                } else {
                    diagnostics.error("列挙定数の値は定数式でなければなりません。", at: constantLocation)
                }
            }
            constants.append((name: constantName, value: nextValue))
            enumConstants[constantName] = nextValue
            nextValue += 1
            if !match(.comma) { break }
        }
        try expect(.rightBrace, "列挙の終わり")

        let definition = EnumDefinition(name: name, constants: constants, location: location)
        pendingEnums[name] = definition
        collectedEnums.append(definition)
        return .enumeration(name)
    }

    // MARK: - 宣言子

    private struct Declarator {
        var name: String
        var pointerDepth: Int
        var arrayCounts: [Int?]
        var location: SourceLocation
    }

    private mutating func parseDeclarator(context: String, allowAnonymous: Bool = false) throws -> Declarator {
        var pointerDepth = 0
        while match(.star) {
            pointerDepth += 1
            while current.isKeyword(.constKeyword) || current.isKeyword(.volatile) { advance() }
        }

        var name = ""
        let location = current.location
        if let identifier = current.identifier {
            name = identifier
            advance()
        } else if !allowAnonymous {
            diagnostics.error("\(context)に名前が必要です (見つかったのは \(current.text))。", at: current.location)
            throw AbortCompilation()
        }

        var arrayCounts: [Int?] = []
        while current.isPunctuator(.leftBracket) {
            advance()
            if current.isPunctuator(.rightBracket) {
                advance()
                arrayCounts.append(nil)
                continue
            }
            let expression = try parseConditionalExpression()
            try expect(.rightBracket, "配列の大きさの後ろ")
            if let value = foldConstant(expression) {
                arrayCounts.append(Int(value))
            } else {
                diagnostics.error("配列の大きさは定数でなければなりません。", at: expression.location)
                arrayCounts.append(0)
            }
        }

        return Declarator(name: name, pointerDepth: pointerDepth, arrayCounts: arrayCounts, location: location)
    }

    /// 定数式を畳み込む (配列の大きさ、enum の値、case ラベル用)。
    func foldConstant(_ expression: Expr) -> Int64? {
        switch expression {
        case .integerLiteral(let value, _, _):
            return value
        case .characterLiteral(let value, _):
            return value
        case .identifier(let name, _):
            return enumConstants[name]
        case .unary(let op, let operand, _):
            guard let value = foldConstant(operand) else { return nil }
            switch op {
            case .minus: return 0 &- value
            case .plus: return value
            case .bitwiseNot: return ~value
            case .logicalNot: return value == 0 ? 1 : 0
            default: return nil
            }
        case .binary(let op, let lhs, let rhs, _):
            guard let left = foldConstant(lhs), let right = foldConstant(rhs) else { return nil }
            switch op {
            case .add: return left &+ right
            case .subtract: return left &- right
            case .multiply: return left &* right
            case .divide: return right == 0 ? nil : left / right
            case .remainder: return right == 0 ? nil : left % right
            case .shiftLeft: return left << right
            case .shiftRight: return left >> right
            case .bitwiseAnd: return left & right
            case .bitwiseOr: return left | right
            case .bitwiseXor: return left ^ right
            case .less: return left < right ? 1 : 0
            case .lessEqual: return left <= right ? 1 : 0
            case .greater: return left > right ? 1 : 0
            case .greaterEqual: return left >= right ? 1 : 0
            case .equal: return left == right ? 1 : 0
            case .notEqual: return left != right ? 1 : 0
            case .logicalAnd: return (left != 0 && right != 0) ? 1 : 0
            case .logicalOr: return (left != 0 || right != 0) ? 1 : 0
            }
        case .conditional(let condition, let then, let otherwise, _):
            guard let value = foldConstant(condition) else { return nil }
            return value != 0 ? foldConstant(then) : foldConstant(otherwise)
        default:
            return nil
        }
    }

    // MARK: - 初期化子

    private mutating func parseInitializer() throws -> Initializer {
        if current.isPunctuator(.leftBrace) {
            let location = current.location
            advance()
            var items: [Initializer] = []
            while !current.isPunctuator(.rightBrace), !isAtEnd {
                items.append(try parseInitializer())
                if !match(.comma) { break }
            }
            try expect(.rightBrace, "初期化子の終わり")
            return .list(items, location)
        }
        return .expression(try parseAssignmentExpression())
    }

    // MARK: - 文

    private mutating func parseStatement() throws -> Stmt {
        let location = current.location

        if current.isPunctuator(.leftBrace) {
            return try parseCompoundStatement()
        }
        if current.isPunctuator(.semicolon) {
            advance()
            return .expression(nil, location)
        }
        if case .keyword(let keyword) = current.kind {
            switch keyword {
            case .ifKeyword: return try parseIfStatement()
            case .whileKeyword: return try parseWhileStatement()
            case .doKeyword: return try parseDoWhileStatement()
            case .forKeyword: return try parseForStatement()
            case .switchKeyword: return try parseSwitchStatement()
            case .breakKeyword:
                advance()
                try expect(.semicolon, "break の後ろ")
                return .breakStmt(location)
            case .continueKeyword:
                advance()
                try expect(.semicolon, "continue の後ろ")
                return .continueStmt(location)
            case .returnKeyword:
                advance()
                if match(.semicolon) { return .returnStmt(nil, location) }
                let value = try parseExpression()
                try expect(.semicolon, "return の後ろ")
                return .returnStmt(value, location)
            case .gotoKeyword:
                diagnostics.error("goto には対応していません。", at: location)
                throw AbortCompilation()
            default:
                break
            }
        }
        if isTypeSpecifierStart(current) {
            return try parseDeclarationStatement()
        }

        let expression = try parseExpression()
        try expect(.semicolon, "式の後ろ")
        return .expression(expression, location)
    }

    private mutating func parseDeclarationStatement() throws -> Stmt {
        let location = current.location
        let (specifier, isStatic) = try parseDeclarationSpecifiers()
        var declarations: [VariableDeclaration] = []
        repeat {
            let declarator = try parseDeclarator(context: "変数宣言")
            let type = TypeName(specifier: specifier, pointerDepth: declarator.pointerDepth,
                                arrayCounts: declarator.arrayCounts, location: declarator.location)
            var initializer: Initializer?
            if match(.assign) {
                initializer = try parseInitializer()
            }
            declarations.append(VariableDeclaration(name: declarator.name, type: type,
                                                    initializer: initializer, isStatic: isStatic,
                                                    location: declarator.location))
        } while match(.comma)
        try expect(.semicolon, "宣言の終わり")
        return .declaration(declarations, location)
    }

    private mutating func parseCompoundStatement() throws -> Stmt {
        let location = current.location
        try expect(.leftBrace, "ブロックの始まり")
        var statements: [Stmt] = []
        while !current.isPunctuator(.rightBrace), !isAtEnd {
            do {
                statements.append(try parseStatement())
            } catch {
                synchronize()
                if current.isPunctuator(.rightBrace) { break }
            }
        }
        try expect(.rightBrace, "ブロックの終わり")
        return .compound(statements, location)
    }

    private mutating func parseIfStatement() throws -> Stmt {
        let location = current.location
        advance()
        try expect(.leftParen, "if の条件の前")
        let condition = try parseExpression()
        try expect(.rightParen, "if の条件の後ろ")
        let thenBranch = try parseStatement()
        var elseBranch: Stmt?
        if match(.elseKeyword) {
            elseBranch = try parseStatement()
        }
        return .ifStmt(condition: condition, then: thenBranch, else: elseBranch, location)
    }

    private mutating func parseWhileStatement() throws -> Stmt {
        let location = current.location
        advance()
        try expect(.leftParen, "while の条件の前")
        let condition = try parseExpression()
        try expect(.rightParen, "while の条件の後ろ")
        let body = try parseStatement()
        return .whileStmt(condition: condition, body: body, location)
    }

    private mutating func parseDoWhileStatement() throws -> Stmt {
        let location = current.location
        advance()
        let body = try parseStatement()
        guard match(.whileKeyword) else {
            diagnostics.error("do の後ろに while が必要です。", at: current.location)
            throw AbortCompilation()
        }
        try expect(.leftParen, "while の条件の前")
        let condition = try parseExpression()
        try expect(.rightParen, "while の条件の後ろ")
        try expect(.semicolon, "do-while の終わり")
        return .doWhile(body: body, condition: condition, location)
    }

    private mutating func parseForStatement() throws -> Stmt {
        let location = current.location
        advance()
        try expect(.leftParen, "for の前")

        var initializer: Stmt?
        if current.isPunctuator(.semicolon) {
            advance()
        } else if isTypeSpecifierStart(current) {
            initializer = try parseDeclarationStatement()
        } else {
            let expression = try parseExpression()
            try expect(.semicolon, "for の初期化式の後ろ")
            initializer = .expression(expression, expression.location)
        }

        var condition: Expr?
        if !current.isPunctuator(.semicolon) {
            condition = try parseExpression()
        }
        try expect(.semicolon, "for の条件の後ろ")

        var step: Expr?
        if !current.isPunctuator(.rightParen) {
            step = try parseExpression()
        }
        try expect(.rightParen, "for の後ろ")

        let body = try parseStatement()
        return .forStmt(initializer: initializer, condition: condition, step: step, body: body, location)
    }

    private mutating func parseSwitchStatement() throws -> Stmt {
        let location = current.location
        advance()
        try expect(.leftParen, "switch の前")
        let subject = try parseExpression()
        try expect(.rightParen, "switch の後ろ")
        try expect(.leftBrace, "switch の本体の始まり")

        var cases: [SwitchCase] = []
        var currentCase: SwitchCase?

        while !current.isPunctuator(.rightBrace), !isAtEnd {
            if current.isKeyword(.caseKeyword) {
                let caseLocation = current.location
                advance()
                let value = try parseConditionalExpression()
                try expect(.colon, "case ラベルの後ろ")
                if let existing = currentCase { cases.append(existing) }
                currentCase = SwitchCase(value: value, body: [], location: caseLocation)
                continue
            }
            if current.isKeyword(.defaultKeyword) {
                let caseLocation = current.location
                advance()
                try expect(.colon, "default の後ろ")
                if let existing = currentCase { cases.append(existing) }
                currentCase = SwitchCase(value: nil, body: [], location: caseLocation)
                continue
            }
            guard currentCase != nil else {
                diagnostics.error("switch の中の文は case か default の後ろに置いてください。", at: current.location)
                throw AbortCompilation()
            }
            let statement = try parseStatement()
            currentCase?.body.append(statement)
        }
        if let existing = currentCase { cases.append(existing) }
        try expect(.rightBrace, "switch の本体の終わり")
        return .switchStmt(subject: subject, cases: cases, location)
    }

    // MARK: - 式

    mutating func parseExpression() throws -> Expr {
        var expression = try parseAssignmentExpression()
        while current.isPunctuator(.comma) {
            let location = current.location
            advance()
            let right = try parseAssignmentExpression()
            expression = .comma(expression, right, location)
        }
        return expression
    }

    private static let compoundAssignments: [Punctuator: BinaryOperator] = [
        .plusAssign: .add, .minusAssign: .subtract, .starAssign: .multiply,
        .slashAssign: .divide, .percentAssign: .remainder,
        .shiftLeftAssign: .shiftLeft, .shiftRightAssign: .shiftRight,
        .ampersandAssign: .bitwiseAnd, .pipeAssign: .bitwiseOr, .caretAssign: .bitwiseXor,
    ]

    mutating func parseAssignmentExpression() throws -> Expr {
        let left = try parseConditionalExpression()

        if current.isPunctuator(.assign) {
            let location = current.location
            advance()
            let right = try parseAssignmentExpression()
            return .assignment(nil, left, right, location)
        }
        if case .punctuator(let punctuator) = current.kind,
           let op = Parser.compoundAssignments[punctuator] {
            let location = current.location
            advance()
            let right = try parseAssignmentExpression()
            return .assignment(op, left, right, location)
        }
        return left
    }

    private mutating func parseConditionalExpression() throws -> Expr {
        let condition = try parseBinaryExpression(minimumPrecedence: 1)
        guard current.isPunctuator(.question) else { return condition }
        let location = current.location
        advance()
        let then = try parseExpression()
        try expect(.colon, "三項演算子の ':' ")
        let otherwise = try parseConditionalExpression()
        return .conditional(condition, then, otherwise, location)
    }

    /// 二項演算子の優先順位 (大きいほど強い)。
    private static let precedences: [Punctuator: (BinaryOperator, Int)] = [
        .logicalOr: (.logicalOr, 1),
        .logicalAnd: (.logicalAnd, 2),
        .pipe: (.bitwiseOr, 3),
        .caret: (.bitwiseXor, 4),
        .ampersand: (.bitwiseAnd, 5),
        .equal: (.equal, 6), .notEqual: (.notEqual, 6),
        .less: (.less, 7), .lessEqual: (.lessEqual, 7),
        .greater: (.greater, 7), .greaterEqual: (.greaterEqual, 7),
        .shiftLeft: (.shiftLeft, 8), .shiftRight: (.shiftRight, 8),
        .plus: (.add, 9), .minus: (.subtract, 9),
        .star: (.multiply, 10), .slash: (.divide, 10), .percent: (.remainder, 10),
    ]

    private mutating func parseBinaryExpression(minimumPrecedence: Int) throws -> Expr {
        var left = try parseCastExpression()
        while true {
            guard case .punctuator(let punctuator) = current.kind,
                  let (op, precedence) = Parser.precedences[punctuator],
                  precedence >= minimumPrecedence else { return left }
            let location = current.location
            advance()
            let right = try parseBinaryExpression(minimumPrecedence: precedence + 1)
            left = .binary(op, left, right, location)
        }
    }

    /// `(` の次が型の始まりなら型変換。
    private func isCastAhead() -> Bool {
        guard current.isPunctuator(.leftParen) else { return false }
        return isTypeSpecifierStart(peek(1))
    }

    private mutating func parseCastExpression() throws -> Expr {
        if isCastAhead() {
            let location = current.location
            advance()
            let typeName = try parseTypeName()
            try expect(.rightParen, "型変換の後ろ")
            let operand = try parseCastExpression()
            return .cast(typeName, operand, location)
        }
        return try parseUnaryExpression()
    }

    /// `int *` や `struct Point *` のような、名前のない型。
    private mutating func parseTypeName() throws -> TypeName {
        let location = current.location
        let (specifier, _) = try parseDeclarationSpecifiers()
        var pointerDepth = 0
        while match(.star) {
            pointerDepth += 1
            while current.isKeyword(.constKeyword) || current.isKeyword(.volatile) { advance() }
        }
        var arrayCounts: [Int?] = []
        while current.isPunctuator(.leftBracket) {
            advance()
            if current.isPunctuator(.rightBracket) {
                advance()
                arrayCounts.append(nil)
                continue
            }
            let expression = try parseConditionalExpression()
            try expect(.rightBracket, "配列の大きさの後ろ")
            arrayCounts.append(foldConstant(expression).map(Int.init))
        }
        return TypeName(specifier: specifier, pointerDepth: pointerDepth,
                        arrayCounts: arrayCounts, location: location)
    }

    private mutating func parseUnaryExpression() throws -> Expr {
        let location = current.location

        if case .punctuator(let punctuator) = current.kind {
            switch punctuator {
            case .plus, .minus, .exclaim, .tilde, .ampersand, .star:
                advance()
                let operand = try parseCastExpression()
                let op: UnaryOperator
                switch punctuator {
                case .plus: op = .plus
                case .minus: op = .minus
                case .exclaim: op = .logicalNot
                case .tilde: op = .bitwiseNot
                case .ampersand: op = .addressOf
                default: op = .dereference
                }
                return .unary(op, operand, location)
            case .increment, .decrement:
                advance()
                let operand = try parseUnaryExpression()
                return .unary(punctuator == .increment ? .preIncrement : .preDecrement, operand, location)
            default:
                break
            }
        }

        if current.isKeyword(.sizeofKeyword) {
            advance()
            if current.isPunctuator(.leftParen), isTypeSpecifierStart(peek(1)) {
                advance()
                let typeName = try parseTypeName()
                try expect(.rightParen, "sizeof の後ろ")
                return .sizeofType(typeName, location)
            }
            let operand = try parseUnaryExpression()
            return .sizeofExpr(operand, location)
        }

        return try parsePostfixExpression()
    }

    private mutating func parsePostfixExpression() throws -> Expr {
        var expression = try parsePrimaryExpression()

        while true {
            let location = current.location
            if match(.leftBracket) {
                let indexExpression = try parseExpression()
                try expect(.rightBracket, "添字の後ろ")
                expression = .subscriptExpr(expression, indexExpression, location)
            } else if match(.leftParen) {
                var arguments: [Expr] = []
                if !current.isPunctuator(.rightParen) {
                    repeat {
                        arguments.append(try parseAssignmentExpression())
                    } while match(.comma)
                }
                try expect(.rightParen, "引数の後ろ")
                expression = .call(expression, arguments, location)
            } else if match(.dot) {
                let (name, _) = try expectIdentifier("メンバー名")
                expression = .member(expression, name, isArrow: false, location)
            } else if match(.arrow) {
                let (name, _) = try expectIdentifier("メンバー名")
                expression = .member(expression, name, isArrow: true, location)
            } else if current.isPunctuator(.increment) {
                advance()
                expression = .postfix(.increment, expression, location)
            } else if current.isPunctuator(.decrement) {
                advance()
                expression = .postfix(.decrement, expression, location)
            } else {
                return expression
            }
        }
    }

    private mutating func parsePrimaryExpression() throws -> Expr {
        let location = current.location
        switch current.kind {
        case .integer(let value, let isLong):
            advance()
            return .integerLiteral(value, isLong: isLong, location)
        case .floating(let value):
            advance()
            return .floatingLiteral(value, location)
        case .character(let value):
            advance()
            return .characterLiteral(value, location)
        case .string(var text):
            advance()
            // 隣り合う文字列リテラルは連結する
            while case .string(let next) = current.kind {
                text += next
                advance()
            }
            return .stringLiteral(text, location)
        case .identifier(let name):
            advance()
            return .identifier(name, location)
        case .punctuator(.leftParen):
            advance()
            let expression = try parseExpression()
            try expect(.rightParen, "括弧の後ろ")
            return expression
        default:
            diagnostics.error("式が必要です (見つかったのは \(current.text))。", at: location)
            throw AbortCompilation()
        }
    }
}
