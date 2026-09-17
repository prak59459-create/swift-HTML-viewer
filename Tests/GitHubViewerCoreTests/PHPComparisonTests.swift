import XCTest
@testable import GitHubViewerCore

/// `Examples/php/` にある PHP プログラム (16 本) を内蔵インタプリタで実行し、
/// `Examples/php/expected/` に置いた期待出力と一致することを確かめる。
///
/// 期待出力は本物の PHP 8.4 (`php file.php`) で同じソースを実行して作ったもの。
final class PHPComparisonTests: XCTestCase {
    private var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/php")
    }

    func testEveryExampleMatchesPHP() throws {
        let directory = examplesDirectory
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".php") }
            .sorted()
        XCTAssertGreaterThanOrEqual(files.count, 16, "サンプルが見つかりません: \(directory.path)")

        for file in files {
            let name = String(file.dropLast(4))
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            let expected = try String(contentsOf: directory.appendingPathComponent("expected/\(name).expected"),
                                      encoding: .utf8)
            let execution = MiniPHP.execute(source: source)
            XCTAssertTrue(execution.parsed, "\(file) の解析に失敗:\n\(execution.diagnosticsText)")
            XCTAssertNil(execution.runtimeError, "\(file) の実行時エラー: \(execution.runtimeError ?? "")")
            XCTAssertEqual(execution.output, expected, "\(file) の出力が PHP と違います")
        }
    }
}
