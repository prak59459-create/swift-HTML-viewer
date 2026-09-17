import Foundation

// MARK: - 138. 構文木のビューア

/// 画面に出すための木の節。
public struct ASTNode: Identifiable, Equatable, Sendable {
    public var id: Int
    /// 節の種類 (`if` / `呼び出し` など)。
    public var kind: String
    /// 名前や値など、その節を特徴づける文字列。
    public var detail: String
    public var line: Int
    public var children: [ASTNode]

    public init(id: Int = 0, kind: String, detail: String = "", line: Int = 0,
                children: [ASTNode] = []) {
        self.id = id
        self.kind = kind
        self.detail = detail
        self.line = line
        self.children = children
    }

    public var title: String { detail.isEmpty ? kind : "\(kind): \(detail)" }

    /// 自分を含めた節の数。
    public var nodeCount: Int {
        1 + children.reduce(0) { $0 + $1.nodeCount }
    }

    /// 木の深さ。
    public var depth: Int {
        1 + (children.map(\.depth).max() ?? 0)
    }

    /// 字下げした文字列。
    public func text(indent: Int = 0) -> String {
        var lines = [String(repeating: "  ", count: indent) + title]
        for child in children { lines.append(child.text(indent: indent + 1)) }
        return lines.joined(separator: "\n")
    }
}

/// 中間表現を、画面に出せる木に組み替える。
public enum SyntaxTreeBuilder {

    /// ソースから木を作る。
    public static func tree(languageID: String, source: String) throws -> ASTNode {
        guard let engine = MiniLangRegistry.engine(for: languageID) else {
            throw RunSessionError.noEngine(languageID)
        }
        let diagnostics = DiagnosticBag(source: source)
        let program = try engine.parse(source: source, diagnostics: diagnostics)
        if let failure = diagnostics.failureIfNeeded() {
            throw SyntaxTreeError.parseFailed(failure.formatted)
        }
        var counter = 0
        return node(kind: "プログラム",
                    children: program.statements.map { statement(&counter, $0) },
                    counter: &counter)
    }

    /// 中間表現から木を作る (すでに解析済みのとき)。
    public static func tree(_ program: MLProgram) -> ASTNode {
        var counter = 0
        return node(kind: "プログラム",
                    children: program.statements.map { statement(&counter, $0) },
                    counter: &counter)
    }

    private static func node(kind: String, detail: String = "", line: Int = 0,
                             children: [ASTNode] = [],
                             counter: inout Int) -> ASTNode {
        counter += 1
        return ASTNode(id: counter, kind: kind, detail: detail, line: line,
                       children: children)
    }

    // MARK: - 文

    static func statement(_ counter: inout Int, _ input: MLStmt) -> ASTNode {
        let line = input.location.line
        switch input {
        case .noop:
            return node(kind: "宣言のみ", line: line, counter: &counter)

        case .expression(let expression, _):
            return node(kind: "式", line: line,
                        children: [self.expression(&counter, expression)],
                        counter: &counter)

        case .varDecl(let pattern, let typeName, let value, let isConstant, _):
            var children = [self.pattern(&counter, pattern)]
            if let value { children.append(expression(&counter, value)) }
            return node(kind: isConstant ? "定数宣言" : "変数宣言",
                        detail: typeName ?? "", line: line, children: children,
                        counter: &counter)

        case .funcDecl(let decl):
            var children: [ASTNode] = []
            for clause in decl.clauses {
                let parameters = clause.parameters.map { $0.name }.joined(separator: ", ")
                children.append(node(kind: "引数", detail: parameters,
                                     line: decl.location.line, counter: &counter))
                children.append(node(kind: "本体",
                                     children: clause.body.map { statement(&counter, $0) },
                                     counter: &counter))
            }
            return node(kind: "関数", detail: decl.name, line: decl.location.line,
                        children: children, counter: &counter)

        case .typeDecl(let decl):
            var children: [ASTNode] = []
            for property in decl.properties {
                children.append(node(kind: "フィールド", detail: property.name,
                                     line: decl.location.line, counter: &counter))
            }
            for method in decl.initializers + decl.methods {
                children.append(statement(&counter, .funcDecl(method)))
            }
            for nested in decl.nestedTypes {
                children.append(statement(&counter, .typeDecl(nested)))
            }
            return node(kind: typeKindName(decl.kind), detail: decl.name,
                        line: decl.location.line, children: children, counter: &counter)

        case .ifStmt(let condition, let then, let otherwise, _):
            var children = [node(kind: "条件",
                                 children: [expression(&counter, condition)],
                                 counter: &counter),
                            node(kind: "真のとき",
                                 children: then.map { statement(&counter, $0) },
                                 counter: &counter)]
            if let otherwise, !otherwise.isEmpty {
                children.append(node(kind: "偽のとき",
                                     children: otherwise.map { statement(&counter, $0) },
                                     counter: &counter))
            }
            return node(kind: "if", line: line, children: children, counter: &counter)

        case .whileStmt(let condition, let body, let label, _):
            return node(kind: "while", detail: label ?? "", line: line,
                        children: [node(kind: "条件",
                                        children: [expression(&counter, condition)],
                                        counter: &counter),
                                   node(kind: "本体",
                                        children: body.map { statement(&counter, $0) },
                                        counter: &counter)],
                        counter: &counter)

        case .doWhile(let body, let condition, let isUntil, let label, _):
            return node(kind: isUntil ? "repeat-until" : "do-while",
                        detail: label ?? "", line: line,
                        children: [node(kind: "本体",
                                        children: body.map { statement(&counter, $0) },
                                        counter: &counter),
                                   node(kind: "条件",
                                        children: [expression(&counter, condition)],
                                        counter: &counter)],
                        counter: &counter)

        case .forClassic(let initializer, let condition, let step, let body,
                         let label, _):
            var children: [ASTNode] = []
            if !initializer.isEmpty {
                children.append(node(kind: "初期化",
                                     children: initializer.map { statement(&counter, $0) },
                                     counter: &counter))
            }
            if let condition {
                children.append(node(kind: "条件",
                                     children: [expression(&counter, condition)],
                                     counter: &counter))
            }
            if !step.isEmpty {
                children.append(node(kind: "更新",
                                     children: step.map { statement(&counter, $0) },
                                     counter: &counter))
            }
            children.append(node(kind: "本体",
                                 children: body.map { statement(&counter, $0) },
                                 counter: &counter))
            return node(kind: "for", detail: label ?? "", line: line,
                        children: children, counter: &counter)

        case .forIn(let binding, let sequence, let body, _, let label, _):
            return node(kind: "for-in", detail: label ?? "", line: line,
                        children: [self.pattern(&counter, binding),
                                   node(kind: "対象",
                                        children: [expression(&counter, sequence)],
                                        counter: &counter),
                                   node(kind: "本体",
                                        children: body.map { statement(&counter, $0) },
                                        counter: &counter)],
                        counter: &counter)

        case .matchStmt(let subject, let arms, _, _):
            var children = [node(kind: "対象",
                                 children: [expression(&counter, subject)],
                                 counter: &counter)]
            for arm in arms {
                children.append(node(kind: arm.isDefault ? "既定の分岐" : "分岐",
                                     children: arm.patterns.map { self.pattern(&counter, $0) }
                                        + arm.body.map { statement(&counter, $0) },
                                     counter: &counter))
            }
            return node(kind: "match", line: line, children: children, counter: &counter)

        case .breakStmt(let label, _):
            return node(kind: "break", detail: label ?? "", line: line, counter: &counter)

        case .continueStmt(let label, _):
            return node(kind: "continue", detail: label ?? "", line: line,
                        counter: &counter)

        case .returnStmt(let value, _):
            return node(kind: "return", line: line,
                        children: value.map { [expression(&counter, $0)] } ?? [],
                        counter: &counter)

        case .throwStmt(let value, _):
            return node(kind: "throw", line: line,
                        children: [expression(&counter, value)], counter: &counter)

        case .tryStmt(let body, let catches, let finallyBody, _):
            var children = [node(kind: "本体",
                                 children: body.map { statement(&counter, $0) },
                                 counter: &counter)]
            for clause in catches {
                let label = [clause.typeName, clause.binding]
                    .compactMap { $0 }.joined(separator: " ")
                children.append(node(kind: "catch", detail: label,
                                     children: clause.body.map { statement(&counter, $0) },
                                     counter: &counter))
            }
            if let finallyBody, !finallyBody.isEmpty {
                children.append(node(kind: "finally",
                                     children: finallyBody.map { statement(&counter, $0) },
                                     counter: &counter))
            }
            return node(kind: "try", line: line, children: children, counter: &counter)

        case .block(let body, _):
            return node(kind: "ブロック", line: line,
                        children: body.map { statement(&counter, $0) }, counter: &counter)

        case .guardStmt(let condition, let elseBody, _):
            return node(kind: "guard", line: line,
                        children: [expression(&counter, condition),
                                   node(kind: "else",
                                        children: elseBody.map { statement(&counter, $0) },
                                        counter: &counter)],
                        counter: &counter)
        }
    }

    // MARK: - 式

    static func expression(_ counter: inout Int, _ input: MLExpr) -> ASTNode {
        let line = input.location.line
        switch input {
        case .literal(let value, _):
            return node(kind: "値", detail: MLDisplay.plain(value), line: line,
                        counter: &counter)

        case .name(let name, _):
            return node(kind: "名前", detail: name, line: line, counter: &counter)

        case .selfRef:
            return node(kind: "self", line: line, counter: &counter)

        case .superRef:
            return node(kind: "super", line: line, counter: &counter)

        case .listLiteral(let items, _, _):
            return node(kind: "配列", line: line,
                        children: items.map { expression(&counter, $0) },
                        counter: &counter)

        case .mapLiteral(let pairs, _):
            return node(kind: "辞書", line: line,
                        children: pairs.flatMap {
                            [expression(&counter, $0.key), expression(&counter, $0.value)]
                        },
                        counter: &counter)

        case .tupleLiteral(let items, _):
            return node(kind: "組", line: line,
                        children: items.map { expression(&counter, $0) },
                        counter: &counter)

        case .interpolation(let parts, _):
            return node(kind: "文字列の組み立て", line: line,
                        children: parts.map { expression(&counter, $0) },
                        counter: &counter)

        case .member(let object, let name, let isOptional, _):
            return node(kind: isOptional ? "メンバー (省略可)" : "メンバー", detail: name,
                        line: line, children: [expression(&counter, object)],
                        counter: &counter)

        case .subscriptExpr(let object, let index, let upper, _):
            var children = [expression(&counter, object), expression(&counter, index)]
            if let upper { children.append(expression(&counter, upper)) }
            return node(kind: upper == nil ? "添字" : "スライス", line: line,
                        children: children, counter: &counter)

        case .call(let callee, let arguments, _):
            return node(kind: "呼び出し", line: line,
                        children: [expression(&counter, callee)]
                            + arguments.map { expression(&counter, $0.value) },
                        counter: &counter)

        case .construct(let typeName, let arguments, _):
            return node(kind: "生成", detail: typeName, line: line,
                        children: arguments.map { expression(&counter, $0.value) },
                        counter: &counter)

        case .unary(let op, let operand, let isPostfix, _):
            return node(kind: isPostfix ? "後置演算" : "前置演算", detail: op, line: line,
                        children: [expression(&counter, operand)], counter: &counter)

        case .binary(let op, let lhs, let rhs, _):
            return node(kind: "二項演算", detail: op, line: line,
                        children: [expression(&counter, lhs), expression(&counter, rhs)],
                        counter: &counter)

        case .assign(let op, let target, let value, _):
            return node(kind: "代入", detail: op, line: line,
                        children: [expression(&counter, target),
                                   expression(&counter, value)],
                        counter: &counter)

        case .ternary(let condition, let then, let otherwise, _):
            return node(kind: "三項演算", line: line,
                        children: [expression(&counter, condition),
                                   expression(&counter, then),
                                   expression(&counter, otherwise)],
                        counter: &counter)

        case .lambda(let decl, _):
            let parameters = decl.clauses.first?.parameters
                .map(\.name).joined(separator: ", ") ?? ""
            return node(kind: "無名関数", detail: parameters, line: line,
                        children: decl.clauses.first?.body
                            .map { statement(&counter, $0) } ?? [],
                        counter: &counter)

        case .range(let lower, let upper, let isClosed, let step, _):
            var children: [ASTNode] = []
            if let lower { children.append(expression(&counter, lower)) }
            if let upper { children.append(expression(&counter, upper)) }
            if let step { children.append(expression(&counter, step)) }
            return node(kind: isClosed ? "範囲 (終端を含む)" : "範囲", line: line,
                        children: children, counter: &counter)

        case .cast(let value, let typeName, let isOptional, _):
            return node(kind: isOptional ? "型変換 (失敗可)" : "型変換", detail: typeName,
                        line: line, children: [expression(&counter, value)],
                        counter: &counter)

        case .typeTest(let value, let typeName, _):
            return node(kind: "型の判定", detail: typeName, line: line,
                        children: [expression(&counter, value)], counter: &counter)

        case .forceUnwrap(let value, _):
            return node(kind: "強制アンラップ", line: line,
                        children: [expression(&counter, value)], counter: &counter)

        case .implicitMember(let name, _):
            return node(kind: "省略メンバー", detail: name, line: line, counter: &counter)

        case .comprehension(let comprehension, _):
            return node(kind: "内包表記", line: line,
                        children: [expression(&counter, comprehension.element)],
                        counter: &counter)

        case .match(let subject, let arms, _):
            var children = [expression(&counter, subject)]
            for arm in arms {
                children.append(node(kind: "分岐",
                                     children: arm.patterns.map { pattern(&counter, $0) }
                                        + arm.body.map { statement(&counter, $0) },
                                     counter: &counter))
            }
            return node(kind: "match 式", line: line, children: children,
                        counter: &counter)

        case .block(let body, _):
            return node(kind: "ブロック式", line: line,
                        children: body.map { statement(&counter, $0) }, counter: &counter)

        case .ifExpr(let condition, let then, let otherwise, _):
            var children = [expression(&counter, condition), expression(&counter, then)]
            if let otherwise { children.append(expression(&counter, otherwise)) }
            return node(kind: "if 式", line: line, children: children, counter: &counter)

        case .lazy(let value, _):
            return node(kind: "遅延評価", line: line,
                        children: [expression(&counter, value)], counter: &counter)

        case .reference(let value, _):
            return node(kind: "参照を作る", line: line,
                        children: [expression(&counter, value)], counter: &counter)

        case .dereference(let value, _):
            return node(kind: "参照をたどる", line: line,
                        children: [expression(&counter, value)], counter: &counter)

        case .defaultValue(let typeName, _):
            return node(kind: "既定値", detail: typeName ?? "", line: line,
                        counter: &counter)
        }
    }

    static func pattern(_ counter: inout Int, _ input: MLPattern) -> ASTNode {
        switch input {
        case .wildcard:
            return node(kind: "何でも", detail: "_", counter: &counter)
        case .binding(let name):
            return node(kind: "束縛", detail: name, counter: &counter)
        case .literal(let value):
            return node(kind: "値との一致", detail: MLDisplay.plain(value),
                        counter: &counter)
        case .expression(let value):
            return node(kind: "式との一致", children: [expression(&counter, value)],
                        counter: &counter)
        case .tuple(let items):
            return node(kind: "組の分解", children: items.map { pattern(&counter, $0) },
                        counter: &counter)
        case .list(let items, _, let restName):
            return node(kind: "並びの分解", detail: restName ?? "",
                        children: items.map { pattern(&counter, $0) }, counter: &counter)
        case .constructor(let name, let positional, let named):
            return node(kind: "構成子", detail: name,
                        children: positional.map { pattern(&counter, $0) }
                            + named.map { pattern(&counter, $0.1) },
                        counter: &counter)
        case .map(let pairs):
            return node(kind: "辞書の分解",
                        children: pairs.map { pattern(&counter, $0.value) },
                        counter: &counter)
        case .typed(let inner, let typeName):
            return node(kind: "型つき", detail: typeName,
                        children: [pattern(&counter, inner)], counter: &counter)
        case .or(let items):
            return node(kind: "どれか", children: items.map { pattern(&counter, $0) },
                        counter: &counter)
        case .named(let name, let inner):
            return node(kind: "名前つき", detail: name,
                        children: [pattern(&counter, inner)], counter: &counter)
        case .range(let lower, let upper, let isClosed):
            return node(kind: isClosed ? "範囲 (終端を含む)" : "範囲",
                        children: [expression(&counter, lower),
                                   expression(&counter, upper)],
                        counter: &counter)
        case .cons(let head, let tail):
            return node(kind: "先頭と残り",
                        children: [pattern(&counter, head), pattern(&counter, tail)],
                        counter: &counter)
        }
    }

    /// 型の種類の呼び名。
    static func typeKindName(_ kind: MLTypeDecl.Kind) -> String {
        switch kind {
        case .classType: return "クラス"
        case .structType: return "構造体"
        case .enumType: return "列挙"
        case .interfaceType: return "インタフェース"
        case .moduleType: return "モジュール"
        }
    }

}

public enum SyntaxTreeError: LocalizedError, Equatable {
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let text): return text
        }
    }
}

// MARK: - 139. トークン一覧

/// 見せるための 1 トークン。
public struct DisplayToken: Identifiable, Equatable, Sendable {
    public var id: Int
    public var text: String
    /// 種類 (色分けと同じ区分)。
    public var kind: HighlightKind
    public var line: Int
    /// 行の中の位置 (UTF-16)。
    public var location: Int
    public var length: Int

    public init(id: Int, text: String, kind: HighlightKind, line: Int, location: Int,
                length: Int) {
        self.id = id
        self.text = text
        self.kind = kind
        self.line = line
        self.location = location
        self.length = length
    }

    public var kindName: String { DisplayToken.name(for: kind) }

    public static func name(for kind: HighlightKind) -> String {
        switch kind {
        case .keyword: return "キーワード"
        case .string: return "文字列"
        case .number: return "数"
        case .comment: return "コメント"
        case .type: return "型"
        case .function: return "関数"
        case .character: return "文字"
        case .documentationComment: return "説明コメント"
        case .operatorSymbol: return "演算子"
        case .punctuation: return "区切り"
        case .preprocessor: return "前処理"
        case .attribute: return "属性"
        case .variable: return "変数"
        case .constant: return "定数"
        case .invalid: return "解釈できない部分"
        case .plain: return "そのほか"
        }
    }
}

/// ソースをトークンに分けて並べる。
///
/// 色分けの仕組みで見つかる部分 (キーワード・文字列・数など) に加えて、
/// そのあいだに残った部分も空白で区切って拾うので、
/// 名前や区切り記号も一覧に出る。
public enum TokenListing {
    public static func tokens(languageID: String?, source: String) -> [DisplayToken] {
        let spans = SyntaxHighlighter.spans(for: source, languageID: languageID)
            .sorted { $0.location < $1.location }
        let units = Array(source.utf16)
        let document = TextDocument(source)
        var pieces: [(location: Int, length: Int, kind: HighlightKind)] = []
        var cursor = 0

        /// 色が付いていない部分を、空白と記号で区切って拾う。
        func addPlain(from start: Int, to end: Int) {
            var index = start
            var wordStart: Int?
            while index < end {
                let unit = units[index]
                let isSpace = unit == 32 || unit == 9 || unit == 10 || unit == 13
                let isWord = !isSpace && isWordUnit(unit)
                if isWord {
                    if wordStart == nil { wordStart = index }
                    index += 1
                    continue
                }
                if let begin = wordStart {
                    pieces.append((begin, index - begin, .plain))
                    wordStart = nil
                }
                if !isSpace { pieces.append((index, 1, .punctuation)) }
                index += 1
            }
            if let begin = wordStart { pieces.append((begin, end - begin, .plain)) }
        }

        for span in spans where span.location >= cursor {
            if span.location > cursor { addPlain(from: cursor, to: span.location) }
            pieces.append((span.location, span.length, span.kind))
            cursor = span.location + span.length
        }
        if cursor < units.count { addPlain(from: cursor, to: units.count) }

        return pieces.enumerated().map { index, piece in
            let position = document.position(at: piece.location)
            let lineStart = document.location(of: TextPosition(line: position.line,
                                                               column: 1))
            return DisplayToken(id: index,
                                text: document.substring(location: piece.location,
                                                         length: piece.length),
                                kind: piece.kind, line: position.line,
                                location: piece.location - lineStart,
                                length: piece.length)
        }
    }

    /// 名前を作れる文字か。
    private static func isWordUnit(_ unit: UInt16) -> Bool {
        // ASCII の英数字と `_` `$`、それと非 ASCII (日本語の識別子など)。
        if unit >= 128 { return true }
        let scalar = Unicode.Scalar(unit)!
        return CharacterSet.alphanumerics.contains(scalar) || unit == 95 || unit == 36
    }

    /// 種類ごとの個数。
    public static func histogram(_ tokens: [DisplayToken]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for token in tokens { counts[token.kindName, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { ($0.key, $0.value) }
    }
}
