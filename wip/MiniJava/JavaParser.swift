import Foundation

/// 内蔵 Java インタプリタの構文解析器 (再帰下降)。
struct JavaParser {
    private let tokens: [JavaToken]
    private var pos = 0
    private let diagnostics: DiagnosticBag

    init(tokens: [JavaToken], diagnostics: DiagnosticBag) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }

    private var current: JavaToken { tokens[pos] }
    private func check(_ text: String) -> Bool { current.text == text && current.kind != .stringLiteral }
    private func checkKind(_ kind: JavaTokenKind) -> Bool { current.kind == kind }

    @discardableResult
    private mutating func advance() -> JavaToken {
        let t = current
        if pos < tokens.count - 1 { pos += 1 }
        return t
    }

    private mutating func match(_ text: String) -> Bool {
        if check(text) { _ = advance(); return true }
        return false
    }

    @discardableResult
    private mutating func expect(_ text: String) throws -> JavaToken {
        if check(text) { return advance() }
        diagnostics.error("'\(text)' が必要です (実際には '\(current.text)')", at: current.location)
        throw AbortCompilation()
    }

    private mutating func expectIdentifier() throws -> String {
        if current.kind == .identifier || current.kind == .keyword {
            return advance().text
        }
        diagnostics.error("識別子が必要です", at: current.location)
        throw AbortCompilation()
    }

    // MARK: - プログラム

    mutating func parseProgram() -> [JavaClassDecl] {
        var classes: [JavaClassDecl] = []
        while current.kind != .eof {
            if check("import") || check("package") {
                while !check(";") && current.kind != .eof { _ = advance() }
                _ = match(";")
                continue
            }
            do {
                if let decl = try parseClass() { classes.append(decl) }
            } catch {
                // エラーは記録済みなので、次のクラスまで読み飛ばして続行する。
                while current.kind != .eof && !check("class") { _ = advance() }
            }
        }
        return classes
    }

    private mutating func skipModifiers() {
        let mods: Set<String> = ["public", "private", "protected", "static", "final", "abstract"]
        while mods.contains(current.text) && (current.kind == .keyword) { _ = advance() }
    }

    private mutating func parseClass() throws -> JavaClassDecl? {
        skipModifiers()
        guard check("class") else {
            // クラス以外のトップレベル要素は読み飛ばす。
            _ = advance()
            return nil
        }
        let location = current.location
        _ = advance() // class
        let name = try expectIdentifier()
        var superName: String? = nil
        if match("extends") {
            superName = try expectIdentifier()
            skipGenericArgsIfPresent()
        }
        if match("implements") {
            _ = try expectIdentifier()
            while match(",") { _ = try expectIdentifier() }
        }
        try expect("{")
        var fields: [JavaFieldDecl] = []
        var methods: [JavaMethodDecl] = []
        var constructors: [JavaMethodDecl] = []
        while !check("}") && current.kind != .eof {
            var isStatic = false
            let mods: Set<String> = ["public", "private", "protected", "final", "abstract"]
            while mods.contains(current.text) || check("static") {
                if check("static") { isStatic = true }
                _ = advance()
            }
            if check(name) && peekIsOpenParen() {
                // コンストラクタ
                let ctorLoc = current.location
                _ = advance()
                try expect("(")
                let params = try parseParams()
                try expect(")")
                skipThrowsClause()
                let body = try parseBlockStatements()
                constructors.append(JavaMethodDecl(name: name, params: params, returnType: "void",
                                                   body: body, isStatic: false, location: ctorLoc))
                continue
            }
            // フィールドかメソッド: 型を読み、識別子の後ろが '(' ならメソッド
            let typeName = try parseTypeName()
            let memberName = try expectIdentifier()
            if check("(") {
                let methodLoc = current.location
                _ = advance()
                let params = try parseParams()
                try expect(")")
                skipThrowsClause()
                let body = try parseBlockStatements()
                methods.append(JavaMethodDecl(name: memberName, params: params, returnType: typeName,
                                              body: body, isStatic: isStatic, location: methodLoc))
            } else {
                var declarators: [(String, JavaExpr?)] = []
                var currentName = memberName
                var currentType = typeName
                while true {
                    while match("[") { try expect("]"); currentType += "[]" }
                    var initExpr: JavaExpr? = nil
                    if match("=") { initExpr = try parseExpression() }
                    declarators.append((currentName, initExpr))
                    if match(",") {
                        currentName = try expectIdentifier()
                        currentType = typeName
                        continue
                    }
                    break
                }
                try expect(";")
                for (n, v) in declarators {
                    fields.append(JavaFieldDecl(name: n, typeName: typeName, isStatic: isStatic, initExpr: v))
                }
            }
        }
        try expect("}")
        return JavaClassDecl(name: name, superName: superName, fields: fields,
                             methods: methods, constructors: constructors, location: location)
    }

    private func peekIsOpenParen() -> Bool {
        pos + 1 < tokens.count && tokens[pos + 1].text == "("
    }

    private mutating func skipThrowsClause() {
        if match("throws") {
            _ = try? expectIdentifier()
            while match(",") { _ = try? expectIdentifier() }
        }
    }

    private mutating func parseParams() throws -> [(typeName: String, name: String)] {
        var params: [(String, String)] = []
        if check(")") { return params }
        repeat {
            let type = try parseTypeName()
            let name = try expectIdentifier()
            params.append((type, name))
        } while match(",")
        return params
    }

    /// ジェネリクス `<...>` と配列 `[]` を含む型名を読む。
    private mutating func parseTypeName() throws -> String {
        var text = try expectIdentifier()
        skipGenericArgsIfPresent()
        while check("[") && peekIsCloseBracketAfterOpen() {
            _ = advance(); _ = advance()
            text += "[]"
        }
        return text
    }

    private func peekIsCloseBracketAfterOpen() -> Bool {
        pos + 1 < tokens.count && tokens[pos + 1].text == "]"
    }

    private mutating func skipGenericArgsIfPresent() {
        guard check("<") else { return }
        var depth = 0
        repeat {
            if check("<") { depth += 1 }
            if check(">") { depth -= 1 }
            if check(">>") { depth -= 2 }
            _ = advance()
        } while depth > 0 && current.kind != .eof
    }

    // MARK: - 文

    private mutating func parseBlockStatements() throws -> [JavaStmt] {
        try expect("{")
        var statements: [JavaStmt] = []
        while !check("}") && current.kind != .eof {
            statements.append(try parseStatement())
        }
        try expect("}")
        return statements
    }

    private mutating func parseStatement() throws -> JavaStmt {
        let location = current.location
        if check("{") { return .block(try parseBlockStatements(), location) }
        if check("if") { return try parseIf() }
        if check("while") { return try parseWhile() }
        if check("do") { return try parseDoWhile() }
        if check("for") { return try parseFor() }
        if check("return") {
            _ = advance()
            if match(";") { return .returnStmt(nil, location) }
            let value = try parseExpression()
            try expect(";")
            return .returnStmt(value, location)
        }
        if check("break") { _ = advance(); try expect(";"); return .breakStmt(location) }
        if check("continue") { _ = advance(); try expect(";"); return .continueStmt(location) }
        if check("switch") { return try parseSwitch() }
        if isTypeStart() {
            return try parseVarDeclStatement()
        }
        let expr = try parseExpression()
        try expect(";")
        return .exprStmt(expr, location)
    }

    private static let primitiveTypes: Set<String> = [
        "int", "long", "double", "float", "boolean", "char", "byte", "short", "String", "var"
    ]

    /// この位置が変数宣言 (型 識別子 ...) の開始かどうかを判定する。
    private func isTypeStart() -> Bool {
        guard current.kind == .identifier || current.kind == .keyword else { return false }
        if Self.primitiveTypes.contains(current.text) { return true }
        // 大文字で始まる識別子 + 識別子 の並びはクラス型の変数宣言とみなす (例: ArrayList<Integer> list)
        guard current.kind == .identifier, let first = current.text.first, first.isUppercase else { return false }
        var p = pos + 1
        if p < tokens.count && tokens[p].text == "<" {
            var depth = 0
            while p < tokens.count {
                if tokens[p].text == "<" { depth += 1 }
                if tokens[p].text == ">" { depth -= 1; if depth == 0 { p += 1; break } }
                if tokens[p].text == ">>" { depth -= 2; if depth <= 0 { p += 1; break } }
                p += 1
            }
        }
        while p < tokens.count && tokens[p].text == "[" && p + 1 < tokens.count && tokens[p + 1].text == "]" {
            p += 2
        }
        return p < tokens.count && tokens[p].kind == .identifier
    }

    private mutating func parseVarDeclStatement() throws -> JavaStmt {
        let location = current.location
        var typeName = try parseTypeName()
        var declarators: [(String, JavaExpr?)] = []
        var name = try expectIdentifier()
        while true {
            var currentType = typeName
            while match("[") { try expect("]"); currentType += "[]" }
            typeName = currentType
            var initExpr: JavaExpr? = nil
            if match("=") { initExpr = try parseExpression() }
            declarators.append((name, initExpr))
            if match(",") {
                name = try expectIdentifier()
                continue
            }
            break
        }
        try expect(";")
        return .varDecl(typeName: typeName, declarators: declarators, location)
    }

    private mutating func parseIf() throws -> JavaStmt {
        let location = current.location
        _ = advance()
        try expect("(")
        let cond = try parseExpression()
        try expect(")")
        let body = try parseStatementAsBlock()
        var elseBody: [JavaStmt]? = nil
        if match("else") {
            elseBody = try parseStatementAsBlock()
        }
        return .ifStmt(cond, body, elseBody, location)
    }

    private mutating func parseStatementAsBlock() throws -> [JavaStmt] {
        if check("{") { return try parseBlockStatements() }
        return [try parseStatement()]
    }

    private mutating func parseWhile() throws -> JavaStmt {
        let location = current.location
        _ = advance()
        try expect("(")
        let cond = try parseExpression()
        try expect(")")
        let body = try parseStatementAsBlock()
        return .whileStmt(cond, body, location)
    }

    private mutating func parseDoWhile() throws -> JavaStmt {
        let location = current.location
        _ = advance()
        let body = try parseStatementAsBlock()
        try expect("while")
        try expect("(")
        let cond = try parseExpression()
        try expect(")")
        try expect(";")
        return .doWhile(body, cond, location)
    }

    private mutating func parseFor() throws -> JavaStmt {
        let location = current.location
        _ = advance()
        try expect("(")
        // 拡張 for か判定: 型 識別子 ':'
        let savedPos = pos
        if isTypeStart() {
            let typeName = try parseTypeName()
            if current.kind == .identifier {
                let name = advance().text
                if match(":") {
                    let iterable = try parseExpression()
                    try expect(")")
                    let body = try parseStatementAsBlock()
                    return .forEach(typeName: typeName, name: name, iterable: iterable, body: body, location: location)
                }
            }
            pos = savedPos
        }
        var initStmts: [JavaStmt] = []
        if !check(";") {
            if isTypeStart() {
                initStmts = [try parseVarDeclStatement()]
            } else {
                var exprs = [try parseExpression()]
                while match(",") { exprs.append(try parseExpression()) }
                try expect(";")
                initStmts = exprs.map { .exprStmt($0, $0.location) }
            }
        } else {
            _ = advance()
        }
        var cond: JavaExpr? = nil
        if !check(";") { cond = try parseExpression() }
        try expect(";")
        var update: [JavaStmt] = []
        if !check(")") {
            repeat {
                let e = try parseExpression()
                update.append(.exprStmt(e, e.location))
            } while match(",")
        }
        try expect(")")
        let body = try parseStatementAsBlock()
        return .forStmt(initStmts: initStmts, cond: cond, update: update, body: body, location)
    }

    private mutating func parseSwitch() throws -> JavaStmt {
        let location = current.location
        _ = advance()
        try expect("(")
        let subject = try parseExpression()
        try expect(")")
        try expect("{")
        var cases: [JavaSwitchCase] = []
        while !check("}") && current.kind != .eof {
            var values: [JavaExpr] = []
            var isDefault = false
            if match("case") {
                values.append(try parseExpression())
                try expect(":")
            } else if match("default") {
                isDefault = true
                try expect(":")
            }
            var body: [JavaStmt] = []
            while !check("case") && !check("default") && !check("}") && current.kind != .eof {
                body.append(try parseStatement())
            }
            cases.append(JavaSwitchCase(values: values, isDefault: isDefault, body: body))
        }
        try expect("}")
        return .switchStmt(subject, cases, location)
    }

    // MARK: - 式 (優先順位順)

    mutating func parseExpression() throws -> JavaExpr {
        try parseAssignment()
    }

    private static let assignOps: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]

    private mutating func parseAssignment() throws -> JavaExpr {
        let left = try parseTernary()
        if Self.assignOps.contains(current.text) {
            let op = advance().text
            let location = left.location
            let right = try parseAssignment()
            return .assign(op, left, right, location)
        }
        return left
    }

    private mutating func parseTernary() throws -> JavaExpr {
        let cond = try parseLogicalOr()
        if match("?") {
            let location = cond.location
            let thenExpr = try parseExpression()
            try expect(":")
            let elseExpr = try parseAssignment()
            return .ternary(cond, thenExpr, elseExpr, location)
        }
        return cond
    }

    private mutating func parseLogicalOr() throws -> JavaExpr {
        var left = try parseLogicalAnd()
        while check("||") {
            let location = current.location
            _ = advance()
            left = .binary("||", left, try parseLogicalAnd(), location)
        }
        return left
    }

    private mutating func parseLogicalAnd() throws -> JavaExpr {
        var left = try parseBitOr()
        while check("&&") {
            let location = current.location
            _ = advance()
            left = .binary("&&", left, try parseBitOr(), location)
        }
        return left
    }

    private mutating func parseBitOr() throws -> JavaExpr {
        var left = try parseBitXor()
        while check("|") {
            let location = current.location
            _ = advance()
            left = .binary("|", left, try parseBitXor(), location)
        }
        return left
    }

    private mutating func parseBitXor() throws -> JavaExpr {
        var left = try parseBitAnd()
        while check("^") {
            let location = current.location
            _ = advance()
            left = .binary("^", left, try parseBitAnd(), location)
        }
        return left
    }

    private mutating func parseBitAnd() throws -> JavaExpr {
        var left = try parseEquality()
        while check("&") {
            let location = current.location
            _ = advance()
            left = .binary("&", left, try parseEquality(), location)
        }
        return left
    }

    private mutating func parseEquality() throws -> JavaExpr {
        var left = try parseRelational()
        while check("==") || check("!=") {
            let op = advance().text
            left = .binary(op, left, try parseRelational(), left.location)
        }
        return left
    }

    private mutating func parseRelational() throws -> JavaExpr {
        var left = try parseShift()
        while check("<") || check(">") || check("<=") || check(">=") || check("instanceof") {
            if check("instanceof") {
                _ = advance()
                let typeName = try parseTypeName()
                left = .instanceOf(left, typeName, left.location)
                continue
            }
            let op = advance().text
            left = .binary(op, left, try parseShift(), left.location)
        }
        return left
    }

    private mutating func parseShift() throws -> JavaExpr {
        var left = try parseAdditive()
        while check("<<") || check(">>") || check(">>>") {
            let op = advance().text
            left = .binary(op, left, try parseAdditive(), left.location)
        }
        return left
    }

    private mutating func parseAdditive() throws -> JavaExpr {
        var left = try parseMultiplicative()
        while check("+") || check("-") {
            let op = advance().text
            left = .binary(op, left, try parseMultiplicative(), left.location)
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> JavaExpr {
        var left = try parseUnary()
        while check("*") || check("/") || check("%") {
            let op = advance().text
            left = .binary(op, left, try parseUnary(), left.location)
        }
        return left
    }

    private mutating func parseUnary() throws -> JavaExpr {
        let location = current.location
        if check("!") || check("-") || check("+") || check("~") {
            let op = advance().text
            return .unary(op, try parseUnary(), prefix: true, location)
        }
        if check("++") || check("--") {
            let op = advance().text
            return .unary(op, try parseUnary(), prefix: true, location)
        }
        if check("(") && isCastAhead() {
            _ = advance()
            let typeName = try parseTypeName()
            try expect(")")
            let operand = try parseUnary()
            return .cast(typeName, operand, location)
        }
        return try parsePostfix()
    }

    private func isCastAhead() -> Bool {
        // '(' 型名 ')' の後に式が続く場合だけキャストとみなす。
        var p = pos + 1
        guard p < tokens.count, (tokens[p].kind == .identifier || Self.primitiveTypes.contains(tokens[p].text)) else { return false }
        let typeNameToken = tokens[p].text
        p += 1
        if p < tokens.count && tokens[p].text == "<" {
            var depth = 0
            while p < tokens.count {
                if tokens[p].text == "<" { depth += 1 }
                if tokens[p].text == ">" { depth -= 1; if depth == 0 { p += 1; break } }
                p += 1
            }
        }
        while p < tokens.count && tokens[p].text == "[" && p + 1 < tokens.count && tokens[p + 1].text == "]" {
            p += 2
        }
        guard p < tokens.count, tokens[p].text == ")" else { return false }
        p += 1
        guard p < tokens.count else { return false }
        let next = tokens[p]
        if Self.primitiveTypes.contains(typeNameToken) {
            return next.kind == .identifier || next.kind == .intLiteral || next.kind == .doubleLiteral ||
                   next.kind == .longLiteral || next.text == "(" || next.text == "-" || next.kind == .charLiteral
        }
        // 参照型キャストは識別子・'(' が続く場合のみとみなす (曖昧さ回避)。
        return next.kind == .identifier && !isBinaryOperatorLike(next.text)
    }

    private func isBinaryOperatorLike(_ text: String) -> Bool { false }

    private mutating func parsePostfix() throws -> JavaExpr {
        var expr = try parsePrimary()
        while true {
            if match(".") {
                let name = try expectIdentifier()
                skipGenericArgsIfPresent()
                if check("(") {
                    _ = advance()
                    let args = try parseArgs()
                    try expect(")")
                    expr = .call(receiver: expr, name: name, args: args, expr.location)
                } else {
                    expr = .member(expr, name, expr.location)
                }
                continue
            }
            if match("[") {
                let indexExpr = try parseExpression()
                try expect("]")
                expr = .index(expr, indexExpr, expr.location)
                continue
            }
            if check("++") || check("--") {
                let op = advance().text
                expr = .unary(op, expr, prefix: false, expr.location)
                continue
            }
            break
        }
        return expr
    }

    private mutating func parseArgs() throws -> [JavaExpr] {
        var args: [JavaExpr] = []
        if check(")") { return args }
        repeat {
            args.append(try parseExpression())
        } while match(",")
        return args
    }

    private mutating func parsePrimary() throws -> JavaExpr {
        let location = current.location
        if current.kind == .intLiteral {
            let text = advance().text
            return .intLiteral(Int32(text) ?? 0, location)
        }
        if current.kind == .longLiteral {
            let text = advance().text
            return .longLiteral(Int64(text) ?? 0, location)
        }
        if current.kind == .doubleLiteral {
            let text = advance().text
            return .doubleLiteral(Double(text) ?? 0, location)
        }
        if current.kind == .stringLiteral {
            return .stringLiteral(advance().text, location)
        }
        if current.kind == .charLiteral {
            let text = advance().text
            return .charLiteral(text.first ?? " ", location)
        }
        if match("true") { return .boolLiteral(true, location) }
        if match("false") { return .boolLiteral(false, location) }
        if match("null") { return .nullLiteral(location) }
        if match("this") { return .thisExpr(location) }
        if match("super") { return .superExpr(location) }
        if match("(") {
            let inner = try parseExpression()
            try expect(")")
            return inner
        }
        if match("new") {
            let typeName = try expectIdentifier()
            skipGenericArgsIfPresent()
            if check("[") {
                var sizeExprs: [JavaExpr] = []
                var sawEmpty = false
                while match("[") {
                    if check("]") { sawEmpty = true; _ = advance() }
                    else { sizeExprs.append(try parseExpression()); try expect("]") }
                }
                var initializer: [JavaExpr]? = nil
                if check("{") {
                    initializer = try parseArrayInitializer()
                }
                _ = sawEmpty
                return .newArray(elementType: typeName, sizeExprs: sizeExprs, initializer: initializer, location)
            }
            try expect("(")
            let args = try parseArgs()
            try expect(")")
            if check("{") {
                // 匿名クラス本体はサポート外なので読み飛ばす。
                _ = try? parseBlockStatements()
            }
            return .newObject(className: typeName, args: args, location)
        }
        if check("{") {
            return .arrayLiteral(try parseArrayInitializer(), location)
        }
        if current.kind == .identifier || current.kind == .keyword {
            let name = advance().text
            if check("(") {
                _ = advance()
                let args = try parseArgs()
                try expect(")")
                return .call(receiver: nil, name: name, args: args, location)
            }
            return .identifier(name, location)
        }
        diagnostics.error("式が必要です (実際には '\(current.text)')", at: location)
        throw AbortCompilation()
    }

    private mutating func parseArrayInitializer() throws -> [JavaExpr] {
        try expect("{")
        var values: [JavaExpr] = []
        if !check("}") {
            repeat {
                if check("}") { break }
                if check("{") {
                    values.append(.arrayLiteral(try parseArrayInitializer(), current.location))
                } else {
                    values.append(try parseExpression())
                }
            } while match(",")
        }
        try expect("}")
        return values
    }
}
