import XCTest
@testable import GitHubViewerCore

final class ANSIParserTests: XCTestCase {
    func testPlainTextIsOneRun() {
        let runs = ANSIParser.parse("こんにちは")
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].style.isPlain)
    }

    func testColour() {
        let runs = ANSIParser.parse("\u{1B}[31m赤\u{1B}[0m黒")
        XCTAssertEqual(runs.map(\.text), ["赤", "黒"])
        XCTAssertEqual(runs[0].style.foreground, .red)
        XCTAssertNil(runs[1].style.foreground)
    }

    func testBoldAndUnderline() {
        let runs = ANSIParser.parse("\u{1B}[1;4mここ")
        XCTAssertTrue(runs[0].style.isBold)
        XCTAssertTrue(runs[0].style.isUnderlined)
    }

    func testBrightColours() {
        let runs = ANSIParser.parse("\u{1B}[91m明るい赤")
        XCTAssertEqual(runs[0].style.foreground, .brightRed)
    }

    func testBackground() {
        let runs = ANSIParser.parse("\u{1B}[42m緑背景")
        XCTAssertEqual(runs[0].style.background, .green)
    }

    func testResetWithEmptyParameters() {
        let runs = ANSIParser.parse("\u{1B}[31m赤\u{1B}[m素")
        XCTAssertNil(runs[1].style.foreground)
    }

    func test256Colour() {
        let runs = ANSIParser.parse("\u{1B}[38;5;4m青")
        XCTAssertEqual(runs[0].style.foreground, .blue)
    }

    func testTrueColourIsSkippedWithoutBreaking() {
        let runs = ANSIParser.parse("\u{1B}[38;2;255;0;0m文字")
        XCTAssertEqual(runs.map(\.text), ["文字"])
    }

    func testCursorMovesAreIgnored() {
        XCTAssertEqual(ANSIParser.strip("a\u{1B}[2Cb"), "ab")
    }

    func testClearScreenDropsEarlierText() {
        let runs = ANSIParser.parse("消える\u{1B}[2J残る")
        XCTAssertEqual(runs.map(\.text), ["残る"])
    }

    func testStrip() {
        XCTAssertEqual(ANSIParser.strip("\u{1B}[1;32m成功\u{1B}[0m"), "成功")
    }

    func testUnfinishedEscapeIsKept() {
        XCTAssertFalse(ANSIParser.strip("a\u{1B}[1").isEmpty)
    }

    func testDetection() {
        XCTAssertTrue(ANSIParser.containsEscapes("\u{1B}[31m"))
        XCTAssertFalse(ANSIParser.containsEscapes("ふつうの文字"))
    }
}

final class OutputDocumentTests: XCTestCase {
    func testStreamsAreKeptApart() {
        let document = OutputDocument.make(standardOutput: "出た\n",
                                           standardError: "まずい\n")
        XCTAssertEqual(document.lines.count, 2)
        XCTAssertEqual(document.lines[0].stream, .standardOutput)
        XCTAssertEqual(document.lines[1].stream, .standardError)
    }

    func testCompilerOutputComesFirst() {
        let document = OutputDocument.make(standardOutput: "実行", compilerOutput: "警告")
        XCTAssertEqual(document.lines.first?.stream, .compiler)
    }

    func testTrailingNewlineDoesNotAddABlankLine() {
        XCTAssertEqual(OutputDocument.make(standardOutput: "a\nb\n").lineCount, 2)
    }

    func testFilter() {
        let document = OutputDocument.make(standardOutput: "a\n", standardError: "b\n")
        XCTAssertEqual(document.filtered(to: [.standardError]).plainText, "b")
    }

    func testPlainText() {
        let document = OutputDocument.make(standardOutput: "\u{1B}[31m赤\u{1B}[0m\n")
        XCTAssertEqual(document.plainText, "赤")
    }

    func testSearch() {
        let document = OutputDocument.make(standardOutput: "あい\nうえ\nあお\n")
        let found = document.search("あ")
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].lineID, 0)
        XCTAssertEqual(found[1].lineID, 2)
    }

    func testSearchWithRegularExpression() {
        let document = OutputDocument.make(standardOutput: "error: 1\nok\nerror: 2\n")
        var options = SearchOptions()
        options.isRegularExpression = true
        XCTAssertEqual(document.search("error: [0-9]", options: options).count, 2)
    }

    func testEmptySearch() {
        XCTAssertTrue(OutputDocument.make(standardOutput: "a").search("").isEmpty)
    }

    func testFoldingLongOutput() {
        let text = (1...1000).map(String.init).joined(separator: "\n")
        let folded = OutputDocument.make(standardOutput: text).folded(head: 10, tail: 5)
        XCTAssertTrue(folded.isFolded)
        XCTAssertEqual(folded.head.count, 10)
        XCTAssertEqual(folded.tail.count, 5)
        XCTAssertEqual(folded.hiddenCount, 985)
        XCTAssertTrue(folded.noticeText.contains("985"))
    }

    func testShortOutputIsNotFolded() {
        let folded = OutputDocument.make(standardOutput: "a\nb\n").folded(head: 10,
                                                                          tail: 5)
        XCTAssertFalse(folded.isFolded)
        XCTAssertEqual(folded.head.count, 2)
        XCTAssertTrue(folded.tail.isEmpty)
    }

    func testMakeFromRunResult() throws {
        let result = try RunSession.run(languageID: "javascript",
                                        source: "console.log('やあ');")
        let document = OutputDocument.make(result)
        XCTAssertTrue(document.plainText.contains("やあ"))
        XCTAssertTrue(document.lines.contains { $0.stream == .note })
    }
}

final class LineWrappingTests: XCTestCase {
    func testShortLineIsUnchanged() {
        XCTAssertEqual(LineWrapping.wrap("短い", columns: 20), ["短い"])
    }

    func testWrapsAtWordBoundary() {
        let wrapped = LineWrapping.wrap("aaa bbb ccc ddd", columns: 8)
        XCTAssertTrue(wrapped.count > 1)
        for line in wrapped { XCTAssertLessThanOrEqual(line.count, 8, line) }
    }

    func testLongWordIsCut() {
        let wrapped = LineWrapping.wrap(String(repeating: "x", count: 25), columns: 10)
        XCTAssertEqual(wrapped.count, 3)
    }

    func testKeepsExistingLineBreaks() {
        XCTAssertEqual(LineWrapping.wrap("a\nb", columns: 10), ["a", "b"])
    }

    func testZeroColumnsIsIgnored() {
        XCTAssertEqual(LineWrapping.wrap("abc", columns: 0), ["abc"])
    }

    func testModesHaveNames() {
        for mode in LineWrapMode.allCases { XCTAssertFalse(mode.displayName.isEmpty) }
    }
}

final class RunSharingTests: XCTestCase {
    private func makeResult() throws -> RunResult {
        try RunSession.run(languageID: "javascript", source: "console.log(42);")
    }

    func testOutputMarkdown() throws {
        let text = RunSharing.outputMarkdown(try makeResult())
        XCTAssertTrue(text.hasPrefix("```\n42"))
        XCTAssertTrue(text.hasSuffix("```"))
    }

    func testEmptyOutputIsLabelled() throws {
        let result = try RunSession.run(languageID: "javascript", source: "1 + 1;")
        XCTAssertTrue(RunSharing.outputMarkdown(result).contains("(出力なし)"))
    }

    func testCodeAndOutputMarkdown() throws {
        let text = RunSharing.markdown(source: "console.log(42);",
                                       result: try makeResult(), input: "入力です")
        XCTAssertTrue(text.contains("```javascript\nconsole.log(42);\n```"))
        XCTAssertTrue(text.contains("入力です"))
        XCTAssertTrue(text.contains("出力:"))
        XCTAssertTrue(text.contains("内蔵"))
    }

    func testMarkdownShowsErrors() throws {
        let result = try RunSession.run(languageID: "javascript",
                                        source: "ないやつ();")
        let text = RunSharing.markdown(source: "ないやつ();", result: result)
        XCTAssertTrue(text.contains("エラー:"), text)
    }

    func testPlainText() throws {
        let text = RunSharing.plainText(source: "console.log(42);",
                                        result: try makeResult())
        XCTAssertTrue(text.contains("--- コード ---"))
        XCTAssertTrue(text.contains("--- 出力 ---"))
    }

    func testComparisonTableIsEmptyWithoutResults() {
        XCTAssertEqual(RunSharing.comparisonTable([]), "")
    }

    func testANSIIsStrippedWhenSharing() {
        let execution = MiniLangExecution(parsed: true, output: "\u{1B}[31m赤\u{1B}[0m")
        let result = RunResult(languageID: "go", engineName: "x", execution: execution)
        XCTAssertTrue(RunSharing.outputMarkdown(result).contains("赤"))
        XCTAssertFalse(RunSharing.outputMarkdown(result).contains("\u{1B}"))
    }
}

final class OutputStreamTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(OutputStream.standardError.displayName, "標準エラー")
        XCTAssertEqual(OutputStream.compiler.displayName, "コンパイル")
    }
}
