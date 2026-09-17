import XCTest
@testable import GitHubViewerCore

final class CodeFoldingTests: XCTestCase {
    func testBraceRanges() {
        let source = """
        int main() {
            if (x) {
                y();
            }
        }
        """
        let ranges = CodeStructure.foldableRanges(in: source, languageID: "c")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].startLine, 1)
        XCTAssertEqual(ranges[0].endLine, 5)
        XCTAssertEqual(ranges[1].startLine, 2)
        XCTAssertEqual(ranges[1].endLine, 4)
    }

    func testBracesInsideStringsAreIgnored() {
        let source = "void f() {\n    puts(\"{\");\n}"
        let ranges = CodeStructure.foldableRanges(in: source, languageID: "c")
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].endLine, 3)
    }

    func testIndentRangesForPython() {
        let source = """
        def f():
            a = 1
            b = 2
        c = 3
        """
        let ranges = CodeStructure.foldableRanges(in: source, languageID: "python")
        XCTAssertTrue(ranges.contains { $0.startLine == 1 && $0.endLine == 3 })
    }

    func testNoRangesWhenNothingToFold() {
        XCTAssertTrue(CodeStructure.foldableRanges(in: "a\nb\nc", languageID: "c").isEmpty)
    }
}

final class CodeSymbolTests: XCTestCase {
    func testSwiftSymbols() {
        let source = """
        struct Point {
            var x: Int
            func length() -> Int { 0 }
        }

        func main() {}
        """
        let symbols = CodeStructure.symbols(in: source, languageID: "swift")
        XCTAssertTrue(symbols.contains { $0.name == "Point" && $0.kind == .type })
        XCTAssertTrue(symbols.contains { $0.name == "length" && $0.kind == .method })
        XCTAssertTrue(symbols.contains { $0.name == "main" && $0.kind == .function })
    }

    func testCFunctionsAreFound() {
        let source = """
        #include <stdio.h>

        int add(int a, int b) {
            return a + b;
        }

        int main(void) {
            return 0;
        }
        """
        let symbols = CodeStructure.symbols(in: source, languageID: "c")
        XCTAssertTrue(symbols.contains { $0.name == "add" })
        XCTAssertTrue(symbols.contains { $0.name == "main" })
    }

    func testControlFlowIsNotASymbol() {
        let source = "int main(void) {\n    if (x) {\n    }\n    while (y) {\n    }\n}"
        let symbols = CodeStructure.symbols(in: source, languageID: "c")
        XCTAssertFalse(symbols.contains { $0.name == "if" })
        XCTAssertFalse(symbols.contains { $0.name == "while" })
    }

    func testMarkdownHeadings() {
        let source = """
        # タイトル

        本文

        ## 節

        ### 小見出し
        """
        let symbols = CodeStructure.symbols(in: source, languageID: "markdown")
        XCTAssertEqual(symbols.map(\.name), ["タイトル", "節", "小見出し"])
        XCTAssertEqual(symbols.map(\.depth), [0, 1, 2])
    }

    func testHeadingsInsideCodeFenceAreSkipped() {
        let source = "# 本物\n\n```\n# 偽物\n```\n"
        let symbols = CodeStructure.symbols(in: source, languageID: "markdown")
        XCTAssertEqual(symbols.map(\.name), ["本物"])
    }

    func testTableOfContents() {
        let toc = CodeStructure.tableOfContents(forMarkdown: "# A\n## B\n")
        XCTAssertEqual(toc, "- [A](#a)\n  - [B](#b)")
    }

    func testAnchorIgnoresPunctuation() {
        XCTAssertEqual(CodeStructure.anchor(for: "Hello, World!"), "hello-world")
    }
}

final class MinimapTests: XCTestCase {
    func testDensityIsNormalised() {
        let density = Minimap.density(of: "aaaa\na\n\n")
        XCTAssertEqual(density.count, 4)
        XCTAssertEqual(density[0], 1, accuracy: 0.001)
        XCTAssertEqual(density[2], 0, accuracy: 0.001)
    }

    func testIndentDepths() {
        XCTAssertEqual(Minimap.indentDepths(of: "a\n  b\n\tc"), [0, 2, 1])
    }
}

final class InvisibleCharacterTests: XCTestCase {
    func testReveal() {
        XCTAssertEqual(InvisibleCharacters.reveal("a b\tc"), "a·b→c")
    }

    func testPositions() {
        let found = InvisibleCharacters.positions(in: "a b\tc")
        XCTAssertEqual(found.spaces, [1])
        XCTAssertEqual(found.tabs, [3])
    }
}

final class SymbolBarTests: XCTestCase {
    func testEveryLanguageGetsKeys() {
        for engine in MiniLangRegistry.all {
            XCTAssertFalse(SymbolBar.keys(for: engine.languageID).isEmpty)
        }
        XCTAssertFalse(SymbolBar.keys(for: nil).isEmpty)
    }

    func testShellKeysIncludeDollar() {
        XCTAssertTrue(SymbolBar.keys(for: "shell").contains("$"))
    }
}

final class FuzzySearchTests: XCTestCase {
    func testFindsSubsequence() {
        let items = ["Sources/Main.swift", "Tests/MainTests.swift", "README.md"]
        let results = FuzzySearch.search("main", in: items) { $0 }
        XCTAssertEqual(results.count, 2)
    }

    func testPrefersWordStarts() {
        let items = ["abcMain.swift", "Main.swift"]
        let results = FuzzySearch.search("main", in: items) { $0 }
        XCTAssertEqual(results.first?.element, "Main.swift")
    }

    func testNoMatchIsExcluded() {
        XCTAssertTrue(FuzzySearch.search("zzz", in: ["abc"]) { $0 }.isEmpty)
    }

    func testEmptyQueryReturnsEverything() {
        let results = FuzzySearch.search("", in: ["a", "b"]) { $0 }
        XCTAssertEqual(results.count, 2)
    }

    func testMatchedIndices() {
        guard let scored = FuzzySearch.score(query: "ac", candidate: "abc") else {
            return XCTFail("一致しませんでした")
        }
        XCTAssertEqual(scored.indices, [0, 2])
    }
}

final class DiffEngineTests: XCTestCase {
    func testIdenticalTextHasNoChanges() {
        let lines = DiffEngine.diff(old: "a\nb", new: "a\nb")
        XCTAssertFalse(DiffEngine.summary(lines).hasChanges)
    }

    func testAddedLine() {
        let lines = DiffEngine.diff(old: "a\nc", new: "a\nb\nc")
        let summary = DiffEngine.summary(lines)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.removed, 0)
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.text == "b" })
    }

    func testRemovedLine() {
        let lines = DiffEngine.diff(old: "a\nb\nc", new: "a\nc")
        let summary = DiffEngine.summary(lines)
        XCTAssertEqual(summary.removed, 1)
        XCTAssertEqual(summary.added, 0)
    }

    func testChangedLineShowsBothSides() {
        let lines = DiffEngine.diff(old: "a\nX\nc", new: "a\nY\nc")
        XCTAssertTrue(lines.contains { $0.kind == .removed && $0.text == "X" })
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.text == "Y" })
    }

    func testLineNumbers() {
        let lines = DiffEngine.diff(old: "a\nb", new: "a\nx\nb")
        let added = lines.first { $0.kind == .added }
        XCTAssertEqual(added?.newLine, 2)
        XCTAssertNil(added?.oldLine)
    }

    func testUnifiedFormat() {
        let text = DiffEngine.unified(old: "a\nb\nc", new: "a\nB\nc",
                                      oldName: "old", newName: "new")
        XCTAssertTrue(text.hasPrefix("--- old\n+++ new\n@@"))
        XCTAssertTrue(text.contains("-b"))
        XCTAssertTrue(text.contains("+B"))
    }

    func testUnifiedIsEmptyWhenSame() {
        XCTAssertEqual(DiffEngine.unified(old: "a", new: "a"), "")
    }

    func testHunksKeepContext() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "\n10\n", with: "\nX\n")
        let hunks = DiffEngine.hunks(DiffEngine.diff(old: old, new: new), context: 2)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertLessThanOrEqual(hunks[0].lines.count, 6)
    }

    func testSideBySidePairsChanges() {
        let lines = DiffEngine.diff(old: "a\nX\nc", new: "a\nY\nc")
        let rows = DiffEngine.sideBySide(lines)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].left?.text, "X")
        XCTAssertEqual(rows[1].right?.text, "Y")
    }

    func testLargeInputStillFinishes() {
        let old = (1...500).map(String.init).joined(separator: "\n")
        let new = (1...500).map { $0 % 50 == 0 ? "x" : String($0) }.joined(separator: "\n")
        let summary = DiffEngine.summary(DiffEngine.diff(old: old, new: new))
        XCTAssertEqual(summary.added, 10)
        XCTAssertEqual(summary.removed, 10)
    }
}

final class SnippetLibraryTests: XCTestCase {
    func testExpandPlaceholder() {
        let expanded = SnippetLibrary.expand("print(\"${1:hello}\")")
        XCTAssertEqual(expanded.text, "print(\"hello\")")
        XCTAssertEqual(expanded.caretLocation, 7)
        XCTAssertEqual(expanded.caretLength, 5)
    }

    func testExpandEmptyPlaceholder() {
        let expanded = SnippetLibrary.expand("f(${1:})")
        XCTAssertEqual(expanded.text, "f()")
        XCTAssertEqual(expanded.caretLocation, 2)
        XCTAssertEqual(expanded.caretLength, 0)
    }

    func testExpandKeepsIndentOnNewLines() {
        let expanded = SnippetLibrary.expand("a\nb", indent: "  ")
        XCTAssertEqual(expanded.text, "a\n  b")
    }

    func testFilterByLanguage() {
        let swift = SnippetLibrary.snippets(for: "swift")
        XCTAssertTrue(swift.contains { $0.id == "swift-func" })
        XCTAssertFalse(swift.contains { $0.id == "go-main" })
    }

    func testCommonSnippetsAppearEverywhere() {
        XCTAssertTrue(SnippetLibrary.snippets(for: "rust").contains { $0.id == "todo" })
    }

    func testLookupByTrigger() {
        XCTAssertEqual(SnippetLibrary.snippet(trigger: "main", languageID: "go")?.id,
                       "go-main")
        XCTAssertNil(SnippetLibrary.snippet(trigger: "nope", languageID: "go"))
    }

    func testUserSnippetsAreIncluded() {
        let mine = Snippet(trigger: "hi", title: "あいさつ", body: "hello",
                           isUserDefined: true)
        XCTAssertNotNil(SnippetLibrary.snippet(trigger: "hi", languageID: "c",
                                               including: [mine]))
    }
}

final class FileTemplateTests: XCTestCase {
    func testTemplateLookup() {
        XCTAssertEqual(FileTemplateCatalog.template(for: "go")?.fileName, "main.go")
        XCTAssertNil(FileTemplateCatalog.template(for: "unknown"))
    }

    func testEveryTemplateHasABody() {
        for template in FileTemplateCatalog.all {
            XCTAssertFalse(template.body.isEmpty, "\(template.id) が空です")
            XCTAssertFalse(template.fileName.isEmpty)
        }
    }

    func testLicenseFilling() {
        let filled = FileTemplateCatalog.fill("(c) {year} {owner}", owner: "私", year: 2026)
        XCTAssertEqual(filled, "(c) 2026 私")
    }

    func testGitignoreTemplatesExist() {
        XCTAssertFalse(FileTemplateCatalog.gitignoreTemplates.isEmpty)
        XCTAssertTrue(FileTemplateCatalog.licenseTemplates.contains { $0.name == "MIT" })
    }
}
