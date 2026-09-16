import Foundation

/// 再帰下降による C++ サブセットの構文解析器。
final class CppParser {
    private let tokens: [CppToken]
    private var index = 0
    private let diagnostics: DiagnosticBag
    /// これまでに見つけた struct/class の名前 (型として認識するため)。
    private var knownTypeNames: Set<String> = []

    init(tokens: [CppToken], diagnostics: DiagnosticBag) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }

    private var current: CppToken { tokens[index] }
    private func peek(_ offset: Int = 1) -> CppToken {
        let i = index + offset
        return i < tokens.count ? tokens[i] : tokens[tokens.count - 1]
    }
    @discardableResult
    private func advance() -> CppToken {
        let token = current
        if index < tokens.count - 1 { index += 1 }
        return token
    }
    private func check(_ text: String) -> Bool { current.text == text && current.kind != .stringLiteral }
    private func match(_ text: String) -> Bool {
        if check(text) { _ = advance(); return true }
        return false
    }
    private func expect(_ text: String, _ context: String = "") -> Bool {
        if match(text) { return true }
        fail("'\(text)' が必要です\(context.isEmpty ? "" : " (\(context))")。実際には '\(current.text)' でした")
        return false
    }
    private func fail(_ message: String) {
        diagnostics.error(message, at: current.location)
    }

    // MARK: - トップレベル

    func parseProgram() -> [CppStmt] {
        var statements: [CppStmt] = []
        skipUsingAndNamespace()
        while current.kind != .eof {
            if let stmt = parseTopLevelItem() {
                statements.append(stmt)
            } else if current.kind != .eof {
                // 復帰: 次のセミコロンか閉じ波括弧まで読み飛ばす。
                advance()
            }
            skipUsingAndNamespace()
        }
        return statements
    }

    private func skipUsingAndNamespace() {
        while check("using") || check("namespace") {
            while current.kind != .eof && !check(";") { advance() }
            _ = match(";")
        }
    }

    private func parseTopLevelItem() -> CppStmt? {
        if check("struct") || check("class") {
            return parseClassDecl()
        }
        guard let type = tryParseType() else {
            fail("宣言を解釈できません: '\(current.text)'")
            return nil
        }
        let byRef = match("&")
        _ = byRef
        guard current.kind == .identifier || current.kind == .keyword else {
            fail("識別子が必要です")
            return nil
        }
        let name = advance().text
        if check("(") {
            return .functionDecl(parseFunctionTail(name: name, returnType: type))
        }
        return parseVarDeclTail(type: type, firstName: name)
    }

    // MARK: - 型

    /// 型として解析できなければ位置を戻して nil を返す。
    private func tryParseType() -> CppType? {
        let saved = index
        while check("const") || check("static") || check("virtual") || check("unsigned") || check("inline") {
            advance()
        }
        if check("auto") { advance(); return .auto_ }
        if check("void") { advance(); return .void }
        if check("bool") { advance(); return .bool_ }
        if check("char") { advance(); return .char_ }
        if check("int") || check("long") || check("short") {
            advance()
            while check("long") || check("int") { advance() }
            return .int
        }
        if check("double") || check("float") { advance(); return .double }
        // std:: 修飾を読み飛ばす
        var beforeQualifier = index
        while current.kind == .identifier, current.text == "std", peek().text == "::" {
            advance(); advance()
            beforeQualifier = index
        }
        _ = beforeQualifier
        if current.kind == .identifier, current.text == "string" {
            advance(); return .string
        }
        if current.kind == .identifier, current.text == "vector" {
            advance()
            guard match("<") else { index = saved; return nil }
            guard let elementType = tryParseType() else { index = saved; return nil }
            _ = match(">") || match(">>") // `>>` はトークナイザが単一トークンにまとめている場合の保険
            closeAngleBracket()
            return .vector(elementType)
        }
        if current.kind == .identifier, current.text == "map" {
            advance()
            guard match("<") else { index = saved; return nil }
            guard let keyType = tryParseType() else { index = saved; return nil }
            guard match(",") else { index = saved; return nil }
            guard let valueType = tryParseType() else { index = saved; return nil }
            closeAngleBracket()
            return .map(keyType, valueType)
        }
        if current.kind == .identifier, knownTypeNames.contains(current.text) {
            let name = advance().text
            return .named(name)
        }
        index = saved
        return nil
    }

    /// ネストした `>>` (map<string, vector<int>> のようなもの) を 1 つずつ閉じる。
    private func closeAngleBracket() {
        if check(">") { advance(); return }
        if current.text == ">>" {
            // 2 つの '>' のうち 1 つだけ消費したことにする: トークンを ">" に置き換えられないため、
            // 単純化のためここでは両方消費する (ネストは 1 段までを想定)。
            advance()
        }
    }

    // MARK: - struct / class

    private func parseClassDecl() -> CppStmt {
        let location = current.location
        advance() // struct / class
        let name = advance().text
        knownTypeNames.insert(name)
        var parentName: String? = nil
        if match(":") {
            _ = match("public") || match("private") || match("protected")
            parentName = advance().text
        }
        expect("{")
        var fields: [CppFieldDecl] = []
        var methods: [String: CppFunctionDecl] = [:]
        var constructors: [CppFunctionDecl] = []
        while current.kind != .eof && !check("}") {
            if check("public") || check("private") || check("protected") {
                advance(); _ = match(":"); continue
            }
            if check("~") {
                // デストラクタは無視する。
                advance(); advance()
                if match("(") { while !check(")") && current.kind != .eof { advance() }; expect(")") }
                if check("{") { skipBraceGroup() } else { _ = match(";") }
                continue
            }
            if current.kind == .identifier, current.text == name, peek().text == "(" {
                let ctor = parseFunctionTail(name: name, returnType: .void, isConstructor: true)
                constructors.append(ctor)
                continue
            }
            guard let type = tryParseType() else {
                fail("メンバ宣言を解釈できません: '\(current.text)'")
                advance()
                continue
            }
            _ = match("&")
            guard current.kind == .identifier || current.kind == .keyword else {
                fail("メンバ名が必要です")
                continue
            }
            let memberName = advance().text
            if check("(") {
                let method = parseFunctionTail(name: memberName, returnType: type)
                methods[memberName] = method
                continue
            }
            var defaultValue: CppExpr? = nil
            if match("=") { defaultValue = parseAssignment() }
            fields.append(CppFieldDecl(type: type, name: memberName, defaultValue: defaultValue))
            while match(",") {
                let extraName = advance().text
                var extraDefault: CppExpr? = nil
                if match("=") { extraDefault = parseAssignment() }
                fields.append(CppFieldDecl(type: type, name: extraName, defaultValue: extraDefault))
            }
            expect(";")
        }
        expect("}")
        _ = match(";")
        return .classDecl(CppClassDecl(name: name, parentName: parentName, fields: fields,
                                       methods: methods, constructors: constructors, location: location))
    }

    private func skipBraceGroup() {
        expect("{")
        var depth = 1
        while depth > 0 && current.kind != .eof {
            if check("{") { depth += 1 }
            if check("}") { depth -= 1 }
            advance()
        }
    }

    // MARK: - 関数

    private func parseFunctionTail(name: String, returnType: CppType, isConstructor: Bool = false) -> CppFunctionDecl {
        let location = current.location
        expect("(")
        var parameters: [CppParameter] = []
        if !check(")") {
            repeat {
                if check("void") && peek().text == ")" { advance(); break }
                guard let ptype = tryParseType() else {
                    fail("引数の型が必要です")
                    break
                }
                let isRef = match("&")
                var pname = ""
                if current.kind == .identifier || (current.kind == .keyword && !check(",") && !check(")")) {
                    pname = advance().text
                }
                var defaultValue: CppExpr? = nil
                if match("=") { defaultValue = parseAssignment() }
                parameters.append(CppParameter(type: ptype, name: pname, isReference: isRef, defaultValue: defaultValue))
            } while match(",")
        }
        expect(")")
        _ = match("const")
        _ = match("override")
        var memberInits: [CppStmt] = []
        if isConstructor, match(":") {
            repeat {
                let fieldName = advance().text
                expect("(")
                var args: [CppExpr] = []
                if !check(")") {
                    repeat { args.append(parseAssignment()) } while match(",")
                }
                expect(")")
                let assignExpr = CppExpr.assign("=", .identifier(fieldName, location),
                                                args.first ?? .intLiteral(0, location), location)
                memberInits.append(.expression(assignExpr, location))
            } while match(",")
        }
        var body: [CppStmt] = []
        if check("{") {
            body = memberInits + parseBlockStatements()
        } else {
            _ = match(";")
            body = memberInits
        }
        return CppFunctionDecl(name: name, returnType: returnType, parameters: parameters, body: body, location: location)
    }

    // MARK: - 文

    private func parseBlockStatements() -> [CppStmt] {
        expect("{")
        var statements: [CppStmt] = []
        while current.kind != .eof && !check("}") {
            statements.append(parseStatement())
        }
        expect("}")
        return statements
    }

    private func parseStatement() -> CppStmt {
        let location = current.location
        if check("{") { return .block(parseBlockStatements(), location) }
        if check("if") { return parseIf() }
        if check("while") { return parseWhile() }
        if check("do") { return parseDoWhile() }
        if check("for") { return parseFor() }
        if check("switch") { return parseSwitch() }
        if check("break") { advance(); expect(";"); return .breakStmt(location) }
        if check("continue") { advance(); expect(";"); return .continueStmt(location) }
        if check("return") {
            advance()
            if match(";") { return .returnStmt(nil, location) }
            let value = parseExpression()
            expect(";")
            return .returnStmt(value, location)
        }
        if check("struct") || check("class") { return parseClassDecl() }
        if let type = tryParseType() {
            _ = match("&")
            guard current.kind == .identifier || current.kind == .keyword else {
                fail("変数名が必要です")
                _ = match(";")
                return .block([], location)
            }
            let name = advance().text
            if check("(") && type.isFunctionLike == false {
                // ローカル関数定義もどきは C++ では無効だが、寛容にプロトタイプとして無視する。
            }
            return parseVarDeclTail(type: type, firstName: name)
        }
        let expr = parseExpression()
        expect(";")
        return .expression(expr, location)
    }

    private func parseVarDeclTail(type: CppType, firstName: String) -> CppStmt {
        let location = current.location
        var names: [(String, CppExpr?)] = []
        names.append((firstName, parseOptionalInitializer(type: type)))
        while match(",") {
            _ = match("&")
            let extraName = advance().text
            names.append((extraName, parseOptionalInitializer(type: type)))
        }
        expect(";")
        return .varDecl(type: type, names: names, location)
    }

    private func parseOptionalInitializer(type: CppType) -> CppExpr? {
        let location = current.location
        if match("=") {
            if check("{") { return parseInitList() }
            return parseAssignment()
        }
        if check("{") { return parseInitList() }
        if check("(") {
            advance()
            var args: [CppExpr] = []
            if !check(")") {
                repeat { args.append(parseAssignment()) } while match(",")
            }
            expect(")")
            return .initList(args, location)
        }
        return nil
    }

    private func parseInitList() -> CppExpr {
        let location = current.location
        expect("{")
        var elements: [CppExpr] = []
        if !check("}") {
            repeat { elements.append(parseAssignment()) } while match(",")
        }
        expect("}")
        return .initList(elements, location)
    }

    private func parseIf() -> CppStmt {
        let location = current.location
        advance()
        expect("(")
        let condition = parseExpression()
        expect(")")
        let thenBody = parseSingleOrBlock()
        var elseBody: [CppStmt]? = nil
        if match("else") {
            if check("if") {
                elseBody = [parseIf()]
            } else {
                elseBody = parseSingleOrBlock()
            }
        }
        return .ifStmt(condition, thenBody, elseBody, location)
    }

    private func parseSingleOrBlock() -> [CppStmt] {
        if check("{") { return parseBlockStatements() }
        return [parseStatement()]
    }

    private func parseWhile() -> CppStmt {
        let location = current.location
        advance()
        expect("(")
        let condition = parseExpression()
        expect(")")
        return .whileStmt(condition, parseSingleOrBlock(), location)
    }

    private func parseDoWhile() -> CppStmt {
        let location = current.location
        advance()
        let body = parseSingleOrBlock()
        expect("while")
        expect("(")
        let condition = parseExpression()
        expect(")")
        expect(";")
        return .doWhile(body, condition, location)
    }

    private func parseFor() -> CppStmt {
        let location = current.location
        advance()
        expect("(")
        // range-based for か判定するため先読み: ')' より前に ':' が現れるか確認する。
        let isRangeBased = scanForColonBeforeSemicolon()
        if isRangeBased {
            let type = tryParseType() ?? .auto_
            let byRef = match("&")
            let name = advance().text
            expect(":")
            let subject = parseExpression()
            expect(")")
            return .forRange(type: type, name: name, byReference: byRef, subject: subject, body: parseSingleOrBlock(), location)
        }
        var initStmt: CppStmt? = nil
        if !check(";") {
            if let type = tryParseType() {
                _ = match("&")
                let name = advance().text
                initStmt = parseVarDeclTail(type: type, firstName: name)
            } else {
                let expr = parseExpression()
                expect(";")
                initStmt = .expression(expr, location)
            }
        } else {
            advance()
        }
        var condition: CppExpr? = nil
        if !check(";") { condition = parseExpression() }
        expect(";")
        var step: CppExpr? = nil
        if !check(")") { step = parseExpression() }
        expect(")")
        return .forStmt(initStmt, condition, step, parseSingleOrBlock(), location)
    }

    private func scanForColonBeforeSemicolon() -> Bool {
        var depth = 0
        var i = index
        while i < tokens.count {
            let t = tokens[i]
            if t.text == "(" { depth += 1 }
            if t.text == ")" { if depth == 0 { return false }; depth -= 1 }
            if depth == 0 && t.text == ";" { return false }
            if depth == 0 && t.text == ":" { return true }
            i += 1
        }
        return false
    }

    private func parseSwitch() -> CppStmt {
        let location = current.location
        advance()
        expect("(")
        let subject = parseExpression()
        expect(")")
        expect("{")
        var cases: [(values: [CppExpr]?, body: [CppStmt])] = []
        while current.kind != .eof && !check("}") {
            var values: [CppExpr] = []
            var isDefault = false
            while check("case") || check("default") {
                if match("case") {
                    values.append(parseExpression())
                    expect(":")
                } else {
                    advance()
                    expect(":")
                    isDefault = true
                }
            }
            var body: [CppStmt] = []
            while current.kind != .eof && !check("case") && !check("default") && !check("}") {
                body.append(parseStatement())
            }
            cases.append((values: isDefault ? nil : values, body: body))
        }
        expect("}")
        return .switchStmt(subject, cases, location)
    }

    // MARK: - 式

    func parseExpression() -> CppExpr { parseAssignment() }

    private static let assignOps: Set<String> = ["=", "+=", "-=", "*=", "/=", "%="]

    private func parseAssignment() -> CppExpr {
        let lhs = parseTernary()
        if Self.assignOps.contains(current.text) {
            let op = advance().text
            let rhs = parseAssignment()
            return .assign(op, lhs, rhs, lhs.location)
        }
        return lhs
    }

    private func parseTernary() -> CppExpr {
        let condition = parseLogicalOr()
        if match("?") {
            let thenValue = parseAssignment()
            expect(":")
            let elseValue = parseAssignment()
            return .ternary(condition, thenValue, elseValue, condition.location)
        }
        return condition
    }

    private func parseLogicalOr() -> CppExpr {
        var lhs = parseLogicalAnd()
        while check("||") {
            let location = advance().location
            lhs = .logical("||", lhs, parseLogicalAnd(), location)
        }
        return lhs
    }

    private func parseLogicalAnd() -> CppExpr {
        var lhs = parseEquality()
        while check("&&") {
            let location = advance().location
            lhs = .logical("&&", lhs, parseEquality(), location)
        }
        return lhs
    }

    private func parseEquality() -> CppExpr {
        var lhs = parseRelational()
        while check("==") || check("!=") {
            let op = advance()
            lhs = .binary(op.text, lhs, parseRelational(), op.location)
        }
        return lhs
    }

    private func parseRelational() -> CppExpr {
        var lhs = parseShift()
        while check("<") || check(">") || check("<=") || check(">=") {
            let op = advance()
            lhs = .binary(op.text, lhs, parseShift(), op.location)
        }
        return lhs
    }

    private func parseShift() -> CppExpr {
        var lhs = parseAdditive()
        while check("<<") || check(">>") {
            let op = advance()
            lhs = .binary(op.text, lhs, parseAdditive(), op.location)
        }
        return lhs
    }

    private func parseAdditive() -> CppExpr {
        var lhs = parseMultiplicative()
        while check("+") || check("-") {
            let op = advance()
            lhs = .binary(op.text, lhs, parseMultiplicative(), op.location)
        }
        return lhs
    }

    private func parseMultiplicative() -> CppExpr {
        var lhs = parseUnary()
        while check("*") || check("/") || check("%") {
            let op = advance()
            lhs = .binary(op.text, lhs, parseUnary(), op.location)
        }
        return lhs
    }

    private func parseUnary() -> CppExpr {
        let location = current.location
        if check("!") || check("-") || check("+") {
            let op = advance().text
            return .unary(op, parseUnary(), location)
        }
        if check("++") || check("--") {
            let op = advance().text
            return .unary(op + "pre", parseUnary(), location)
        }
        if check("&") || check("*") {
            // ポインタ/参照は扱わないので、そのまま中身だけ評価する。
            advance()
            return parseUnary()
        }
        // C 形式のキャスト: (int)expr / (double)expr
        if check("(") {
            let saved = index
            advance()
            if let type = tryParseType(), check(")") {
                advance()
                if type == .void { index = saved } else {
                    return .unary("cast:" + castName(type), parseUnary(), location)
                }
            } else {
                index = saved
            }
        }
        if current.kind == .identifier, current.text == "static_cast" || current.text == "static_cast" {
            advance()
            expect("<")
            let type = tryParseType() ?? .int
            closeAngleBracket()
            expect("(")
            let value = parseAssignment()
            expect(")")
            return .unary("cast:" + castName(type), value, location)
        }
        return parsePostfix()
    }

    private func castName(_ type: CppType) -> String {
        switch type {
        case .int: return "int"
        case .double: return "double"
        case .bool_: return "bool"
        case .char_: return "char"
        case .string: return "string"
        default: return "int"
        }
    }

    private func parsePostfix() -> CppExpr {
        var expr = parsePrimary()
        while true {
            if check(".") || check("->") {
                advance()
                let name = advance().text
                if check("(") {
                    expr = .memberCall(expr, name, parseArgumentList(), expr.location)
                } else {
                    expr = .member(expr, name, expr.location)
                }
                continue
            }
            if check("[") {
                advance()
                let indexExpr = parseExpression()
                expect("]")
                expr = .index(expr, indexExpr, expr.location)
                continue
            }
            if check("++") || check("--") {
                let op = advance().text
                expr = .postfix(op, expr, expr.location)
                continue
            }
            break
        }
        return expr
    }

    private func parseArgumentList() -> [CppExpr] {
        expect("(")
        var args: [CppExpr] = []
        if !check(")") {
            repeat { args.append(parseAssignment()) } while match(",")
        }
        expect(")")
        return args
    }

    private func parsePrimary() -> CppExpr {
        let token = current
        let location = token.location
        switch token.kind {
        case .intLiteral:
            advance(); return .intLiteral(Int(token.text) ?? 0, location)
        case .doubleLiteral:
            advance(); return .doubleLiteral(Double(token.text) ?? 0, location)
        case .stringLiteral:
            advance(); return .stringLiteral(token.stringValue, location)
        case .charLiteral:
            advance(); return .charLiteral(token.stringValue.first ?? "\0", location)
        default: break
        }
        if check("true") { advance(); return .boolLiteral(true, location) }
        if check("false") { advance(); return .boolLiteral(false, location) }
        if check("this") { advance(); return .thisExpr(location) }
        if check("nullptr") { advance(); return .intLiteral(0, location) }
        if check("new") {
            advance()
            let name = advance().text
            let args = check("(") ? parseArgumentList() : []
            return .newObject(name, args, location)
        }
        if check("(") {
            advance()
            let expr = parseExpression()
            expect(")")
            return expr
        }
        if check("{") { return parseInitList() }
        if token.kind == .identifier || token.kind == .keyword {
            // std:: 修飾を読み飛ばす (std::cout, std::endl, std::to_string など)。
            var name = advance().text
            while name == "std" && check("::") {
                advance()
                name = advance().text
            }
            if check("::") {
                // ClassName::member のような静的アクセスは名前だけ使う (簡易対応)。
                advance()
                name = advance().text
            }
            if check("(") {
                return .call(name, parseArgumentList(), location)
            }
            return .identifier(name, location)
        }
        fail("式が必要です: '\(token.text)'")
        advance()
        return .intLiteral(0, location)
    }
}

private extension CppType {
    var isFunctionLike: Bool { false }
}
