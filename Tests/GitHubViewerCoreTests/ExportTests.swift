import XCTest
@testable import GitHubViewerCore

/// 231-233. サンプルを探す、足す、しまう。
final class SampleSearchTests: XCTestCase {

    func testSearchFindsByTitleAndTag() {
        let library = SampleLibrary()
        XCTAssertFalse(library.search("辞書").isEmpty)
        XCTAssertFalse(library.search("クロージャ").isEmpty)
    }

    func testSearchCanBeNarrowedByLanguage() {
        let library = SampleLibrary()
        let kotlin = library.search("", languageID: "kotlin")
        XCTAssertFalse(kotlin.isEmpty)
        XCTAssertTrue(kotlin.allSatisfy { $0.languageID == "kotlin" })
    }

    func testSearchCanBeNarrowedByCategory() {
        let library = SampleLibrary()
        let category = try! XCTUnwrap(library.categories.first)
        let found = library.search("", category: category)
        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.allSatisfy { $0.category == category })
    }

    func testEmptyQueryReturnsEverythingUpToTheLimit() {
        let library = SampleLibrary()
        XCTAssertEqual(library.search("", limit: 3).count, 3)
    }

    func testSamplesByLanguageAndID() {
        let library = SampleLibrary()
        let sample = try! XCTUnwrap(library.sample(id: "hello-go"))
        XCTAssertEqual(sample.languageID, "go")
        XCTAssertTrue(library.samples(languageID: "go").contains(sample))
        XCTAssertNil(library.sample(id: "そんなものはない"))
    }

    func testAddAndRemoveUserSample() {
        var library = SampleLibrary()
        let builtInCount = library.all.count
        let mine = SampleLibrary.makeSample(title: "わたしの例", languageID: "go",
                                            source: "package main")
        library.add(mine)
        XCTAssertEqual(library.all.count, builtInCount + 1)
        XCTAssertTrue(try! XCTUnwrap(library.sample(id: mine.id)).isUserDefined)
        library.remove(id: mine.id)
        XCTAssertEqual(library.all.count, builtInCount)
    }

    func testAddingTheSameIDReplacesIt() {
        var library = SampleLibrary()
        var mine = SampleLibrary.makeSample(title: "1 回目", languageID: "go",
                                            source: "a")
        library.add(mine)
        mine.title = "2 回目"
        library.add(mine)
        XCTAssertEqual(library.userSamples.count, 1)
        XCTAssertEqual(library.sample(id: mine.id)?.title, "2 回目")
    }

    func testEncodeRoundTripKeepsOnlyUserSamples() throws {
        var library = SampleLibrary()
        library.add(SampleLibrary.makeSample(title: "保存する", languageID: "go",
                                             source: "a"))
        let data = try XCTUnwrap(library.encoded())
        let restored = SampleLibrary.decoded(data)
        XCTAssertEqual(restored.userSamples.count, 1)
        XCTAssertEqual(restored.userSamples.first?.title, "保存する")
    }

    func testDecodeGarbageGivesTheBuiltInLibrary() {
        let library = SampleLibrary.decoded(Data("こわれている".utf8))
        XCTAssertTrue(library.userSamples.isEmpty)
        XCTAssertEqual(library.all.count, SampleLibrary.builtIn.count)
    }

    func testLevelText() {
        for sample in SampleLibrary.builtIn {
            XCTAssertFalse(sample.levelText.isEmpty)
        }
    }
}

/// 234. 共有のかたち。
final class ShareBundleTests: XCTestCase {

    func testBundleHasCodeWithTheRightFileName() {
        let bundle = ShareBundle.make(title: "共有", languageID: "go",
                                      source: "package main")
        XCTAssertEqual(bundle.description, "共有")
        XCTAssertFalse(bundle.isPublic)
        XCTAssertTrue(bundle.files.keys.contains { $0.hasSuffix(".go") })
        XCTAssertNil(bundle.files["input.txt"])
    }

    func testInputIsIncludedWhenGiven() {
        let bundle = ShareBundle.make(title: "共有", languageID: "go",
                                      source: "package main", input: "1 2 3")
        XCTAssertEqual(bundle.files["input.txt"], "1 2 3")
    }

    func testResultAddsAReadme() throws {
        let result = try RunSession.run(languageID: "go",
                                        source: SampleLibrary.builtIn[0].source)
        let bundle = ShareBundle.make(title: "共有", languageID: "go",
                                      source: SampleLibrary.builtIn[0].source,
                                      result: result, isPublic: true)
        XCTAssertTrue(bundle.isPublic)
        let readme = try XCTUnwrap(bundle.files["README.md"])
        XCTAssertTrue(readme.contains("```"))
    }
}

/// 235. 書き出す。
final class ExporterTests: XCTestCase {

    private let source = """
    package main

    import "fmt"

    func main() {
        fmt.Println("こんにちは")
    }
    """

    private func run() throws -> RunResult {
        try RunSession.run(languageID: "go", source: source)
    }

    func testFormatsAreDescribed() {
        for format in ExportFormat.allCases {
            XCTAssertFalse(format.displayName.isEmpty)
            XCTAssertFalse(format.fileExtension.isEmpty)
            XCTAssertEqual(format.id, format.rawValue)
        }
    }

    func testPlainTextWithoutResultIsJustTheSource() {
        let data = Exporter.export(format: .plainText, title: "題", languageID: "go",
                                   source: source)
        XCTAssertEqual(String(data: data, encoding: .utf8), source)
    }

    func testPlainTextWithResultIncludesTheOutput() throws {
        let data = Exporter.export(format: .plainText, title: "題", languageID: "go",
                                   source: source, result: try run())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("こんにちは"))
    }

    func testMarkdownHasATitleAndAFencedBlock() {
        let data = Exporter.export(format: .markdown, title: "わたしの題",
                                   languageID: "go", source: source)
        let text = try! XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("# わたしの題"))
        XCTAssertTrue(text.contains("```go"))
    }

    func testHTMLIsWellFormedAndEscaped() {
        let data = Exporter.export(format: .html, title: "題 & <印刷>",
                                   languageID: "go", source: "a < b && c > d")
        let text = try! XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(text.contains("</html>"))
        XCTAssertTrue(text.contains("題 &amp; &lt;印刷&gt;"))
        // 本文の山かっこも、そのままにはしない。
        XCTAssertTrue(text.contains("&lt;"))
        XCTAssertFalse(text.contains("a < b"))
        // 外のライブラリに頼らない。
        XCTAssertFalse(text.contains("<script src="))
    }

    func testPlaygroundArchiveIsAReadableSwiftpm() throws {
        let data = Exporter.export(format: .playground, title: "MyApp",
                                   languageID: "swift", source: "print(1)")
        XCTAssertTrue(Zip.looksLikeZip(data))
        let entries = try Zip.entries(in: data)
        let paths = entries.map(\.path)
        XCTAssertTrue(paths.contains("Package.swift"))
        XCTAssertTrue(paths.contains("ContentView.swift"))
        let package = try XCTUnwrap(entries.first { $0.path == "Package.swift" })
        XCTAssertTrue(try XCTUnwrap(String(data: package.data, encoding: .utf8))
            .contains("MyApp"))
    }

    /// Swift でない言語も、そのまま持ち込めること。
    func testPlaygroundArchiveKeepsOtherLanguagesAsFiles() throws {
        let data = Exporter.export(format: .playground, title: "Go", languageID: "go",
                                   source: source)
        let paths = try Zip.entries(in: data).map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix(".go") })
        XCTAssertTrue(paths.contains("ContentView.swift"))
    }

    func testZipContainsSourceInputAndOutput() throws {
        let data = Exporter.export(format: .zip, title: "題", languageID: "go",
                                   source: source, result: try run(), input: "1 2")
        let entries = try Zip.entries(in: data)
        let paths = entries.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix(".go") })
        XCTAssertTrue(paths.contains("input.txt"))
        XCTAssertTrue(paths.contains("output.txt"))
        XCTAssertTrue(paths.contains("README.md"))
        let output = try XCTUnwrap(entries.first { $0.path == "output.txt" })
        XCTAssertTrue(try XCTUnwrap(String(data: output.data, encoding: .utf8))
            .contains("こんにちは"))
    }

    func testZipWithoutResultHasOnlyTheSource() throws {
        let data = Exporter.export(format: .zip, title: "題", languageID: "go",
                                   source: source)
        XCTAssertEqual(try Zip.entries(in: data).count, 1)
    }
}
