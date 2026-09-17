import XCTest
@testable import GitHubViewerCore

final class StatusBarTests: XCTestCase {
    func testPositionAndLanguage() {
        let info = StatusBarInfo.make(text: "let a = 1\nlet b = 2", caretLocation: 12,
                                      selectionLength: 0, languageID: "swift",
                                      settings: .default)
        XCTAssertEqual(info.position, "2:3")
        XCTAssertEqual(info.languageName, "Swift")
        XCTAssertEqual(info.encodingName, "UTF-8")
        XCTAssertEqual(info.lineEndingName, "LF")
        XCTAssertEqual(info.indentName, "空白 4")
    }

    func testSelectionSummary() {
        let info = StatusBarInfo.make(text: "abcdef", caretLocation: 1,
                                      selectionLength: 3, languageID: nil,
                                      settings: .default)
        XCTAssertTrue(info.selection?.contains("3 文字") == true)
    }

    func testNoSelection() {
        let info = StatusBarInfo.make(text: "abc", caretLocation: 0,
                                      selectionLength: 0, languageID: nil,
                                      settings: .default)
        XCTAssertNil(info.selection)
    }

    func testTabIndent() {
        var settings = EditorSettings()
        settings.indent = IndentStyle(usesSpaces: false, width: 4)
        let info = StatusBarInfo.make(text: "a", caretLocation: 0, selectionLength: 0,
                                      languageID: nil, settings: settings)
        XCTAssertEqual(info.indentName, "タブ")
    }

    func testCRLFIsReported() {
        let info = StatusBarInfo.make(text: "a\r\nb", caretLocation: 0,
                                      selectionLength: 0, languageID: nil,
                                      settings: .default)
        XCTAssertEqual(info.lineEndingName, "CRLF")
    }

    func testDiagnosticsAndRun() throws {
        let run = try RunSession.run(languageID: "javascript",
                                     source: "console.log(1);")
        let diagnostics = DiagnosticSet(items: [
            InlineDiagnostic(line: 1, severity: .warning, message: "x")
        ])
        let info = StatusBarInfo.make(text: "a", caretLocation: 0, selectionLength: 0,
                                      languageID: "javascript", settings: .default,
                                      diagnostics: diagnostics, run: run,
                                      rateLimit: RateLimitStatus(limit: 60,
                                                                 remaining: 42,
                                                                 resetDate: nil))
        XCTAssertTrue(info.text.contains("警告 1"))
        XCTAssertTrue(info.text.contains("ステップ"))
        XCTAssertTrue(info.text.contains("あと 42"))
    }

    func testEmptyDiagnosticsAreHidden() {
        let info = StatusBarInfo.make(text: "a", caretLocation: 0, selectionLength: 0,
                                      languageID: nil, settings: .default,
                                      diagnostics: DiagnosticSet())
        XCTAssertNil(info.diagnostics)
    }
}

final class ToastTests: XCTestCase {
    func testShowAndDismiss() {
        var queue = ToastQueue()
        queue.show("保存しました", style: .success)
        XCTAssertEqual(queue.toasts.count, 1)
        queue.dismiss(id: queue.toasts[0].id)
        XCTAssertTrue(queue.isEmpty)
    }

    func testDuplicatesAreReplaced() {
        var queue = ToastQueue()
        queue.show("同じ")
        queue.show("同じ")
        XCTAssertEqual(queue.toasts.count, 1)
    }

    func testLimit() {
        var queue = ToastQueue(limit: 2)
        for name in ["a", "b", "c"] { queue.show(name) }
        XCTAssertEqual(queue.toasts.map(\.message), ["b", "c"])
    }

    func testPruning() {
        var queue = ToastQueue()
        let old = Toast(style: .info, message: "古い",
                        createdAt: Date(timeIntervalSince1970: 0))
        queue.show(old)
        queue.prune(at: Date())
        XCTAssertTrue(queue.isEmpty)
    }

    func testErrorsStayLonger() {
        XCTAssertGreaterThan(Toast.Style.error.duration, Toast.Style.info.duration)
        for style in [Toast.Style.info, .success, .warning, .error] {
            XCTAssertFalse(style.symbol.isEmpty)
        }
    }

    func testVisibility() {
        let toast = Toast(style: .info, message: "x",
                          createdAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(toast.isVisible(at: Date(timeIntervalSince1970: 101)))
        XCTAssertFalse(toast.isVisible(at: Date(timeIntervalSince1970: 200)))
    }
}

final class ProgressStateTests: XCTestCase {
    func testFraction() {
        let progress = ProgressState(title: "取得中", completed: 25, total: 100)
        XCTAssertEqual(progress.fraction, 0.25)
        XCTAssertTrue(progress.isDeterminate)
        XCTAssertEqual(progress.progressText, "25 / 100 (25%)")
    }

    func testIndeterminate() {
        let progress = ProgressState(title: "待っています", detail: "接続中")
        XCTAssertFalse(progress.isDeterminate)
        XCTAssertEqual(progress.progressText, "接続中")
        XCTAssertEqual(progress.fraction, 0)
    }

    func testFinished() {
        XCTAssertTrue(ProgressState(title: "x", completed: 10, total: 10).isFinished)
        XCTAssertFalse(ProgressState(title: "x", completed: 1, total: 10).isFinished)
    }

    func testEstimate() {
        let start = Date(timeIntervalSince1970: 0)
        let progress = ProgressState(title: "x", completed: 10, total: 100,
                                     startedAt: start)
        let remaining = progress.estimatedRemaining(at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(remaining ?? 0, 90, accuracy: 0.001)
        XCTAssertTrue(progress.remainingText(at: Date(timeIntervalSince1970: 10))?
            .contains("あと") == true)
    }

    func testNoEstimateAtTheStart() {
        let progress = ProgressState(title: "x", completed: 0, total: 100)
        XCTAssertNil(progress.estimatedRemaining())
    }
}

final class FailureStateTests: XCTestCase {
    func testRateLimit() {
        let state = FailureState.make(from: GitHubClientError.rateLimited)
        XCTAssertTrue(state.canRetry)
        XCTAssertTrue(state.hint?.contains("トークン") == true)
    }

    func testNotFoundCannotRetry() {
        let state = FailureState.make(from: GitHubClientError.notFound("a/b"))
        XCTAssertFalse(state.canRetry)
    }

    func testServerErrorCanRetry() {
        let state = FailureState.make(from: GitHubClientError.http(status: 503,
                                                                   message: "x"))
        XCTAssertTrue(state.canRetry)
        XCTAssertNotNil(state.hint)
    }

    func testClientErrorCannotRetry() {
        let state = FailureState.make(from: GitHubClientError.http(status: 422,
                                                                   message: "x"))
        XCTAssertFalse(state.canRetry)
    }

    func testNetworkError() {
        let state = FailureState.make(from: URLError(.notConnectedToInternet))
        XCTAssertTrue(state.canRetry)
        XCTAssertTrue(state.hint?.contains("Wi-Fi") == true)
    }

    func testRetryBackoff() {
        var state = FailureState(title: "x", message: "y")
        XCTAssertEqual(state.retryDelay, 1)
        state = state.retried()
        XCTAssertEqual(state.retryDelay, 2)
        state = state.retried()
        XCTAssertEqual(state.retryDelay, 4)
        XCTAssertTrue(state.isPersistent)
    }

    func testDelayIsCapped() {
        var state = FailureState(title: "x", message: "y", attempts: 20)
        state = state.retried()
        XCTAssertEqual(state.retryDelay, 30)
    }
}

final class EmptyStateTests: XCTestCase {
    func testWelcomeHasExamples() {
        XCTAssertFalse(EmptyState.welcome.examples.isEmpty)
        XCTAssertNotNil(EmptyState.welcome.actionTitle)
    }

    func testSearchResults() {
        let state = EmptyState.noSearchResults(query: "あいう")
        XCTAssertTrue(state.title.contains("あいう"))
    }

    func testEveryStateHasText() {
        let states = [EmptyState.welcome, .emptyDirectory, .noOutput, .noTabs,
                      .noBookmarks, .noOfflineRepositories]
        for state in states {
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.message.isEmpty)
        }
    }
}

final class HTMLInspectorTests: XCTestCase {
    let html = """
    <!DOCTYPE html>
    <html>
      <head><title>見本</title></head>
      <body>
        <div id="main" class="card wide">
          <p>こんにちは</p>
          <img src="a.png">
        </div>
      </body>
    </html>
    """

    func testStructure() {
        let root = HTMLInspector.parse(html)
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(root.children[0].tagName, "html")
        XCTAssertEqual(root.children[0].children.map(\.tagName), ["head", "body"])
    }

    func testAttributes() {
        let root = HTMLInspector.parse(html)
        let divs = HTMLInspector.elements(named: "div", in: root)
        XCTAssertEqual(divs.count, 1)
        XCTAssertEqual(divs[0].idAttribute, "main")
        XCTAssertEqual(divs[0].classNames, ["card", "wide"])
        XCTAssertEqual(divs[0].selector, "div#main.card.wide")
    }

    func testText() {
        let root = HTMLInspector.parse(html)
        let paragraphs = HTMLInspector.elements(named: "p", in: root)
        XCTAssertEqual(paragraphs.first?.text, "こんにちは")
    }

    func testVoidElementsHaveNoChildren() {
        let root = HTMLInspector.parse(html)
        let images = HTMLInspector.elements(named: "img", in: root)
        XCTAssertEqual(images.count, 1)
        XCTAssertTrue(images[0].children.isEmpty)
        XCTAssertEqual(images[0].attribute("src"), "a.png")
    }

    func testSelfClosingTag() {
        let root = HTMLInspector.parse("<div><br/><span>a</span></div>")
        let div = root.children[0]
        XCTAssertEqual(div.children.map(\.tagName), ["br", "span"])
    }

    func testCommentsAreIgnored() {
        let root = HTMLInspector.parse("<div><!-- メモ --><p>a</p></div>")
        XCTAssertEqual(root.children[0].children.count, 1)
    }

    func testDoctypeIsIgnored() {
        let root = HTMLInspector.parse(html)
        XCTAssertFalse(root.children.contains { $0.tagName.hasPrefix("!") })
    }

    func testLineNumbers() {
        let root = HTMLInspector.parse(html)
        XCTAssertEqual(HTMLInspector.elements(named: "body", in: root).first?.line, 4)
    }

    func testNodeCount() {
        let root = HTMLInspector.parse("<div><p>a</p><p>b</p></div>")
        XCTAssertEqual(root.children[0].nodeCount, 3)
    }

    func testUnclosedTagsDoNotHang() {
        let root = HTMLInspector.parse("<div><p>開いたまま")
        XCTAssertEqual(root.children.count, 1)
    }

    func testFindByPredicate() {
        let root = HTMLInspector.parse(html)
        let withID = HTMLInspector.find(in: root) { $0.idAttribute != nil }
        XCTAssertEqual(withID.count, 1)
    }

    func testAttributeWithoutValue() {
        let root = HTMLInspector.parse("<input disabled>")
        XCTAssertEqual(root.children[0].attribute("disabled"), "")
    }
}

final class JavaScriptConsoleTests: XCTestCase {
    func testAddAndCount() {
        var console = JavaScriptConsole()
        console.add("こんにちは")
        console.add("まずい", level: .error)
        XCTAssertEqual(console.entries.count, 2)
        XCTAssertEqual(console.errorCount, 1)
        XCTAssertFalse(console.isEmpty)
    }

    func testLimit() {
        var console = JavaScriptConsole(limit: 2)
        for name in ["a", "b", "c"] { console.add(name) }
        XCTAssertEqual(console.entries.map(\.text), ["b", "c"])
    }

    func testSubmitRecordsHistory() {
        var console = JavaScriptConsole()
        console.submit("1 + 1")
        console.submit("2 + 2")
        XCTAssertEqual(console.historyEntry(offset: 1), "2 + 2")
        XCTAssertEqual(console.historyEntry(offset: 2), "1 + 1")
        XCTAssertNil(console.historyEntry(offset: 3))
    }

    func testRepeatedInputIsMovedToTheEnd() {
        var console = JavaScriptConsole()
        console.submit("a")
        console.submit("b")
        console.submit("a")
        XCTAssertEqual(console.inputHistory, ["b", "a"])
    }

    func testBlankInputIsIgnored() {
        var console = JavaScriptConsole()
        console.submit("   ")
        XCTAssertTrue(console.inputHistory.isEmpty)
    }

    func testClear() {
        var console = JavaScriptConsole()
        console.add("a")
        console.clear()
        XCTAssertTrue(console.isEmpty)
    }

    func testBridgeScript() {
        let script = JavaScriptConsole.bridgeScript
        XCTAssertTrue(script.contains("viewerConsole"))
        XCTAssertTrue(script.contains("unhandledrejection"))
        XCTAssertTrue(script.contains("__viewerConsoleInstalled"))
    }

    func testLevelSymbols() {
        for level in [ConsoleEntry.Level.log, .info, .warn, .error, .input, .result] {
            XCTAssertFalse(level.symbol.isEmpty)
        }
    }
}
