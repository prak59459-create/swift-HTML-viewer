import Foundation

/// 内蔵の処理系 (コンパイラ / インタプリタ) が共通で返す実行結果。
public struct MiniLangExecution: Equatable, Sendable {
    /// 構文解析まで通ったか。
    public var parsed: Bool
    /// 構文エラーを整形した文字列 (問題がなければ空)。
    public var diagnosticsText: String
    public var errorCount: Int
    /// 標準出力。
    public var output: String
    /// 実行時エラー (正常なら nil)。
    public var runtimeError: String?
    public var exitCode: Int32
    /// 実行したステップ数。
    public var steps: Int
    /// かかった時間 (秒)。`RunSession` が測って入れる。
    public var duration: TimeInterval
    /// おおよそのメモリ使用量 (バイト)。
    public var approximateMemoryBytes: Int
    /// 途中で止められたか。
    public var wasCancelled: Bool
    /// 時間切れになったか。
    public var timedOut: Bool
    /// エラーが出たときの呼び出しの積み重ね。
    public var errorStack: ErrorStackTrace?
    /// 実行中に気づいたこと。
    public var warnings: [RuntimeWarning]

    public init(parsed: Bool, diagnosticsText: String = "", errorCount: Int = 0,
                output: String = "", runtimeError: String? = nil, exitCode: Int32 = 0,
                steps: Int = 0, duration: TimeInterval = 0,
                approximateMemoryBytes: Int = 0, wasCancelled: Bool = false,
                timedOut: Bool = false, errorStack: ErrorStackTrace? = nil,
                warnings: [RuntimeWarning] = []) {
        self.parsed = parsed
        self.diagnosticsText = diagnosticsText
        self.errorCount = errorCount
        self.output = output
        self.runtimeError = runtimeError
        self.exitCode = exitCode
        self.steps = steps
        self.duration = duration
        self.approximateMemoryBytes = approximateMemoryBytes
        self.wasCancelled = wasCancelled
        self.timedOut = timedOut
        self.errorStack = errorStack
        self.warnings = warnings
    }

    public var succeeded: Bool { parsed && runtimeError == nil }

    /// 構文エラーだけの結果を作る。
    public static func syntaxError(_ failure: CompileFailure) -> MiniLangExecution {
        let errors = failure.diagnostics.filter { $0.severity == .error }
        return MiniLangExecution(parsed: false, diagnosticsText: failure.formatted,
                                 errorCount: errors.count, exitCode: 1)
    }
}

/// 実行を途中で止めるための合図。別のスレッドから `cancel()` を呼ぶ。
public final class RunCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    public func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        flag = false
        lock.unlock()
    }
}

/// 実行時の上限 (無限ループなどでアプリが固まらないようにする) と、実行の設定。
public struct MiniLangLimits {
    public var maximumSteps: Int
    public var maximumOutputBytes: Int
    public var maximumCallDepth: Int
    /// 実際の時間の上限 (秒)。nil なら見ない。
    public var timeLimit: TimeInterval?
    /// コマンドライン引数 (argv[1] 以降)。
    public var arguments: [String]
    /// argv[0] にあたる名前。
    public var programName: String
    /// 乱数の種。決めておくと毎回同じ結果になる。
    public var randomSeed: UInt64?
    /// 途中で止めるための合図。
    public var cancellation: RunCancellation?
    /// プログラムから読み書きできる仮想のファイル。
    public var fileSystem: VirtualFileSystem?
    /// 構文を調べるだけで、実行はしない。
    public var parseOnly: Bool
    /// 対話的に動かすときの割り込み口 (出力の途中経過と、追加の入力)。
    public var hooks: InteractiveHooks?
    /// デバッグの設定と記録。付けると 1 文ごとに知らせが飛ぶ。
    public var debugger: Debugger?
    /// 実行中に気づいたことをためる先。
    public var warnings: WarningCollector?

    public init(maximumSteps: Int = 5_000_000,
                maximumOutputBytes: Int = 1 << 20,
                maximumCallDepth: Int = 400,
                timeLimit: TimeInterval? = nil,
                arguments: [String] = [],
                programName: String = "program",
                randomSeed: UInt64? = nil,
                cancellation: RunCancellation? = nil,
                fileSystem: VirtualFileSystem? = nil,
                parseOnly: Bool = false,
                hooks: InteractiveHooks? = nil,
                debugger: Debugger? = nil,
                warnings: WarningCollector? = nil) {
        self.maximumSteps = maximumSteps
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumCallDepth = maximumCallDepth
        self.timeLimit = timeLimit
        self.arguments = arguments
        self.programName = programName
        self.randomSeed = randomSeed
        self.cancellation = cancellation
        self.fileSystem = fileSystem
        self.parseOnly = parseOnly
        self.hooks = hooks
        self.debugger = debugger
        self.warnings = warnings
    }

    public static let `default` = MiniLangLimits()

    /// argv の全体 (プログラム名を含む)。
    public var argv: [String] { [programName] + arguments }
}

/// 内蔵処理系が満たす約束。アプリ側はこれだけを見て実行する。
public protocol MiniLangEngine {
    /// `LanguageCatalog` の言語 ID と合わせる ("go", "rust" など)。
    static var languageID: String { get }
    /// 表示名 ("内蔵 Go インタプリタ" など)。
    static var displayName: String { get }
    static func execute(source: String, input: String, limits: MiniLangLimits) -> MiniLangExecution
    /// 構文木だけを組み立てる (実行はしない)。対応していなければ投げる。
    static func parse(source: String, diagnostics: DiagnosticBag) throws -> MLProgram
}

public extension MiniLangEngine {
    static func execute(source: String) -> MiniLangExecution {
        execute(source: source, input: "", limits: .default)
    }

    /// 構文木を組み立てられない処理系のための既定。
    static func parse(source: String, diagnostics: DiagnosticBag) throws -> MLProgram {
        throw ParseUnavailable(languageID: languageID)
    }
}

/// その処理系では構文木を取り出せないときのエラー。
public struct ParseUnavailable: LocalizedError, Equatable {
    public var languageID: String

    public init(languageID: String) {
        self.languageID = languageID
    }

    public var errorDescription: String? {
        "\(languageID) は構文木の取り出しに対応していません。"
    }
}

/// 深い再帰でも落ちないよう、スタックを大きく取った専用スレッドで実行する。
public enum MiniLangRunner {
    public static func run(_ body: @escaping () -> MiniLangExecution) -> MiniLangExecution {
        var result = MiniLangExecution(parsed: false)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = body()
            finished.signal()
        }
        thread.stackSize = 32 << 20
        thread.start()
        finished.wait()
        return result
    }
}

/// 出力をためる小さな入れ物 (上限つき)。
public final class MiniLangOutput {
    private var buffer = Data()
    private var overflowed = false
    private let limit: Int
    /// 書かれるたびに呼ばれる (途中経過を見せるため)。
    ///
    /// 実行しているスレッドから呼ばれるので、画面を触るときは主スレッドに渡すこと。
    public var onWrite: ((String) -> Void)?

    public init(limit: Int) {
        self.limit = limit
    }

    public func write(_ text: String) {
        guard !overflowed else { return }
        let bytes = Data(text.utf8)
        if buffer.count + bytes.count > limit {
            let kept = bytes.prefix(max(0, limit - buffer.count))
            buffer.append(kept)
            overflowed = true
            if !kept.isEmpty { onWrite?(String(decoding: kept, as: UTF8.self)) }
            return
        }
        buffer.append(bytes)
        onWrite?(text)
    }

    public var text: String {
        var value = String(decoding: buffer, as: UTF8.self)
        if overflowed { value += "\n…出力が上限に達したので打ち切りました。" }
        return value
    }

    /// ためこんだバイト数。
    public var byteCount: Int { buffer.count }

    /// 上限に達して打ち切ったか。
    public var didOverflow: Bool { overflowed }
}

/// 標準入力を 1 行ずつ渡す。
public final class MiniLangInput {
    private var lines: [String]
    private var index = 0
    private var raw: [Character]
    private var characterIndex = 0
    /// 用意した入力を使い切ったときに、その場で足してもらう相手。
    ///
    /// 対話的に動かすときに使う。nil を返したら入力の終わり。
    public var provider: (() -> String?)?

    public init(_ text: String) {
        self.raw = Array(text)
        self.lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// 改行を含まない 1 行。無ければ nil。
    public func nextLine() -> String? {
        if index >= lines.count, !requestMore() { return nil }
        guard index < lines.count else { return nil }
        defer { index += 1 }
        return lines[index]
    }

    /// 1 文字。無ければ nil。
    public func nextCharacter() -> Character? {
        if characterIndex >= raw.count, !requestMore() { return nil }
        guard characterIndex < raw.count else { return nil }
        defer { characterIndex += 1 }
        return raw[characterIndex]
    }

    public var remainingText: String {
        characterIndex < raw.count ? String(raw[characterIndex...]) : ""
    }

    /// 入力がまだあるか。
    public var hasMoreLines: Bool { index < lines.count }

    /// 足してもらう。足せたら true。
    @discardableResult
    private func requestMore() -> Bool {
        guard let provider, let more = provider() else { return false }
        let text = more.hasSuffix("\n") ? more : more + "\n"
        raw.append(contentsOf: Array(text))
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        // 1 行目は、まだ読み終えていない最後の行につなぐのではなく新しい行にする。
        lines.append(contentsOf: parts)
        return true
    }

    /// あとから入力を足す (対話的な実行で使う)。
    public func append(_ text: String) {
        let value = text.hasSuffix("\n") ? text : text + "\n"
        raw.append(contentsOf: Array(value))
        var parts = value.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        lines.append(contentsOf: parts)
    }
}
