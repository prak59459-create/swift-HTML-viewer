import XCTest
@testable import GitHubViewerCore

/// `Examples/c/` にある C プログラム (40 本) を内蔵コンパイラで実行し、
/// `Examples/c/expected/` に置いた期待出力と一致することを確かめる。
///
/// 期待出力は GCC 13.3 (`gcc -std=c99`) で同じソースをコンパイル・実行して作ったもの。
/// つまりこのテストは「内蔵コンパイラの出力が本物の C コンパイラと同じか」を見ている。
final class GCCComparisonTests: XCTestCase {
    private var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)           // Tests/GitHubViewerCoreTests/GCCComparisonTests.swift
            .deletingLastPathComponent()          // Tests/GitHubViewerCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // リポジトリのルート
            .appendingPathComponent("Examples/c")
    }

    func testEveryExampleMatchesGCC() throws {
        let fileManager = FileManager.default
        let directory = examplesDirectory
        let files = try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".c") }
            .sorted()
        XCTAssertGreaterThanOrEqual(files.count, 40, "サンプルが見つかりません: \(directory.path)")

        for file in files {
            let name = String(file.dropLast(2))
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            let expectedURL = directory.appendingPathComponent("expected/\(name).expected")
            let expected = try String(contentsOf: expectedURL, encoding: .utf8)
            let inputURL = directory.appendingPathComponent("expected/\(name).stdin")
            let input = (try? String(contentsOf: inputURL, encoding: .utf8)) ?? ""

            let execution = MiniC.execute(source: source, input: input)
            XCTAssertTrue(execution.compiled, "\(file) のコンパイルに失敗:\n\(execution.diagnosticsText)")
            XCTAssertNil(execution.runtimeError, "\(file) の実行時エラー: \(execution.runtimeError ?? "")")
            XCTAssertEqual(execution.output, expected, "\(file) の出力が GCC と違います")
        }
    }

    /// 逆アセンブルが全サンプルで壊れずに作れること。
    func testDisassemblyWorksForEveryExample() throws {
        let directory = examplesDirectory
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".c") }.sorted()
        for file in files {
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            let text = try MiniC.disassemble(source: source)
            XCTAssertTrue(text.contains("main:"), "\(file) の逆アセンブルに main がありません")
        }
    }
}
