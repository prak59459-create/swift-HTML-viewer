import Foundation

/// 1 回の実行に使う設定。
public struct RunOptions: Equatable, Sendable {
    /// コマンドライン引数 (argv[1] 以降)。
    public var arguments: [String]
    /// argv[0] にあたる名前。
    public var programName: String
    /// 標準入力。
    public var input: String
    /// 乱数の種。決めておくと毎回同じ結果になる。
    public var randomSeed: UInt64?
    /// 実際の時間の上限 (秒)。nil なら見ない。
    public var timeLimit: TimeInterval?
    public var maximumSteps: Int
    public var maximumOutputBytes: Int
    public var maximumCallDepth: Int
    /// 最初から置いておく仮想ファイル。
    public var files: [String: String]

    public init(arguments: [String] = [], programName: String = "program",
                input: String = "", randomSeed: UInt64? = nil,
                timeLimit: TimeInterval? = 10,
                maximumSteps: Int = 5_000_000,
                maximumOutputBytes: Int = 1 << 20,
                maximumCallDepth: Int = 400,
                files: [String: String] = [:]) {
        self.arguments = arguments
        self.programName = programName
        self.input = input
        self.randomSeed = randomSeed
        self.timeLimit = timeLimit
        self.maximumSteps = maximumSteps
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumCallDepth = maximumCallDepth
        self.files = files
    }

    public static let `default` = RunOptions()

    /// 処理系に渡す形に直す。
    public func makeLimits(cancellation: RunCancellation? = nil,
                           fileSystem: VirtualFileSystem? = nil,
                           parseOnly: Bool = false,
                           debugger: Debugger? = nil,
                           warnings: WarningCollector? = nil) -> MiniLangLimits {
        MiniLangLimits(maximumSteps: maximumSteps,
                       maximumOutputBytes: maximumOutputBytes,
                       maximumCallDepth: maximumCallDepth,
                       timeLimit: timeLimit,
                       arguments: arguments,
                       programName: programName,
                       randomSeed: randomSeed,
                       cancellation: cancellation,
                       fileSystem: fileSystem ?? VirtualFileSystem(files: files),
                       parseOnly: parseOnly,
                       debugger: debugger,
                       warnings: warnings ?? WarningCollector())
    }
}

/// 1 回の実行の結果。
public struct RunResult: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var languageID: String
    /// どの処理系が動いたか (「内蔵 Go 処理系」など)。
    public var engineName: String
    public var execution: MiniLangExecution
    public var startedAt: Date
    /// 実行が終わったあとの仮想ファイルの中身。
    public var files: [String: String]

    public init(id: UUID = UUID(), languageID: String, engineName: String,
                execution: MiniLangExecution, startedAt: Date = Date(),
                files: [String: String] = [:]) {
        self.id = id
        self.languageID = languageID
        self.engineName = engineName
        self.execution = execution
        self.startedAt = startedAt
        self.files = files
    }

    public var output: String { execution.output }
    public var exitCode: Int32 { execution.exitCode }
    public var duration: TimeInterval { execution.duration }
    public var steps: Int { execution.steps }
    public var succeeded: Bool { execution.succeeded && execution.exitCode == 0 }

    /// 失敗の理由 (構文エラー / 実行時エラー)。問題がなければ nil。
    public var failureText: String? {
        if !execution.parsed { return execution.diagnosticsText }
        return execution.runtimeError
    }

    /// 「0.12 秒 / 4,821 ステップ / 終了コード 0」のような 1 行。
    public var statusLine: String {
        var parts = [RunFormatting.duration(duration),
                     "\(RunFormatting.number(steps)) ステップ"]
        if execution.approximateMemoryBytes > 0 {
            parts.append(RunFormatting.bytes(execution.approximateMemoryBytes))
        }
        parts.append("終了コード \(exitCode)")
        if execution.timedOut { parts.append("時間切れ") }
        if execution.wasCancelled { parts.append("中断") }
        return parts.joined(separator: " / ")
    }
}

/// 数や時間の見せ方。
public enum RunFormatting {
    /// 「1,234」。
    public static func number(_ value: Int) -> String {
        let text = String(value)
        guard text.count > 3 else { return text }
        var result = ""
        for (index, character) in text.reversed().enumerated() {
            if index > 0, index % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return String(result.reversed())
    }

    /// 「12 ミリ秒」「1.24 秒」。
    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 0.001 { return String(format: "%.0f マイクロ秒", seconds * 1_000_000) }
        if seconds < 1 { return String(format: "%.0f ミリ秒", seconds * 1000) }
        if seconds < 60 { return String(format: "%.2f 秒", seconds) }
        let minutes = Int(seconds) / 60
        return String(format: "%d 分 %.0f 秒", minutes, seconds - Double(minutes * 60))
    }

    /// 「1.2 MB」。
    public static func bytes(_ count: Int) -> String {
        OfflineCache.sizeText(count)
    }
}

/// 構文だけを調べた結果。
public struct SyntaxCheckResult: Equatable, Sendable {
    public var isValid: Bool
    public var diagnosticsText: String
    public var errorCount: Int

    public init(isValid: Bool, diagnosticsText: String = "", errorCount: Int = 0) {
        self.isValid = isValid
        self.diagnosticsText = diagnosticsText
        self.errorCount = errorCount
    }
}

public enum RunSessionError: LocalizedError, Equatable {
    case noEngine(String)

    public var errorDescription: String? {
        switch self {
        case .noEngine(let id): return "\(id) の内蔵処理系がありません。"
        }
    }
}

/// 内蔵処理系を動かす窓口。
///
/// 時間やステップ数を測り、仮想ファイルの中身まで含めて結果にまとめる。
public enum RunSession {

    /// その言語の処理系があるか。
    public static func hasEngine(for languageID: String) -> Bool {
        MiniLangRegistry.engine(for: languageID) != nil
    }

    /// 動かす。
    public static func run(languageID: String, source: String,
                           options: RunOptions = .default,
                           cancellation: RunCancellation? = nil,
                           debugger: Debugger? = nil) throws -> RunResult {
        guard let engine = MiniLangRegistry.engine(for: languageID) else {
            throw RunSessionError.noEngine(languageID)
        }
        let files = VirtualFileSystem(files: options.files)
        let limits = options.makeLimits(cancellation: cancellation, fileSystem: files,
                                        debugger: debugger)
        let startedAt = Date()
        let clock = Date()
        var execution = engine.execute(source: source, input: options.input,
                                       limits: limits)
        execution.duration = Date().timeIntervalSince(clock)
        return RunResult(languageID: languageID, engineName: engine.displayName,
                         execution: execution, startedAt: startedAt,
                         files: files.snapshot())
    }

    /// 構文だけを調べる (実行はしない)。
    public static func checkSyntax(languageID: String,
                                   source: String) throws -> SyntaxCheckResult {
        guard let engine = MiniLangRegistry.engine(for: languageID) else {
            throw RunSessionError.noEngine(languageID)
        }
        let limits = MiniLangLimits(parseOnly: true)
        let execution = engine.execute(source: source, input: "", limits: limits)
        return SyntaxCheckResult(isValid: execution.parsed,
                                 diagnosticsText: execution.diagnosticsText,
                                 errorCount: execution.errorCount)
    }

    /// 入力を取り替えながら何度も動かす。
    public static func run(languageID: String, source: String, inputs: [String],
                           options: RunOptions = .default) throws -> [RunResult] {
        try inputs.map { input in
            var each = options
            each.input = input
            return try run(languageID: languageID, source: source, options: each)
        }
    }

    /// 同じ問題を複数の言語で解いた結果を並べる。
    ///
    /// `sources` は 言語 ID → ソース。処理系が無い言語は飛ばす。
    public static func compare(_ sources: [String: String],
                               options: RunOptions = .default) -> [RunResult] {
        sources.keys.sorted().compactMap { languageID in
            try? run(languageID: languageID, source: sources[languageID] ?? "",
                     options: options)
        }
    }
}

// MARK: - 130. バックグラウンド実行

/// 走らせている実行 1 つぶん。別のスレッドで動くので、途中で止められる。
public final class RunTask: @unchecked Sendable {
    public let languageID: String
    private let cancellation = RunCancellation()
    private let lock = NSLock()
    private var finishedResult: RunResult?
    private var failure: Error?
    private let done = DispatchSemaphore(value: 0)

    /// 終わったときに呼ばれる。
    public var onFinish: ((Result<RunResult, Error>) -> Void)?

    public init(languageID: String, source: String, options: RunOptions = .default) {
        self.languageID = languageID
        let cancellation = self.cancellation
        let thread = Thread { [weak self] in
            let outcome: Result<RunResult, Error>
            do {
                outcome = .success(try RunSession.run(languageID: languageID,
                                                      source: source, options: options,
                                                      cancellation: cancellation))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.lock.lock()
            switch outcome {
            case .success(let result): self.finishedResult = result
            case .failure(let error): self.failure = error
            }
            self.lock.unlock()
            self.done.signal()
            self.onFinish?(outcome)
        }
        thread.stackSize = 32 << 20
        thread.start()
    }

    /// 途中で止める。
    public func cancel() { cancellation.cancel() }

    public var isCancelled: Bool { cancellation.isCancelled }

    /// もう終わっているか。
    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishedResult != nil || failure != nil
    }

    /// 終わるまで待つ。`timeout` を過ぎたら nil。
    @discardableResult
    public func wait(timeout: TimeInterval = 30) -> RunResult? {
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return finishedResult
    }

    /// 終わるまで待って、結果かエラーを返す。
    public func value(timeout: TimeInterval = 30) throws -> RunResult {
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        if let finishedResult { return finishedResult }
        if let failure { throw failure }
        throw RunSessionError.noEngine(languageID)
    }
}

// MARK: - 109. 実行結果の履歴

/// 実行 1 回ぶんの覚え書き。
public struct RunHistoryEntry: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var languageID: String
    public var source: String
    public var input: String
    public var arguments: [String]
    public var output: String
    public var exitCode: Int32
    public var duration: TimeInterval
    public var steps: Int
    public var failureText: String?
    public var ranAt: Date

    public init(id: UUID = UUID(), languageID: String, source: String,
                input: String = "", arguments: [String] = [], output: String,
                exitCode: Int32 = 0, duration: TimeInterval = 0, steps: Int = 0,
                failureText: String? = nil, ranAt: Date = Date()) {
        self.id = id
        self.languageID = languageID
        self.source = source
        self.input = input
        self.arguments = arguments
        self.output = output
        self.exitCode = exitCode
        self.duration = duration
        self.steps = steps
        self.failureText = failureText
        self.ranAt = ranAt
    }

    public init(result: RunResult, source: String, input: String = "",
                arguments: [String] = []) {
        self.init(languageID: result.languageID, source: source, input: input,
                  arguments: arguments, output: result.output,
                  exitCode: result.exitCode, duration: result.duration,
                  steps: result.steps, failureText: result.failureText,
                  ranAt: result.startedAt)
    }

    public var succeeded: Bool { failureText == nil && exitCode == 0 }

    /// 一覧に出す 1 行。
    public var summary: String {
        let head = output.components(separatedBy: "\n").first ?? ""
        if let failureText { return failureText.components(separatedBy: "\n").first ?? failureText }
        return head.isEmpty ? "(出力なし)" : head
    }
}

/// 実行の履歴 (新しい順)。
public final class RunHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RunHistoryEntry] = []
    public let limit: Int

    public init(limit: Int = 50, entries: [RunHistoryEntry] = []) {
        self.limit = limit
        self.entries = Array(entries.prefix(limit))
    }

    public var all: [RunHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func add(_ entry: RunHistoryEntry) {
        lock.lock()
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        lock.unlock()
    }

    public func add(_ result: RunResult, source: String, input: String = "",
                    arguments: [String] = []) {
        add(RunHistoryEntry(result: result, source: source, input: input,
                            arguments: arguments))
    }

    public func entries(languageID: String) -> [RunHistoryEntry] {
        all.filter { $0.languageID == languageID }
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// 同じソースを前に動かしたときの結果。
    public func lastEntry(forSource source: String) -> RunHistoryEntry? {
        all.first { $0.source == source }
    }
}

// MARK: - 97. ファイルごとの標準入力

/// ファイルごとに、前に入れた標準入力や引数を覚えておく。
public final class RunInputStore: @unchecked Sendable {
    /// ファイルごとの設定。
    public struct Entry: Equatable, Codable, Sendable {
        public var input: String
        public var arguments: [String]

        public init(input: String = "", arguments: [String] = []) {
            self.input = input
            self.arguments = arguments
        }
    }

    private let lock = NSLock()
    private var storage: [String: Entry] = [:]

    public init(entries: [String: Entry] = [:]) {
        self.storage = entries
    }

    /// 保存しておいた JSON から復元する。
    public convenience init(json: Data?) {
        let loaded = json.flatMap { try? JSONDecoder().decode([String: Entry].self,
                                                              from: $0) }
        self.init(entries: loaded ?? [:])
    }

    public func entry(for key: String) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        return storage[key] ?? Entry()
    }

    public func set(_ entry: Entry, for key: String) {
        lock.lock()
        if entry == Entry() { storage[key] = nil } else { storage[key] = entry }
        lock.unlock()
    }

    public func setInput(_ input: String, for key: String) {
        var current = entry(for: key)
        current.input = input
        set(current, for: key)
    }

    public func setArguments(_ arguments: [String], for key: String) {
        var current = entry(for: key)
        current.arguments = arguments
        set(current, for: key)
    }

    /// `RunOptions` に反映する。
    public func apply(to options: RunOptions, key: String) -> RunOptions {
        var updated = options
        let saved = entry(for: key)
        updated.input = saved.input
        updated.arguments = saved.arguments
        return updated
    }

    public var keys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.keys.sorted()
    }

    public func encoded() -> Data? {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        return try? JSONEncoder().encode(snapshot)
    }
}

// MARK: - 96 / 127. 引数の文字列を分ける

/// 「-n 3 "a b"」のような 1 行を、引数の配列に分ける。
public enum ArgumentParser {
    public static func split(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var hasCurrent = false
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                hasCurrent = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasCurrent = true
                continue
            }
            if character == " " || character == "\t" || character == "\n" {
                if hasCurrent || !current.isEmpty { result.append(current) }
                current = ""
                hasCurrent = false
                continue
            }
            current.append(character)
            hasCurrent = true
        }
        if hasCurrent || !current.isEmpty { result.append(current) }
        return result
    }

    /// 配列を 1 行に戻す (空白を含むものは引用符でくくる)。
    public static func join(_ arguments: [String]) -> String {
        arguments.map { argument in
            let needsQuotes = argument.isEmpty
                || argument.contains(" ") || argument.contains("\t")
                || argument.contains("\"") || argument.contains("'")
            guard needsQuotes else { return argument }
            let escaped = argument.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: " ")
    }
}

// MARK: - 103. 保存時の自動実行

/// いつ自動で動かすか。
public enum AutoRunPolicy: String, CaseIterable, Identifiable, Codable, Equatable,
                           Sendable {
    /// 自動では動かさない。
    case never
    /// 保存したときだけ。
    case onSave
    /// 入力が止まってしばらくしたら。
    case onPause

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .never: return "自動実行しない"
        case .onSave: return "保存したときに実行"
        case .onPause: return "手が止まったら実行"
        }
    }

    /// 入力が止まってから動かすまでの秒数。
    public var debounce: TimeInterval? {
        self == .onPause ? 1.2 : nil
    }

    /// この出来事で動かしてよいか。
    public func shouldRun(on event: AutoRunEvent) -> Bool {
        switch (self, event) {
        case (.never, _): return false
        case (.onSave, .save): return true
        case (.onSave, .pause): return false
        case (.onPause, _): return true
        }
    }
}

/// 自動実行のきっかけ。
public enum AutoRunEvent: Equatable, Sendable {
    case save
    case pause
}
