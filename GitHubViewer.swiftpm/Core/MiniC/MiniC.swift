import Foundation

/// 端末の中で動く C コンパイラ + 仮想マシン。
///
/// 字句解析 → プリプロセス → 構文解析 → 型検査とコード生成 → バイトコード実行、
/// という普通の構成で、外部のサービスもネットワークも使わない。
public enum MiniC {
    /// コンパイル結果 (警告つき)。
    public struct Build {
        public var program: MiniCProgram
        public var warnings: [Diagnostic]
    }

    /// コンパイルから実行までの結果。UI にはこれを渡す。
    public struct Execution: Equatable {
        public var compiled: Bool
        /// エラーと警告を整形した文字列 (問題がなければ空)。
        public var diagnosticsText: String
        public var warningCount: Int
        public var errorCount: Int
        public var output: String
        /// stderr に書かれた内容。
        public var errorOutput: String
        public var exitCode: Int32
        public var runtimeError: String?
        public var executedSteps: Int
        public var disassembly: String

        public var succeeded: Bool { compiled && runtimeError == nil }
    }

    /// ソースをバイトコードにコンパイルする。
    public static func compile(source: String) throws -> Build {
        let diagnostics = DiagnosticBag(source: source)

        var lexer = Lexer(source: source, diagnostics: diagnostics)
        let rawTokens = lexer.tokenize()

        var preprocessor = Preprocessor(diagnostics: diagnostics)
        let tokens = preprocessor.process(rawTokens)

        var parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let unit = parser.parseTranslationUnit()
        if let failure = diagnostics.failureIfNeeded() { throw failure }

        let compiler = MiniCCompiler(diagnostics: diagnostics)
        let program = try compiler.compile(unit: unit,
                                           structs: parser.collectedStructs,
                                           enums: parser.collectedEnums)
        return Build(program: program, warnings: diagnostics.diagnostics.filter { $0.severity == .warning })
    }

    /// コンパイルして実行する。失敗しても例外ではなく結果で返す。
    public static func execute(source: String,
                               input: String = "",
                               limits: MiniCLimits = .default,
                               includeDisassembly: Bool = false) -> Execution {
        do {
            let build = try compile(source: source)
            let machine = MiniCVM(program: build.program, input: input, limits: limits)
            let result = machine.run()
            let warningText = build.warnings.isEmpty ? ""
                : CompileFailure(diagnostics: build.warnings, source: source).formatted
            return Execution(compiled: true,
                             diagnosticsText: warningText,
                             warningCount: build.warnings.count,
                             errorCount: 0,
                             output: result.output,
                             errorOutput: result.errorOutput,
                             exitCode: result.exitCode,
                             runtimeError: result.runtimeError,
                             executedSteps: result.executedSteps,
                             disassembly: includeDisassembly ? build.program.disassembly : "")
        } catch let failure as CompileFailure {
            let errors = failure.diagnostics.filter { $0.severity == .error }
            return Execution(compiled: false,
                             diagnosticsText: failure.formatted,
                             warningCount: failure.diagnostics.count - errors.count,
                             errorCount: errors.count,
                             output: "",
                             errorOutput: "",
                             exitCode: 1,
                             runtimeError: nil,
                             executedSteps: 0,
                             disassembly: "")
        } catch {
            return Execution(compiled: false,
                             diagnosticsText: "コンパイルに失敗しました: \(error)",
                             warningCount: 0,
                             errorCount: 1,
                             output: "",
                             errorOutput: "",
                             exitCode: 1,
                             runtimeError: nil,
                             executedSteps: 0,
                             disassembly: "")
        }
    }

    /// 逆アセンブル結果だけが欲しいとき。
    public static func disassemble(source: String) throws -> String {
        try compile(source: source).program.disassembly
    }
}
