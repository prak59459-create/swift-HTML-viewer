import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 120 / 121. 途中経過の表示と、対話的な標準入力

/// 対話的に動かしている実行 1 つぶん。
///
/// 出力は書かれたそばから `onOutput` に流れ、プログラムが入力を求めたら
/// `onNeedsInput` が呼ばれる。利用者が打ち込んだ行は `send(_:)` で渡す。
public final class InteractiveRun: @unchecked Sendable {
    public let languageID: String
    private let cancellation = RunCancellation()
    private let lock = NSLock()
    private var pending: [String] = []
    private let inputReady = DispatchSemaphore(value: 0)
    private var closedInput = false
    private var finished: RunResult?
    private var failure: Error?
    private let done = DispatchSemaphore(value: 0)

    /// 出力が増えるたびに呼ばれる (実行スレッドから)。
    public var onOutput: ((String) -> Void)?
    /// プログラムが入力を待ちはじめたときに呼ばれる。
    public var onNeedsInput: (() -> Void)?
    /// 終わったときに呼ばれる。
    public var onFinish: ((Result<RunResult, Error>) -> Void)?
    /// 入力を待つ最大の時間。過ぎたら「入力の終わり」とみなす。
    public var inputTimeout: TimeInterval = 30

    public init(languageID: String, source: String, options: RunOptions = .default) {
        self.languageID = languageID
        let thread = Thread { [weak self] in
            guard let self else { return }
            let outcome: Result<RunResult, Error>
            do {
                outcome = .success(try self.execute(source: source, options: options))
            } catch {
                outcome = .failure(error)
            }
            self.lock.lock()
            switch outcome {
            case .success(let result): self.finished = result
            case .failure(let error): self.failure = error
            }
            self.lock.unlock()
            self.done.signal()
            self.onFinish?(outcome)
        }
        thread.stackSize = 32 << 20
        thread.start()
    }

    /// 実際に動かす。`MiniLangEngine` は出力と入力の口を持っているので、
    /// そこに割り込んで流し込む。
    private func execute(source: String, options: RunOptions) throws -> RunResult {
        guard let engine = MiniLangRegistry.engine(for: languageID) else {
            throw RunSessionError.noEngine(languageID)
        }
        let files = VirtualFileSystem(files: options.files)
        var limits = options.makeLimits(cancellation: cancellation, fileSystem: files)
        // 対話中は時間の上限を外す (人を待つため)。
        limits.timeLimit = nil

        limits.hooks = InteractiveHooks(onOutput: { [weak self] text in
            self?.onOutput?(text)
        }, provideInput: { [weak self] in
            self?.waitForInput()
        })
        let startedAt = Date()
        let clock = Date()
        var execution = engine.execute(source: source, input: options.input,
                                       limits: limits)
        execution.duration = Date().timeIntervalSince(clock)
        return RunResult(languageID: languageID, engineName: engine.displayName,
                         execution: execution, startedAt: startedAt,
                         files: files.snapshot())
    }

    /// プログラムに 1 行渡す。
    public func send(_ line: String) {
        lock.lock()
        pending.append(line)
        lock.unlock()
        inputReady.signal()
    }

    /// もう入力は無いと伝える。
    public func closeInput() {
        lock.lock()
        closedInput = true
        lock.unlock()
        inputReady.signal()
    }

    /// 途中で止める。
    public func cancel() {
        cancellation.cancel()
        closeInput()
    }

    public var isCancelled: Bool { cancellation.isCancelled }

    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished != nil || failure != nil
    }

    /// 終わるまで待つ。
    @discardableResult
    public func wait(timeout: TimeInterval = 60) -> RunResult? {
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// 入力が来るまで待つ。来なければ nil (= 入力の終わり)。
    private func waitForInput() -> String? {
        while true {
            lock.lock()
            if !pending.isEmpty {
                let line = pending.removeFirst()
                lock.unlock()
                return line
            }
            let closed = closedInput
            lock.unlock()
            if closed || cancellation.isCancelled { return nil }

            onNeedsInput?()
            if inputReady.wait(timeout: .now() + inputTimeout) == .timedOut {
                return nil
            }
        }
    }
}

/// 実行中の割り込み口。
///
/// `MiniLangLimits` に載せて処理系に渡す。処理系は専用のスレッドで動くので、
/// ここに置いた関数はそのスレッドから呼ばれる。
public struct InteractiveHooks: @unchecked Sendable {
    /// 出力が増えるたびに呼ばれる。
    public var onOutput: ((String) -> Void)?
    /// 入力を使い切ったときに呼ばれる。nil を返したら入力の終わり。
    public var provideInput: (() -> String?)?

    public init(onOutput: ((String) -> Void)? = nil,
                provideInput: (() -> String?)? = nil) {
        self.onOutput = onOutput
        self.provideInput = provideInput
    }
}

// MARK: - 111. 内蔵処理系とサーバー実行の比べ

/// 内蔵処理系と外の実行サービスを比べた結果。
public struct EngineComparison: Equatable, Sendable {
    public var builtin: RunResult?
    public var builtinError: String?
    public var remote: ExecutionOutput?
    public var remoteError: String?

    public init(builtin: RunResult? = nil, builtinError: String? = nil,
                remote: ExecutionOutput? = nil, remoteError: String? = nil) {
        self.builtin = builtin
        self.builtinError = builtinError
        self.remote = remote
        self.remoteError = remoteError
    }

    /// 両方が動いたか。
    public var hasBothSides: Bool { builtin != nil && remote != nil }

    /// 出力が同じか。片方でも動かなければ nil。
    public var outputsMatch: Bool? {
        guard let builtin, let remote else { return nil }
        return TestRunner.normalize(ANSIParser.strip(builtin.output), trims: true)
            == TestRunner.normalize(remote.stdout, trims: true)
    }

    /// 違いの行。
    public var diff: [DiffLine] {
        guard let builtin, let remote else { return [] }
        return DiffEngine.diff(old: ANSIParser.strip(builtin.output),
                               new: remote.stdout)
    }

    /// 人に見せる 1 行。
    public var summary: String {
        switch outputsMatch {
        case .some(true): return "内蔵処理系とサーバーの出力は同じでした。"
        case .some(false): return "内蔵処理系とサーバーで出力が違います。"
        case .none:
            if let builtinError { return "内蔵処理系で失敗しました: \(builtinError)" }
            if let remoteError { return "サーバー実行で失敗しました: \(remoteError)" }
            return "片方しか動きませんでした。"
        }
    }
}

extension RunSession {
    /// 内蔵処理系と外の実行サービスの両方で動かして、結果を並べる。
    public static func compareWithRemote(languageID: String, source: String,
                                         spec: RemoteSpec, backend: ExecutionBackend,
                                         runner: CodeRunner,
                                         options: RunOptions = .default) async
        -> EngineComparison {
        var comparison = EngineComparison()
        do {
            comparison.builtin = try run(languageID: languageID, source: source,
                                         options: options)
        } catch {
            comparison.builtinError = error.localizedDescription
        }
        do {
            comparison.remote = try await runner.run(spec: spec, source: source,
                                                     stdin: options.input,
                                                     backend: backend)
        } catch {
            comparison.remoteError = error.localizedDescription
        }
        return comparison
    }
}
