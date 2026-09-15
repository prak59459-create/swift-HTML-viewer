import XCTest
@testable import GitHubViewerCore

/// `Examples/swift/` にある Swift プログラム (14 本) を内蔵インタプリタで実行し、
/// 本物の Swift コンパイラ (swiftc 6.0.3) で同じソースを実行した出力と一致することを確かめる。
final class SwiftComparisonTests: XCTestCase {
    private var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/swift")
    }

    func testEveryExampleMatchesSwiftc() throws {
        let directory = examplesDirectory
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertGreaterThanOrEqual(files.count, 14, "サンプルが見つかりません: \(directory.path)")

        for file in files {
            let name = String(file.dropLast(6))
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            let expected = try String(contentsOf: directory.appendingPathComponent("expected/\(name).expected"),
                                      encoding: .utf8)
            let execution = MiniSwift.execute(source: source)
            XCTAssertTrue(execution.parsed, "\(file) の解析に失敗:\n\(execution.diagnosticsText)")
            XCTAssertNil(execution.runtimeError, "\(file) の実行時エラー: \(execution.runtimeError ?? "")")
            XCTAssertEqual(execution.output, expected, "\(file) の出力が swiftc と違います")
        }
    }
}
