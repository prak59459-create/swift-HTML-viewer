import Foundation

/// 端末の中で動く PHP インタプリタ。
///
/// 字句解析 → 構文解析 → AST をたどって実行、という構成で、
/// 外部のサービスもネットワークも使わない。
public enum MiniPHP {
    /// 実行結果。
    public struct Execution: Equatable {
        public var parsed: Bool
        /// 構文エラーを整形した文字列 (問題がなければ空)。
        public var diagnosticsText: String
        public var errorCount: Int
        public var output: String
        /// 実行時エラー (正常なら nil)。
        public var runtimeError: String?
        public var exitCode: Int32

        public var succeeded: Bool { parsed && runtimeError == nil }
    }

    /// 構文解析だけ行う (エラー表示用)。
    public static func parse(source: String) throws -> [PHPStmt] {
        let diagnostics = DiagnosticBag(source: source)
        var lexer = PHPLexer(source: prepared(source), diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        var parser = PHPParser(tokens: tokens, diagnostics: diagnostics)
        let statements = parser.parseProgram()
        if let failure = diagnostics.failureIfNeeded() { throw failure }
        return statements
    }

    /// 解析して実行する。
    ///
    /// 深い再帰でもアプリが落ちないよう、スタックを大きく取った別スレッドで動かす。
    public static func execute(source: String, input: String = "",
                               limits: PHPLimits = .default) -> Execution {
        var result = Execution(parsed: false, diagnosticsText: "", errorCount: 0,
                               output: "", runtimeError: nil, exitCode: 255)
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

    static func executeOnCurrentThread(source: String, input: String,
                                       limits: PHPLimits) -> Execution {
        do {
            let statements = try parse(source: source)
            let interpreter = PHPInterpreter(limits: limits, input: input)
            let result = interpreter.run(statements)
            return Execution(parsed: true, diagnosticsText: "", errorCount: 0,
                             output: result.output, runtimeError: result.error, exitCode: result.exitCode)
        } catch let failure as CompileFailure {
            let errors = failure.diagnostics.filter { $0.severity == .error }
            return Execution(parsed: false, diagnosticsText: failure.formatted, errorCount: errors.count,
                             output: "", runtimeError: nil, exitCode: 255)
        } catch {
            return Execution(parsed: false, diagnosticsText: "解析に失敗しました: \(error)", errorCount: 1,
                             output: "", runtimeError: nil, exitCode: 255)
        }
    }

    /// `<?php` が無いソースは、PHP コードだけが書かれているものとして扱う。
    private static func prepared(_ source: String) -> String {
        source.contains("<?php") || source.contains("<?=") ? source : "<?php\n" + source
    }
}
