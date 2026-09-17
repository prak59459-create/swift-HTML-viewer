import Foundation

/// 字下げでブロックを表す言語のための共通構文解析器。
///
/// Nim・Python・Haskell のように中括弧を使わない言語はここを継承する。
/// 字句解析器は改行を捨ててよい。ブロックの範囲は各字句が持つ桁位置で決める。
open class MLIndentParser: MLProfileParser {

    /// いま開いているブロックの字下げ桁 (1 始まり)。
    public private(set) var indentColumns: [Int] = []

    /// ブロックの始まりを表す記号 (`:` / `=` / `where` など)。
    open var blockIntroducer: String? { ":" }

    /// いまのブロックの字下げ桁。外側にいるときは 0。
    public var currentIndent: Int { indentColumns.last ?? 0 }

    /// `:` を読んだあとのブロック。
    ///
    /// `if x: echo 1` のように同じ行に書く書き方にも対応する。
    open func parseIndentedBlock() throws -> [MLStmt] {
        if !isAtEnd, !current.precededByNewline {
            var statements: [MLStmt] = []
            repeat {
                if isAtEnd || current.precededByNewline { break }
                if let statement = try parseStatement() { statements.append(statement) }
            } while match(";")
            return statements
        }
        return try parseIndentedStatements()
    }

    /// いまより深く字下げされた文をまとめて読む。
    open func parseIndentedStatements() throws -> [MLStmt] {
        guard !isAtEnd else { return [] }
        let column = current.location.column
        guard column > currentIndent else { return [] }
        indentColumns.append(column)
        defer { indentColumns.removeLast() }

        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            if current.location.column < column { break }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        return statements
    }

    /// いまの字下げより浅い所まで来たか (ブロックの終わり)。
    public func isBlockEnd(deeperThan column: Int) -> Bool {
        isAtEnd || current.location.column < column
    }

    open override func parseBlock() throws -> [MLStmt] {
        if let introducer = blockIntroducer { _ = match(introducer) }
        return try parseIndentedBlock()
    }

    open override func parseStatementAsBlock() throws -> [MLStmt] {
        try parseBlock()
    }

    // MARK: 制御構文

    open override func parseIf() throws -> MLStmt {
        let location = current.location
        advance()   // if / elif
        let condition = try parseExpression(stopAtBrace: true)
        let then = try parseBlock()

        var otherwise: [MLStmt]?
        if check("elif") {
            otherwise = [try parseIf()]
        } else if match("else") {
            otherwise = try parseBlock()
        }
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
        let body = try parseBlock()
        return .whileStmt(condition: condition, body: body, label: label, location)
    }

    open override func parseFor(label: String?) throws -> MLStmt {
        let location = current.location
        advance()   // for
        let pattern = try parseForPattern()
        guard match("in") else { throw report("for のあとに `in` が必要です") }
        let sequence = try parseExpression(stopAtBrace: true)
        let body = try parseBlock()
        return .forIn(pattern: pattern, sequence: sequence, body: body,
                      whereClause: nil, label: label, location)
    }

    open override func parseForPattern() throws -> MLPattern {
        var names: [String] = [try expectIdentifier("for の変数")]
        while match(",") { names.append(try expectIdentifier("for の変数")) }
        if names.count == 1 {
            return names[0] == "_" ? .wildcard : .binding(names[0])
        }
        return .tuple(names.map { $0 == "_" ? .wildcard : .binding($0) })
    }
}
