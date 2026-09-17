import XCTest
@testable import GitHubViewerCore

final class TextDocumentTests: XCTestCase {
    func testLineIndex() {
        let document = TextDocument("abc\ndef\nghi")
        XCTAssertEqual(document.lineCount, 3)
        XCTAssertEqual(document.line(1), "abc")
        XCTAssertEqual(document.line(2), "def")
        XCTAssertEqual(document.line(3), "ghi")
    }

    func testPositionRoundTrip() {
        let document = TextDocument("abc\ndef\nghi")
        XCTAssertEqual(document.position(at: 0), TextPosition(line: 1, column: 1))
        XCTAssertEqual(document.position(at: 4), TextPosition(line: 2, column: 1))
        XCTAssertEqual(document.position(at: 6), TextPosition(line: 2, column: 3))
        XCTAssertEqual(document.location(of: TextPosition(line: 2, column: 1)), 4)
        XCTAssertEqual(document.location(of: TextPosition(line: 3, column: 3)), 10)
    }

    func testEmptyLines() {
        let document = TextDocument("a\n\nb")
        XCTAssertEqual(document.lineCount, 3)
        XCTAssertEqual(document.line(2), "")
        XCTAssertEqual(document.position(at: 2), TextPosition(line: 2, column: 1))
    }

    func testTrailingNewlineMakesAnEmptyLastLine() {
        let document = TextDocument("a\n")
        XCTAssertEqual(document.lineCount, 2)
        XCTAssertEqual(document.line(2), "")
    }

    func testCarriageReturnLineFeed() {
        let document = TextDocument("a\r\nb")
        XCTAssertEqual(document.lineEnding, .crlf)
        XCTAssertEqual(document.lineCount, 2)
        XCTAssertEqual(document.line(1), "a")
        XCTAssertEqual(document.line(2), "b")
    }

    func testMultibyteCharactersUseUTF16Offsets() {
        let document = TextDocument("あいう\nかきく")
        XCTAssertEqual(document.lineCount, 2)
        XCTAssertEqual(document.line(2), "かきく")
        XCTAssertEqual(document.position(at: 4), TextPosition(line: 2, column: 1))
    }

    func testSelectionSummary() {
        let document = TextDocument("hello world\nsecond line")
        let summary = document.summary(location: 0, length: 11)
        XCTAssertEqual(summary.characters, 11)
        XCTAssertEqual(summary.words, 2)
        XCTAssertEqual(summary.lines, 1)
    }

    func testLineEndingConversion() {
        let document = TextDocument("a\r\nb\r\nc")
        XCTAssertEqual(document.convertingLineEndings(to: .lf), "a\nb\nc")
        XCTAssertEqual(TextDocument("a\nb").convertingLineEndings(to: .crlf), "a\r\nb")
    }

    func testTrimmingTrailingWhitespace() {
        let document = TextDocument("a  \nb\t\nc")
        XCTAssertEqual(document.trimmingTrailingWhitespace(), "a\nb\nc")
    }

    func testHumanReadableSize() {
        XCTAssertEqual(TextEncodingInfo.humanReadableSize(512), "512 B")
        XCTAssertEqual(TextEncodingInfo.humanReadableSize(2048), "2.0 KB")
    }
}

final class SyntaxHighlighterTests: XCTestCase {
    func testKeywordsAndStringsAreHighlighted() {
        let source = "let x = \"hi\" // note"
        let spans = SyntaxHighlighter.spans(for: source, languageID: "swift")
        let kinds = Set(spans.map(\.kind))
        XCTAssertTrue(kinds.contains(.keyword))
        XCTAssertTrue(kinds.contains(.string))
        XCTAssertTrue(kinds.contains(.comment))
    }

    func testCommentRunsToEndOfLine() {
        let source = "a // comment\nb"
        let spans = SyntaxHighlighter.spans(for: source, languageID: "javascript")
        guard let comment = spans.first(where: { $0.kind == .comment }) else {
            return XCTFail("コメントが見つかりません")
        }
        XCTAssertEqual(comment.location, 2)
        XCTAssertEqual(comment.length, 10)
    }

    func testBlockCommentIsOneSpan() {
        let source = "/* two\nlines */ x"
        let spans = SyntaxHighlighter.spans(for: source, languageID: "c")
        guard let comment = spans.first(where: { $0.kind == .comment }) else {
            return XCTFail("コメントが見つかりません")
        }
        XCTAssertEqual(comment.location, 0)
        XCTAssertEqual(comment.length, 15)
    }

    func testNumbersIncludingHex() {
        let spans = SyntaxHighlighter.spans(for: "0xFF + 12.5e3", languageID: "c")
        let numbers = spans.filter { $0.kind == .number }
        XCTAssertEqual(numbers.count, 2)
    }

    func testFunctionCallIsDetected() {
        let spans = SyntaxHighlighter.spans(for: "foo(1)", languageID: "c")
        XCTAssertTrue(spans.contains { $0.kind == .function && $0.location == 0 })
    }

    func testSpansDoNotOverlap() {
        let source = """
        // header
        int main(void) {
            printf("%d\\n", 42);
            return 0;
        }
        """
        let spans = SyntaxHighlighter.spans(for: source, languageID: "c")
        for (left, right) in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(left.endLocation, right.location,
                                     "範囲が重なっています")
        }
    }

    func testEveryBuiltInLanguageHasAProfile() {
        for engine in MiniLangRegistry.all {
            let profile = SyntaxHighlighter.profile(for: engine.languageID)
            XCTAssertFalse(profile.keywords.isEmpty,
                           "\(engine.languageID) の予約語が空です")
        }
    }

    func testHighlightingEveryExampleDoesNotCrash() {
        // 実際のサンプルで走らせて、範囲が本文をはみ出さないことを見る。
        for engine in MiniLangRegistry.all {
            let source = "x = 1 // c\n\"s\"\n"
            let spans = SyntaxHighlighter.spans(for: source, languageID: engine.languageID)
            let length = (source as NSString).length
            for span in spans {
                XCTAssertLessThanOrEqual(span.endLocation, length,
                                         "\(engine.languageID) で範囲がはみ出しました")
            }
        }
    }
}

final class TextSearchTests: XCTestCase {
    func testPlainSearch() {
        let matches = TextSearch.matches(of: "ab", in: "ab cd ab")
        XCTAssertEqual(matches.map(\.location), [0, 6])
    }

    func testCaseSensitivity() {
        let sensitive = SearchOptions(isCaseSensitive: true)
        XCTAssertEqual(TextSearch.matches(of: "AB", in: "ab AB", options: sensitive).count, 1)
        XCTAssertEqual(TextSearch.matches(of: "AB", in: "ab AB").count, 2)
    }

    func testWholeWord() {
        let options = SearchOptions(matchesWholeWord: true)
        XCTAssertEqual(TextSearch.matches(of: "cat", in: "cat catalog", options: options).count, 1)
    }

    func testRegularExpression() {
        let options = SearchOptions(isRegularExpression: true)
        let matches = TextSearch.matches(of: "[0-9]+", in: "a1 b22", options: options)
        XCTAssertEqual(matches.map(\.length), [1, 2])
    }

    func testNextWrapsAround() {
        let found = TextSearch.next(of: "a", in: "a b a", after: 10)
        XCTAssertEqual(found?.location, 0)
    }

    func testPreviousFindsEarlierMatch() {
        let found = TextSearch.previous(of: "a", in: "a b a", before: 4)
        XCTAssertEqual(found?.location, 0)
    }

    func testReplaceAll() {
        let result = TextSearch.replaceAll(of: "x", with: "y", in: "x x x")
        XCTAssertEqual(result.text, "y y y")
        XCTAssertEqual(result.count, 3)
    }

    func testReplaceAllWithGroups() {
        let options = SearchOptions(isRegularExpression: true)
        let result = TextSearch.replaceAll(of: "(\\w+)@(\\w+)", with: "$2:$1",
                                           in: "me@host", options: options)
        XCTAssertEqual(result.text, "host:me")
    }
}

final class BracketMatcherTests: XCTestCase {
    func testMatchesForward() {
        let found = BracketMatcher.match(in: "f(a, b)", at: 1)
        XCTAssertEqual(found?.0, 1)
        XCTAssertEqual(found?.1, 6)
    }

    func testMatchesBackward() {
        let found = BracketMatcher.match(in: "f(a, b)", at: 7)
        XCTAssertEqual(found?.0, 1)
        XCTAssertEqual(found?.1, 6)
    }

    func testNested() {
        let found = BracketMatcher.match(in: "((x))", at: 0)
        XCTAssertEqual(found?.1, 4)
    }

    func testUnbalancedReturnsNil() {
        XCTAssertNil(BracketMatcher.match(in: "(x", at: 0))
    }

    func testAutoClosing() {
        XCTAssertTrue(BracketMatcher.shouldAutoClose("(", before: nil))
        XCTAssertTrue(BracketMatcher.shouldAutoClose("(", before: " "))
        XCTAssertFalse(BracketMatcher.shouldAutoClose("(", before: "a"))
        XCTAssertFalse(BracketMatcher.shouldAutoClose("a", before: nil))
    }
}

final class TextEditingTests: XCTestCase {
    func testIndentAddsToEveryLine() {
        let document = TextDocument("a\nb")
        let result = TextEditing.indent(document, location: 0, length: 3,
                                        style: IndentStyle(usesSpaces: true, width: 2))
        XCTAssertEqual(result.applied(to: document.text), "  a\n  b")
    }

    func testOutdentRemovesIndent() {
        let document = TextDocument("    a\n    b")
        let result = TextEditing.outdent(document, location: 0, length: 11,
                                         style: IndentStyle(usesSpaces: true, width: 4))
        XCTAssertEqual(result.applied(to: document.text), "a\nb")
    }

    func testToggleCommentAddsAndRemoves() {
        let document = TextDocument("a\nb")
        let commented = TextEditing.toggleComment(document, location: 0, length: 3,
                                                  languageID: "c")
        let text = commented.applied(to: document.text)
        XCTAssertEqual(text, "// a\n// b")

        let second = TextDocument(text)
        let restored = TextEditing.toggleComment(second, location: 0, length: 9,
                                                 languageID: "c")
        XCTAssertEqual(restored.applied(to: text), "a\nb")
    }

    func testToggleCommentUsesLanguageMarker() {
        let document = TextDocument("x = 1")
        let result = TextEditing.toggleComment(document, location: 0, length: 5,
                                               languageID: "python")
        XCTAssertEqual(result.applied(to: document.text), "# x = 1")
    }

    func testNewlineIndentKeepsIndent() {
        let document = TextDocument("    foo")
        let indent = TextEditing.newlineIndent(document, at: 7,
                                               style: IndentStyle(), languageID: "c")
        XCTAssertEqual(indent, "    ")
    }

    func testNewlineIndentDeepensAfterBrace() {
        let document = TextDocument("if (x) {")
        let indent = TextEditing.newlineIndent(document, at: 8,
                                               style: IndentStyle(usesSpaces: true, width: 2),
                                               languageID: "c")
        XCTAssertEqual(indent, "  ")
    }

    func testDuplicateLines() {
        let document = TextDocument("a\nb")
        let result = TextEditing.duplicateLines(document, location: 0, length: 1)
        XCTAssertEqual(result.applied(to: document.text), "a\na\nb")
    }

    func testDeleteLines() {
        let document = TextDocument("a\nb\nc")
        let result = TextEditing.deleteLines(document, location: 2, length: 1)
        XCTAssertEqual(result.applied(to: document.text), "a\nc")
    }

    func testMoveLineDown() {
        let document = TextDocument("a\nb\nc")
        guard let result = TextEditing.moveLines(document, location: 0, length: 1,
                                                 up: false) else {
            return XCTFail("動かせませんでした")
        }
        XCTAssertEqual(result.applied(to: document.text), "b\na\nc")
    }

    func testMoveLineUp() {
        let document = TextDocument("a\nb\nc")
        guard let result = TextEditing.moveLines(document, location: 2, length: 1,
                                                 up: true) else {
            return XCTFail("動かせませんでした")
        }
        XCTAssertEqual(result.applied(to: document.text), "b\na\nc")
    }

    func testMoveLineAtEdgeReturnsNil() {
        let document = TextDocument("a\nb")
        XCTAssertNil(TextEditing.moveLines(document, location: 0, length: 1, up: true))
    }

    func testIndentStyleDetection() {
        let spaces = IndentStyle.detect(in: "a\n  b\n  c\n    d\n")
        XCTAssertTrue(spaces.usesSpaces)
        XCTAssertEqual(spaces.width, 2)

        let tabs = IndentStyle.detect(in: "a\n\tb\n\tc\n")
        XCTAssertFalse(tabs.usesSpaces)
    }
}

final class UndoHistoryTests: XCTestCase {
    func testUndoAndRedo() {
        let history = UndoHistory()
        history.record(.init(text: "a", selectionLocation: 1, selectionLength: 0))
        history.record(.init(text: "ab", selectionLocation: 2, selectionLength: 0))
        history.record(.init(text: "abc", selectionLocation: 3, selectionLength: 0))

        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.undo()?.text, "ab")
        XCTAssertEqual(history.undo()?.text, "a")
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redo()?.text, "ab")
        XCTAssertEqual(history.redo()?.text, "abc")
        XCTAssertFalse(history.canRedo)
    }

    func testRecordingSameTextOnlyUpdatesSelection() {
        let history = UndoHistory()
        history.record(.init(text: "a", selectionLocation: 0, selectionLength: 0))
        history.record(.init(text: "a", selectionLocation: 1, selectionLength: 0))
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.current?.selectionLocation, 1)
    }

    func testNewEditClearsRedo() {
        let history = UndoHistory()
        history.record(.init(text: "a", selectionLocation: 0, selectionLength: 0))
        history.record(.init(text: "ab", selectionLocation: 0, selectionLength: 0))
        _ = history.undo()
        XCTAssertTrue(history.canRedo)
        history.record(.init(text: "ax", selectionLocation: 0, selectionLength: 0))
        XCTAssertFalse(history.canRedo)
    }
}

final class EditorThemeTests: XCTestCase {
    func testHexRoundTrip() {
        XCTAssertEqual(ThemeColor(hex: "#FF8000").hexString, "#FF8000")
        XCTAssertEqual(ThemeColor(hex: "0A0B0C").hexString, "#0A0B0C")
    }

    func testShortHex() {
        XCTAssertEqual(ThemeColor(hex: "#F00").hexString, "#FF0000")
    }

    func testEveryThemeHasEveryColor() {
        for theme in EditorThemeCatalog.all {
            for kind in HighlightKind.allCases where kind != .plain {
                XCTAssertNotNil(theme.colors[kind],
                                "\(theme.id) に \(kind.rawValue) の色がありません")
            }
        }
    }

    func testLookupByID() {
        XCTAssertEqual(EditorThemeCatalog.theme(id: "dark")?.name, "ダーク")
        XCTAssertNil(EditorThemeCatalog.theme(id: "nope"))
        XCTAssertTrue(EditorThemeCatalog.default(isDark: true).isDark)
    }
}
