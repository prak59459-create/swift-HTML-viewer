import Foundation

/// 端末の中で動く Swift インタプリタ (Swift のサブセット)。
public enum MiniSwift {
    public struct Execution: Equatable {
        public var parsed: Bool
        public var diagnosticsText: String
        public var errorCount: Int
        public var output: String
        public var runtimeError: String?

        public var succeeded: Bool { parsed && runtimeError == nil }
    }

    public static func parse(source: String) throws -> [SwiftStmt] {
        let diagnostics = DiagnosticBag(source: source)
        var lexer = SwiftLexer(source: source, diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        var parser = SwiftParser(tokens: tokens, diagnostics: diagnostics)
        let statements = parser.parseProgram()
        if let failure = diagnostics.failureIfNeeded() { throw failure }
        return statements
    }

    /// 解析して実行する。深い再帰でも落ちないよう、大きなスタックの別スレッドで動かす。
    public static func execute(source: String, input: String = "",
                               limits: SwiftLimits = .default) -> Execution {
        var result = Execution(parsed: false, diagnosticsText: "", errorCount: 0,
                               output: "", runtimeError: nil)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = executeOnCurrentThread(source: source, input: input, limits: limits)
            finished.signal()
        }
        thread.stackSize = 32 << 20
        thread.start()
        finished.wait()
        return result
    }

    static func executeOnCurrentThread(source: String, input: String, limits: SwiftLimits) -> Execution {
        do {
            let statements = try parse(source: source)
            let interpreter = SwiftInterpreter(limits: limits, input: input)
            let result = interpreter.run(statements)
            return Execution(parsed: true, diagnosticsText: "", errorCount: 0,
                             output: result.output, runtimeError: result.error)
        } catch let failure as CompileFailure {
            let errors = failure.diagnostics.filter { $0.severity == .error }
            return Execution(parsed: false, diagnosticsText: failure.formatted, errorCount: errors.count,
                             output: "", runtimeError: nil)
        } catch {
            return Execution(parsed: false, diagnosticsText: "解析に失敗しました: \(error)", errorCount: 1,
                             output: "", runtimeError: nil)
        }
    }
}
