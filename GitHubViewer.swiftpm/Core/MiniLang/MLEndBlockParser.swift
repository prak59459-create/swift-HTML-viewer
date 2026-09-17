import Foundation

/// `end` でブロックを閉じる言語のための共通構文解析器。
///
/// Julia・Crystal・Ruby・Pascal・Lua のように、中括弧ではなくキーワードで
/// ブロックを閉じる言語はここを継承する。
open class MLEndBlockParser: MLProfileParser {

    /// ブロックを閉じる語。
    open var blockTerminators: Set<String> { ["end"] }
    /// 途中で分岐する語 (ここでもブロックが切れる)。
    open var branchKeywords: Set<String> { ["else", "elseif", "elsif", "elif"] }
    /// `if cond then` のように、条件のあとに置く語。
    open var thenKeywords: Set<String> { ["then", "do"] }
    /// ブロックを開く語 (Pascal の `begin`)。無ければ nil。
    open var blockOpener: String? { nil }

    /// 指定の語のどれかに出会うまで文を読む (その語は消費しない)。
    open func parseStatements(until stops: Set<String>) throws -> [MLStmt] {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            if stops.contains(current.text) { break }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        return statements
    }

    /// ブロック 1 つぶん (終わりの語まで読んで消費する)。
    open override func parseBlock() throws -> [MLStmt] {
        if let opener = blockOpener { _ = match(opener) }
        let body = try parseStatements(until: blockTerminators)
        if blockTerminators.contains(current.text) { advance() }
        return body
    }

    open override func parseStatementAsBlock() throws -> [MLStmt] {
        try parseBlock()
    }

    // MARK: 制御構文

    open override func parseIf() throws -> MLStmt {
        let location = current.location
        advance()   // if / elseif
        let condition = try parseExpression(stopAtBrace: true)
        for keyword in thenKeywords where match(keyword) { break }
        let then = try parseStatements(until: blockTerminators.union(branchKeywords))

        var otherwise: [MLStmt]?
        if branchKeywords.contains(current.text) {
            if current.text == "else" {
                advance()
                otherwise = try parseStatements(until: blockTerminators)
            } else {
                // `elseif` / `elsif` / `elif` は入れ子の if として読む。
                otherwise = [try parseIf()]
                return .ifStmt(condition: condition, then: then, otherwise: otherwise,
                               location)
            }
        }
        if blockTerminators.contains(current.text) { advance() }
        return .ifStmt(condition: condition, then: then, otherwise: otherwise, location)
    }

    open override func parseIfExpression() throws -> MLExpr {
        let location = current.location
        let statement = try parseIf()
        guard case .ifStmt(let condition, let then, let otherwise, _) = statement else {
            return .block([statement], location)
        }
        return .ifExpr(condition: condition, then: .block(then, location),
                       otherwise: otherwise.map { .block($0, location) }, location)
    }

    open override func parseWhile(label: String?) throws -> MLStmt {
        let location = current.location
        try expect("while")
        let condition = try parseExpression(stopAtBrace: true)
        for keyword in thenKeywords where match(keyword) { break }
        let body = try parseBlock()
        return .whileStmt(condition: condition, body: body, label: label, location)
    }

    open override func parseFor(label: String?) throws -> MLStmt {
        let location = current.location
        advance()   // for / foreach
        let pattern = try parseForPattern()
        guard match("in") || match("=") || match(":") else {
            throw report("for のあとに `in` が必要です")
        }
        let sequence = try parseExpression(stopAtBrace: true)
        for keyword in thenKeywords where match(keyword) { break }
        let body = try parseBlock()
        return .forIn(pattern: pattern, sequence: sequence, body: body,
                      whereClause: nil, label: label, location)
    }

    open override func parseForPattern() throws -> MLPattern {
        if check("(") {
            advance()
            var items: [MLPattern] = []
            repeat {
                let name = try expectIdentifier("for の変数")
                items.append(name == "_" ? .wildcard : .binding(name))
            } while match(",")
            try expect(")", "for のパターン")
            return items.count == 1 ? items[0] : .tuple(items)
        }
        var names: [String] = [try expectIdentifier("for の変数")]
        while match(",") { names.append(try expectIdentifier("for の変数")) }
        if names.count == 1 {
            return names[0] == "_" ? .wildcard : .binding(names[0])
        }
        return .tuple(names.map { $0 == "_" ? .wildcard : .binding($0) })
    }

    /// `begin ... end` はただのブロック。
    open override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location
        if let opener = blockOpener, check(opener) {
            advance()
            let body = try parseStatements(until: blockTerminators)
            if blockTerminators.contains(current.text) { advance() }
            return .block(body, location)
        }
        return try super.parseStatement()
    }
}
