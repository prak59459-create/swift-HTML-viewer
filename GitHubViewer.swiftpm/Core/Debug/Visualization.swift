import Foundation

// MARK: - 151. 関数の呼び出しグラフ

/// 呼び出しの矢印 1 本。
public struct CallEdge: Identifiable, Equatable, Hashable, Sendable {
    public var caller: String
    public var callee: String
    /// 何回呼ばれたか (実行の記録から作ったとき)。
    public var count: Int

    public var id: String { "\(caller)→\(callee)" }

    public init(caller: String, callee: String, count: Int = 1) {
        self.caller = caller
        self.callee = callee
        self.count = count
    }
}

/// 関数どうしの呼び出し関係。
public struct CallGraph: Equatable, Sendable {
    public var nodes: [String]
    public var edges: [CallEdge]

    public init(nodes: [String] = [], edges: [CallEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    /// その関数が呼んでいる相手。
    public func callees(of name: String) -> [String] {
        edges.filter { $0.caller == name }.map(\.callee)
    }

    /// その関数を呼んでいる相手。
    public func callers(of name: String) -> [String] {
        edges.filter { $0.callee == name }.map(\.caller)
    }

    /// 誰からも呼ばれていない関数 (入口か、使われていないもの)。
    public var roots: [String] {
        nodes.filter { name in !edges.contains { $0.callee == name } }
    }

    /// 自分を呼んでいる関数 (再帰)。
    public var recursive: [String] {
        edges.filter { $0.caller == $0.callee }.map(\.caller)
    }

    /// Mermaid の図にする。
    public var mermaid: String {
        var lines = ["graph TD"]
        var identifiers: [String: String] = [:]
        for (index, node) in nodes.enumerated() {
            let key = "n\(index)"
            identifiers[node] = key
            lines.append("    \(key)[\"\(node)\"]")
        }
        for edge in edges {
            guard let from = identifiers[edge.caller],
                  let to = identifiers[edge.callee] else { continue }
            let label = edge.count > 1 ? "|\(edge.count)|" : ""
            lines.append("    \(from) -->\(label) \(to)")
        }
        return lines.joined(separator: "\n")
    }
}

/// 呼び出しグラフを組み立てる。
public enum CallGraphBuilder {

    /// 中間表現から、静的に組み立てる。
    public static func graph(languageID: String, source: String) throws -> CallGraph {
        guard let engine = MiniLangRegistry.engine(for: languageID) else {
            throw RunSessionError.noEngine(languageID)
        }
        let diagnostics = DiagnosticBag(source: source)
        let program = try engine.parse(source: source, diagnostics: diagnostics)
        return graph(program)
    }

    public static func graph(_ program: MLProgram) -> CallGraph {
        var functions: [String: [MLStmt]] = [:]
        collectFunctions(program.statements, into: &functions)

        var nodes = functions.keys.sorted()
        var counts: [CallEdge: Int] = [:]

        for (name, body) in functions {
            var called: [String] = []
            for statement in body { collectCalls(statement, into: &called) }
            for callee in called where functions[callee] != nil {
                let edge = CallEdge(caller: name, callee: callee)
                counts[edge, default: 0] += 1
            }
        }

        // 大域から呼ばれているものも入れる。
        var topLevel: [String] = []
        for statement in program.statements {
            if case .funcDecl = statement { continue }
            if case .typeDecl = statement { continue }
            collectCalls(statement, into: &topLevel)
        }
        if !topLevel.isEmpty {
            let global = "(大域)"
            if !nodes.contains(global) { nodes.insert(global, at: 0) }
            for callee in topLevel where functions[callee] != nil {
                counts[CallEdge(caller: global, callee: callee), default: 0] += 1
            }
        }

        let edges = counts.map { CallEdge(caller: $0.key.caller, callee: $0.key.callee,
                                          count: $0.value) }
            .sorted { ($0.caller, $0.callee) < ($1.caller, $1.callee) }
        return CallGraph(nodes: nodes, edges: edges)
    }

    /// 実行の記録から作る (実際に呼ばれたものだけ)。
    public static func graph(fromTrace steps: [TraceStep]) -> CallGraph {
        var nodes: [String] = []
        var counts: [CallEdge: Int] = [:]
        var stack: [String] = []

        for step in steps {
            let name = step.functionName
            if !nodes.contains(name) { nodes.append(name) }
            // 深さが変わったところが、呼び出しと戻り。
            while stack.count > step.depth { stack.removeLast() }
            if stack.count == step.depth {
                if stack.last != name {
                    if let caller = stack.count >= 1 ? stack.last : nil, caller != name {
                        counts[CallEdge(caller: caller, callee: name), default: 0] += 1
                    }
                    if stack.isEmpty { stack.append(name) } else { stack[stack.count - 1] = name }
                }
                continue
            }
            let caller = stack.last ?? "(大域)"
            if caller != name {
                counts[CallEdge(caller: caller, callee: name), default: 0] += 1
            }
            stack.append(name)
        }

        let edges = counts.map { CallEdge(caller: $0.key.caller, callee: $0.key.callee,
                                          count: $0.value) }
            .sorted { ($0.caller, $0.callee) < ($1.caller, $1.callee) }
        return CallGraph(nodes: nodes, edges: edges)
    }

    /// 関数の定義を集める。
    static func collectFunctions(_ statements: [MLStmt],
                                 into table: inout [String: [MLStmt]]) {
        for statement in statements {
            switch statement {
            case .funcDecl(let decl):
                table[decl.name] = decl.clauses.flatMap(\.body)
            case .typeDecl(let decl):
                for method in decl.initializers + decl.methods {
                    table[method.name] = method.clauses.flatMap(\.body)
                }
                for nested in decl.nestedTypes {
                    collectFunctions([.typeDecl(nested)], into: &table)
                }
            case .block(let body, _), .group(let body, _):
                collectFunctions(body, into: &table)
            default:
                continue
            }
        }
    }

    /// 文の中の呼び出し先の名前を集める。
    static func collectCalls(_ statement: MLStmt, into names: inout [String]) {
        switch statement {
        case .expression(let expression, _):
            collectCalls(expression, into: &names)
        case .varDecl(_, _, let value, _, _):
            if let value { collectCalls(value, into: &names) }
        case .ifStmt(let condition, let then, let otherwise, _):
            collectCalls(condition, into: &names)
            for item in then { collectCalls(item, into: &names) }
            for item in otherwise ?? [] { collectCalls(item, into: &names) }
        case .whileStmt(let condition, let body, _, _):
            collectCalls(condition, into: &names)
            for item in body { collectCalls(item, into: &names) }
        case .doWhile(let body, let condition, _, _, _):
            for item in body { collectCalls(item, into: &names) }
            collectCalls(condition, into: &names)
        case .forClassic(let initializer, let condition, let step, let body, _, _):
            for item in initializer { collectCalls(item, into: &names) }
            if let condition { collectCalls(condition, into: &names) }
            for item in step { collectCalls(item, into: &names) }
            for item in body { collectCalls(item, into: &names) }
        case .forIn(_, let sequence, let body, _, _, _):
            collectCalls(sequence, into: &names)
            for item in body { collectCalls(item, into: &names) }
        case .matchStmt(let subject, let arms, _, _):
            collectCalls(subject, into: &names)
            for arm in arms {
                for item in arm.body { collectCalls(item, into: &names) }
            }
        case .returnStmt(let value, _):
            if let value { collectCalls(value, into: &names) }
        case .throwStmt(let value, _):
            collectCalls(value, into: &names)
        case .tryStmt(let body, let catches, let finallyBody, _):
            for item in body { collectCalls(item, into: &names) }
            for clause in catches {
                for item in clause.body { collectCalls(item, into: &names) }
            }
            for item in finallyBody ?? [] { collectCalls(item, into: &names) }
        case .block(let body, _), .group(let body, _):
            for item in body { collectCalls(item, into: &names) }
        case .guardStmt(let condition, let elseBody, _):
            collectCalls(condition, into: &names)
            for item in elseBody { collectCalls(item, into: &names) }
        case .funcDecl(let decl):
            for clause in decl.clauses {
                for item in clause.body { collectCalls(item, into: &names) }
            }
        case .typeDecl, .breakStmt, .continueStmt, .noop:
            return
        }
    }

    /// 式の中の呼び出し先の名前を集める。
    static func collectCalls(_ expression: MLExpr, into names: inout [String]) {
        switch expression {
        case .call(let callee, let arguments, _):
            switch callee {
            case .name(let name, _): names.append(name)
            case .member(_, let name, _, _): names.append(name)
            default: collectCalls(callee, into: &names)
            }
            for argument in arguments { collectCalls(argument.value, into: &names) }
        case .construct(let typeName, let arguments, _):
            names.append(typeName)
            for argument in arguments { collectCalls(argument.value, into: &names) }
        case .binary(_, let lhs, let rhs, _):
            collectCalls(lhs, into: &names)
            collectCalls(rhs, into: &names)
        case .unary(_, let operand, _, _):
            collectCalls(operand, into: &names)
        case .assign(_, let target, let value, _):
            collectCalls(target, into: &names)
            collectCalls(value, into: &names)
        case .ternary(let condition, let then, let otherwise, _):
            collectCalls(condition, into: &names)
            collectCalls(then, into: &names)
            collectCalls(otherwise, into: &names)
        case .member(let object, _, _, _):
            collectCalls(object, into: &names)
        case .subscriptExpr(let object, let index, let upper, _):
            collectCalls(object, into: &names)
            collectCalls(index, into: &names)
            if let upper { collectCalls(upper, into: &names) }
        case .listLiteral(let items, _, _), .tupleLiteral(let items, _),
             .interpolation(let items, _):
            for item in items { collectCalls(item, into: &names) }
        case .mapLiteral(let pairs, _):
            for pair in pairs {
                collectCalls(pair.key, into: &names)
                collectCalls(pair.value, into: &names)
            }
        case .lambda(let decl, _):
            for clause in decl.clauses {
                for item in clause.body { collectCalls(item, into: &names) }
            }
        case .block(let body, _):
            for item in body { collectCalls(item, into: &names) }
        case .ifExpr(let condition, let then, let otherwise, _):
            collectCalls(condition, into: &names)
            collectCalls(then, into: &names)
            if let otherwise { collectCalls(otherwise, into: &names) }
        case .match(let subject, let arms, _):
            collectCalls(subject, into: &names)
            for arm in arms {
                for item in arm.body { collectCalls(item, into: &names) }
            }
        case .cast(let value, _, _, _), .typeTest(let value, _, _),
             .forceUnwrap(let value, _), .lazy(let value, _),
             .reference(let value, _), .dereference(let value, _):
            collectCalls(value, into: &names)
        default:
            return
        }
    }
}

// MARK: - 152. データ構造の可視化

/// 値をほどいて見せるための節。
public struct ValueNode: Identifiable, Equatable, Sendable {
    public var id: Int
    /// キーや添字 (根なら空)。
    public var label: String
    /// 値の見た目。
    public var text: String
    public var typeName: String
    public var children: [ValueNode]

    public init(id: Int = 0, label: String = "", text: String, typeName: String,
                children: [ValueNode] = []) {
        self.id = id
        self.label = label
        self.text = text
        self.typeName = typeName
        self.children = children
    }

    public var isLeaf: Bool { children.isEmpty }

    public var title: String {
        label.isEmpty ? text : "\(label): \(text)"
    }

    public func outline(indent: Int = 0) -> String {
        var lines = [String(repeating: "  ", count: indent) + title]
        for child in children { lines.append(child.outline(indent: indent + 1)) }
        return lines.joined(separator: "\n")
    }
}

/// 配列や辞書を、たたんで見せられる木に直す。
public enum ValueInspector {

    /// 値を木にほどく。
    ///
    /// `maximumDepth` は開く段数。それより深いところは「…」の 1 節にまとめるので、
    /// 木の深さは最大で `maximumDepth + 1` になる。
    public static func node(for value: MLValue, label: String = "",
                            depth: Int = 0, maximumDepth: Int = 6,
                            maximumChildren: Int = 200) -> ValueNode {
        var counter = 0
        return build(value, label: label, depth: depth, maximumDepth: maximumDepth,
                     maximumChildren: maximumChildren, counter: &counter)
    }

    private static func build(_ value: MLValue, label: String, depth: Int,
                              maximumDepth: Int, maximumChildren: Int,
                              counter: inout Int) -> ValueNode {
        counter += 1
        let identifier = counter
        let typeName = name(of: value)

        guard depth < maximumDepth else {
            return ValueNode(id: identifier, label: label, text: "…",
                             typeName: typeName)
        }

        switch value.forced {
        case .array(let array):
            let items = array.elements.prefix(maximumChildren)
            var children = items.enumerated().map { index, element in
                build(element, label: "[\(index)]", depth: depth + 1,
                      maximumDepth: maximumDepth, maximumChildren: maximumChildren,
                      counter: &counter)
            }
            if array.elements.count > maximumChildren {
                counter += 1
                children.append(ValueNode(id: counter, label: "",
                                          text: "… ほか \(array.elements.count - maximumChildren) 個",
                                          typeName: ""))
            }
            return ValueNode(id: identifier, label: label,
                             text: "配列 (\(array.elements.count) 個)",
                             typeName: typeName, children: children)

        case .map(let map):
            let keys = map.keys.prefix(maximumChildren)
            let children = keys.map { key in
                build(map[key] ?? .unit, label: MLDisplay.plain(key.asValue),
                      depth: depth + 1, maximumDepth: maximumDepth,
                      maximumChildren: maximumChildren, counter: &counter)
            }
            return ValueNode(id: identifier, label: label,
                             text: "辞書 (\(map.keys.count) 組)",
                             typeName: typeName, children: children)

        case .tuple(let items):
            let children = items.prefix(maximumChildren).enumerated().map { index, item in
                build(item, label: ".\(index)", depth: depth + 1,
                      maximumDepth: maximumDepth, maximumChildren: maximumChildren,
                      counter: &counter)
            }
            return ValueNode(id: identifier, label: label,
                             text: "組 (\(items.count) 個)", typeName: typeName,
                             children: children)

        case .object(let object):
            var children = object.fields.keys.prefix(maximumChildren).map { key in
                build(object.fields[key] ?? .unit, label: MLDisplay.plain(key.asValue),
                      depth: depth + 1, maximumDepth: maximumDepth,
                      maximumChildren: maximumChildren, counter: &counter)
            }
            children += object.payload.prefix(maximumChildren).enumerated()
                .map { index, item in
                    build(item, label: "[\(index)]", depth: depth + 1,
                          maximumDepth: maximumDepth, maximumChildren: maximumChildren,
                          counter: &counter)
                }
            let title = object.caseName ?? object.typeName
            return ValueNode(id: identifier, label: label, text: title,
                             typeName: typeName, children: children)

        default:
            return ValueNode(id: identifier, label: label,
                             text: MLDisplay.plain(value), typeName: typeName)
        }
    }

    static func name(of value: MLValue) -> String {
        switch value.forced {
        case .int: return "整数"
        case .double: return "小数"
        case .string: return "文字列"
        case .bool: return "真偽"
        case .char: return "文字"
        case .array: return "配列"
        case .map: return "辞書"
        case .tuple: return "組"
        case .object(let object): return object.typeName
        case .function: return "関数"
        case .range: return "範囲"
        case .symbol: return "シンボル"
        case .unit: return "値なし"
        default: return "値"
        }
    }
}

// MARK: - 153. アルゴリズムのステップ可視化

/// ある変数が、実行のあいだにどう変わったか。
public struct ValueTimeline: Equatable, Sendable {
    public var name: String
    /// (歩数, そのときの見た目)。
    public var points: [(step: Int, value: String)]

    public init(name: String, points: [(step: Int, value: String)]) {
        self.name = name
        self.points = points
    }

    public static func == (lhs: ValueTimeline, rhs: ValueTimeline) -> Bool {
        lhs.name == rhs.name
            && lhs.points.count == rhs.points.count
            && zip(lhs.points, rhs.points).allSatisfy { $0.step == $1.step && $0.value == $1.value }
    }

    public var changeCount: Int { points.count }
}

/// 配列が並び替わっていく様子など、途中経過を取り出す。
public enum AlgorithmTrace {

    /// 記録から、変数ごとの移り変わりを作る。
    public static func timelines(from debugger: Debugger,
                                 names: [String]) -> [ValueTimeline] {
        names.map { name in
            ValueTimeline(name: name, points: debugger.history(of: name))
        }
    }

    /// 配列の中身を数の並びとして取り出す (棒グラフ用)。
    public static func numbers(from text: String) -> [Double]? {
        var body = text.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("["), body.hasSuffix("]") else { return nil }
        body.removeFirst()
        body.removeLast()
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let parts = body.components(separatedBy: ",")
        var values: [Double] = []
        for part in parts {
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            values.append(value)
        }
        return values
    }

    /// 並びの移り変わりを、コマ送りにする。
    public static func frames(of timeline: ValueTimeline) -> [[Double]] {
        timeline.points.compactMap { numbers(from: $0.value) }
    }
}

// MARK: - 154. 数値出力のグラフ化

/// グラフにする数の並び。
public struct NumberSeries: Identifiable, Equatable, Sendable {
    public var name: String
    public var values: [Double]

    public var id: String { name }

    public init(name: String, values: [Double]) {
        self.name = name
        self.values = values
    }

    public var minimum: Double { values.min() ?? 0 }
    public var maximum: Double { values.max() ?? 0 }
    public var total: Double { values.reduce(0, +) }
    public var average: Double { values.isEmpty ? 0 : total / Double(values.count) }

    /// 0〜1 に直した値 (棒の高さに使う)。
    public var normalized: [Double] {
        let low = minimum
        let span = maximum - low
        guard span > 0 else { return values.map { _ in 0.5 } }
        return values.map { ($0 - low) / span }
    }
}

/// 出力の中から数を拾ってグラフにする。
public enum OutputCharting {

    /// 1 行に 1 つ数が並んでいるとき。
    public static func series(from output: String,
                              name: String = "出力") -> NumberSeries? {
        var values: [Double] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let value = Double(trimmed) else { return nil }
            values.append(value)
        }
        guard !values.isEmpty else { return nil }
        return NumberSeries(name: name, values: values)
    }

    /// 「名前: 数」や CSV のように、列で並んでいるとき。
    public static func columns(from output: String) -> [NumberSeries] {
        var byName: [String: [Double]] = [:]
        var order: [String] = []
        var unnamed: [[Double]] = []

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let separator = trimmed.range(of: ":") ?? trimmed.range(of: "=") {
                let name = String(trimmed[trimmed.startIndex..<separator.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let rest = String(trimmed[separator.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if let value = Double(rest), !name.isEmpty {
                    if byName[name] == nil { order.append(name) }
                    byName[name, default: []].append(value)
                    continue
                }
            }

            let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: ",\t "))
                .filter { !$0.isEmpty }
            let numbers = parts.compactMap { Double($0) }
            if numbers.count == parts.count, !numbers.isEmpty {
                unnamed.append(numbers)
            }
        }

        var result = order.map { NumberSeries(name: $0, values: byName[$0] ?? []) }

        // 行ごとに同じ個数の数が並んでいれば、列ごとの並びとして扱う。
        if !unnamed.isEmpty, let width = unnamed.first?.count,
           unnamed.allSatisfy({ $0.count == width }) {
            for column in 0..<width {
                result.append(NumberSeries(name: width == 1 ? "値" : "列 \(column + 1)",
                                           values: unnamed.map { $0[column] }))
            }
        }
        return result
    }

    /// 文字だけで折れ線を描く (等幅で見る用)。
    public static func sparkline(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "" }
        let marks = Array("▁▂▃▄▅▆▇█")
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let span = high - low
        return String(values.map { value -> Character in
            guard span > 0 else { return marks[marks.count / 2] }
            let index = Int(((value - low) / span) * Double(marks.count - 1))
            return marks[Swift.max(0, Swift.min(marks.count - 1, index))]
        })
    }
}
