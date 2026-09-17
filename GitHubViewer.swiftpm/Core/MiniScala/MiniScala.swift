import Foundation

// MiniScala: 端末の中で動く、ごく小さな Scala インタプリタ。
//
// 字句解析 → 構文解析 (AST) → 木を辿って実行、という素朴な構成で、
// 外部のサービスやネットワークには一切依存しない。
// `object Main { def main(args: Array[String]): Unit = { ... } }` の形と、
// トップレベルに文が並ぶスクリプト形式の両方を受け付ける。

// MARK: - トークン

private enum ScalaTokenKind: Equatable {
    case identifier(String)
    case intLiteral(Int)
    case doubleLiteral(Double)
    case stringLiteral(String)
    /// 文字列補間 (s"...") のかけら。text はそのままの文字列、code は式のソース断片。
    case interpString([ScalaInterpPiece])
    case keyword(String)
    case symbol(String)
    case eof
}

enum ScalaInterpPiece: Equatable {
    case text(String)
    case code(String)
}

private struct ScalaToken {
    var kind: ScalaTokenKind
    var location: SourceLocation
}

private let scalaKeywords: Set<String> = [
    "val", "var", "def", "if", "else", "while", "for", "yield", "match", "case",
    "class", "object", "def", "true", "false", "new", "return", "import",
    "extends", "this", "None", "Some", "to", "until", "do", "override",
    "Unit", "Int", "Double", "String", "Boolean", "Array", "List", "Map",
]

// MARK: - レキサ

private struct ScalaLexer {
    let source: [Character]
    var index = 0
    var line = 1
    var column = 1
    let diagnostics: DiagnosticBag

    init(source: String, diagnostics: DiagnosticBag) {
        self.source = Array(source)
        self.diagnostics = diagnostics
    }

    private var currentLocation: SourceLocation { SourceLocation(line: line, column: column) }

    private mutating func advance() -> Character? {
        guard index < source.count else { return nil }
        let c = source[index]
        index += 1
        if c == "\n" { line += 1; column = 1 } else { column += 1 }
        return c
    }

    private func peek(_ offset: Int = 0) -> Character? {
        let i = index + offset
        return i < source.count ? source[i] : nil
    }

    mutating func tokenize() -> [ScalaToken] {
        var tokens: [ScalaToken] = []
        while true {
            skipTrivia()
            let loc = currentLocation
            guard let c = peek() else {
                tokens.append(ScalaToken(kind: .eof, location: loc))
                break
            }
            if c.isLetter || c == "_" {
                tokens.append(lexIdentifier())
                continue
            }
            if c.isNumber {
                tokens.append(lexNumber())
                continue
            }
            if c == "\"" {
                tokens.append(lexString(interpolated: false))
                continue
            }
            tokens.append(lexSymbolOrOperator())
        }
        return tokens
    }

    private mutating func skipTrivia() {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\r" || c == "\n" {
                _ = advance()
            } else if c == "/" && peek(1) == "/" {
                while let cc = peek(), cc != "\n" { _ = advance() }
            } else if c == "/" && peek(1) == "*" {
                _ = advance(); _ = advance()
                while let cc = peek(), !(cc == "*" && peek(1) == "/") { _ = advance() }
                if peek() != nil { _ = advance(); _ = advance() }
            } else {
                break
            }
        }
    }

    private mutating func lexIdentifier() -> ScalaToken {
        let loc = currentLocation
        var text = ""
        while let c = peek(), c.isLetter || c.isNumber || c == "_" {
            text.append(c)
            _ = advance()
        }
        // s"..." 補間文字列
        if text == "s", peek() == "\"" {
            return lexString(interpolated: true, location: loc)
        }
        if scalaKeywords.contains(text) {
            return ScalaToken(kind: .keyword(text), location: loc)
        }
        return ScalaToken(kind: .identifier(text), location: loc)
    }

    private mutating func lexNumber() -> ScalaToken {
        let loc = currentLocation
        var text = ""
        while let c = peek(), c.isNumber { text.append(c); _ = advance() }
        var isDouble = false
        if peek() == ".", let n = peek(1), n.isNumber {
            isDouble = true
            text.append("."); _ = advance()
            while let c = peek(), c.isNumber { text.append(c); _ = advance() }
        }
        if peek() == "e" || peek() == "E" {
            isDouble = true
            text.append("e"); _ = advance()
            if peek() == "+" || peek() == "-" { text.append(peek()!); _ = advance() }
            while let c = peek(), c.isNumber { text.append(c); _ = advance() }
        }
        if isDouble {
            return ScalaToken(kind: .doubleLiteral(Double(text) ?? 0), location: loc)
        }
        return ScalaToken(kind: .intLiteral(Int(text) ?? 0), location: loc)
    }

    /// 文字列を読む。`interpolated` なら s"..." として補間片を作る。
    private mutating func lexString(interpolated: Bool, location: SourceLocation? = nil) -> ScalaToken {
        let loc = location ?? currentLocation
        _ = advance() // 開き "
        var pieces: [ScalaInterpPiece] = []
        var plain = ""
        var text = ""
        while let c = peek(), c != "\"" {
            if c == "\\" {
                _ = advance()
                if let esc = advance() {
                    let resolved = resolveEscape(esc)
                    text.append(resolved)
                    plain.append(resolved)
                }
                continue
            }
            if interpolated && c == "$" {
                if !text.isEmpty { pieces.append(.text(text)); text = "" }
                _ = advance()
                if peek() == "{" {
                    _ = advance()
                    var depth = 1
                    var code = ""
                    while let cc = peek(), depth > 0 {
                        if cc == "{" { depth += 1 }
                        if cc == "}" { depth -= 1; if depth == 0 { _ = advance(); break } }
                        code.append(cc)
                        _ = advance()
                    }
                    pieces.append(.code(code))
                } else {
                    var name = ""
                    while let cc = peek(), cc.isLetter || cc.isNumber || cc == "_" {
                        name.append(cc); _ = advance()
                    }
                    pieces.append(.code(name))
                }
                continue
            }
            text.append(c)
            plain.append(c)
            _ = advance()
        }
        if peek() == "\"" { _ = advance() }
        if interpolated {
            if !text.isEmpty { pieces.append(.text(text)) }
            return ScalaToken(kind: .interpString(pieces), location: loc)
        }
        return ScalaToken(kind: .stringLiteral(plain), location: loc)
    }

    private func resolveEscape(_ c: Character) -> Character {
        switch c {
        case "n": return "\n"
        case "t": return "\t"
        case "\\": return "\\"
        case "\"": return "\""
        case "'": return "'"
        case "$": return "$"
        default: return c
        }
    }

    private mutating func lexSymbolOrOperator() -> ScalaToken {
        let loc = currentLocation
        let threeChar = ["<-"]
        _ = threeChar
        let twoCharOps = ["=>", "<-", "==", "!=", "<=", ">=", "&&", "||", "::", "->", "..", "+=", "-=", "*=", "/="]
        if let c0 = peek(), let c1 = peek(1) {
            let two = String([c0, c1])
            if two == "..." || (two == ".." && peek(2) == ".") {
                _ = advance(); _ = advance(); _ = advance()
                return ScalaToken(kind: .symbol("..."), location: loc)
            }
            if twoCharOps.contains(two) {
                _ = advance(); _ = advance()
                return ScalaToken(kind: .symbol(two), location: loc)
            }
        }
        let c = advance() ?? " "
        return ScalaToken(kind: .symbol(String(c)), location: loc)
    }
}

// MARK: - AST

indirect enum ScalaExpr {
    case intLit(Int)
    case doubleLit(Double)
    case stringLit(String)
    case interp([ScalaInterpPart])
    case boolLit(Bool)
    case unit
    case ident(String)
    case unary(String, ScalaExpr)
    case binary(String, ScalaExpr, ScalaExpr)
    case call(ScalaExpr, [ScalaExpr])
    case methodCall(ScalaExpr, String, [ScalaExpr])
    case index(ScalaExpr, ScalaExpr)
    case closure([String], [ScalaStmt])
    case placeholder // `_`
    case ifExpr(ScalaExpr, [ScalaStmt], [ScalaStmt]?)
    case block([ScalaStmt])
    case matchExpr(ScalaExpr, [ScalaCase])
    case listLit(String, [ScalaExpr]) // "List" / "Array" / "Set"
    case mapLit([(ScalaExpr, ScalaExpr)])
    case newInstance(String, [ScalaExpr])
    case forExpr(String, ScalaExpr, ScalaExpr?, [ScalaStmt], yields: Bool)
}

enum ScalaInterpPart {
    case text(String)
    case expr(ScalaExpr)
}

struct ScalaCase {
    var pattern: ScalaPattern
    var guardExpr: ScalaExpr?
    var body: [ScalaStmt]
}

indirect enum ScalaPattern {
    case wildcard
    case literal(ScalaExpr)
    case bind(String)
    case constructor(String, [ScalaPattern])
}

indirect enum ScalaStmt {
    case expr(ScalaExpr)
    case valDecl(String, ScalaExpr)
    case varDecl(String, ScalaExpr)
    case assign(ScalaExpr, ScalaExpr)
    case opAssign(String, ScalaExpr, ScalaExpr)
    case funcDecl(ScalaFunctionDecl)
    case whileStmt(ScalaExpr, [ScalaStmt])
    case caseClassDecl(String, [String])
    case classDecl(String, [String], [ScalaStmt])
    case objectDecl(String, [ScalaStmt])
    case returnStmt(ScalaExpr?)
}

struct ScalaFunctionDecl {
    var name: String
    var params: [(name: String, defaultValue: ScalaExpr?)]
    var body: [ScalaStmt]
}

// MARK: - パーサ

private final class ScalaParser {
    var tokens: [ScalaToken]
    var pos = 0
    let diagnostics: DiagnosticBag

    init(tokens: [ScalaToken], diagnostics: DiagnosticBag) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }

    private var current: ScalaToken { tokens[pos] }
    private var currentLoc: SourceLocation { current.location }

    private func check(symbol: String) -> Bool {
        if case .symbol(let s) = current.kind, s == symbol { return true }
        return false
    }
    private func check(keyword: String) -> Bool {
        if case .keyword(let k) = current.kind, k == keyword { return true }
        return false
    }
    private func isEOF() -> Bool { if case .eof = current.kind { return true }; return false }

    @discardableResult
    private func advance() -> ScalaToken {
        let t = current
        if !isEOF() { pos += 1 }
        return t
    }

    @discardableResult
    private func expectSymbol(_ s: String) -> Bool {
        if check(symbol: s) { advance(); return true }
        diagnostics.error("'\(s)' が必要です", at: currentLoc)
        return false
    }

    private func matchSymbol(_ s: String) -> Bool {
        if check(symbol: s) { advance(); return true }
        return false
    }
    private func matchKeyword(_ k: String) -> Bool {
        if check(keyword: k) { advance(); return true }
        return false
    }

    private func identifierName() -> String? {
        if case .identifier(let name) = current.kind { advance(); return name }
        return nil
    }

    func parseProgram() -> [ScalaStmt] {
        var stmts: [ScalaStmt] = []
        while !isEOF() {
            if matchSymbol(";") { continue }
            stmts.append(parseTopLevel())
        }
        return stmts
    }

    private func parseTopLevel() -> ScalaStmt {
        parseStatement()
    }

    // 型注釈 `: Type` は読み飛ばす (中身の型は評価しない)。
    private func skipTypeAnnotationIfPresent() {
        guard matchSymbol(":") else { return }
        skipType()
    }

    private func skipType() {
        // Array[Int], List[String], (Int, Int) => Int などをざっくり読み飛ばす。
        _ = advance()
        if matchSymbol("[") {
            var depth = 1
            while depth > 0 && !isEOF() {
                if check(symbol: "[") { depth += 1 }
                if check(symbol: "]") { depth -= 1 }
                advance()
            }
        }
        if matchSymbol("=>") { skipType() }
    }

    private func parseStatement() -> ScalaStmt {
        if matchKeyword("val") { return parseValOrVar(isVar: false) }
        if matchKeyword("var") { return parseValOrVar(isVar: true) }
        if matchKeyword("def") { return .funcDecl(parseFunctionDecl()) }
        if matchKeyword("while") { return parseWhile() }
        if check(keyword: "case") && peekIsClass() { advance(); return parseCaseClass() }
        if matchKeyword("class") { return parseClassDecl() }
        if matchKeyword("object") { return parseObjectDecl() }
        if matchKeyword("return") {
            if check(symbol: "}") || isEOF() { return .returnStmt(nil) }
            return .returnStmt(parseExpr())
        }
        if matchKeyword("import") {
            while !check(symbol: ";") && !isAtStatementEnd() { advance() }
            return .expr(.unit)
        }
        if matchKeyword("override") {
            // override def ... のとき override を読み飛ばす
            return parseStatement()
        }
        // 式文、代入、複合代入
        let expr = parseExpr()
        if matchSymbol("=") {
            return .assign(expr, parseExpr())
        }
        for op in ["+=", "-=", "*=", "/="] {
            if matchSymbol(op) {
                return .opAssign(String(op.dropLast()), expr, parseExpr())
            }
        }
        return .expr(expr)
    }

    private func isAtStatementEnd() -> Bool {
        check(symbol: "}") || isEOF()
    }

    private func peekIsClass() -> Bool {
        if case .keyword("case") = current.kind, pos + 1 < tokens.count,
           case .keyword("class") = tokens[pos + 1].kind {
            return true
        }
        return false
    }

    private func parseValOrVar(isVar: Bool) -> ScalaStmt {
        let name = identifierName() ?? "_"
        skipTypeAnnotationIfPresent()
        expectSymbol("=")
        let value = parseExpr()
        return isVar ? .varDecl(name, value) : .valDecl(name, value)
    }

    private func parseFunctionDecl() -> ScalaFunctionDecl {
        let name = identifierName() ?? "_"
        var params: [(name: String, defaultValue: ScalaExpr?)] = []
        if matchSymbol("(") {
            while !check(symbol: ")") && !isEOF() {
                let pname = identifierName() ?? "_"
                skipTypeAnnotationIfPresent()
                var def: ScalaExpr?
                if matchSymbol("=") { def = parseExpr() }
                params.append((pname, def))
                if !matchSymbol(",") { break }
            }
            expectSymbol(")")
        }
        skipTypeAnnotationIfPresent()
        expectSymbol("=")
        let body: [ScalaStmt]
        if check(symbol: "{") {
            body = parseBlock()
        } else {
            body = [.expr(parseExpr())]
        }
        return ScalaFunctionDecl(name: name, params: params, body: body)
    }

    private func parseWhile() -> ScalaStmt {
        expectSymbol("(")
        let cond = parseExpr()
        expectSymbol(")")
        let body = check(symbol: "{") ? parseBlock() : [parseStatement()]
        return .whileStmt(cond, body)
    }

    private func parseCaseClass() -> ScalaStmt {
        expectSymbol("class")
        let name = identifierName() ?? "_"
        var fields: [String] = []
        if matchSymbol("(") {
            while !check(symbol: ")") && !isEOF() {
                _ = matchKeyword("val")
                _ = matchKeyword("var")
                let fname = identifierName() ?? "_"
                skipTypeAnnotationIfPresent()
                if matchSymbol("=") { _ = parseExpr() }
                fields.append(fname)
                if !matchSymbol(",") { break }
            }
            expectSymbol(")")
        }
        if matchKeyword("extends") { _ = identifierName() }
        return .caseClassDecl(name, fields)
    }

    private func parseClassDecl() -> ScalaStmt {
        let name = identifierName() ?? "_"
        var fields: [String] = []
        if matchSymbol("(") {
            while !check(symbol: ")") && !isEOF() {
                _ = matchKeyword("val")
                _ = matchKeyword("var")
                let fname = identifierName() ?? "_"
                skipTypeAnnotationIfPresent()
                fields.append(fname)
                if !matchSymbol(",") { break }
            }
            expectSymbol(")")
        }
        if matchKeyword("extends") { _ = identifierName(); if matchSymbol("(") {
            while !check(symbol: ")") && !isEOF() { advance() }
            _ = matchSymbol(")")
        } }
        var body: [ScalaStmt] = []
        if matchSymbol("{") {
            while !check(symbol: "}") && !isEOF() {
                if matchSymbol(";") { continue }
                body.append(parseStatement())
            }
            expectSymbol("}")
        }
        return .classDecl(name, fields, body)
    }

    private func parseObjectDecl() -> ScalaStmt {
        let name = identifierName() ?? "_"
        if matchKeyword("extends") { _ = identifierName() }
        var body: [ScalaStmt] = []
        expectSymbol("{")
        while !check(symbol: "}") && !isEOF() {
            if matchSymbol(";") { continue }
            body.append(parseStatement())
        }
        expectSymbol("}")
        return .objectDecl(name, body)
    }

    private func parseBlock() -> [ScalaStmt] {
        expectSymbol("{")
        var stmts: [ScalaStmt] = []
        while !check(symbol: "}") && !isEOF() {
            if matchSymbol(";") { continue }
            stmts.append(parseStatement())
        }
        expectSymbol("}")
        return stmts
    }

    // MARK: 式

    func parseExpr() -> ScalaExpr {
        parseAssignExprLevel()
    }

    private func parseAssignExprLevel() -> ScalaExpr { parseIf() }

    private func parseIf() -> ScalaExpr {
        if matchKeyword("if") {
            expectSymbol("(")
            let cond = parseExpr()
            expectSymbol(")")
            let thenBody = check(symbol: "{") ? parseBlock() : [.expr(parseExpr())]
            var elseBody: [ScalaStmt]?
            if matchKeyword("else") {
                elseBody = check(symbol: "{") ? parseBlock() : [.expr(parseExpr())]
            }
            return .ifExpr(cond, thenBody, elseBody)
        }
        if matchKeyword("for") { return parseFor() }
        if matchKeyword("match") { fatalError("unreachable") }
        return parseMatchPostfix(parseArrow())
    }

    private func parseMatchPostfix(_ base: ScalaExpr) -> ScalaExpr {
        var result = base
        while matchKeyword("match") {
            expectSymbol("{")
            var cases: [ScalaCase] = []
            while matchKeyword("case") {
                let pattern = parsePattern()
                var guardExpr: ScalaExpr?
                if matchKeyword("if") { guardExpr = parseExpr() }
                expectSymbol("=>")
                var body: [ScalaStmt] = []
                while !check(keyword: "case") && !check(symbol: "}") && !isEOF() {
                    if matchSymbol(";") { continue }
                    body.append(parseStatement())
                }
                cases.append(ScalaCase(pattern: pattern, guardExpr: guardExpr, body: body))
            }
            expectSymbol("}")
            result = .matchExpr(result, cases)
        }
        return result
    }

    private func parsePattern() -> ScalaPattern {
        if matchSymbol("_") { return .wildcard }
        if case .identifier(let name) = current.kind, name.first?.isUppercase == true {
            advance()
            if matchSymbol("(") {
                var subs: [ScalaPattern] = []
                while !check(symbol: ")") && !isEOF() {
                    subs.append(parsePattern())
                    if !matchSymbol(",") { break }
                }
                expectSymbol(")")
                return .constructor(name, subs)
            }
            return .bind(name)
        }
        if case .identifier(let name) = current.kind {
            advance()
            return .bind(name)
        }
        // リテラルパターン
        let e = parsePrimary()
        return .literal(e)
    }

    private func parseFor() -> ScalaExpr {
        expectSymbol("(")
        let varName = identifierName() ?? "_"
        expectSymbol("<-")
        let seq = parseExpr()
        var filter: ScalaExpr?
        if matchSymbol(";") {
            _ = matchKeyword("if")
            filter = parseExpr()
        } else if matchKeyword("if") {
            filter = parseExpr()
        }
        expectSymbol(")")
        var yields = false
        if matchKeyword("yield") { yields = true }
        let body = check(symbol: "{") ? parseBlock() : [.expr(parseExpr())]
        return .forExpr(varName, seq, filter, body, yields: yields)
    }

    // 演算子優先順位: || < && < 比較 < :: (右結合) < + - < * / % < 単項 < 後置
    private func parseArrow() -> ScalaExpr {
        // 無名関数 `x => expr` / `(a, b) => expr`
        let save = pos
        if case .identifier(let name) = current.kind, pos + 1 < tokens.count,
           case .symbol("=>") = tokens[pos + 1].kind {
            advance(); advance()
            let body = check(symbol: "{") ? parseBlock() : [.expr(parseExpr())]
            return .closure([name], body)
        }
        if check(symbol: "(") {
            if let params = tryParseClosureParams() {
                if matchSymbol("=>") {
                    let body = check(symbol: "{") ? parseBlock() : [.expr(parseExpr())]
                    return .closure(params, body)
                }
                pos = save
            } else {
                pos = save
            }
        }
        return parseOr()
    }

    /// `(a, b)` の形が無名関数の引数リストかどうか先読みで判定する。
    private func tryParseClosureParams() -> [String]? {
        guard check(symbol: "(") else { return nil }
        let save = pos
        advance()
        var names: [String] = []
        while !check(symbol: ")") && !isEOF() {
            guard case .identifier(let n) = current.kind else { pos = save; return nil }
            advance()
            skipTypeAnnotationIfPresent()
            names.append(n)
            if !matchSymbol(",") { break }
        }
        guard matchSymbol(")") else { pos = save; return nil }
        if check(symbol: "=>") { return names }
        pos = save
        return nil
    }

    private func parseOr() -> ScalaExpr {
        var left = parseAnd()
        while matchSymbol("||") { left = .binary("||", left, parseAnd()) }
        return left
    }
    private func parseAnd() -> ScalaExpr {
        var left = parseComparison()
        while matchSymbol("&&") { left = .binary("&&", left, parseComparison()) }
        return left
    }
    private func parseComparison() -> ScalaExpr {
        var left = parseCons()
        while true {
            var matched = false
            for op in ["==", "!=", "<=", ">=", "<", ">"] {
                if check(symbol: op) { advance(); left = .binary(op, left, parseCons()); matched = true; break }
            }
            if !matched { break }
        }
        return left
    }
    private func parseCons() -> ScalaExpr {
        let left = parseArrowOp()
        if matchSymbol("::") {
            return .binary("::", left, parseCons())
        }
        return left
    }
    private func parseArrowOp() -> ScalaExpr {
        var left = parseAdditive()
        while matchSymbol("->") { left = .binary("->", left, parseAdditive()) }
        return left
    }
    private func parseAdditive() -> ScalaExpr {
        var left = parseMultiplicative()
        while true {
            if matchSymbol("+") { left = .binary("+", left, parseMultiplicative()) }
            else if matchSymbol("-") { left = .binary("-", left, parseMultiplicative()) }
            else { break }
        }
        return left
    }
    private func parseMultiplicative() -> ScalaExpr {
        var left = parseUnary()
        while true {
            if matchSymbol("*") { left = .binary("*", left, parseUnary()) }
            else if matchSymbol("/") { left = .binary("/", left, parseUnary()) }
            else if matchSymbol("%") { left = .binary("%", left, parseUnary()) }
            else { break }
        }
        return left
    }
    private func parseUnary() -> ScalaExpr {
        if matchSymbol("!") { return .unary("!", parseUnary()) }
        if matchSymbol("-") { return .unary("-", parseUnary()) }
        return parsePostfix()
    }

    private func parsePostfix() -> ScalaExpr {
        var expr = parsePrimary()
        while true {
            if matchSymbol(".") {
                let name = identifierName() ?? (matchKeyword("to") ? "to" : (matchKeyword("until") ? "until" : "_"))
                var args: [ScalaExpr] = []
                if matchSymbol("(") {
                    while !check(symbol: ")") && !isEOF() {
                        args.append(parseExpr())
                        if !matchSymbol(",") { break }
                    }
                    expectSymbol(")")
                }
                if check(symbol: "{") {
                    let closureBody = parseTrailingClosure()
                    args.append(closureBody)
                }
                expr = .methodCall(expr, name, args)
            } else if matchSymbol("(") {
                var args: [ScalaExpr] = []
                while !check(symbol: ")") && !isEOF() {
                    args.append(parseExpr())
                    if !matchSymbol(",") { break }
                }
                expectSymbol(")")
                expr = .call(expr, args)
            } else {
                break
            }
        }
        return expr
    }

    /// `{ x => ... }` や `{ it * 2 }` のような末尾クロージャを式として解析する。
    private func parseTrailingClosure() -> ScalaExpr {
        let save = pos
        advance() // {
        if case .identifier(let name) = current.kind, pos + 1 < tokens.count,
           case .symbol("=>") = tokens[pos + 1].kind {
            advance(); advance()
            var stmts: [ScalaStmt] = []
            while !check(symbol: "}") && !isEOF() {
                if matchSymbol(";") { continue }
                stmts.append(parseStatement())
            }
            expectSymbol("}")
            return .closure([name], stmts)
        }
        pos = save
        let body = parseBlock()
        return .closure(["_"], body)
    }

    private func parsePrimary() -> ScalaExpr {
        let loc = currentLoc
        switch current.kind {
        case .intLiteral(let v): advance(); return .intLit(v)
        case .doubleLiteral(let v): advance(); return .doubleLit(v)
        case .stringLiteral(let v): advance(); return .stringLit(v)
        case .interpString(let pieces):
            advance()
            let parts: [ScalaInterpPart] = pieces.map { piece in
                switch piece {
                case .text(let t): return .expr(.stringLit(t)) // placeholder, fixed below
                case .code: return .expr(.unit)
                }
            }
            _ = parts
            var out: [ScalaInterpPart] = []
            for piece in pieces {
                switch piece {
                case .text(let t): out.append(.text(t))
                case .code(let code):
                    out.append(.expr(parseSubExpr(code)))
                }
            }
            return .interp(out)
        case .keyword("true"): advance(); return .boolLit(true)
        case .keyword("false"): advance(); return .boolLit(false)
        case .keyword("None"): advance(); return .ident("None")
        case .keyword("Some"):
            advance()
            if matchSymbol("(") {
                let e = parseExpr()
                expectSymbol(")")
                return .call(.ident("Some"), [e])
            }
            return .ident("Some")
        case .keyword("this"): advance(); return .ident("this")
        case .keyword("new"):
            advance()
            let name = identifierName() ?? "_"
            var args: [ScalaExpr] = []
            if matchSymbol("(") {
                while !check(symbol: ")") && !isEOF() {
                    args.append(parseExpr())
                    if !matchSymbol(",") { break }
                }
                expectSymbol(")")
            }
            return .newInstance(name, args)
        case .keyword("List"), .keyword("Array"):
            let kw: String
            if case .keyword(let k) = current.kind { kw = k } else { kw = "List" }
            advance()
            if matchSymbol("(") {
                var args: [ScalaExpr] = []
                while !check(symbol: ")") && !isEOF() {
                    args.append(parseExpr())
                    if !matchSymbol(",") { break }
                }
                expectSymbol(")")
                return .listLit(kw, args)
            }
            return .ident(kw)
        case .keyword("Map"):
            advance()
            if matchSymbol("(") {
                var pairs: [(ScalaExpr, ScalaExpr)] = []
                while !check(symbol: ")") && !isEOF() {
                    let k = parseExpr()
                    // parseArrowOp が既に -> を binary として消費している場合がある
                    if case .binary("->", let l, let r) = k {
                        pairs.append((l, r))
                    } else if matchSymbol("->") {
                        pairs.append((k, parseExpr()))
                    }
                    if !matchSymbol(",") { break }
                }
                expectSymbol(")")
                return .mapLit(pairs)
            }
            return .ident("Map")
        case .identifier(let name):
            advance()
            if name == "_" { return .placeholder }
            return .ident(name)
        case .symbol("("):
            advance()
            if matchSymbol(")") { return .unit }
            var items = [parseExpr()]
            while matchSymbol(",") { items.append(parseExpr()) }
            expectSymbol(")")
            return items.count == 1 ? items[0] : items[0] // タプルは未対応。最初の要素のみ。
        case .symbol("{"):
            return .block(parseBlock())
        case .symbol("_"):
            advance()
            return .placeholder
        default:
            diagnostics.error("式が必要です", at: loc)
            advance()
            return .unit
        }
    }

    private func parseSubExpr(_ code: String) -> ScalaExpr {
        let subDiagnostics = DiagnosticBag(source: code)
        var lexer = ScalaLexer(source: code, diagnostics: subDiagnostics)
        let subTokens = lexer.tokenize()
        let subParser = ScalaParser(tokens: subTokens, diagnostics: subDiagnostics)
        return subParser.parseExpr()
    }
}

// MARK: - 値

final class ScalaObjectRef {
    let typeName: String
    var fields: [String: ScalaValue]
    var order: [String]
    init(typeName: String, fields: [String: ScalaValue], order: [String]) {
        self.typeName = typeName
        self.fields = fields
        self.order = order
    }
}

final class ScalaClosureRef {
    let params: [String]
    let body: [ScalaStmt]
    let env: ScalaEnvironment
    init(params: [String], body: [ScalaStmt], env: ScalaEnvironment) {
        self.params = params
        self.body = body
        self.env = env
    }
}

indirect enum ScalaValue {
    case unit
    case intV(Int)
    case doubleV(Double)
    case stringV(String)
    case boolV(Bool)
    case listV([ScalaValue], kind: String) // kind: "List" / "Array" / "Set"
    case mapV([(ScalaValue, ScalaValue)])
    case tupleV(ScalaValue, ScalaValue)
    case rangeV(Int, Int, Bool) // lower, upper, isClosed(to) / until=false
    case noneV
    case someV(ScalaValue)
    case closureV(ScalaClosureRef)
    case objectV(ScalaObjectRef)

    var asBool: Bool {
        if case .boolV(let b) = self { return b }
        return false
    }
    var asInt: Int {
        switch self {
        case .intV(let v): return v
        case .doubleV(let v): return Int(v)
        default: return 0
        }
    }
    var asDouble: Double {
        switch self {
        case .intV(let v): return Double(v)
        case .doubleV(let v): return v
        default: return 0
        }
    }
}

enum ScalaFormatter {
    static func display(_ value: ScalaValue) -> String {
        switch value {
        case .unit: return "()"
        case .intV(let v): return String(v)
        case .doubleV(let v): return doubleText(v)
        case .stringV(let v): return v
        case .boolV(let v): return v ? "true" : "false"
        case .listV(let items, let kind):
            return "\(kind)(\(items.map { display($0) }.joined(separator: ", ")))"
        case .mapV(let pairs):
            return "Map(\(pairs.map { "\(display($0.0)) -> \(display($0.1))" }.joined(separator: ", ")))"
        case .tupleV(let a, let b):
            return "(\(display(a)),\(display(b)))"
        case .rangeV(let lo, let hi, let closed):
            return "Range \(lo) \(closed ? "to" : "until") \(hi)"
        case .noneV: return "None"
        case .someV(let v): return "Some(\(display(v)))"
        case .closureV: return "<function>"
        case .objectV(let ref):
            let fields = ref.order.map { "\($0) -> " + display(ref.fields[$0] ?? .unit) }
            _ = fields
            let content = ref.order.map { display(ref.fields[$0] ?? .unit) }.joined(separator: ", ")
            return "\(ref.typeName)(\(content))"
        }
    }

    static func doubleText(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        return String(value)
    }
}

// MARK: - 環境

final class ScalaEnvironment {
    var values: [String: ScalaValue] = [:]
    var isConstant: Set<String> = []
    let parent: ScalaEnvironment?

    init(parent: ScalaEnvironment? = nil) {
        self.parent = parent
    }

    func define(_ name: String, _ value: ScalaValue, constant: Bool) {
        values[name] = value
        if constant { isConstant.insert(name) }
    }

    func get(_ name: String) -> ScalaValue? {
        if let v = values[name] { return v }
        return parent?.get(name)
    }

    @discardableResult
    func set(_ name: String, _ value: ScalaValue) -> Bool {
        if values[name] != nil {
            values[name] = value
            return true
        }
        return parent?.set(name, value) ?? false
    }

    func isImmutable(_ name: String) -> Bool {
        if values[name] != nil { return isConstant.contains(name) }
        return parent?.isImmutable(name) ?? false
    }
}

// MARK: - 実行時エラー / 制御フロー

private struct ScalaRuntimeError: Error { let message: String }
private struct ScalaReturnSignal: Error { let value: ScalaValue }
private struct ScalaStepLimitExceeded: Error {}

public struct ScalaLimits {
    public var maximumSteps: Int
    public init(maximumSteps: Int = 5_000_000) { self.maximumSteps = maximumSteps }
    public static let `default` = ScalaLimits()
}

// MARK: - インタプリタ

private final class ScalaInterpreter {
    let output: MiniLangOutput
    var steps = 0
    let maxSteps: Int
    var caseClassFields: [String: [String]] = [:]
    var classDecls: [String: ([String], [ScalaStmt])] = [:]
    let global: ScalaEnvironment

    init(limits: ScalaLimits, outputLimit: Int) {
        self.output = MiniLangOutput(limit: outputLimit)
        self.maxSteps = limits.maximumSteps
        self.global = ScalaEnvironment()
    }

    func tick() throws {
        steps += 1
        if steps > maxSteps { throw ScalaStepLimitExceeded() }
    }

    func run(_ program: [ScalaStmt]) -> (output: String, error: String?) {
        do {
            try registerTopLevel(program, env: global)
            var mainCall: ScalaClosureRef?
            if let m = global.get("main"), case .closureV(let ref) = m {
                mainCall = ref
            }
            // トップレベルの通常の文を実行 (def/class/object の登録以外)
            var executedAny = false
            for stmt in program {
                switch stmt {
                case .funcDecl, .caseClassDecl, .classDecl, .objectDecl: continue
                default:
                    _ = try execute(stmt, env: global)
                    executedAny = true
                }
            }
            if !executedAny, let ref = mainCall {
                _ = try callClosure(ref, args: [.listV([], kind: "Array")])
            }
            return (output.text, nil)
        } catch let e as ScalaRuntimeError {
            return (output.text, e.message)
        } catch is ScalaStepLimitExceeded {
            return (output.text, "実行が長すぎます (無限ループの可能性があります)")
        } catch is ScalaReturnSignal {
            return (output.text, nil)
        } catch {
            return (output.text, "\(error)")
        }
    }

    private func registerTopLevel(_ stmts: [ScalaStmt], env: ScalaEnvironment) throws {
        for stmt in stmts {
            switch stmt {
            case .funcDecl(let decl):
                env.define(decl.name, .closureV(ScalaClosureRef(params: decl.params.map { $0.name }, body: decl.body, env: env)), constant: true)
                funcDefaults[decl.name] = decl.params
            case .caseClassDecl(let name, let fields):
                caseClassFields[name] = fields
            case .classDecl(let name, let fields, let body):
                classDecls[name] = (fields, body)
            case .objectDecl(let name, let body):
                if name == "Main" || true {
                    try registerTopLevel(body, env: env)
                }
            default:
                break
            }
        }
    }

    var funcDefaults: [String: [(name: String, defaultValue: ScalaExpr?)]] = [:]

    // MARK: 文の実行

    @discardableResult
    private func execute(_ stmt: ScalaStmt, env: ScalaEnvironment) throws -> ScalaValue {
        try tick()
        switch stmt {
        case .expr(let e):
            return try eval(e, env: env)
        case .valDecl(let name, let e):
            let v = try eval(e, env: env)
            env.define(name, v, constant: true)
            return .unit
        case .varDecl(let name, let e):
            let v = try eval(e, env: env)
            env.define(name, v, constant: false)
            return .unit
        case .assign(let target, let valueExpr):
            let value = try eval(valueExpr, env: env)
            try assign(target, value, env: env)
            return .unit
        case .opAssign(let op, let target, let valueExpr):
            let current = try eval(target, env: env)
            let rhs = try eval(valueExpr, env: env)
            let combined = try binaryOp(op, current, rhs)
            try assign(target, combined, env: env)
            return .unit
        case .funcDecl(let decl):
            env.define(decl.name, .closureV(ScalaClosureRef(params: decl.params.map { $0.name }, body: decl.body, env: env)), constant: true)
            funcDefaults[decl.name] = decl.params
            return .unit
        case .whileStmt(let cond, let body):
            while try eval(cond, env: env).asBool {
                try tick()
                let loopEnv = ScalaEnvironment(parent: env)
                for s in body { _ = try execute(s, env: loopEnv) }
            }
            return .unit
        case .caseClassDecl(let name, let fields):
            caseClassFields[name] = fields
            return .unit
        case .classDecl(let name, let fields, let body):
            classDecls[name] = (fields, body)
            return .unit
        case .objectDecl(let name, let body):
            _ = name
            for s in body { _ = try execute(s, env: env) }
            return .unit
        case .returnStmt(let e):
            let v = try e.map { try eval($0, env: env) } ?? .unit
            throw ScalaReturnSignal(value: v)
        }
    }

    private func assign(_ target: ScalaExpr, _ value: ScalaValue, env: ScalaEnvironment) throws {
        switch target {
        case .ident(let name):
            if env.isImmutable(name) {
                throw ScalaRuntimeError(message: "val で宣言された '\(name)' へは代入できません")
            }
            if !env.set(name, value) {
                env.define(name, value, constant: false)
            }
        case .methodCall(let receiver, let field, let args) where args.isEmpty:
            let recv = try eval(receiver, env: env)
            if case .objectV(let ref) = recv {
                if ref.fields[field] == nil { ref.order.append(field) }
                ref.fields[field] = value
            }
        default:
            throw ScalaRuntimeError(message: "代入できない式です")
        }
    }

    private func execBlock(_ stmts: [ScalaStmt], env: ScalaEnvironment) throws -> ScalaValue {
        var result: ScalaValue = .unit
        for stmt in stmts {
            result = try execute(stmt, env: env)
        }
        return result
    }

    // MARK: 式の評価

    private func eval(_ expr: ScalaExpr, env: ScalaEnvironment) throws -> ScalaValue {
        try tick()
        switch expr {
        case .intLit(let v): return .intV(v)
        case .doubleLit(let v): return .doubleV(v)
        case .stringLit(let v): return .stringV(v)
        case .boolLit(let v): return .boolV(v)
        case .unit: return .unit
        case .placeholder: return env.get("_") ?? .unit
        case .interp(let parts):
            var text = ""
            for part in parts {
                switch part {
                case .text(let t): text += t
                case .expr(let e): text += ScalaFormatter.display(try eval(e, env: env))
                }
            }
            return .stringV(text)
        case .ident(let name):
            if let v = env.get(name) { return v }
            if let fields = caseClassFields[name] { _ = fields }
            throw ScalaRuntimeError(message: "未定義の識別子です: \(name)")
        case .unary(let op, let e):
            let v = try eval(e, env: env)
            switch op {
            case "!": return .boolV(!v.asBool)
            case "-":
                if case .doubleV(let d) = v { return .doubleV(-d) }
                return .intV(-v.asInt)
            default: return v
            }
        case .binary(let op, let l, let r):
            if op == "&&" {
                let lv = try eval(l, env: env)
                if !lv.asBool { return .boolV(false) }
                return .boolV(try eval(r, env: env).asBool)
            }
            if op == "||" {
                let lv = try eval(l, env: env)
                if lv.asBool { return .boolV(true) }
                return .boolV(try eval(r, env: env).asBool)
            }
            let lv = try eval(l, env: env)
            let rv = try eval(r, env: env)
            return try binaryOp(op, lv, rv)
        case .block(let stmts):
            let blockEnv = ScalaEnvironment(parent: env)
            return try execBlock(stmts, env: blockEnv)
        case .ifExpr(let cond, let thenBody, let elseBody):
            if try eval(cond, env: env).asBool {
                return try execBlock(thenBody, env: ScalaEnvironment(parent: env))
            } else if let elseBody {
                return try execBlock(elseBody, env: ScalaEnvironment(parent: env))
            }
            return .unit
        case .closure(let params, let body):
            return .closureV(ScalaClosureRef(params: params, body: body, env: env))
        case .listLit(let kind, let items):
            let values = try items.map { try eval($0, env: env) }
            return .listV(values, kind: kind)
        case .mapLit(let pairs):
            let values = try pairs.map { (try eval($0.0, env: env), try eval($0.1, env: env)) }
            return .mapV(values)
        case .newInstance(let name, let args):
            return try instantiate(name, args: args, env: env)
        case .call(let callee, let args):
            return try evalCall(callee: callee, args: args, env: env)
        case .methodCall(let receiver, let name, let args):
            return try evalMethodCall(receiver: receiver, name: name, args: args, env: env)
        case .index(let base, let idx):
            let b = try eval(base, env: env)
            let i = try eval(idx, env: env).asInt
            return try indexValue(b, i)
        case .matchExpr(let scrutinee, let cases):
            let value = try eval(scrutinee, env: env)
            for c in cases {
                let matchEnv = ScalaEnvironment(parent: env)
                if matchPattern(c.pattern, value, env: matchEnv) {
                    if let g = c.guardExpr {
                        if try !eval(g, env: matchEnv).asBool { continue }
                    }
                    return try execBlock(c.body, env: matchEnv)
                }
            }
            throw ScalaRuntimeError(message: "match に一致するケースがありません: \(ScalaFormatter.display(value))")
        case .forExpr(let varName, let seqExpr, let filter, let body, let yields):
            let seq = try eval(seqExpr, env: env)
            let items = try sequenceItems(seq)
            var collected: [ScalaValue] = []
            for item in items {
                try tick()
                let loopEnv = ScalaEnvironment(parent: env)
                loopEnv.define(varName, item, constant: true)
                if let filter, try !eval(filter, env: loopEnv).asBool { continue }
                let result = try execBlock(body, env: loopEnv)
                if yields { collected.append(result) }
            }
            return yields ? .listV(collected, kind: "List") : .unit
        }
    }

    private func instantiate(_ name: String, args: [ScalaExpr], env: ScalaEnvironment) throws -> ScalaValue {
        let values = try args.map { try eval($0, env: env) }
        if let (fields, body) = classDecls[name] {
            var storage: [String: ScalaValue] = [:]
            var order: [String] = []
            for (i, f) in fields.enumerated() {
                storage[f] = i < values.count ? values[i] : .unit
                order.append(f)
            }
            let ref = ScalaObjectRef(typeName: name, fields: storage, order: order)
            // メソッド/val を評価する環境 (this を参照可能に)
            let instEnv = ScalaEnvironment(parent: env)
            instEnv.define("this", .objectV(ref), constant: true)
            for stmt in body {
                switch stmt {
                case .funcDecl(let decl):
                    ref.fields[decl.name] = .closureV(ScalaClosureRef(params: decl.params.map { $0.name }, body: decl.body, env: instEnv))
                case .valDecl(let n, let e):
                    let v = try eval(e, env: instEnv)
                    if ref.fields[n] == nil { ref.order.append(n) }
                    ref.fields[n] = v
                    instEnv.define(n, v, constant: true)
                case .varDecl(let n, let e):
                    let v = try eval(e, env: instEnv)
                    if ref.fields[n] == nil { ref.order.append(n) }
                    ref.fields[n] = v
                default: break
                }
            }
            for f in fields { instEnv.define(f, ref.fields[f] ?? .unit, constant: false) }
            return .objectV(ref)
        }
        throw ScalaRuntimeError(message: "未定義のクラスです: \(name)")
    }

    private func evalCall(callee: ScalaExpr, args: [ScalaExpr], env: ScalaEnvironment) throws -> ScalaValue {
        // ケースクラスのコンストラクタ呼び出し
        if case .ident(let name) = callee, let fields = caseClassFields[name] {
            let values = try args.map { try eval($0, env: env) }
            var storage: [String: ScalaValue] = [:]
            for (i, f) in fields.enumerated() { storage[f] = i < values.count ? values[i] : .unit }
            return .objectV(ScalaObjectRef(typeName: name, fields: storage, order: fields))
        }
        if case .ident(let name) = callee {
            if let result = try builtinFunction(name, args: args, env: env) { return result }
        }
        let calleeValue = try eval(callee, env: env)
        if case .closureV(let ref) = calleeValue {
            let values = try resolveArgs(ref: ref, args: args, env: env, funcName: nameOf(callee))
            return try callClosure(ref, args: values)
        }
        throw ScalaRuntimeError(message: "呼び出せない値です")
    }

    private func nameOf(_ expr: ScalaExpr) -> String? {
        if case .ident(let n) = expr { return n }
        return nil
    }

    private func resolveArgs(ref: ScalaClosureRef, args: [ScalaExpr], env: ScalaEnvironment, funcName: String?) throws -> [ScalaValue] {
        var values = try args.map { try eval($0, env: env) }
        if let funcName, let defaults = funcDefaults[funcName], values.count < ref.params.count {
            for i in values.count..<ref.params.count {
                if let d = defaults[i].defaultValue {
                    values.append(try eval(d, env: env))
                } else {
                    values.append(.unit)
                }
            }
        }
        return values
    }

    private func builtinFunction(_ name: String, args: [ScalaExpr], env: ScalaEnvironment) throws -> ScalaValue? {
        switch name {
        case "println":
            let values = try args.map { try eval($0, env: env) }
            output.write(values.map { ScalaFormatter.display($0) }.joined(separator: " ") + "\n")
            return .unit
        case "print":
            let values = try args.map { try eval($0, env: env) }
            output.write(values.map { ScalaFormatter.display($0) }.joined(separator: " "))
            return .unit
        case "printf":
            let values = try args.map { try eval($0, env: env) }
            guard case .stringV(let fmt) = values.first else { return .unit }
            output.write(formatPrintf(fmt, Array(values.dropFirst())))
            return .unit
        case "Some":
            let v = try eval(args[0], env: env)
            return .someV(v)
        default:
            return nil
        }
    }

    private func formatPrintf(_ fmt: String, _ values: [ScalaValue]) -> String {
        var result = ""
        var valueIndex = 0
        var chars = Array(fmt)
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 1 < chars.count {
                var j = i + 1
                var spec = "%"
                while j < chars.count, "-+0123456789.".contains(chars[j]) { spec.append(chars[j]); j += 1 }
                if j < chars.count {
                    let conv = chars[j]
                    spec.append(conv)
                    if valueIndex < values.count {
                        let v = values[valueIndex]; valueIndex += 1
                        switch conv {
                        case "d": result += String(format: spec, v.asInt)
                        case "f": result += String(format: spec, v.asDouble)
                        case "s": result += String(format: spec.replacingOccurrences(of: "s", with: "@"), ScalaFormatter.display(v) as NSString)
                        case "%": result += "%"; valueIndex -= 1
                        default: result += spec
                        }
                    }
                    i = j + 1
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        _ = chars
        return result
    }

    func callClosure(_ ref: ScalaClosureRef, args: [ScalaValue]) throws -> ScalaValue {
        let callEnv = ScalaEnvironment(parent: ref.env)
        for (i, p) in ref.params.enumerated() {
            callEnv.define(p, i < args.count ? args[i] : .unit, constant: false)
        }
        if ref.params.count == 1 { callEnv.define("it", args.first ?? .unit, constant: false) }
        do {
            return try execBlock(ref.body, env: callEnv)
        } catch let sig as ScalaReturnSignal {
            return sig.value
        }
    }

    private func evalMethodCall(receiver: ScalaExpr, name: String, args: [ScalaExpr], env: ScalaEnvironment) throws -> ScalaValue {
        // Range: 1 to 10 / 1 until 10
        if name == "to" || name == "until" {
            let lo = try eval(receiver, env: env)
            let hi = try eval(args[0], env: env)
            return .rangeV(lo.asInt, hi.asInt, name == "to")
        }
        let recv = try eval(receiver, env: env)
        if case .objectV(let ref) = recv {
            if let member = ref.fields[name] {
                if case .closureV(let cref) = member {
                    let values = try args.map { try eval($0, env: env) }
                    return try callClosure(cref, args: values)
                }
                if args.isEmpty { return member }
            }
            if name == "copy" {
                var newFields = ref.fields
                for (i, a) in args.enumerated() where i < ref.order.count {
                    newFields[ref.order[i]] = try eval(a, env: env)
                }
                return .objectV(ScalaObjectRef(typeName: ref.typeName, fields: newFields, order: ref.order))
            }
            if name == "toString" { return .stringV(ScalaFormatter.display(recv)) }
        }
        let evaluatedArgs = try args.map { try eval($0, env: env) }
        return try builtinMethod(receiver: recv, name: name, args: evaluatedArgs, rawArgs: args, env: env)
    }

    private func sequenceItems(_ v: ScalaValue) throws -> [ScalaValue] {
        switch v {
        case .listV(let items, _): return items
        case .rangeV(let lo, let hi, let closed):
            guard lo <= hi else { return [] }
            return (closed ? Array(lo...hi) : Array(lo..<hi)).map { .intV($0) }
        case .mapV(let pairs): return pairs.map { .tupleV($0.0, $0.1) }
        case .stringV(let s): return s.map { .stringV(String($0)) }
        default: return []
        }
    }

    private func indexValue(_ base: ScalaValue, _ i: Int) throws -> ScalaValue {
        switch base {
        case .listV(let items, _):
            guard i >= 0 && i < items.count else { throw ScalaRuntimeError(message: "範囲外の添字です: \(i)") }
            return items[i]
        case .stringV(let s):
            let chars = Array(s)
            guard i >= 0 && i < chars.count else { throw ScalaRuntimeError(message: "範囲外の添字です: \(i)") }
            return .stringV(String(chars[i]))
        case .mapV(let pairs):
            for p in pairs where ScalaFormatter.display(p.0) == String(i) { return p.1 }
            throw ScalaRuntimeError(message: "キーが見つかりません")
        default:
            return .unit
        }
    }

    private func matchPattern(_ pattern: ScalaPattern, _ value: ScalaValue, env: ScalaEnvironment) -> Bool {
        switch pattern {
        case .wildcard: return true
        case .bind(let name):
            if name == "_" { return true }
            env.define(name, value, constant: true)
            return true
        case .literal(let e):
            guard let lit = try? eval(e, env: env) else { return false }
            return ScalaFormatter.display(lit) == ScalaFormatter.display(value)
        case .constructor(let name, let subs):
            guard case .objectV(let ref) = value, ref.typeName == name else {
                if name == "Some", case .someV(let inner) = value, subs.count == 1 {
                    return matchPattern(subs[0], inner, env: env)
                }
                if name == "None", case .noneV = value { return true }
                return false
            }
            for (i, sub) in subs.enumerated() where i < ref.order.count {
                if !matchPattern(sub, ref.fields[ref.order[i]] ?? .unit, env: env) { return false }
            }
            return true
        }
    }

    // MARK: 二項演算

    private func binaryOp(_ op: String, _ l: ScalaValue, _ r: ScalaValue) throws -> ScalaValue {
        switch op {
        case "+":
            if case .stringV(let ls) = l { return .stringV(ls + ScalaFormatter.display(r)) }
            if case .stringV(let rs) = r { return .stringV(ScalaFormatter.display(l) + rs) }
            if isDouble(l) || isDouble(r) { return .doubleV(l.asDouble + r.asDouble) }
            if case .listV(let items, let kind) = l, case .listV(let items2, _) = r {
                return .listV(items + items2, kind: kind)
            }
            return .intV(l.asInt + r.asInt)
        case "-":
            if isDouble(l) || isDouble(r) { return .doubleV(l.asDouble - r.asDouble) }
            return .intV(l.asInt - r.asInt)
        case "*":
            if isDouble(l) || isDouble(r) { return .doubleV(l.asDouble * r.asDouble) }
            return .intV(l.asInt * r.asInt)
        case "/":
            if isDouble(l) || isDouble(r) {
                guard r.asDouble != 0 else { throw ScalaRuntimeError(message: "ゼロ除算です") }
                return .doubleV(l.asDouble / r.asDouble)
            }
            guard r.asInt != 0 else { throw ScalaRuntimeError(message: "ゼロ除算です") }
            return .intV(Int((Double(l.asInt) / Double(r.asInt)).rounded(.towardZero)))
        case "%":
            if isDouble(l) || isDouble(r) { return .doubleV(l.asDouble.truncatingRemainder(dividingBy: r.asDouble)) }
            guard r.asInt != 0 else { throw ScalaRuntimeError(message: "ゼロ除算です") }
            return .intV(l.asInt % r.asInt)
        case "==": return .boolV(ScalaFormatter.display(l) == ScalaFormatter.display(r) && sameKind(l, r))
        case "!=": return .boolV(!(ScalaFormatter.display(l) == ScalaFormatter.display(r) && sameKind(l, r)))
        case "<": return .boolV(compare(l, r) < 0)
        case ">": return .boolV(compare(l, r) > 0)
        case "<=": return .boolV(compare(l, r) <= 0)
        case ">=": return .boolV(compare(l, r) >= 0)
        case "->": return .tupleV(l, r)
        case "::":
            if case .listV(let items, let kind) = r { return .listV([l] + items, kind: kind) }
            return .listV([l], kind: "List")
        default:
            throw ScalaRuntimeError(message: "未対応の演算子です: \(op)")
        }
    }

    private func sameKind(_ l: ScalaValue, _ r: ScalaValue) -> Bool {
        switch (l, r) {
        case (.intV, .doubleV), (.doubleV, .intV): return true
        default: return true
        }
    }

    private func isDouble(_ v: ScalaValue) -> Bool { if case .doubleV = v { return true }; return false }

    private func compare(_ l: ScalaValue, _ r: ScalaValue) -> Int {
        if case .stringV(let ls) = l, case .stringV(let rs) = r {
            if ls == rs { return 0 }
            return ls < rs ? -1 : 1
        }
        let ld = l.asDouble, rd = r.asDouble
        if ld == rd { return 0 }
        return ld < rd ? -1 : 1
    }

    // MARK: 組み込みメソッド (List / String / Map など)

    private func builtinMethod(receiver: ScalaValue, name: String, args: [ScalaValue], rawArgs: [ScalaExpr], env: ScalaEnvironment) throws -> ScalaValue {
        switch receiver {
        case .listV(let items, let kind):
            return try listMethod(items: items, kind: kind, name: name, args: args, rawArgs: rawArgs, env: env)
        case .stringV(let s):
            return try stringMethod(s: s, name: name, args: args)
        case .mapV(let pairs):
            return try mapMethod(pairs: pairs, name: name, args: args, rawArgs: rawArgs, env: env)
        case .rangeV(let lo, let hi, let closed):
            let items = (closed ? Array(lo...max(lo, hi)) : Array(lo..<max(lo, hi))).map { ScalaValue.intV($0) }
            if lo > hi { return try listMethod(items: [], kind: "List", name: name, args: args, rawArgs: rawArgs, env: env) }
            return try listMethod(items: items, kind: "List", name: name, args: args, rawArgs: rawArgs, env: env)
        case .intV, .doubleV:
            switch name {
            case "toString": return .stringV(ScalaFormatter.display(receiver))
            case "toDouble": return .doubleV(receiver.asDouble)
            case "toInt": return .intV(receiver.asInt)
            case "abs": return isDouble(receiver) ? .doubleV(abs(receiver.asDouble)) : .intV(abs(receiver.asInt))
            default: throw ScalaRuntimeError(message: "未対応のメソッドです: \(name)")
            }
        case .someV(let inner):
            switch name {
            case "get": return inner
            case "getOrElse": return inner
            case "isDefined": return .boolV(true)
            case "map":
                if case .closureV(let c) = args.first { return .someV(try callClosure(c, args: [inner])) }
                return receiver
            default: throw ScalaRuntimeError(message: "未対応のメソッドです: \(name)")
            }
        case .noneV:
            switch name {
            case "getOrElse": return args.first ?? .unit
            case "isDefined": return .boolV(false)
            default: throw ScalaRuntimeError(message: "未対応のメソッドです: \(name)")
            }
        default:
            throw ScalaRuntimeError(message: "未対応のメソッドです: \(name)")
        }
    }

    private func listMethod(items: [ScalaValue], kind: String, name: String, args: [ScalaValue], rawArgs: [ScalaExpr], env: ScalaEnvironment) throws -> ScalaValue {
        func closureArg() throws -> ScalaClosureRef {
            guard case .closureV(let c) = args.first else { throw ScalaRuntimeError(message: "関数が必要です") }
            return c
        }
        switch name {
        case "map":
            let c = try closureArg()
            return .listV(try items.map { try callClosure(c, args: [$0]) }, kind: kind)
        case "filter":
            let c = try closureArg()
            return .listV(try items.filter { try callClosure(c, args: [$0]).asBool }, kind: kind)
        case "foreach":
            let c = try closureArg()
            for item in items { _ = try callClosure(c, args: [item]) }
            return .unit
        case "reduce":
            let c = try closureArg()
            guard var acc = items.first else { throw ScalaRuntimeError(message: "空のリストに reduce は使えません") }
            for item in items.dropFirst() { acc = try callClosure(c, args: [acc, item]) }
            return acc
        case "fold", "foldLeft":
            var acc = args[0]
            guard case .closureV(let c) = args[1] else { throw ScalaRuntimeError(message: "関数が必要です") }
            for item in items { acc = try callClosure(c, args: [acc, item]) }
            return acc
        case "sum":
            if items.contains(where: { isDouble($0) }) {
                return .doubleV(items.reduce(0.0) { $0 + $1.asDouble })
            }
            return .intV(items.reduce(0) { $0 + $1.asInt })
        case "length", "size":
            return .intV(items.count)
        case "head":
            guard let f = items.first else { throw ScalaRuntimeError(message: "空のリストです") }
            return f
        case "tail":
            return .listV(Array(items.dropFirst()), kind: kind)
        case "last":
            guard let l = items.last else { throw ScalaRuntimeError(message: "空のリストです") }
            return l
        case "isEmpty": return .boolV(items.isEmpty)
        case "nonEmpty": return .boolV(!items.isEmpty)
        case "mkString":
            let sep: String
            if args.count == 1, case .stringV(let s) = args[0] { sep = s } else { sep = "" }
            if args.count == 3 {
                guard case .stringV(let pre) = args[0], case .stringV(let mid) = args[1], case .stringV(let post) = args[2] else {
                    return .stringV(items.map { ScalaFormatter.display($0) }.joined())
                }
                return .stringV(pre + items.map { ScalaFormatter.display($0) }.joined(separator: mid) + post)
            }
            return .stringV(items.map { ScalaFormatter.display($0) }.joined(separator: sep))
        case "sorted":
            return .listV(items.sorted { compare($0, $1) < 0 }, kind: kind)
        case "reverse":
            return .listV(items.reversed(), kind: kind)
        case "contains":
            return .boolV(items.contains { ScalaFormatter.display($0) == ScalaFormatter.display(args[0]) })
        case "distinct":
            var seen: [String] = []
            var out: [ScalaValue] = []
            for item in items {
                let key = ScalaFormatter.display(item)
                if !seen.contains(key) { seen.append(key); out.append(item) }
            }
            return .listV(out, kind: kind)
        case "toList": return .listV(items, kind: "List")
        case "toArray": return .listV(items, kind: "Array")
        case "min":
            guard let m = items.min(by: { compare($0, $1) < 0 }) else { throw ScalaRuntimeError(message: "空のリストです") }
            return m
        case "max":
            guard let m = items.max(by: { compare($0, $1) < 0 }) else { throw ScalaRuntimeError(message: "空のリストです") }
            return m
        case "take": return .listV(Array(items.prefix(args[0].asInt)), kind: kind)
        case "drop": return .listV(Array(items.dropFirst(args[0].asInt)), kind: kind)
        case "zip":
            guard case .listV(let other, _) = args[0] else { return .listV([], kind: kind) }
            let n = min(items.count, other.count)
            return .listV((0..<n).map { .tupleV(items[$0], other[$0]) }, kind: kind)
        case "indices":
            return .listV((0..<items.count).map { .intV($0) }, kind: "Range")
        case "apply":
            return try indexValue(.listV(items, kind: kind), args[0].asInt)
        case "count":
            let c = try closureArg()
            return .intV(try items.filter { try callClosure(c, args: [$0]).asBool }.count)
        case "toString":
            return .stringV(ScalaFormatter.display(.listV(items, kind: kind)))
        default:
            throw ScalaRuntimeError(message: "未対応のメソッドです: \(name)")
        }
    }

    private func stringMethod(s: String, name: String, args: [ScalaValue]) throws -> ScalaValue {
        switch name {
        case "length": return .intV(s.count)
        case "toUpperCase": return .stringV(s.uppercased())
        case "toLowerCase": return .stringV(s.lowercased())
        case "trim": return .stringV(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case "toInt": return .intV(Int(s) ?? 0)
        case "toDouble": return .doubleV(Double(s) ?? 0)
        case "reverse": return .stringV(String(s.reversed()))
        case "split":
            guard case .stringV(let sep) = args.first else { return .listV([.stringV(s)], kind: "Array") }
            return .listV(s.components(separatedBy: sep).map { .stringV($0) }, kind: "Array")
        case "contains":
            guard case .stringV(let sub) = args.first else { return .boolV(false) }
            return .boolV(s.contains(sub))
        case "startsWith":
            guard case .stringV(let sub) = args.first else { return .boolV(false) }
            return .boolV(s.hasPrefix(sub))
        case "endsWith":
            guard case .stringV(let sub) = args.first else { return .boolV(false) }
            return .boolV(s.hasSuffix(sub))
        case "charAt":
            let chars = Array(s)
            let i = args[0].asInt
            guard i >= 0 && i < chars.count else { throw ScalaRuntimeError(message: "範囲外の添字です") }
            return .stringV(String(chars[i]))
        case "substring":
            let chars = Array(s)
            let start = args[0].asInt
            let end = args.count > 1 ? args[1].asInt : chars.count
            guard start >= 0, end <= chars.count, start <= end else { throw ScalaRuntimeError(message: "範囲外の添字です") }
            return .stringV(String(chars[start..<end]))
        case "isEmpty": return .boolV(s.isEmpty)
        case "nonEmpty": return .boolV(!s.isEmpty)
        case "replace":
            guard case .stringV(let a) = args[0], case .stringV(let b) = args[1] else { return .stringV(s) }
            return .stringV(s.replacingOccurrences(of: a, with: b))
        case "toString": return .stringV(s)
        default:
            throw ScalaRuntimeError(message: "未対応のメソッドです: \(name)")
        }
    }

    private func mapMethod(pairs: [(ScalaValue, ScalaValue)], name: String, args: [ScalaValue], rawArgs: [ScalaExpr], env: ScalaEnvironment) throws -> ScalaValue {
        switch name {
        case "size": return .intV(pairs.count)
        case "isEmpty": return .boolV(pairs.isEmpty)
        case "contains":
            return .boolV(pairs.contains { ScalaFormatter.display($0.0) == ScalaFormatter.display(args[0]) })
        case "getOrElse":
            for p in pairs where ScalaFormatter.display(p.0) == ScalaFormatter.display(args[0]) { return p.1 }
            return args.count > 1 ? args[1] : .unit
        case "keys":
            return .listV(pairs.map { $0.0 }, kind: "List")
        case "values":
            return .listV(pairs.map { $0.1 }, kind: "List")
        case "foreach":
            guard case .closureV(let c) = args.first else { return .unit }
            for p in pairs { _ = try callClosure(c, args: [.tupleV(p.0, p.1)]) }
            return .unit
        case "apply":
            for p in pairs where ScalaFormatter.display(p.0) == ScalaFormatter.display(args[0]) { return p.1 }
            throw ScalaRuntimeError(message: "キーが見つかりません")
        case "toString": return .stringV(ScalaFormatter.display(.mapV(pairs)))
        default:
            throw ScalaRuntimeError(message: "未対応のメソッドです: \(name)")
        }
    }
}

// MARK: - エンジン本体

public enum MiniScala: MiniLangEngine {
    public static let languageID = "scala"
    public static let displayName = "内蔵 Scala インタプリタ"

    public static func execute(source: String, input: String = "", limits: MiniLangLimits = .default) -> MiniLangExecution {
        MiniLangRunner.run {
            executeOnCurrentThread(source: source, input: input, limits: limits)
        }
    }

    static func executeOnCurrentThread(source: String, input: String, limits: MiniLangLimits) -> MiniLangExecution {
        let diagnostics = DiagnosticBag(source: source)
        var lexer = ScalaLexer(source: source, diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = ScalaParser(tokens: tokens, diagnostics: diagnostics)
        let program = parser.parseProgram()
        if let failure = diagnostics.failureIfNeeded() {
            return .syntaxError(failure)
        }
        let interpreter = ScalaInterpreter(limits: ScalaLimits(maximumSteps: limits.maximumSteps), outputLimit: limits.maximumOutputBytes)
        let result = interpreter.run(program)
        return MiniLangExecution(parsed: true, diagnosticsText: "", errorCount: 0,
                                 output: result.output, runtimeError: result.error,
                                 exitCode: result.error == nil ? 0 : 1)
    }
}
