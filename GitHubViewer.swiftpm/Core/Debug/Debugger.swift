import Foundation

// MARK: - 134. コールスタック

/// コールスタックの 1 段。
public struct StackFrame: Identifiable, Equatable, Sendable {
    public var id: Int
    /// 関数名 (大域なら "(大域)")。
    public var functionName: String
    /// 呼ばれた場所。
    public var line: Int
    public var column: Int
    /// その関数の中で、いま実行している行。
    public var currentLine: Int

    public init(id: Int, functionName: String, line: Int, column: Int,
                currentLine: Int) {
        self.id = id
        self.functionName = functionName
        self.line = line
        self.column = column
        self.currentLine = currentLine
    }

    /// 「main (12 行目)」。
    public var description: String { "\(functionName) (\(currentLine) 行目)" }
}

// MARK: - 144. 例外のスタックトレース

/// エラーが起きたときの様子。
public struct ErrorStackTrace: Equatable, Sendable {
    public var message: String
    /// エラーが出た行。
    public var line: Int
    /// そこまでの呼び出し (外側から内側の順)。
    public var frames: [StackFrame]

    public init(message: String, line: Int, frames: [StackFrame]) {
        self.message = message
        self.line = line
        self.frames = frames
    }

    /// 人に見せる形。
    ///
    /// ```
    /// エラー: 0 で割りました (12 行目)
    ///   divide (12 行目)
    ///   main (4 行目)
    /// ```
    public var description: String {
        var lines = ["エラー: \(message) (\(line) 行目)"]
        for frame in frames.reversed() {
            lines.append("  \(frame.functionName) (\(frame.currentLine) 行目)")
        }
        if frames.isEmpty { lines.append("  (大域) (\(line) 行目)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 133. 変数のウォッチ

/// ある時点で見えている変数 1 つ。
public struct WatchedVariable: Identifiable, Equatable, Sendable {
    public var name: String
    /// 見せるための文字列。
    public var displayValue: String
    /// 型の名前 (150. 推論型の表示)。
    public var typeName: String
    /// 大域か、その関数の中か。
    public var isGlobal: Bool

    public var id: String { name }

    public init(name: String, displayValue: String, typeName: String,
                isGlobal: Bool = false) {
        self.name = name
        self.displayValue = displayValue
        self.typeName = typeName
        self.isGlobal = isGlobal
    }
}

// MARK: - 136 / 143. トレースとタイムトラベル

/// 実行の 1 歩ぶんの記録。
public struct TraceStep: Identifiable, Equatable, Sendable {
    public var id: Int
    public var line: Int
    public var column: Int
    /// 何段目の呼び出しか。
    public var depth: Int
    /// そのときの関数名。
    public var functionName: String
    /// そのとき見えていた変数 (タイムトラベル用)。
    public var variables: [WatchedVariable]

    public init(id: Int, line: Int, column: Int, depth: Int, functionName: String,
                variables: [WatchedVariable] = []) {
        self.id = id
        self.line = line
        self.column = column
        self.depth = depth
        self.functionName = functionName
        self.variables = variables
    }

    public func variable(named name: String) -> WatchedVariable? {
        variables.first { $0.name == name }
    }
}

// MARK: - 131 / 132. ブレークポイントとステップ実行

/// 止まったあと、次にどうするか。
public enum DebugAction: Equatable, Sendable {
    /// そのまま続ける。
    case resume
    /// 次の 1 行まで進む (関数の中には入らない)。
    case stepOver
    /// 次の 1 歩まで進む (関数の中にも入る)。
    case stepInto
    /// いまの関数を抜けるまで進む。
    case stepOut
    /// 実行をやめる。
    case stop
}

/// なぜ止まったか。
public enum PauseReason: Equatable, Sendable {
    case breakpoint(line: Int)
    case step
    case entry
    case error(String)

    public var description: String {
        switch self {
        case .breakpoint(let line): return "\(line) 行目のブレークポイント"
        case .step: return "ステップ実行"
        case .entry: return "実行の始まり"
        case .error(let message): return "エラー: \(message)"
        }
    }
}

/// 止まったときに渡される、その場の様子。
public struct DebugSnapshot: Equatable, Sendable {
    public var reason: PauseReason
    public var line: Int
    public var column: Int
    public var callStack: [StackFrame]
    public var variables: [WatchedVariable]
    public var stepCount: Int

    public init(reason: PauseReason, line: Int, column: Int,
                callStack: [StackFrame] = [], variables: [WatchedVariable] = [],
                stepCount: Int = 0) {
        self.reason = reason
        self.line = line
        self.column = column
        self.callStack = callStack
        self.variables = variables
        self.stepCount = stepCount
    }
}

/// デバッグの設定と記録。
///
/// `MiniLangLimits.debugger` に載せると、処理系が 1 文ごとに知らせてくる。
public final class Debugger: @unchecked Sendable {
    private let lock = NSLock()

    /// 止まりたい行 (1 から数える)。
    private var breakpoints: Set<Int> = []
    /// 行ごとの実行回数 (137. ヒートマップ)。
    private var hitCounts: [Int: Int] = [:]
    /// 実行の記録 (136 / 143)。
    private var trace: [TraceStep] = []
    /// 記録する歩数の上限。
    public let traceLimit: Int
    /// トレースに変数まで残すか (タイムトラベル用。重いので既定は false)。
    public var recordsVariables: Bool
    /// 最初の 1 文で止まるか。
    public var pausesAtEntry: Bool
    /// 見張る変数の名前。空なら見えているもの全部。
    public var watchedNames: Set<String> = []

    /// 止まったときに呼ばれる。返した値のとおりに進む。
    ///
    /// 実行スレッドから呼ばれるので、画面を触るときは主スレッドに渡すこと。
    public var onPause: ((DebugSnapshot) -> DebugAction)?

    /// いま何をしている途中か。
    private enum Mode {
        case running
        case stepping(fromDepth: Int, overOnly: Bool)
        case steppingOut(fromDepth: Int)
    }
    private var mode: Mode = .running
    private var stopped = false
    private var lastLine = -1

    public init(breakpoints: Set<Int> = [], traceLimit: Int = 100_000,
                recordsVariables: Bool = false, pausesAtEntry: Bool = false) {
        self.breakpoints = breakpoints
        self.traceLimit = traceLimit
        self.recordsVariables = recordsVariables
        self.pausesAtEntry = pausesAtEntry
    }

    // MARK: - 131. ブレークポイント

    public func addBreakpoint(line: Int) {
        lock.lock()
        breakpoints.insert(line)
        lock.unlock()
    }

    public func removeBreakpoint(line: Int) {
        lock.lock()
        breakpoints.remove(line)
        lock.unlock()
    }

    @discardableResult
    public func toggleBreakpoint(line: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if breakpoints.contains(line) {
            breakpoints.remove(line)
            return false
        }
        breakpoints.insert(line)
        return true
    }

    public var breakpointLines: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return breakpoints.sorted()
    }

    public func clearBreakpoints() {
        lock.lock()
        breakpoints.removeAll()
        lock.unlock()
    }

    // MARK: - 137. ヒートマップ

    /// 行ごとの実行回数。
    public var lineHitCounts: [Int: Int] {
        lock.lock()
        defer { lock.unlock() }
        return hitCounts
    }

    /// いちばん多く通った回数。
    public var maximumHitCount: Int {
        lineHitCounts.values.max() ?? 0
    }

    /// 0〜1 に直した濃さ (色の濃さに使う)。
    public func heat(forLine line: Int) -> Double {
        let counts = lineHitCounts
        guard let maximum = counts.values.max(), maximum > 0,
              let count = counts[line] else { return 0 }
        return Double(count) / Double(maximum)
    }

    // MARK: - 136. トレース

    public var steps: [TraceStep] {
        lock.lock()
        defer { lock.unlock() }
        return trace
    }

    /// 通った行の並び。
    public var visitedLines: [Int] { steps.map(\.line) }

    /// 143. その時点の様子に戻る。
    public func snapshot(atStep index: Int) -> TraceStep? {
        let all = steps
        guard index >= 0, index < all.count else { return nil }
        return all[index]
    }

    /// ある変数が変わっていった様子。
    public func history(of name: String) -> [(step: Int, value: String)] {
        var result: [(Int, String)] = []
        var previous: String?
        for step in steps {
            guard let variable = step.variable(named: name) else { continue }
            if variable.displayValue != previous {
                result.append((step.id, variable.displayValue))
                previous = variable.displayValue
            }
        }
        return result
    }

    public func reset() {
        lock.lock()
        hitCounts.removeAll()
        trace.removeAll()
        mode = .running
        stopped = false
        lastLine = -1
        lock.unlock()
    }

    // MARK: - 処理系からの呼び出し

    /// 1 文を実行する直前に呼ばれる。
    ///
    /// 戻り値が false なら、実行をやめる。
    func willExecute(line: Int, column: Int, depth: Int, functionName: String,
                     variables: @autoclosure () -> [WatchedVariable],
                     stack: @autoclosure () -> [StackFrame],
                     stepCount: Int) -> Bool {
        lock.lock()
        if stopped {
            lock.unlock()
            return false
        }
        // 同じ行を何度も数えないよう、行が変わったときだけ数える。
        if line > 0 { hitCounts[line, default: 0] += 1 }

        let shouldRecord = trace.count < traceLimit
        let needsVariables = recordsVariables && shouldRecord
        let breakpointHit = breakpoints.contains(line) && line != lastLine
        let currentMode = mode
        lock.unlock()

        var captured: [WatchedVariable] = []
        if needsVariables { captured = filter(variables()) }

        if shouldRecord {
            lock.lock()
            trace.append(TraceStep(id: trace.count, line: line, column: column,
                                   depth: depth, functionName: functionName,
                                   variables: captured))
            lock.unlock()
        }

        // 止まる理由を決める。
        var reason: PauseReason?
        if breakpointHit {
            reason = .breakpoint(line: line)
        } else {
            switch currentMode {
            case .running:
                lock.lock()
                let atEntry = pausesAtEntry && trace.count <= 1
                lock.unlock()
                if atEntry { reason = .entry }
            case .stepping(let fromDepth, let overOnly):
                if overOnly {
                    if depth <= fromDepth, line != lastLine { reason = .step }
                } else if line != lastLine || depth != fromDepth {
                    reason = .step
                }
            case .steppingOut(let fromDepth):
                if depth < fromDepth { reason = .step }
            }
        }

        lock.lock()
        lastLine = line
        lock.unlock()

        guard let reason, let onPause else { return true }

        let snapshot = DebugSnapshot(reason: reason, line: line, column: column,
                                     callStack: stack(),
                                     variables: filter(variables()),
                                     stepCount: stepCount)
        let action = onPause(snapshot)

        lock.lock()
        switch action {
        case .resume: mode = .running
        case .stepOver: mode = .stepping(fromDepth: depth, overOnly: true)
        case .stepInto: mode = .stepping(fromDepth: depth, overOnly: false)
        case .stepOut: mode = .steppingOut(fromDepth: depth)
        case .stop:
            stopped = true
            lock.unlock()
            return false
        }
        lock.unlock()
        return true
    }

    // MARK: - 155. 式を選んで値を見る

    /// 止まっている場所で式を評価する。
    ///
    /// 処理系が `onPause` を呼んでいるあいだだけ使える。
    /// それ以外のときは nil。
    public var evaluator: ((String) -> ExpressionValue?)?

    /// いま止まっている場所で式を評価する。
    public func evaluate(_ expression: String) -> ExpressionValue? {
        evaluator?(expression)
    }

    /// 見張る名前を決めてあれば、そこだけに絞る。
    private func filter(_ variables: [WatchedVariable]) -> [WatchedVariable] {
        lock.lock()
        let names = watchedNames
        lock.unlock()
        guard !names.isEmpty else { return variables }
        return variables.filter { names.contains($0.name) }
    }
}

/// 式を評価した結果。
public struct ExpressionValue: Equatable, Sendable {
    /// 評価できたときの見た目。
    public var text: String
    public var typeName: String
    /// 評価できなかったときの理由。
    public var failureText: String?
    /// 値としてほどいたもの (配列や辞書を開いて見せる用)。
    public var node: ValueNode?

    public init(text: String, typeName: String = "", failureText: String? = nil,
                node: ValueNode? = nil) {
        self.text = text
        self.typeName = typeName
        self.failureText = failureText
        self.node = node
    }

    public var succeeded: Bool { failureText == nil }

    public static func failure(_ message: String) -> ExpressionValue {
        ExpressionValue(text: "", failureText: message)
    }
}

// MARK: - 149. 実行時の警告

/// 実行中に気づいたこと。
public struct RuntimeWarning: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// 0 で割った。
        case divisionByZero
        /// 数に直せない文字列を数として使った。
        case badNumberConversion
        /// 大きすぎて桁があふれた。
        case overflow
        /// 使われていない変数。
        case unusedVariable
        /// 深い再帰。
        case deepRecursion
        case other
    }

    public var id: UUID
    public var kind: Kind
    public var message: String
    public var line: Int

    public init(id: UUID = UUID(), kind: Kind, message: String, line: Int = 0) {
        self.id = id
        self.kind = kind
        self.message = message
        self.line = line
    }
}

/// 実行中の警告をためる。
public final class WarningCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var warnings: [RuntimeWarning] = []
    public let limit: Int

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public func add(_ warning: RuntimeWarning) {
        lock.lock()
        // 同じ場所の同じ警告は 1 度だけ。
        if !warnings.contains(where: { $0.kind == warning.kind
            && $0.line == warning.line && $0.message == warning.message }),
           warnings.count < limit {
            warnings.append(warning)
        }
        lock.unlock()
    }

    public func add(_ kind: RuntimeWarning.Kind, _ message: String, line: Int = 0) {
        add(RuntimeWarning(kind: kind, message: message, line: line))
    }

    public var all: [RuntimeWarning] {
        lock.lock()
        defer { lock.unlock() }
        return warnings
    }

    public func clear() {
        lock.lock()
        warnings.removeAll()
        lock.unlock()
    }
}
