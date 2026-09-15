import XCTest
@testable import GitHubViewerCore

final class ContentClassifierTests: XCTestCase {
    func testHTMLIsWeb() {
        XCTAssertEqual(ContentClassifier.classify(fileName: "index.html", data: Data("<h1>hi</h1>".utf8)), .web)
        XCTAssertEqual(ContentClassifier.classify(fileName: "logo.svg", data: Data("<svg/>".utf8)), .web)
    }

    func testMarkdown() {
        XCTAssertEqual(ContentClassifier.classify(fileName: "README.md", data: Data("# hi".utf8)), .markdown)
    }

    func testImage() {
        XCTAssertEqual(ContentClassifier.classify(fileName: "a.PNG", data: Data([0x89, 0x50])), .image)
    }

    func testCodeLanguage() {
        XCTAssertEqual(ContentClassifier.classify(fileName: "main.swift", data: Data("let a = 1".utf8)),
                       .code(language: "swift"))
    }

    func testBinaryDetection() {
        let data = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(ContentClassifier.classify(fileName: "blob.bin", data: data), .binary)
        XCTAssertFalse(ContentClassifier.isProbablyText(data))
    }

    func testDisplayModeResolution() {
        XCTAssertEqual(DisplayMode.auto.resolved(for: .markdown), .markdown)
        XCTAssertEqual(DisplayMode.auto.resolved(for: .web), .web)
        XCTAssertEqual(DisplayMode.web.resolved(for: .markdown), .web, "明示的な選択は自動判定より優先される")
    }
}

final class MarkdownRendererTests: XCTestCase {
    func testHeadingAndParagraph() {
        let html = MarkdownRenderer.render("# タイトル\n\n本文です。")
        XCTAssertTrue(html.contains("<h1>タイトル</h1>"), html)
        XCTAssertTrue(html.contains("<p>本文です。</p>"), html)
    }

    func testInlineFormatting() {
        let html = MarkdownRenderer.inline("**太字** と *斜体* と `code` と [link](https://example.com)")
        XCTAssertTrue(html.contains("<strong>太字</strong>"), html)
        XCTAssertTrue(html.contains("<em>斜体</em>"), html)
        XCTAssertTrue(html.contains("<code>code</code>"), html)
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">link</a>"), html)
    }

    func testCodeFenceIsEscaped() {
        let html = MarkdownRenderer.render("```swift\nlet x = \"<b>\"\n```")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"), html)
        XCTAssertTrue(html.contains("&lt;b&gt;"), html)
        XCTAssertFalse(html.contains("<b>"), html)
    }

    func testList() {
        let html = MarkdownRenderer.render("- one\n- two\n")
        XCTAssertTrue(html.contains("<ul>"), html)
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 2, html)
    }

    func testTable() {
        let html = MarkdownRenderer.render("| a | b |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertTrue(html.contains("<table>"), html)
        XCTAssertTrue(html.contains("<th>a</th>"), html)
        XCTAssertTrue(html.contains("<td>2</td>"), html)
    }

    func testScriptInMarkdownIsEscaped() {
        let html = MarkdownRenderer.render("<script>alert(1)</script>")
        XCTAssertFalse(html.contains("<script>"), html)
    }
}

final class HTMLDocumentBuilderTests: XCTestCase {
    func testFullDocumentIsPassedThrough() {
        let source = "<!doctype html><html><body><p>hi</p></body></html>"
        XCTAssertEqual(HTMLDocumentBuilder.executable(html: source, title: "t"), source)
    }

    func testFragmentIsWrapped() {
        let html = HTMLDocumentBuilder.executable(html: "<p>hi</p>", title: "t")
        XCTAssertTrue(html.hasPrefix("<!doctype html>"), html)
        XCTAssertTrue(html.contains("<p>hi</p>"), html)
    }

    func testCodePageEscapes() {
        let html = HTMLDocumentBuilder.code("<script>", title: "t")
        XCTAssertTrue(html.contains("&lt;script&gt;"), html)
    }
}
