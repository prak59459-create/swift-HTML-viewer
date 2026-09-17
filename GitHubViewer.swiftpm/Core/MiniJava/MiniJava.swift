import Foundation

/// 内蔵の Java 処理系。
///
/// 構文解析は `MLProfileParser` を Java 向けに調整したもの、
/// 実行は共通の `MLInterpreter` を使い、Java らしい振る舞い
/// (整数の巻き戻し、`Double.toString` の書式、標準ライブラリ) を
/// `JavaSemantics` で与える。
public enum MiniJava: MiniLangEngine {
    public static var languageID: String { "java" }
    public static var displayName: String { "内蔵 Java 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = JavaLexer(source: source, diagnostics: diagnostics).tokenize()
        return try JavaParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            executeOnCurrentThread(source: source, input: input, limits: limits)
        }
    }

    static func executeOnCurrentThread(source: String, input: String,
                                       limits: MiniLangLimits) -> MiniLangExecution {
        let diagnostics = DiagnosticBag(source: source)
        let lexer = JavaLexer(source: source, diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = JavaParser(tokens: tokens, diagnostics: diagnostics)
        let program: MLProgram
        do {
            program = try parser.parseProgram()
        } catch {
            if let failure = diagnostics.failureIfNeeded() {
                return .syntaxError(failure)
            }
            return MiniLangExecution(parsed: false,
                                     diagnosticsText: "構文を解析できませんでした",
                                     errorCount: 1, exitCode: 1)
        }
        if let failure = diagnostics.failureIfNeeded() { return .syntaxError(failure) }

        let interpreter = MLInterpreter(semantics: JavaSemantics(), limits: limits, input: input)
        return interpreter.run(program)
    }
}
