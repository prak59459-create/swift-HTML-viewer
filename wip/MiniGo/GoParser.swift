import Foundation

/// Go のトークン列から AST を組み立てる再帰下降パーサ。
/// セミコロンの自動挿入は正確にはまねず、`;` や改行は単なる区切りとして扱う
/// (このインタプリタが実行する範囲のプログラムでは違いが出ない)。
struct GoParser {
    private let tokens: [GoToken]
    private var position = 0
    private let diagnostics: DiagnosticBag

    init(tokens: [GoToken], diagnostics: DiagnosticBag) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }

    private var current: GoToken { tokens[position] }
    private func peek(_ offset: Int = 0) -> GoToken {
        let index = position + offset
        return index < tokens.count ? tokens[index] : tokens[tokens.count - 1]
    }

    @discardableResult
    private mutating func advance() -> GoToken {
        let token = current
        if case .endOfFile = token.kind {} else { position += 1 }
        return token
    }

    private func check(op symbol: String) -> Bool { current.isOperator(symbol) }
    private func check(keyword: String) -> Bool { current.isKeyword(keyword) }

    @discardableResult
    private mutating func match(op symbol: String) -> Bool {
        if check(op: symbol) { advance(); return true }
        return false
    }

    @discardableResult
    private mutating func match(keyword: String) -> Bool {
        if check(keyword: keyword) { advance(); return true }
        return false
    }

    @discardableResult
    private mutating func expect(op symbol: String) -> Bool {
        if match(op: symbol) { return true }
        diagnostics.error("'\(symbol)' が必要です (実際には '\(current.text)')", at: current.location)
        return false
    }

    private mutating func expectIdentifier() -> String {
        if let name = current.identifier, !GoLexer.keywords.contains(name) || isSoftContext(name) {
            advance()
            return name
        }
        diagnostics.error("識別子が必要です (実際には '\(current.text)')", at: current.location)
        return "_"
    }

    private func isSoftContext(_ name: String) -> Bool {
        // 型名としても識別子としても使われるもの
        ["int", "int64", "float64", "string", "bool", "byte", "rune", "error"].contains(name)
    }

    private mutating func skipTerminators() {
        while check(op: ";") { advance() }
    }

    // MARK: - プログラム全体

    mutating func parseProgram() -> [GoStmt] {
        match(keyword: "package")
        if !check(op: ";") { _ = current.identifier; advance() }
        skipTerminators()
        while match(keyword: "import") {
            if match(op: "(") {
                while !check(op: ")"), !isAtEnd { advance() }
                match(op: ")")
            } else {
                advance()
            }
            skipTerminators()
        }
        var statements: [GoStmt] = []
        skipTerminators()
        while !isAtEnd {
            statements.append(parseTopLevel())
            skipTerminators()
        }
        return statements
    }

    private var isAtEnd: Bool { if case .endOfFile = current.kind { return true }; return false }

    private mutating func parseTopLevel() -> GoStmt {
        if check(keyword: "func") { return parseFuncDecl() }
        if check(keyword: "var") { return parseVarDecl() }
        if check(keyword: "const") { return parseConstDecl() }
        if check(keyword: "type") { return parseTypeDecl() }
        diagnostics.error("トップレベルの宣言が必要です (実際には '\(current.text)')", at: current.location)
        advance()
        return .empty
    }

    // MARK: - 型

    private mutating func parseType() -> GoTypeRef {
        if match(op: "*") { return .pointer(parseType()) }
        if match(op: "[") {
            if match(op: "]") { return .slice(parseType()) }
            if let sizeToken = current.identifier, case .integer = current.kind {} // unreachable guard
            if case .integer(let n) = current.kind {
                advance()
                match(op: "]")
                return .array(n, parseType())
            }
            // サイズを式で書かない前提。念のため読み飛ばし
            while !check(op: "]"), !isAtEnd { advance() }
            match(op: "]")
            return .slice(parseType())
        }
        if match(keyword: "map") {
            expect(op: "[")
            let key = parseType()
            expect(op: "]")
            let value = parseType()
            return .map(key, value)
        }
        if match(keyword: "func") {
            _ = parseFuncSignature()
            return .named("func")
        }
        if match(keyword: "struct") {
            // 無名 struct 型はほぼ使わない想定。フィールドを読み飛ばす。
            expect(op: "{")
            while !check(op: "}"), !isAtEnd { advance() }
            expect(op: "}")
            return .named("struct")
        }
        let name = expectIdentifier()
        return .named(name)
    }

    private mutating func parseFuncSignature() -> GoFunctionSignature {
        expect(op: "(")
        let params = parseParamList()
        expect(op: ")")
        var results: [GoParam] = []
        if match(op: "(") {
            results = parseParamList()
            expect(op: ")")
        } else if !check(op: "{") && !check(op: ";") && !isAtEnd {
            results = [GoParam(name: "", type: parseType())]
        }
        return GoFunctionSignature(params: params, results: results)
    }

    private mutating func parseParamList() -> [GoParam] {
        var params: [GoParam] = []
        if check(op: ")") { return params }
        while true {
            var names = [expectIdentifier()]
            while match(op: ",") {
                // 型が続く場合と、さらに名前が続く場合がある (`a, b int`)
                if check(op: ")") { break }
                names.append(expectIdentifier())
            }
            let type = parseType()
            for name in names { params.append(GoParam(name: name, type: type)) }
            if !match(op: ",") { break }
            if check(op: ")") { break }
        }
        return params
    }

    // MARK: - 宣言

    private mutating func parseFuncDecl() -> GoStmt {
        match(keyword: "func")
        var receiver: GoParam? = nil
        if match(op: "(") {
            let name = expectIdentifier()
            let type = parseType()
            receiver = GoParam(name: name, type: type)
            expect(op: ")")
        }
        let name = expectIdentifier()
        let signature = parseFuncSignature()
        let body = parseBlock()
        return .funcDecl(GoFunctionDecl(name: name, receiver: receiver, signature: signature, body: body))
    }

    private mutating func parseVarDecl() -> GoStmt {
        let location = current.location
        match(keyword: "var")
        if match(op: "(") {
            var names: [String] = []
            var type: GoTypeRef = .unknown
            var values: [GoExpr] = []
            skipTerminators()
            while !check(op: ")"), !isAtEnd {
                let (n, t, v) = parseVarSpec()
                names.append(contentsOf: n)
                if !n.isEmpty { type = t }
                values.append(contentsOf: v)
                skipTerminators()
            }
            expect(op: ")")
            return .varDecl(names: names, type: type, values: values, location: location)
        }
        let (names, type, values) = parseVarSpec()
        return .varDecl(names: names, type: type, values: values, location: location)
    }

    private mutating func parseVarSpec() -> ([String], GoTypeRef, [GoExpr]) {
        var names = [expectIdentifier()]
        while match(op: ",") { names.append(expectIdentifier()) }
        var type: GoTypeRef = .unknown
        if !check(op: "=") && !check(op: ";") {
            type = parseType()
        }
        var values: [GoExpr] = []
        if match(op: "=") {
            values.append(parseExpr())
            while match(op: ",") { values.append(parseExpr()) }
        }
        return (names, type, values)
    }

    private mutating func parseConstDecl() -> GoStmt {
        let location = current.location
        match(keyword: "const")
        if match(op: "(") {
            var names: [String] = []
            var type: GoTypeRef = .unknown
            var values: [GoExpr] = []
            skipTerminators()
            while !check(op: ")"), !isAtEnd {
                let (n, t, v) = parseVarSpec()
                names.append(contentsOf: n)
                if !n.isEmpty { type = t }
                values.append(contentsOf: v)
                skipTerminators()
            }
            expect(op: ")")
            return .constDecl(names: names, type: type, values: values, location: location)
        }
        let (names, type, values) = parseVarSpec()
        return .constDecl(names: names, type: type, values: values, location: location)
    }

    private mutating func parseTypeDecl() -> GoStmt {
        match(keyword: "type")
        let name = expectIdentifier()
        if match(keyword: "struct") {
            expect(op: "{")
            skipTerminators()
            var fields: [GoParam] = []
            while !check(op: "}"), !isAtEnd {
                var names = [expectIdentifier()]
                while match(op: ",") { names.append(expectIdentifier()) }
                let type = parseType()
                for n in names { fields.append(GoParam(name: n, type: type)) }
                skipTerminators()
            }
            expect(op: "}")
            return .structDecl(name: name, fields: fields)
        }
        let underlying = parseType()
        return .typeDecl(name: name, underlying: underlying, isStruct: false, fields: [])
    }

    // MARK: - 文

    private mutating func parseBlock() -> [GoStmt] {
        expect(op: "{")
        skipTerminators()
        var statements: [GoStmt] = []
        while !check(op: "}"), !isAtEnd {
            statements.append(parseStatement())
            skipTerminators()
        }
        expect(op: "}")
        return statements
    }

    private mutating func parseStatement() -> GoStmt {
        if check(op: "{") { return .block(parseBlock()) }
        if check(keyword: "var") { return parseVarDecl() }
        if check(keyword: "const") { return parseConstDecl() }
        if check(keyword: "type") { return parseTypeDecl() }
        if check(keyword: "if") { return parseIf() }
        if check(keyword: "for") { return parseFor() }
        if check(keyword: "switch") { return parseSwitch() }
        if check(keyword: "return") { return parseReturn() }
        if check(keyword: "break") { advance(); return .breakStmt }
        if check(keyword: "continue") { advance(); return .continueStmt }
        if check(keyword: "func"), peek(1).identifier != nil {
            return parseFuncDecl()
        }
        return parseSimpleStatement()
    }

    /// 式文・代入・:=・インクリメントをまとめて扱う (if/for の init にも使う)。
    private mutating func parseSimpleStatement() -> GoStmt {
        let location = current.location
        let first = parseExpr()
        if match(op: ":=") {
            var names = [exprAsName(first)]
            var values = [parseExpr()]
            while match(op: ",") {
                // 2 つ目以降の左辺は識別子のみのはずだが、緩く式として読む
                names.append(expectIdentifier())
                _ = values // placeholder, replaced below
            }
            // 複数代入 `:=` は左辺を先に全部集める必要があるため、上のロジックを直す
            return finishShortVarDecl(first: first, location: location)
        }
        if check(op: "++") || check(op: "--") {
            let opText = current.text
            advance()
            return .incDec(target: first, op: opText, location: location)
        }
        let assignOps = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]
        for opSymbol in assignOps where check(op: opSymbol) {
            advance()
            var targets = [first]
            var values: [GoExpr] = []
            if opSymbol == "=" {
                values.append(parseExpr())
                while match(op: ",") {
                    if values.count >= 1, targets.count < 2, false { }
                    values.append(parseExpr())
                }
                // 複数代入 `a, b = b, a` 用に左辺を集め直す必要がある
            } else {
                values.append(parseExpr())
            }
            return .assign(op: opSymbol, targets: targets, values: values, location: location)
        }
        if match(op: ",") {
            // 複数代入 `a, b = ...` または複数宣言 `a, b := ...`
            var targets = [first]
            targets.append(parseExpr())
            while match(op: ",") { targets.append(parseExpr()) }
            if match(op: ":=") {
                let names = targets.map { exprAsName($0) }
                var values = [parseExpr()]
                while match(op: ",") { values.append(parseExpr()) }
                return .shortVarDecl(names: names, values: values, location: location)
            }
            expect(op: "=")
            var values = [parseExpr()]
            while match(op: ",") { values.append(parseExpr()) }
            return .assign(op: "=", targets: targets, values: values, location: location)
        }
        return .exprStmt(first)
    }

    private mutating func finishShortVarDecl(first: GoExpr, location: SourceLocation) -> GoStmt {
        let names = [exprAsName(first)]
        var values = [parseExpr()]
        while match(op: ",") { values.append(parseExpr()) }
        return .shortVarDecl(names: names, values: values, location: location)
    }

    private func exprAsName(_ expr: GoExpr) -> String {
        if case .identifier(let name, _) = expr { return name }
        return "_"
    }

    private mutating func parseIf() -> GoStmt {
        match(keyword: "if")
        let (initStmt, cond) = parseHeaderWithOptionalInit()
        let thenBody = parseBlock()
        var elseStmt: GoStmt? = nil
        if match(keyword: "else") {
            if check(keyword: "if") {
                elseStmt = parseIf()
            } else {
                elseStmt = .block(parseBlock())
            }
        }
        return .ifStmt(initStmt: initStmt, cond: cond, then: thenBody, elseStmt: elseStmt)
    }

    /// `if init; cond {` の形をパースする。init が無ければ cond だけ。
    private mutating func parseHeaderWithOptionalInit() -> (GoStmt?, GoExpr) {
        let checkpoint = position
        // 単純に式として cond を読めるか試し、';' があれば init だったと判断する
        var initStmt: GoStmt? = nil
        var stmt = parseSimpleStatement()
        if match(op: ";") {
            initStmt = stmt
            stmt = parseSimpleStatement()
        }
        if case .exprStmt(let expr) = stmt {
            return (initStmt, expr)
        }
        // 想定外の形。式に戻せなければ true 扱いにしてエラーは出さない (簡略化)
        position = checkpoint
        let expr = parseExpr()
        return (nil, expr)
    }

    private mutating func parseFor() -> GoStmt {
        match(keyword: "for")
        if check(op: "{") {
            return .forInfinite(body: parseBlock())
        }
        // range 形式かどうかを先読みで判定
        let checkpoint = position
        if let rangeStmt = tryParseForRange() {
            return rangeStmt
        }
        position = checkpoint

        // クラシック形式 `for init; cond; post { }` か、条件だけの `for cond { }`
        if !check(op: ";") {
            let start = position
            let firstExpr = tryParseExprOnly()
            if let firstExpr, check(op: "{") {
                return .forClassic(initStmt: nil, cond: firstExpr, post: nil, body: parseBlock())
            }
            position = start
        }
        var initStmt: GoStmt? = nil
        if !check(op: ";") { initStmt = parseSimpleStatement() }
        expect(op: ";")
        var cond: GoExpr? = nil
        if !check(op: ";") { cond = parseExpr() }
        expect(op: ";")
        var post: GoStmt? = nil
        if !check(op: "{") { post = parseSimpleStatement() }
        let body = parseBlock()
        return .forClassic(initStmt: initStmt, cond: cond, post: post, body: body)
    }

    private mutating func tryParseExprOnly() -> GoExpr? {
        let expr = parseExpr()
        return expr
    }

    private mutating func tryParseForRange() -> GoStmt? {
        var keyName: String? = nil
        var valueName: String? = nil
        var declares = true
        if check(op: "{") { return nil }
        if check(keyword: "range") {
            advance()
            let collection = parseExpr()
            guard check(op: "{") else { return nil }
            return .forRange(keyName: nil, valueName: nil, declares: false, collection: collection, body: parseBlock())
        }
        let firstIsBlank = check(op: "_")
        guard current.identifier != nil || firstIsBlank else { return nil }
        let firstName = current.identifier ?? "_"
        let saved = position
        advance()
        if match(op: ",") {
            guard current.identifier != nil else { position = saved; return nil }
            let secondName = current.identifier!
            advance()
            if match(op: ":=") {
                declares = true
            } else if match(op: "=") {
                declares = false
            } else {
                position = saved
                return nil
            }
            guard match(keyword: "range") else { position = saved; return nil }
            keyName = firstName
            valueName = secondName
            let collection = parseExpr()
            guard check(op: "{") else { return nil }
            return .forRange(keyName: keyName, valueName: valueName, declares: declares, collection: collection, body: parseBlock())
        }
        if match(op: ":=") {
            declares = true
        } else if match(op: "=") {
            declares = false
        } else {
            position = saved
            return nil
        }
        guard match(keyword: "range") else { position = saved; return nil }
        valueName = firstName
        let collection = parseExpr()
        guard check(op: "{") else { return nil }
        return .forRange(keyName: nil, valueName: valueName, declares: declares, collection: collection, body: parseBlock())
    }

    private mutating func parseSwitch() -> GoStmt {
        match(keyword: "switch")
        var initStmt: GoStmt? = nil
        var tag: GoExpr? = nil
        if !check(op: "{") {
            let checkpoint = position
            var stmt = parseSimpleStatement()
            if match(op: ";") {
                initStmt = stmt
                if !check(op: "{") { stmt = parseSimpleStatement() } else { stmt = .empty }
            }
            if case .exprStmt(let expr) = stmt {
                tag = expr
            } else if case .empty = stmt {
                tag = nil
            } else {
                position = checkpoint
                tag = nil
                initStmt = nil
                if !check(op: "{") { tag = parseExpr() }
            }
        }
        expect(op: "{")
        skipTerminators()
        var cases: [(values: [GoExpr], body: [GoStmt])] = []
        var defaultBody: [GoStmt]? = nil
        while check(keyword: "case") || check(keyword: "default") {
            if match(keyword: "case") {
                var values = [parseExpr()]
                while match(op: ",") { values.append(parseExpr()) }
                expect(op: ":")
                skipTerminators()
                var body: [GoStmt] = []
                while !check(keyword: "case"), !check(keyword: "default"), !check(op: "}"), !isAtEnd {
                    body.append(parseStatement())
                    skipTerminators()
                }
                cases.append((values, body))
            } else {
                match(keyword: "default")
                expect(op: ":")
                skipTerminators()
                var body: [GoStmt] = []
                while !check(keyword: "case"), !check(keyword: "default"), !check(op: "}"), !isAtEnd {
                    body.append(parseStatement())
                    skipTerminators()
                }
                defaultBody = body
            }
        }
        expect(op: "}")
        return .switchStmt(initStmt: initStmt, tag: tag, cases: cases, defaultBody: defaultBody)
    }

    private mutating func parseReturn() -> GoStmt {
        let location = current.location
        match(keyword: "return")
        var values: [GoExpr] = []
        if !check(op: ";"), !check(op: "}"), !isAtEnd {
            values.append(parseExpr())
            while match(op: ",") { values.append(parseExpr()) }
        }
        return .returnStmt(values, location)
    }

    // MARK: - 式 (優先順位登り法)

    mutating func parseExpr() -> GoExpr { parseBinary(0) }

    private static let precedence: [String: Int] = [
        "||": 1, "&&": 2,
        "==": 3, "!=": 3, "<": 3, "<=": 3, ">": 3, ">=": 3,
        "+": 4, "-": 4, "|": 4, "^": 4,
        "*": 5, "/": 5, "%": 5, "<<": 5, ">>": 5, "&": 5, "&^": 5,
    ]

    private mutating func parseBinary(_ minPrecedence: Int) -> GoExpr {
        var left = parseUnary()
        while case .op(let symbol) = current.kind, let precedence = GoParser.precedence[symbol], precedence >= minPrecedence {
            let location = current.location
            advance()
            let right = parseBinary(precedence + 1)
            left = .binary(symbol, left, right, location)
        }
        return left
    }

    private mutating func parseUnary() -> GoExpr {
        let location = current.location
        if match(op: "-") { return .unary("-", parseUnary(), location) }
        if match(op: "!") { return .unary("!", parseUnary(), location) }
        if match(op: "+") { return parseUnary() }
        if match(op: "&") { return .addressOf(parseUnary(), location) }
        if match(op: "*") {
            // *T (型) と *expr (デリファレンス) は文脈依存。式の文脈ではデリファレンスとして扱う。
            return .deref(parseUnary(), location)
        }
        return parsePostfix(parsePrimary())
    }

    private mutating func parsePostfix(_ base: GoExpr) -> GoExpr {
        var expr = base
        while true {
            let location = current.location
            if match(op: ".") {
                let name = expectIdentifier()
                expr = .selector(expr, name, location)
            } else if match(op: "(") {
                var args: [GoExpr] = []
                if !check(op: ")") {
                    args.append(parseExpr())
                    while match(op: ",") {
                        if check(op: ")") { break }
                        args.append(parseExpr())
                    }
                }
                match(op: "...") // append(a, b...) の可変長展開は読み飛ばす
                expect(op: ")")
                expr = .call(expr, args, location)
            } else if match(op: "[") {
                if check(op: ":") {
                    advance()
                    let high = check(op: "]") ? nil : parseExpr()
                    expect(op: "]")
                    expr = .sliceExpr(expr, nil, high, location)
                } else {
                    let first = parseExpr()
                    if match(op: ":") {
                        let high = check(op: "]") ? nil : parseExpr()
                        expect(op: "]")
                        expr = .sliceExpr(expr, first, high, location)
                    } else {
                        expect(op: "]")
                        expr = .index(expr, first, location)
                    }
                }
            } else if check(op: "{"), isCompositeLiteralContext(expr) {
                expr = parseCompositeLiteralBody(for: expr, location: location)
            } else {
                break
            }
        }
        return expr
    }

    /// `Point{X: 1}` のような複合リテラルを、選択子・識別子の直後の `{` から判定する。
    /// if/for/switch の条件式直後の `{` と衝突しないよう、呼び出し側で制御する。
    private var allowCompositeLiteral = true
    private func isCompositeLiteralContext(_ expr: GoExpr) -> Bool {
        guard allowCompositeLiteral else { return false }
        switch expr {
        case .identifier, .selector: return true
        default: return false
        }
    }

    private mutating func parseCompositeLiteralBody(for base: GoExpr, location: SourceLocation) -> GoExpr {
        expect(op: "{")
        skipTerminators()
        var fields: [(String?, GoExpr)] = []
        while !check(op: "}"), !isAtEnd {
            if let name = current.identifier, peek(1).isOperator(":") {
                advance(); advance()
                fields.append((name, parseExpr()))
            } else {
                fields.append((nil, parseExpr()))
            }
            skipTerminators()
            if !match(op: ",") { break }
            skipTerminators()
        }
        expect(op: "}")
        let typeName: String
        if case .identifier(let n, _) = base { typeName = n } else { typeName = "?" }
        return .compositeLiteral(.named(typeName), fields, location)
    }

    private mutating func parsePrimary() -> GoExpr {
        let location = current.location
        switch current.kind {
        case .integer(let value):
            advance()
            return .intLiteral(value)
        case .double(let value):
            advance()
            return .doubleLiteral(value)
        case .string(let value):
            advance()
            return .stringLiteral(value)
        case .identifier(let name):
            if name == "true" { advance(); return .boolLiteral(true) }
            if name == "false" { advance(); return .boolLiteral(false) }
            if name == "nil" { advance(); return .nilLiteral }
            if name == "func" { return parseFunctionLiteral() }
            if name == "make" { return parseMakeCall() }
            if ["int", "int64", "float64", "string", "bool", "byte", "rune"].contains(name), peek(1).isOperator("(") {
                advance(); advance()
                let inner = parseExpr()
                expect(op: ")")
                return .typeConversion(.named(name), inner, location)
            }
            advance()
            return .identifier(name, location)
        case .op("("):
            advance()
            let saved = allowCompositeLiteral
            allowCompositeLiteral = true
            let expr = parseExpr()
            allowCompositeLiteral = saved
            expect(op: ")")
            return parsePostfixNoRecurse(expr)
        case .op("["):
            return parseSliceOrArrayLiteral()
        case .op("{"):
            // 無名 struct 的な用途はほぼ無い。安全側で空を返す。
            advance()
            while !check(op: "}"), !isAtEnd { advance() }
            expect(op: "}")
            return .nilLiteral
        default:
            if check(keyword: "map") { return parseMapLiteral() }
            diagnostics.error("式が必要です (実際には '\(current.text)')", at: current.location)
            advance()
            return .nilLiteral
        }
    }

    private mutating func parsePostfixNoRecurse(_ expr: GoExpr) -> GoExpr { expr }

    private mutating func parseFunctionLiteral() -> GoExpr {
        let location = current.location
        match(keyword: "func")
        let signature = parseFuncSignature()
        let body = parseBlock()
        return .functionLiteral(signature, body, location)
    }

    private mutating func parseMakeCall() -> GoExpr {
        let location = current.location
        advance() // make
        expect(op: "(")
        let type = parseType()
        var args: [GoExpr] = []
        while match(op: ",") { args.append(parseExpr()) }
        expect(op: ")")
        // make はコール式として扱い、インタプリタ側で型を見て解釈する
        return .call(.identifier("make", location), [typeRefAsMarker(type)] + args, location)
    }

    /// GoTypeRef を式に埋め込むためのマーカー (インタプリタでのみ解釈)。
    private func typeRefAsMarker(_ type: GoTypeRef) -> GoExpr {
        .compositeLiteral(type, [], .unknown)
    }

    private mutating func parseSliceOrArrayLiteral() -> GoExpr {
        let location = current.location
        advance() // [
        if match(op: "]") {
            let elementType = parseType()
            expect(op: "{")
            skipTerminators()
            var elements: [GoExpr] = []
            while !check(op: "}"), !isAtEnd {
                elements.append(parseExpr())
                skipTerminators()
                if !match(op: ",") { break }
                skipTerminators()
            }
            expect(op: "}")
            return .sliceLiteral(elementType, elements, location)
        }
        // 固定長配列 [N]T{...}
        var length: GoExpr? = nil
        if !check(op: "]") { length = parseExpr() }
        expect(op: "]")
        let elementType = parseType()
        expect(op: "{")
        skipTerminators()
        var elements: [GoExpr] = []
        while !check(op: "}"), !isAtEnd {
            elements.append(parseExpr())
            skipTerminators()
            if !match(op: ",") { break }
            skipTerminators()
        }
        expect(op: "}")
        _ = length
        return .sliceLiteral(elementType, elements, location)
    }

    private mutating func parseMapLiteral() -> GoExpr {
        let location = current.location
        match(keyword: "map")
        expect(op: "[")
        let keyType = parseType()
        expect(op: "]")
        let valueType = parseType()
        expect(op: "{")
        skipTerminators()
        var pairs: [(GoExpr, GoExpr)] = []
        while !check(op: "}"), !isAtEnd {
            let key = parseExpr()
            expect(op: ":")
            let value = parseExpr()
            pairs.append((key, value))
            skipTerminators()
            if !match(op: ",") { break }
            skipTerminators()
        }
        expect(op: "}")
        return .mapLiteral(keyType, valueType, pairs, location)
    }
}
