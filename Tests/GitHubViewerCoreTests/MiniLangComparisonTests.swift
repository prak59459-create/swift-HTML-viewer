import XCTest
@testable import GitHubViewerCore

/// `Examples/<言語ID>/` に置いたプログラムを内蔵処理系で動かし、
/// `expected/<名前>.expected` と 1 バイトも違わないことを確かめる。
///
/// 期待値は、本物の処理系 (javac / g++ / go / rustc / perl / bash など) が
/// 使える言語ではそれで生成し、使えない言語は言語仕様にもとづいて用意している。
final class MiniLangComparisonTests: XCTestCase {

    /// リポジトリの `Examples` ディレクトリ。
    private var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GitHubViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリのルート
            .appendingPathComponent("Examples")
    }

    /// 言語 ID と拡張子の対応。
    private static let fileExtensions: [String: [String]] = [
        "java": ["java"],
        "csharp": ["cs"],
        "kotlin": ["kt"],
        "scala": ["scala"],
        "go": ["go"],
        "rust": ["rs"],
        "cpp": ["cpp", "cc"],
        "objectivec": ["m"],
        "d": ["d"],
        "dart": ["dart"],
        "groovy": ["groovy"],
        "zig": ["zig"],
        "nim": ["nim"],
        "crystal": ["cr"],
        "julia": ["jl"],
        "haskell": ["hs"],
        "ocaml": ["ml"],
        "elixir": ["exs", "ex"],
        "erlang": ["erl"],
        "perl": ["pl"],
        "shell": ["sh"],
        "r": ["R", "r"],
        "pascal": ["pas"],
        "lisp": ["lisp", "lsp"],
        "javascript": ["js"],
        "typescript": ["ts"]
    ]

    func testAllExamplesMatchExpectedOutput() throws {
        let manager = FileManager.default
        var checked = 0

        for engine in MiniLangRegistry.all {
            let languageID = engine.languageID
            guard let extensions = Self.fileExtensions[languageID] else { continue }
            let directory = examplesDirectory.appendingPathComponent(languageID)
            guard manager.fileExists(atPath: directory.path) else { continue }

            let names = try manager.contentsOfDirectory(atPath: directory.path)
                .filter { extensions.contains(($0 as NSString).pathExtension) }
                .sorted()

            for name in names {
                let sourceURL = directory.appendingPathComponent(name)
                let base = (name as NSString).deletingPathExtension
                let expectedURL = directory.appendingPathComponent("expected")
                    .appendingPathComponent(base + ".expected")
                guard manager.fileExists(atPath: expectedURL.path) else { continue }

                let source = try String(contentsOf: sourceURL, encoding: .utf8)
                let expected = try String(contentsOf: expectedURL, encoding: .utf8)
                // 標準入力が要るサンプルは `<名前>.stdin` に置く。
                let inputURL = directory.appendingPathComponent("expected")
                    .appendingPathComponent(base + ".stdin")
                let input = (try? String(contentsOf: inputURL, encoding: .utf8)) ?? ""

                let result = engine.execute(source: source, input: input, limits: .default)
                XCTAssertTrue(result.parsed,
                              "\(languageID)/\(name): 構文解析に失敗しました\n\(result.diagnosticsText)")
                XCTAssertNil(result.runtimeError,
                             "\(languageID)/\(name): 実行時エラー \(result.runtimeError ?? "")")
                XCTAssertEqual(result.output, expected,
                               "\(languageID)/\(name): 出力が期待値と違います")
                checked += 1
            }
        }

        XCTAssertGreaterThan(checked, 0, "比較したサンプルが 1 つもありませんでした")
    }

    /// すべての内蔵処理系が、空のプログラムで落ちないこと。
    func testEveryEngineHandlesEmptySource() {
        for engine in MiniLangRegistry.all {
            let result = engine.execute(source: "", input: "", limits: .default)
            XCTAssertNil(result.runtimeError,
                         "\(engine.languageID): 空のプログラムで実行時エラーになりました")
        }
    }

    /// 言語 ID が重複していないこと。
    func testLanguageIDsAreUnique() {
        let ids = MiniLangRegistry.all.map { $0.languageID }
        XCTAssertEqual(ids.count, Set(ids).count, "言語 ID が重複しています: \(ids)")
    }

    /// 無限ループが上限で止まること。
    func testInfiniteLoopIsStopped() {
        let limits = MiniLangLimits(maximumSteps: 50_000)
        let result = MiniJava.execute(
            source: "public class Main { public static void main(String[] a) { while (true) {} } }",
            input: "", limits: limits)
        XCTAssertNotNil(result.runtimeError, "無限ループが止まりませんでした")
    }
}
