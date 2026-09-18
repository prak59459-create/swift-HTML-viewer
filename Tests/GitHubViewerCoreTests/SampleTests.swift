import XCTest
@testable import GitHubViewerCore

final class SampleLibraryTests: XCTestCase {

    /// 期待する出力を書いてあるサンプルは、そのとおりに動くこと。
    func testSamplesWithExpectedOutputActuallyRun() throws {
        for sample in SampleLibrary.builtIn {
            guard let expected = sample.expectedOutput else { continue }
            guard sample.isRunnable else {
                XCTFail("\(sample.id): \(sample.languageID) を動かせません")
                continue
            }
            var options = RunOptions()
            options.input = sample.input
            let result = try RunSession.run(languageID: sample.languageID,
                                            source: sample.source, options: options)
            XCTAssertNil(result.failureText, "\(sample.id) が失敗しました")
            XCTAssertEqual(
                TestRunner.normalize(ANSIParser.strip(result.output), trims: true),
                TestRunner.normalize(expected, trims: true),
                "\(sample.id) の出力が違います")
        }
    }

    /// 期待を書いていないものも、少なくともエラーなく動くこと。
    func testEverySampleRunsWithoutErrors() throws {
        for sample in SampleLibrary.builtIn {
            guard sample.isRunnable else { continue }
            var options = RunOptions()
            options.input = sample.input
            options.timeLimit = 10
            let result = try RunSession.run(languageID: sample.languageID,
                                            source: sample.source, options: options)
            XCTAssertNil(result.failureText,
                         "\(sample.id) (\(sample.languageID)) が失敗しました")
        }
    }

    func testEverySampleIsWellFormed() {
        for sample in SampleLibrary.builtIn {
            XCTAssertFalse(sample.title.isEmpty)
            XCTAssertFalse(sample.summary.isEmpty)
            XCTAssertFalse(sample.source.isEmpty)
            XCTAssertFalse(sample.tags.isEmpty, "\(sample.id) にタグがありません")
            XCTAssertTrue((1...3).contains(sample.level))
            XCTAssertTrue(sample.isRunnable, "\(sample.id) は動かせません")
        }
    }

    func testNoDuplicateIDs() {
        let ids = SampleLibrary.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
