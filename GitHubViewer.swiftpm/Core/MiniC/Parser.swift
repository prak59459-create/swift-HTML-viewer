import Foundation

/// トークン列を AST に変換する再帰下降パーサ。
struct Parser {
    private let tokens: [Token]
    private var index = 0
    private let diagnostics: DiagnosticBag

    /// typedef された名前 (型名として扱うために覚えておく)。
    /// 標準ヘッダで定義されている名前は最初から入れておく。
    private var typedefNames: Set<String> = [
        "va_list", "size_t", "ssize_t", "FILE",
        "int8_t", "uint8_t", "int16_t", "uint16_t",
        "int32_t", "uint32_t", "int64_t", "uint64_t",
        "ptrdiff_t", "intptr_t", "uintptr_t",
    ]
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
                declarations.append(contentsOf: pendingTypedefs)
                pendingTypedefs.removeAll()
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
            var names: [(String, TypeRef, SourceLocation)] = []
            repeat {
                let declarator = try parseDeclarator(context: "typedef", base: specifier)
                typedefNames.insert(declarator.name)
                names.append((declarator.name, declarator.type, declarator.location))
            } while match(.comma)
            try expect(.semicolon, "typedef の終わり")
            // 複数書かれていても、最初のものを宣言として返す (残りも名前は登録済み)
            for (name, type, location) in names.dropFirst() {
                pendingTypedefs.append(.typedefDefinition(name: name,
                                                          type: TypeName(type, location: location),
                                                          location))
            }
            guard let first = names.first else { return nil }
            return .typedefDefinition(name: first.0, type: TypeName(first.1, location: first.2), startLocation)
        }

        let (specifier, isStatic) = try parseDeclarationSpecifiers()

        // struct / enum の定義だけの行
        if current.isPunctuator(.semicolon) {
            advance()
            switch specifier {
            case .structure(let name):
                return .structDefinition(pendingStructs[name] ?? StructDefinition(name: name, members: [],
                                                                                  isUnion: false,
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
            let declarator = try parseDeclarator(context: "宣言", base: specifier)
            let typeName = TypeName(declarator.type, location: declarator.location)

            // 関数の定義・宣言
            if let parts = typeName.functionParts, current.isPunctuator(.leftBrace) || current.isPunctuator(.semicolon) {
                if match(.semicolon) {
                    return .function(FunctionDeclaration(name: declarator.name,
                                                         returnType: TypeName(parts.returns, location: declarator.location),
                                                         parameters: parts.parameters,
                                                         isVariadic: parts.isVariadic,
                                                         body: nil,
                                                         location: declarator.location))
                }
                let body = try parseCompoundStatement()
                guard case .compound(let statements, _) = body else { throw AbortCompilation() }
                return .function(FunctionDeclaration(name: declarator.name,
                                                     returnType: TypeName(parts.returns, location: declarator.location),
                                                     parameters: parts.parameters,
                                                     isVariadic: parts.isVariadic,
                                                     body: statements,
                                                     location: declarator.location))
            }

            var initializer: Initializer?
            if match(.assign) {
                initializer = try parseInitializer()
            }
            declarations.append(VariableDeclaration(name: declarator.name, type: typeName,
                                                    initializer: initializer, isStatic: isStatic,
                                                    location: declarator.location))
        } while match(.comma)

        try expect(.semicolon, "宣言の終わり")
        return .globalVariables(declarations, startLocation)
    }

    // MARK: - 型指定

    /// 解析済みの struct / enum 定義 (宣言だけの行で使う)。
    private var pendingStructs: [String: StructDefinition] = [:]
    private var pendingEnums: [String: EnumDefinition] = [:]
    /// 解析中に見つけた struct / enum の定義 (呼び出し側が回収する)。
    private(set) var collectedStructs: [StructDefinition] = []
    private(set) var collectedEnums: [EnumDefinition] = []
    /// `typedef A B, C;` のように 1 行で複数書かれたときの 2 つ目以降と、関数の中の typedef。
    private var pendingTypedefs: [TopLevelDeclaration] = []

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
                    advance()
                    specifier = try parseStructSpecifier(isUnion: isUnion)
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

    private mutating func parseStructSpecifier(isUnion: Bool = false) throws -> TypeSpecifier {
        var name: String
        let location = current.location
        if let identifier = current.identifier {
            name = identifier
            advance()
        } else {
            anonymousCounter += 1
            name = (isUnion ? "匿名共用体" : "匿名構造体") + "\(anonymousCounter)"
        }

        guard current.isPunctuator(.leftBrace) else {
            return .structure(name)
        }
        advance()

        var members: [VariableDeclaration] = []
        while !current.isPunctuator(.rightBrace), !isAtEnd {
            let (memberSpecifier, _) = try parseDeclarationSpecifiers()
            repeat {
                let declarator = try parseDeclarator(context: "構造体のメンバー", base: memberSpecifier)
                let type = TypeName(declarator.type, location: declarator.location)
                members.append(VariableDeclaration(name: declarator.name, type: type, initializer: nil,
                                                   isStatic: false, location: declarator.location))
            } while match(.comma)
            try expect(.semicolon, "メンバー宣言の終わり")
        }
        try expect(.rightBrace, "構造体の終わり")

        let definition = StructDefinition(name: name, members: members, isUnion: isUnion, location: location)
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

    /// 宣言子の形 (`*p[3]`, `(*f)(int)` など) をそのまま木にしたもの。
    private indirect enum DeclaratorNode {
        case name(String, SourceLocation)
        case pointer(DeclaratorNode)
        case array(DeclaratorNode, Int?)
        case function(DeclaratorNode, [FunctionParameter], Bool)
    }

    private struct Declarator {
        var name: String
        var type: TypeRef
        var location: SourceLocation
    }

    /// 宣言子を読み、基底型と組み合わせて完全な型にする。
    private mutating func parseDeclarator(context: String, base: TypeSpecifier,
                                          allowAnonymous: Bool = false) throws -> Declarator {
        let node = try parseDeclaratorNode(context: context, allowAnonymous: allowAnonymous)
        return resolve(node, base: .base(base))
    }

    private mutating func parseDeclaratorNode(context: String,
                                              allowAnonymous: Bool) throws -> DeclaratorNode {
        var pointerCount = 0
        while match(.star) {
            pointerCount += 1
            while current.isKeyword(.constKeyword) || current.isKeyword(.volatile) { advance() }
        }

        var node: DeclaratorNode
        // 括弧でくくられた宣言子 (関数ポインタなど)
        if current.isPunctuator(.leftParen),
           peek(1).isPunctuator(.star) || peek(1).isPunctuator(.leftParen)
            || (peek(1).identifier != nil && !isTypeSpecifierStart(peek(1))) {
            advance()
            node = try parseDeclaratorNode(context: context, allowAnonymous: allowAnonymous)
            try expect(.rightParen, "宣言子の括弧の後ろ")
        } else if let identifier = current.identifier {
            node = .name(identifier, current.location)
            advance()
        } else if allowAnonymous {
            node = .name("", current.location)
        } else {
            diagnostics.error("\(context)に名前が必要です (見つかったのは \(current.text))。", at: current.location)
            throw AbortCompilation()
        }

        // 後置 (配列・関数)
        while true {
            if current.isPunctuator(.leftBracket) {
                advance()
                if current.isPunctuator(.rightBracket) {
                    advance()
                    node = .array(node, nil)
                    continue
                }
                let expression = try parseConditionalExpression()
                try expect(.rightBracket, "配列の大きさの後ろ")
                if let value = foldConstant(expression) {
                    node = .array(node, Int(value))
                } else {
                    diagnostics.error("配列の大きさは定数でなければなりません。", at: expression.location)
                    node = .array(node, 0)
                }
            } else if current.isPunctuator(.leftParen) {
                advance()
                let (parameters, isVariadic) = try parseParameterList()
                node = .function(node, parameters, isVariadic)
            } else {
                break
            }
        }

        for _ in 0..<pointerCount {
            node = .pointer(node)
        }
        return node
    }

    /// `(` を読んだ後の引数リスト。
    private mutating func parseParameterList() throws -> ([FunctionParameter], Bool) {
        var parameters: [FunctionParameter] = []
        var isVariadic = false

        if current.isPunctuator(.rightParen) {
            advance()
            return (parameters, isVariadic)
        }
        if current.isKeyword(.void), peek(1).isPunctuator(.rightParen) {
            advance()
            advance()
            return (parameters, isVariadic)
        }

        repeat {
            if current.isPunctuator(.ellipsis) {
                advance()
                isVariadic = true
                break
            }
            let location = current.location
            let (specifier, _) = try parseDeclarationSpecifiers()
            let declarator = try parseDeclarator(context: "引数", base: specifier, allowAnonymous: true)
            parameters.append(FunctionParameter(name: declarator.name,
                                                type: TypeName(declarator.type, location: location),
                                                location: location))
        } while match(.comma)

        try expect(.rightParen, "引数リストの終わり")
        return (parameters, isVariadic)
    }

    /// 宣言子の木を、内側から基底型に適用していく。
    private func resolve(_ node: DeclaratorNode, base: TypeRef) -> Declarator {
        switch node {
        case .name(let name, let location):
            return Declarator(name: name, type: base, location: location)
        case .pointer(let inner):
            return resolve(inner, base: .pointer(base))
        case .array(let inner, let count):
            return resolve(inner, base: .array(base, count: count))
        case .function(let inner, let parameters, let isVariadic):
            return resolve(inner, base: .function(base, parameters: parameters, isVariadic: isVariadic))
        }
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
                advance()
                let (label, _) = try expectIdentifier("goto の飛び先")
                try expect(.semicolon, "goto の後ろ")
                return .gotoStmt(label, location)
            default:
                break
            }
        }
        if isTypeSpecifierStart(current) {
            return try parseDeclarationStatement()
        }

        // ラベル (`name:`) — goto の飛び先
        if let label = current.identifier, peek(1).isPunctuator(.colon) {
            advance()
            advance()
            let statement = try parseStatement()
            return .labeled(label, statement, location)
        }

        let expression = try parseExpression()
        try expect(.semicolon, "式の後ろ")
        return .expression(expression, location)
    }

    private mutating func parseDeclarationStatement() throws -> Stmt {
        let location = current.location
        if current.isKeyword(.typedef) {
            advance()
            let (typedefSpecifier, _) = try parseDeclarationSpecifiers()
            repeat {
                let declarator = try parseDeclarator(context: "typedef", base: typedefSpecifier)
                typedefNames.insert(declarator.name)
                pendingTypedefs.append(.typedefDefinition(name: declarator.name,
                                                          type: TypeName(declarator.type,
                                                                         location: declarator.location),
                                                          declarator.location))
            } while match(.comma)
            try expect(.semicolon, "typedef の終わり")
            return .expression(nil, location)
        }

        let (specifier, isStatic) = try parseDeclarationSpecifiers()
        var declarations: [VariableDeclaration] = []
        repeat {
            let declarator = try parseDeclarator(context: "変数宣言", base: specifier)
            let type = TypeName(declarator.type, location: declarator.location)
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

    /// `int *` や `int (*)(int)` のような、名前のない型。
    private mutating func parseTypeName() throws -> TypeName {
        let location = current.location
        let (specifier, _) = try parseDeclarationSpecifiers()
        let declarator = try parseDeclarator(context: "型", base: specifier, allowAnonymous: true)
        return TypeName(declarator.type, location: location)
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
            } else if current.isPunctuator(.leftParen),
                      case .identifier("va_arg", _) = expression {
                advance()
                let list = try parseAssignmentExpression()
                try expect(.comma, "va_arg の型の前")
                let typeName = try parseTypeName()
                try expect(.rightParen, "va_arg の後ろ")
                expression = .vaArg(list, typeName, location)
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
