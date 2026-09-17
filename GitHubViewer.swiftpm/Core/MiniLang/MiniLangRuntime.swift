import Foundation

/// 内蔵の処理系 (コンパイラ / インタプリタ) が共通で返す実行結果。
public struct MiniLangExecution: Equatable {
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

    public init(parsed: Bool, diagnosticsText: String = "", errorCount: Int = 0,
                output: String = "", runtimeError: String? = nil, exitCode: Int32 = 0) {
        self.parsed = parsed
        self.diagnosticsText = diagnosticsText
        self.errorCount = errorCount
        self.output = output
        self.runtimeError = runtimeError
        self.exitCode = exitCode
    }

    public var succeeded: Bool { parsed && runtimeError == nil }

    /// 構文エラーだけの結果を作る。
    public static func syntaxError(_ failure: CompileFailure) -> MiniLangExecution {
        let errors = failure.diagnostics.filter { $0.severity == .error }
        return MiniLangExecution(parsed: false, diagnosticsText: failure.formatted,
                                 errorCount: errors.count, exitCode: 1)
    }
}

/// 実行時の上限 (無限ループなどでアプリが固まらないようにする)。
public struct MiniLangLimits {
    public var maximumSteps: Int
    public var maximumOutputBytes: Int
    public var maximumCallDepth: Int

    public init(maximumSteps: Int = 5_000_000,
                maximumOutputBytes: Int = 1 << 20,
                maximumCallDepth: Int = 400) {
        self.maximumSteps = maximumSteps
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumCallDepth = maximumCallDepth
    }

    public static let `default` = MiniLangLimits()
}

/// 内蔵処理系が満たす約束。アプリ側はこれだけを見て実行する。
public protocol MiniLangEngine {
    /// `LanguageCatalog` の言語 ID と合わせる ("go", "rust" など)。
    static var languageID: String { get }
    /// 表示名 ("内蔵 Go インタプリタ" など)。
    static var displayName: String { get }
    static func execute(source: String, input: String, limits: MiniLangLimits) -> MiniLangExecution
}

public extension MiniLangEngine {
    static func execute(source: String) -> MiniLangExecution {
        execute(source: source, input: "", limits: .default)
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

    public init(limit: Int) {
        self.limit = limit
    }

    public func write(_ text: String) {
        guard !overflowed else { return }
        let bytes = Data(text.utf8)
        if buffer.count + bytes.count > limit {
            buffer.append(bytes.prefix(max(0, limit - buffer.count)))
            overflowed = true
            return
        }
        buffer.append(bytes)
    }

    public var text: String {
        var value = String(decoding: buffer, as: UTF8.self)
        if overflowed { value += "\n…出力が上限に達したので打ち切りました。" }
        return value
    }
}

/// 標準入力を 1 行ずつ渡す。
public final class MiniLangInput {
    private let lines: [String]
    private var index = 0
    private let raw: [Character]
    private var characterIndex = 0

    public init(_ text: String) {
        self.raw = Array(text)
        self.lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// 改行を含まない 1 行。無ければ nil。
    public func nextLine() -> String? {
        guard index < lines.count else { return nil }
        defer { index += 1 }
        return lines[index]
    }

    /// 1 文字。無ければ nil。
    public func nextCharacter() -> Character? {
        guard characterIndex < raw.count else { return nil }
        defer { characterIndex += 1 }
        return raw[characterIndex]
    }

    public var remainingText: String {
        String(raw[characterIndex...])
    }
}
