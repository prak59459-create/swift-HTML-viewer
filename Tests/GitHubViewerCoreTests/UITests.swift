import XCTest
@testable import GitHubViewerCore

final class LayoutTests: XCTestCase {
    func testModeFlags() {
        XCTAssertTrue(LayoutMode.editorOnly.showsEditor)
        XCTAssertFalse(LayoutMode.editorOnly.showsOutput)
        XCTAssertTrue(LayoutMode.sideBySide.isSplit)
        XCTAssertTrue(LayoutMode.sideBySide.isHorizontal)
        XCTAssertFalse(LayoutMode.stacked.isHorizontal)
    }

    func testSuggestedLayout() {
        XCTAssertEqual(LayoutMode.suggested(width: 1200, height: 800), .sideBySide)
        XCTAssertEqual(LayoutMode.suggested(width: 800, height: 1200), .stacked)
    }

    func testNames() {
        for mode in LayoutMode.allCases { XCTAssertFalse(mode.displayName.isEmpty) }
    }

    func testSplitRatioIsClamped() {
        XCTAssertEqual(SplitRatio(0.01).value, SplitRatio.minimum)
        XCTAssertEqual(SplitRatio(0.99).value, SplitRatio.maximum)
    }

    func testSplitSizes() {
        let ratio = SplitRatio(0.25)
        XCTAssertEqual(ratio.leading(of: 400), 100)
        XCTAssertEqual(ratio.trailing(of: 400), 300)
    }

    func testDragging() {
        var ratio = SplitRatio(0.5)
        ratio.drag(by: 100, total: 1000)
        XCTAssertEqual(ratio.value, 0.6, accuracy: 0.001)
        ratio.reset()
        XCTAssertEqual(ratio.value, 0.5)
    }

    func testDraggingWithZeroTotal() {
        var ratio = SplitRatio(0.5)
        ratio.drag(by: 100, total: 0)
        XCTAssertEqual(ratio.value, 0.5)
    }
}

final class DisplayStateTests: XCTestCase {
    func testZoomIsClamped() {
        var state = DisplayState()
        state.setZoom(99)
        XCTAssertEqual(state.zoom, DisplayState.maximumZoom)
        state.setZoom(0.01)
        XCTAssertEqual(state.zoom, DisplayState.minimumZoom)
    }

    func testPinchAndSteps() {
        var state = DisplayState()
        state.pinch(by: 1.5)
        XCTAssertEqual(state.zoom, 1.5, accuracy: 0.001)
        state.resetZoom()
        XCTAssertTrue(state.isDefaultZoom)
        state.zoomIn()
        XCTAssertEqual(state.zoom, 1.1, accuracy: 0.001)
        state.zoomOut()
        XCTAssertEqual(state.zoom, 1.0, accuracy: 0.001)
    }

    func testZoomText() {
        var state = DisplayState()
        state.setZoom(1.25)
        XCTAssertEqual(state.zoomText, "125%")
    }

    func testFocusModeHidesChrome() {
        var state = DisplayState()
        XCTAssertTrue(state.showsSidebar)
        state.toggleFocus()
        XCTAssertTrue(state.isFocused)
        XCTAssertFalse(state.showsSidebar)
        XCTAssertFalse(state.showsStatusBar)
        XCTAssertFalse(state.showsTabBar)
    }

    func testCodable() throws {
        var state = DisplayState()
        state.setZoom(2)
        state.layout = .stacked
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(DisplayState.self, from: data)
        XCTAssertEqual(back.zoom, 2)
        XCTAssertEqual(back.layout, .stacked)
    }
}

final class SplitEditorTests: XCTestCase {
    func testSplitAndClose() {
        var editor = SplitEditor()
        let first = UUID()
        let second = UUID()
        editor.primaryTabID = first
        editor.split(with: second)
        XCTAssertTrue(editor.isSplit)
        XCTAssertEqual(editor.activeTabID, second)

        editor.close()
        XCTAssertFalse(editor.isSplit)
        XCTAssertEqual(editor.primaryTabID, second)
    }

    func testSplitWithoutATabReusesThePrimary() {
        var editor = SplitEditor()
        let first = UUID()
        editor.primaryTabID = first
        editor.split(with: nil)
        XCTAssertEqual(editor.secondaryTabID, first)
    }

    func testToggleFocus() {
        var editor = SplitEditor()
        editor.split(with: UUID())
        editor.toggleFocus()
        XCTAssertFalse(editor.focusIsSecondary)
        XCTAssertEqual(editor.activeTabID, editor.primaryTabID)
    }

    func testToggleFocusDoesNothingWhenNotSplit() {
        var editor = SplitEditor()
        editor.toggleFocus()
        XCTAssertFalse(editor.focusIsSecondary)
    }

    func testSwap() {
        var editor = SplitEditor()
        let first = UUID()
        let second = UUID()
        editor.primaryTabID = first
        editor.split(with: second)
        editor.swap()
        XCTAssertEqual(editor.primaryTabID, second)
        XCTAssertEqual(editor.secondaryTabID, first)
    }

    func testPlaceUsesTheFocusedSide() {
        var editor = SplitEditor()
        editor.split(with: UUID())
        let new = UUID()
        editor.place(new)
        XCTAssertEqual(editor.secondaryTabID, new)
    }

    func testForgetClosedTab() {
        var editor = SplitEditor()
        let second = UUID()
        editor.primaryTabID = UUID()
        editor.split(with: second)
        editor.forget(second)
        XCTAssertFalse(editor.isSplit)
    }
}

final class ImageViewerStateTests: XCTestCase {
    func testPinch() {
        var state = ImageViewerState()
        state.pinch(by: 2)
        XCTAssertEqual(state.scale, 2)
        XCTAssertEqual(state.scaleText, "200%")
    }

    func testScaleIsClamped() {
        var state = ImageViewerState()
        state.pinch(by: 1000)
        XCTAssertEqual(state.scale, ImageViewerState.maximumScale)
    }

    func testPanAndReset() {
        var state = ImageViewerState()
        state.pinch(by: 2)
        state.pan(dx: 10, dy: -5)
        XCTAssertEqual(state.offsetX, 10)
        XCTAssertEqual(state.offsetY, -5)
        state.reset()
        XCTAssertEqual(state.offsetX, 0)
        XCTAssertTrue(state.isFit)
    }

    func testDoubleTapToggles() {
        var state = ImageViewerState()
        state.toggleZoom()
        XCTAssertEqual(state.scale, 2)
        state.toggleZoom()
        XCTAssertTrue(state.isFit)
    }

    func testReturningToFitClearsTheOffset() {
        var state = ImageViewerState()
        state.pinch(by: 3)
        state.pan(dx: 30, dy: 30)
        state.pinch(by: 1.0 / 3.0)
        XCTAssertEqual(state.offsetX, 0)
    }

    func testFitScale() {
        XCTAssertEqual(ImageViewerState.fitScale(imageWidth: 200, imageHeight: 100,
                                                 viewWidth: 100, viewHeight: 100), 0.5)
        XCTAssertEqual(ImageViewerState.fitScale(imageWidth: 0, imageHeight: 0,
                                                 viewWidth: 100, viewHeight: 100), 1)
    }
}

final class DevicePresetTests: XCTestCase {
    func testPresets() {
        XCTAssertFalse(DevicePresets.all.isEmpty)
        XCTAssertNotNil(DevicePresets.preset(named: "iPad Pro 11"))
        XCTAssertNil(DevicePresets.preset(named: "どこにもない"))
    }

    func testRotation() {
        let preset = DevicePresets.all[0]
        XCTAssertFalse(preset.isLandscape)
        XCTAssertTrue(preset.rotated.isLandscape)
        XCTAssertEqual(preset.rotated.width, preset.height)
    }

    func testSizeText() {
        XCTAssertEqual(DevicePreset(name: "x", width: 390, height: 844).sizeText,
                       "390 × 844")
    }

    func testBreakpointNames() {
        XCTAssertTrue(DevicePresets.breakpointName(forWidth: 375).contains("とても狭い"))
        XCTAssertTrue(DevicePresets.breakpointName(forWidth: 1400).contains("とても広い"))
    }
}

final class MarkdownFeatureTests: XCTestCase {
    let markdown = """
    # タイトル

    説明の文。

    ```javascript
    console.log(1);
    ```

    ## 次の節

    ```
    ただの文字
    ```
    """

    func testViewModes() {
        XCTAssertTrue(MarkdownViewMode.both.showsPreview)
        XCTAssertTrue(MarkdownViewMode.both.showsSource)
        XCTAssertFalse(MarkdownViewMode.preview.showsSource)
        for mode in MarkdownViewMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }

    func testScrollAnchors() {
        let anchors = MarkdownScrollSync.anchors(in: markdown)
        XCTAssertEqual(anchors.map(\.line), [1, 9])
        XCTAssertEqual(MarkdownScrollSync.headingIndex(forSourceLine: 10,
                                                       in: markdown), 1)
        XCTAssertEqual(MarkdownScrollSync.sourceLine(forHeadingIndex: 1,
                                                     in: markdown), 9)
    }

    func testHeadingsInsideCodeAreIgnored() {
        let anchors = MarkdownScrollSync.anchors(in: "# 本物\n```\n# 偽物\n```\n")
        XCTAssertEqual(anchors.count, 1)
    }

    func testCodeBlocks() {
        let blocks = MarkdownCode.blocks(in: markdown)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].language, "javascript")
        XCTAssertEqual(blocks[0].code, "console.log(1);")
        XCTAssertNil(blocks[1].language)
    }

    func testRunnableBlocks() {
        let runnable = MarkdownCode.runnableBlocks(in: markdown)
        XCTAssertEqual(runnable.count, 1)
        XCTAssertEqual(runnable.first?.runnableLanguageID, "javascript")
    }

    func testLanguageAliases() {
        XCTAssertEqual(MarkdownCodeBlock.normalize("JS"), "javascript")
        XCTAssertEqual(MarkdownCodeBlock.normalize("c++"), "cpp")
        XCTAssertEqual(MarkdownCodeBlock.normalize("sh"), "shell")
    }

    func testRunABlock() throws {
        let block = MarkdownCode.runnableBlocks(in: markdown)[0]
        let result = try MarkdownCode.run(block)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "1")
    }

    func testRunningANonRunnableBlockThrows() {
        let block = MarkdownCode.blocks(in: markdown)[1]
        XCTAssertThrowsError(try MarkdownCode.run(block))
    }

    func testInsertingTheOutput() throws {
        let block = MarkdownCode.runnableBlocks(in: markdown)[0]
        let result = try MarkdownCode.run(block)
        let updated = MarkdownCode.inserting(result, after: block, in: markdown)
        XCTAssertTrue(updated.contains("出力:"))
        XCTAssertTrue(updated.contains("## 次の節"))
    }

    func testTildeFences() {
        let blocks = MarkdownCode.blocks(in: "~~~python\nprint(1)\n~~~\n")
        XCTAssertEqual(blocks.first?.language, "python")
    }
}

final class EmbeddedContentTests: XCTestCase {
    func testDisplayMath() {
        let blocks = EmbeddedContent.blocks(in: "文\n\n$$\nx^2 + y^2\n$$\n")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .displayMath)
        XCTAssertEqual(blocks[0].content, "x^2 + y^2")
    }

    func testInlineMath() {
        let blocks = EmbeddedContent.blocks(in: "式は $a + b$ です。")
        XCTAssertEqual(blocks.first?.kind, .inlineMath)
        XCTAssertEqual(blocks.first?.content, "a + b")
    }

    func testSameLineDisplayMath() {
        let blocks = EmbeddedContent.blocks(in: "$$E = mc^2$$")
        XCTAssertEqual(blocks.first?.kind, .displayMath)
        XCTAssertEqual(blocks.first?.content, "E = mc^2")
    }

    func testEscapedDollarIsNotMath() {
        XCTAssertTrue(EmbeddedContent.blocks(in: "値段は \\$100 です").isEmpty)
    }

    func testMermaid() {
        let markdown = "```mermaid\ngraph TD\n  A --> B\n```\n"
        let blocks = EmbeddedContent.blocks(in: markdown)
        XCTAssertEqual(blocks.first?.kind, .mermaid)
        XCTAssertTrue(blocks.first!.content.contains("graph TD"))
    }

    func testMathInsideCodeIsIgnored() {
        let markdown = "```\n$a + b$\n```\n"
        XCTAssertFalse(EmbeddedContent.hasMath(markdown))
    }

    func testRequiredLibraries() {
        XCTAssertEqual(EmbeddedContent.requiredLibraries(for: "$x$"), ["KaTeX"])
        XCTAssertEqual(EmbeddedContent.requiredLibraries(for: "```mermaid\na\n```"),
                       ["Mermaid"])
        XCTAssertTrue(EmbeddedContent.requiredLibraries(for: "ふつうの文").isEmpty)
    }

    func testKindNames() {
        for kind in [EmbeddedBlock.Kind.displayMath, .inlineMath, .mermaid] {
            XCTAssertFalse(kind.displayName.isEmpty)
        }
    }
}

final class TablePreviewTests: XCTestCase {
    func testCSV() {
        let table = CSVParser.parse("名前,年\nあ,3\nい,4\n")
        XCTAssertEqual(table.columns, ["名前", "年"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.row(0), ["あ", "3"])
        XCTAssertEqual(table.summary, "2 列 × 2 行")
    }

    func testQuotedFields() {
        let table = CSVParser.parse("a,b\n\"1,2\",3\n")
        XCTAssertEqual(table.row(0), ["1,2", "3"])
    }

    func testEscapedQuotes() {
        let table = CSVParser.parse("a\n\"言\"\"葉\"\n")
        XCTAssertEqual(table.row(0), ["言\"葉"])
    }

    func testNewlineInsideQuotes() {
        let table = CSVParser.parse("a,b\n\"1\n2\",3\n")
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.row(0)[0], "1\n2")
    }

    func testTabSeparated() {
        let table = CSVParser.parse("a\tb\n1\t2\n")
        XCTAssertEqual(table.columns, ["a", "b"])
    }

    func testGuessSeparator() {
        XCTAssertEqual(CSVParser.guessSeparator("a;b;c\n"), ";")
        XCTAssertEqual(CSVParser.guessSeparator("a,b\n"), ",")
    }

    func testWithoutHeader() {
        let table = CSVParser.parse("1,2\n3,4\n", hasHeader: false)
        XCTAssertEqual(table.columns, ["列 1", "列 2"])
        XCTAssertEqual(table.rows.count, 2)
    }

    func testRowLimit() {
        let text = (1...50).map { "\($0)" }.joined(separator: "\n")
        let table = CSVParser.parse(text, hasHeader: false, maximumRows: 10)
        XCTAssertEqual(table.rows.count, 10)
        XCTAssertGreaterThan(table.skippedRows, 0)
    }

    func testEmptyText() {
        XCTAssertTrue(CSVParser.parse("").isEmpty)
    }

    func testColumnWidths() {
        let table = CSVParser.parse("ab,c\n1,2345\n")
        XCTAssertEqual(table.columnWidths, [2, 4])
    }

    func testShortRowIsPadded() {
        let table = CSVParser.parse("a,b,c\n1\n")
        XCTAssertEqual(table.row(0).count, 3)
    }
}

final class JSONPreviewTests: XCTestCase {
    func testArrayOfObjects() {
        let table = JSONPreview.table(#"[{"a":1,"b":"x"},{"a":2}]"#)
        XCTAssertEqual(table?.columns, ["a", "b"])
        XCTAssertEqual(table?.rows[0], ["1", "x"])
        XCTAssertEqual(table?.rows[1][1], "null")
    }

    func testPlainArray() {
        let table = JSONPreview.table("[1, 2, 3]")
        XCTAssertEqual(table?.columns, ["値"])
        XCTAssertEqual(table?.rows.count, 3)
    }

    func testObject() {
        let table = JSONPreview.table(#"{"b":2,"a":1}"#)
        XCTAssertEqual(table?.columns, ["キー", "値"])
        XCTAssertEqual(table?.rows.first, ["a", "1"])
    }

    func testBooleansAndNull() {
        let table = JSONPreview.table(#"[{"t":true,"f":false,"n":null}]"#)
        XCTAssertEqual(table?.rows[0], ["false", "null", "true"])
    }

    func testTree() {
        let tree = JSONPreview.tree(#"{"a":[1,2],"b":{"c":3}}"#)
        XCTAssertEqual(tree?.children.count, 2)
        XCTAssertEqual(tree?.children[0].children.count, 2)
        XCTAssertEqual(tree?.children[1].children.first?.text, "3")
    }

    func testFormatted() {
        let text = JSONPreview.formatted(#"{"b":1,"a":2}"#)
        XCTAssertTrue(text?.contains("\n") == true)
        XCTAssertTrue(text?.range(of: "\"a\"")?.lowerBound
            ?? text!.endIndex < text!.range(of: "\"b\"")!.lowerBound)
    }

    func testValidity() {
        XCTAssertTrue(JSONPreview.isValid("[1]"))
        XCTAssertFalse(JSONPreview.isValid("{こわれている"))
        XCTAssertNil(JSONPreview.table("{こわれている"))
    }
}

final class YAMLPreviewTests: XCTestCase {
    func testKeysAndValues() {
        let tree = YAMLPreview.tree("name: あいう\nversion: 2\n")
        XCTAssertEqual(tree.children.map(\.label), ["name", "version"])
        XCTAssertEqual(tree.children[0].text, "あいう")
    }

    func testNesting() {
        let tree = YAMLPreview.tree("""
        server:
          host: localhost
          port: 8080
        """)
        XCTAssertEqual(tree.children.count, 1)
        XCTAssertEqual(tree.children[0].children.map(\.label), ["host", "port"])
    }

    func testList() {
        let tree = YAMLPreview.tree("""
        items:
          - りんご
          - みかん
        """)
        XCTAssertEqual(tree.children[0].children.count, 2)
        XCTAssertEqual(tree.children[0].children[0].text, "りんご")
    }

    func testCommentsAreIgnored() {
        let tree = YAMLPreview.tree("# 説明\nname: x   # うしろのコメント\n")
        XCTAssertEqual(tree.children.count, 1)
        XCTAssertEqual(tree.children[0].text, "x")
    }

    func testQuotesAreRemoved() {
        let tree = YAMLPreview.tree("name: \"あ: い\"\n")
        XCTAssertEqual(tree.children[0].text, "あ: い")
    }

    func testDocumentMarkersAreSkipped() {
        let tree = YAMLPreview.tree("---\na: 1\n...\n")
        XCTAssertEqual(tree.children.count, 1)
    }

    func testTable() {
        let table = YAMLPreview.table("a: 1\nb: 2\n")
        XCTAssertEqual(table.columns, ["キー", "値"])
        XCTAssertEqual(table.rows.count, 2)
    }
}

final class HexDumpTests: XCTestCase {
    func testLines() {
        let data = Data((0..<20).map { UInt8($0) })
        let lines = HexDump.lines(of: data)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].offset, 0)
        XCTAssertEqual(lines[1].offset, 16)
        XCTAssertTrue(lines[0].hex.hasPrefix("00 01 02"))
    }

    func testAsciiColumn() {
        let lines = HexDump.lines(of: Data("Hi\u{01}".utf8))
        XCTAssertEqual(lines[0].ascii, "Hi.")
    }

    func testTextFormat() {
        let text = HexDump.text(of: Data("A".utf8))
        XCTAssertTrue(text.hasPrefix("00000000  41"))
        XCTAssertTrue(text.contains("|A|"))
    }

    func testLineLimit() {
        let data = Data(repeating: 0, count: 1000)
        XCTAssertEqual(HexDump.lines(of: data, maximumLines: 3).count, 3)
    }

    func testEmptyData() {
        XCTAssertTrue(HexDump.lines(of: Data()).isEmpty)
    }

    func testFileTypeGuess() {
        XCTAssertEqual(HexDump.fileTypeGuess(Data([0x89, 0x50, 0x4E, 0x47])), "PNG 画像")
        XCTAssertEqual(HexDump.fileTypeGuess(Data("%PDF-1.4".utf8)), "PDF")
        XCTAssertNil(HexDump.fileTypeGuess(Data("ふつうの文字".utf8)))
    }
}

final class ImageInspectorTests: XCTestCase {
    func testPNG() {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += [0, 0, 0, 13]                      // IHDR の長さ
        bytes += Array("IHDR".utf8)
        bytes += [0, 0, 0x04, 0x00]                 // 幅 1024
        bytes += [0, 0, 0x03, 0x00]                 // 高さ 768
        bytes += [8, 6, 0, 0, 0]
        let info = ImageInspector.info(from: Data(bytes))
        XCTAssertEqual(info?.format, "PNG")
        XCTAssertEqual(info?.width, 1024)
        XCTAssertEqual(info?.height, 768)
        XCTAssertEqual(info?.bitDepth, 8)
        XCTAssertEqual(info?.sizeText, "1024 × 768")
    }

    func testGIF() {
        var bytes = Array("GIF89a".utf8)
        bytes += [0x20, 0x00, 0x10, 0x00]           // 32 × 16
        let info = ImageInspector.info(from: Data(bytes))
        XCTAssertEqual(info?.format, "GIF")
        XCTAssertEqual(info?.width, 32)
        XCTAssertEqual(info?.height, 16)
        XCTAssertTrue(info!.isAnimated)
    }

    func testJPEG() {
        var bytes: [UInt8] = [0xFF, 0xD8]
        bytes += [0xFF, 0xC0, 0x00, 0x11, 0x08]     // SOF0
        bytes += [0x00, 0x64]                       // 高さ 100
        bytes += [0x00, 0xC8]                       // 幅 200
        bytes += Array(repeating: 0, count: 10)
        let info = ImageInspector.info(from: Data(bytes))
        XCTAssertEqual(info?.format, "JPEG")
        XCTAssertEqual(info?.width, 200)
        XCTAssertEqual(info?.height, 100)
    }

    func testBMP() {
        var bytes: [UInt8] = [0x42, 0x4D]
        bytes += Array(repeating: 0, count: 16)
        bytes += [0x40, 0, 0, 0]                    // 幅 64
        bytes += [0x20, 0, 0, 0]                    // 高さ 32
        bytes += Array(repeating: 0, count: 4)
        let info = ImageInspector.info(from: Data(bytes))
        XCTAssertEqual(info?.format, "BMP")
        XCTAssertEqual(info?.width, 64)
    }

    func testSVG() {
        let svg = #"<svg width="120" height="60" xmlns="http://www.w3.org/2000/svg"/>"#
        let info = ImageInspector.info(from: Data(svg.utf8))
        XCTAssertEqual(info?.format, "SVG")
        XCTAssertEqual(info?.width, 120)
    }

    func testNotAnImage() {
        XCTAssertNil(ImageInspector.info(from: Data("ただの文字です".utf8)))
    }

    func testSummaryAndRatio() {
        let info = ImageInfo(format: "PNG", width: 200, height: 100, byteCount: 2048)
        XCTAssertEqual(info.aspectRatio, 2)
        XCTAssertEqual(info.pixelCount, 20000)
        XCTAssertTrue(info.summary.contains("2.0 KB"))
    }
}

final class MediaClassifierTests: XCTestCase {
    func testByExtension() {
        XCTAssertEqual(MediaClassifier.kind(fileName: "a.png"), .image)
        XCTAssertEqual(MediaClassifier.kind(fileName: "a.pdf"), .pdf)
        XCTAssertEqual(MediaClassifier.kind(fileName: "a.mp4"), .video)
        XCTAssertEqual(MediaClassifier.kind(fileName: "a.mp3"), .audio)
        XCTAssertEqual(MediaClassifier.kind(fileName: "a.woff2"), .font)
        XCTAssertEqual(MediaClassifier.kind(fileName: "a.zip"), .archive)
        XCTAssertEqual(MediaClassifier.kind(fileName: "a.swift"), .other)
    }

    func testByContent() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])
        XCTAssertEqual(MediaClassifier.kind(fileName: "なぞ", data: png), .image)
    }

    func testViewable() {
        XCTAssertTrue(MediaKind.image.isViewable)
        XCTAssertFalse(MediaKind.archive.isViewable)
        for kind in [MediaKind.image, .pdf, .video, .audio, .font, .archive, .other] {
            XCTAssertFalse(kind.displayName.isEmpty)
        }
    }

    func testPDFPageCount() {
        let pdf = "%PDF-1.4\n/Type /Pages\n/Type /Page\n/Type /Page\n"
        XCTAssertEqual(MediaClassifier.pdfPageCount(Data(pdf.utf8)), 2)
        XCTAssertNil(MediaClassifier.pdfPageCount(Data("ただの文字".utf8)))
    }

    func testPDFTitle() {
        let pdf = "%PDF-1.4\n/Title (私の資料)\n"
        XCTAssertEqual(MediaClassifier.pdfTitle(Data(pdf.utf8)), "私の資料")
    }
}

final class FontInspectorTests: XCTestCase {
    func testTrueTypeHeader() {
        var bytes: [UInt8] = [0x00, 0x01, 0x00, 0x00]
        bytes += [0x00, 0x01]                        // テーブル 1 個
        bytes += Array(repeating: 0, count: 6)
        bytes += Array("maxp".utf8)
        bytes += [0, 0, 0, 0]                        // チェックサム
        bytes += [0, 0, 0, 28]                       // テーブルの位置
        bytes += [0, 0, 0, 32]                       // 長さ
        bytes += [0, 0, 0, 0]                        // maxp の version
        bytes += [0x01, 0x00]                        // 字の数 256
        bytes += Array(repeating: 0, count: 8)
        let info = FontInspector.info(from: Data(bytes))
        XCTAssertEqual(info?.format, "TrueType")
        XCTAssertEqual(info?.glyphCount, 256)
    }

    func testWOFF() {
        let bytes: [UInt8] = Array("wOFF".utf8) + Array(repeating: 0, count: 16)
        XCTAssertEqual(FontInspector.info(from: Data(bytes))?.format, "WOFF")
    }

    func testNotAFont() {
        XCTAssertNil(FontInspector.info(from: Data("ただの文字です".utf8)))
    }

    func testSampleTexts() {
        XCTAssertFalse(FontInspector.sampleTexts.isEmpty)
        XCTAssertTrue(FontInspector.sampleTexts.contains { $0.contains("あ") })
    }

    func testSummary() {
        let info = FontInfo(format: "WOFF", glyphCount: 100, familyName: "Test",
                            byteCount: 1024)
        XCTAssertTrue(info.summary.contains("100 字"))
        XCTAssertTrue(info.summary.contains("Test"))
    }
}

final class ChunkedTextTests: XCTestCase {
    private var text: String {
        (1...100).map(String.init).joined(separator: "\n")
    }

    func testFirstChunk() {
        let chunked = ChunkedText(text: text, chunkSize: 10)
        XCTAssertEqual(chunked.visibleCount, 10)
        XCTAssertTrue(chunked.hasMore)
        XCTAssertEqual(chunked.remaining, 90)
        XCTAssertEqual(chunked.visibleText.components(separatedBy: "\n").count, 10)
    }

    func testLoadMore() {
        var chunked = ChunkedText(text: text, chunkSize: 10)
        chunked.loadMore()
        XCTAssertEqual(chunked.visibleCount, 20)
        chunked.loadAll()
        XCTAssertFalse(chunked.hasMore)
    }

    func testReveal() {
        var chunked = ChunkedText(text: text, chunkSize: 10)
        chunked.reveal(line: 50)
        XCTAssertGreaterThanOrEqual(chunked.visibleCount, 50)
    }

    func testRevealingAnAlreadyVisibleLineDoesNothing() {
        var chunked = ChunkedText(text: text, chunkSize: 50)
        chunked.reveal(line: 5)
        XCTAssertEqual(chunked.visibleCount, 50)
    }

    func testShortTextNeedsNoChunking() {
        let chunked = ChunkedText(text: "a\nb", chunkSize: 100)
        XCTAssertFalse(chunked.hasMore)
        XCTAssertFalse(ChunkedText.needsChunking("a\nb"))
        XCTAssertTrue(ChunkedText.needsChunking(text, threshold: 10))
    }

    func testProgressText() {
        let chunked = ChunkedText(text: text, chunkSize: 10)
        XCTAssertEqual(chunked.progressText, "10 / 100 行")
    }
}

final class SQLiteInspectorTests: XCTestCase {
    private func makeHeader(tables: [String] = []) -> Data {
        var bytes = Array("SQLite format 3\0".utf8)
        bytes += [0x10, 0x00]                        // ページの大きさ 4096
        bytes += Array(repeating: 0, count: 10)
        bytes += [0, 0, 0, 5]                        // ページ数 5
        bytes += Array(repeating: 0, count: 100)
        for table in tables { bytes += Array("CREATE TABLE \(table) (".utf8) }
        return Data(bytes)
    }

    func testDetection() {
        XCTAssertTrue(SQLiteInspector.isSQLite(makeHeader()))
        XCTAssertFalse(SQLiteInspector.isSQLite(Data("ただの文字".utf8)))
    }

    func testHeader() {
        let info = SQLiteInspector.info(from: makeHeader())
        XCTAssertEqual(info?.pageSize, 4096)
        XCTAssertEqual(info?.pageCount, 5)
    }

    func testTableNames() {
        let info = SQLiteInspector.info(from: makeHeader(tables: ["users", "posts",
                                                                  "sqlite_sequence"]))
        XCTAssertEqual(info?.tableNames, ["users", "posts"])
        XCTAssertTrue(info!.summary.contains("2 テーブル"))
    }

    func testNotSQLite() {
        XCTAssertNil(SQLiteInspector.info(from: Data("ただの文字".utf8)))
    }
}
