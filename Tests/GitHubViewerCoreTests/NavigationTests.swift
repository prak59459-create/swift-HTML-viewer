import XCTest
@testable import GitHubViewerCore

final class MultiSelectionTests: XCTestCase {
    func testSortedAndMerged() {
        let selection = MultiSelection([TextSelection(location: 5, length: 3),
                                        TextSelection(location: 0, length: 2),
                                        TextSelection(location: 6, length: 3)])
        XCTAssertEqual(selection.count, 2)
        XCTAssertEqual(selection.selections[0].location, 0)
        XCTAssertEqual(selection.selections[1].length, 4)
    }

    func testDuplicateCaretsAreMerged() {
        let selection = MultiSelection([TextSelection(location: 3),
                                        TextSelection(location: 3)])
        XCTAssertEqual(selection.count, 1)
    }

    func testInsertAtEveryCaret() {
        let selection = MultiSelection([TextSelection(location: 0),
                                        TextSelection(location: 3)])
        let result = selection.inserting("-", into: "abcdef")
        XCTAssertEqual(result.text, "-abc-def")
        XCTAssertEqual(result.selections.selections.map(\.location), [1, 5])
    }

    func testInsertReplacesSelections() {
        let selection = MultiSelection([TextSelection(location: 0, length: 3),
                                        TextSelection(location: 4, length: 3)])
        let result = selection.inserting("x", into: "abc def")
        XCTAssertEqual(result.text, "x x")
    }

    func testReplacingEachWithDifferentText() {
        let selection = MultiSelection([TextSelection(location: 0),
                                        TextSelection(location: 1)])
        let result = selection.replacingEach(in: "ab") { index, _ in "\(index)" }
        XCTAssertEqual(result.text, "0a1b")
    }

    func testDeleteBackward() {
        let selection = MultiSelection([TextSelection(location: 2),
                                        TextSelection(location: 5)])
        let result = selection.deletingBackward(in: "abcdef")
        XCTAssertEqual(result.text, "acdf")
        XCTAssertEqual(result.selections.selections.map(\.location), [1, 3])
    }

    func testDeleteBackwardAtStartDoesNothing() {
        let result = MultiSelection([TextSelection(location: 0)])
            .deletingBackward(in: "abc")
        XCTAssertEqual(result.text, "abc")
    }

    func testDeleteSelection() {
        let result = MultiSelection([TextSelection(location: 1, length: 2)])
            .deletingBackward(in: "abcd")
        XCTAssertEqual(result.text, "ad")
    }

    func testAddNextOccurrence() {
        let source = "foo bar foo baz foo"
        var selection = MultiSelection([TextSelection(location: 0, length: 3)])
        selection = selection.addingNextOccurrence(in: source)
        XCTAssertEqual(selection.count, 2)
        selection = selection.addingNextOccurrence(in: source)
        XCTAssertEqual(selection.count, 3)
        // もう無ければ増えない。
        selection = selection.addingNextOccurrence(in: source)
        XCTAssertEqual(selection.count, 3)
    }

    func testAddNextOccurrenceNeedsASelection() {
        let selection = MultiSelection([TextSelection(location: 0)])
        XCTAssertEqual(selection.addingNextOccurrence(in: "abc").count, 1)
    }

    func testAllOccurrences() {
        let selection = MultiSelection.allOccurrences(of: "ab", in: "ab cd ab")
        XCTAssertEqual(selection.count, 2)
        XCTAssertEqual(selection.selections.map(\.location), [0, 6])
    }

    func testCaretsOnEachLine() {
        let source = "one\ntwo\nthree"
        let selection = MultiSelection.caretsOnEachLine(of: source, location: 0,
                                                        length: source.utf16.count)
        XCTAssertEqual(selection.count, 3)
        XCTAssertEqual(selection.selections.map(\.location), [0, 4, 8])
    }

    func testCaretsAtLineEnds() {
        let selection = MultiSelection.caretsOnEachLine(of: "ab\ncde", location: 0,
                                                        length: 6, atEnd: true)
        XCTAssertEqual(selection.selections.map(\.location), [2, 6])
    }

    func testCollapse() {
        let selection = MultiSelection([TextSelection(location: 0),
                                        TextSelection(location: 5)])
        XCTAssertEqual(selection.collapsed().count, 1)
    }

    func testRemove() {
        let selection = MultiSelection([TextSelection(location: 0),
                                        TextSelection(location: 5)])
        XCTAssertEqual(selection.removing(at: 0).selections.first?.location, 5)
        XCTAssertEqual(selection.removing(at: 9).count, 2)
    }
}

final class BlockSelectionTests: XCTestCase {
    let source = "abcdef\nghijkl\nmno"

    func testRectangle() {
        let selection = BlockSelection.selections(
            in: source, from: TextPosition(line: 1, column: 2),
            to: TextPosition(line: 3, column: 4))
        XCTAssertEqual(selection.count, 3)
        XCTAssertEqual(BlockSelection.text(in: source, selection: selection),
                       "bc\nhi\nno")
    }

    func testShortLineIsClamped() {
        let selection = BlockSelection.selections(
            in: source, from: TextPosition(line: 3, column: 1),
            to: TextPosition(line: 3, column: 20))
        XCTAssertEqual(BlockSelection.text(in: source, selection: selection), "mno")
    }

    func testReversedCornersWork() {
        let forward = BlockSelection.selections(
            in: source, from: TextPosition(line: 1, column: 2),
            to: TextPosition(line: 2, column: 4))
        let backward = BlockSelection.selections(
            in: source, from: TextPosition(line: 2, column: 4),
            to: TextPosition(line: 1, column: 2))
        XCTAssertEqual(forward, backward)
    }

    func testOutOfRangeLines() {
        let selection = BlockSelection.selections(
            in: source, from: TextPosition(line: 1, column: 1),
            to: TextPosition(line: 99, column: 2))
        XCTAssertTrue(selection.isEmpty)
    }
}

final class EditorSettingsTests: XCTestCase {
    func testFontSizeIsClamped() {
        XCTAssertEqual(FontSize(points: 1).points, FontSize.minimum)
        XCTAssertEqual(FontSize(points: 999).points, FontSize.maximum)
    }

    func testPinchScaling() {
        let size = FontSize(points: 14).scaled(by: 2)
        XCTAssertEqual(size.points, 28)
        XCTAssertTrue(FontSize(points: 14).scaled(by: 100).isLargest)
    }

    func testStepping() {
        XCTAssertEqual(FontSize(points: 14).stepped(by: 1).points, 15)
    }

    func testLineHeight() {
        XCTAssertEqual(FontSize(points: 10).lineHeight, 13.5, accuracy: 0.001)
    }

    func testFontCatalog() {
        XCTAssertFalse(EditorFontCatalog.all.isEmpty)
        XCTAssertNotNil(EditorFontCatalog.font(id: EditorFontCatalog.default.id))
        XCTAssertNil(EditorFontCatalog.font(id: "どこにもない"))
        for font in EditorFontCatalog.all {
            XCTAssertFalse(font.displayName.isEmpty)
        }
    }

    func testSettingsRoundTrip() {
        var settings = EditorSettings()
        settings.fontSize = FontSize(points: 18)
        settings.wrapMode = .fixedColumns
        settings.rulerColumn = 80
        let restored = EditorSettings.decoded(settings.encoded())
        XCTAssertEqual(restored.fontSize.points, 18)
        XCTAssertEqual(restored.wrapMode, .fixedColumns)
        XCTAssertEqual(restored.rulerColumn, 80)
    }

    func testDecodingNothingGivesTheDefault() {
        XCTAssertEqual(EditorSettings.decoded(nil), .default)
        XCTAssertEqual(EditorSettings.decoded(Data("こわれている".utf8)), .default)
    }

    func testThemeAndFontLookup() {
        var settings = EditorSettings()
        settings.themeID = "dark"
        XCTAssertEqual(settings.theme.id, "dark")
        settings.themeID = "どこにもない"
        XCTAssertEqual(settings.theme.id, EditorThemeCatalog.light.id)
    }

    func testAppearance() {
        XCTAssertTrue(AppearanceMode.dark.prefersDark(systemIsDark: false))
        XCTAssertFalse(AppearanceMode.light.prefersDark(systemIsDark: true))
        XCTAssertTrue(AppearanceMode.system.prefersDark(systemIsDark: true))
        for mode in AppearanceMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }

    func testAppearancePicksATheme() {
        XCTAssertEqual(AppearanceMode.dark.theme(systemIsDark: false).id, "dark")
        XCTAssertEqual(AppearanceMode.light.theme(systemIsDark: true).id, "light")
    }
}

final class DiagnosticSetTests: XCTestCase {
    private var set: DiagnosticSet {
        DiagnosticSet(items: [
            InlineDiagnostic(line: 10, severity: .warning, message: "警告"),
            InlineDiagnostic(line: 3, severity: .error, message: "エラー"),
            InlineDiagnostic(line: 3, severity: .hint, message: "ヒント")
        ])
    }

    func testSortedByLineAndSeverity() {
        XCTAssertEqual(set.items.map(\.line), [3, 3, 10])
        XCTAssertEqual(set.items.first?.severity, .error)
    }

    func testByLine() {
        XCTAssertEqual(set.diagnostics(atLine: 3).count, 2)
        XCTAssertEqual(set.severity(atLine: 3), .error)
        XCTAssertNil(set.severity(atLine: 99))
    }

    func testCounts() {
        XCTAssertEqual(set.errorCount, 1)
        XCTAssertEqual(set.warningCount, 1)
        XCTAssertTrue(set.hasErrors)
        XCTAssertTrue(set.summary.contains("エラー 1"))
    }

    func testEmptySummary() {
        XCTAssertEqual(DiagnosticSet().summary, "問題は見つかりませんでした")
    }

    func testJumpToNextAndPrevious() {
        XCTAssertEqual(set.next(after: 3)?.line, 10)
        XCTAssertEqual(set.next(after: 10)?.line, 3)     // 先頭に戻る。
        XCTAssertEqual(set.previous(before: 10)?.line, 3)
        XCTAssertEqual(set.previous(before: 1)?.line, 10) // 末尾に戻る。
    }

    func testFirstError() {
        XCTAssertEqual(set.firstError?.line, 3)
    }

    func testCollectFindsSyntaxErrors() {
        let result = DiagnosticSet.collect(source: "function (", languageID: "javascript")
        XCTAssertTrue(result.hasErrors)
    }

    func testCollectFindsLintAndHints() {
        let result = DiagnosticSet.collect(source: "if (a = 1) { }\n",
                                           languageID: "c")
        XCTAssertTrue(result.items.contains { $0.message.contains("代入") })
    }

    func testCollectOnCleanCode() {
        let result = DiagnosticSet.collect(source: "console.log(1);\n",
                                           languageID: "javascript")
        XCTAssertFalse(result.hasErrors)
    }

    func testFromRunWithRuntimeError() throws {
        let run = try RunSession.run(languageID: "javascript", source: """
        function bad() { return ないやつ(); }
        console.log(bad());
        """)
        let set = DiagnosticSet.fromRun(run)
        XCTAssertTrue(set.hasErrors)
        XCTAssertEqual(set.items.first?.line, 1)
    }

    func testFromRunWithSyntaxError() throws {
        let run = try RunSession.run(languageID: "javascript", source: "function (")
        XCTAssertTrue(DiagnosticSet.fromRun(run).hasErrors)
    }

    func testFromSuccessfulRun() throws {
        let run = try RunSession.run(languageID: "javascript", source: "console.log(1);")
        XCTAssertTrue(DiagnosticSet.fromRun(run).isEmpty)
    }

    func testSeverityNames() {
        for severity in [InlineDiagnostic.Severity.error, .warning, .hint] {
            XCTAssertFalse(severity.displayName.isEmpty)
            XCTAssertFalse(severity.symbol.isEmpty)
        }
        XCTAssertLessThan(InlineDiagnostic.Severity.error,
                          InlineDiagnostic.Severity.warning)
    }
}

final class TabBarTests: XCTestCase {
    private func tab(_ name: String, path: String? = nil) -> EditorTab {
        EditorTab(location: GitHubLocation(owner: "o", repo: "r",
                                           path: path ?? name),
                  title: name)
    }

    func testOpenAndSelect() {
        var bar = TabBar()
        bar.open(tab("a"))
        bar.open(tab("b"))
        XCTAssertEqual(bar.count, 2)
        XCTAssertEqual(bar.selected?.title, "b")
    }

    func testOpeningTheSameFileSelectsIt() {
        var bar = TabBar()
        bar.open(tab("a"))
        bar.open(tab("b"))
        bar.open(tab("a"))
        XCTAssertEqual(bar.count, 2)
        XCTAssertEqual(bar.selected?.title, "a")
    }

    func testClose() {
        var bar = TabBar()
        bar.open(tab("a"))
        bar.open(tab("b"))
        let id = bar.selected!.id
        bar.close(id: id)
        XCTAssertEqual(bar.count, 1)
        XCTAssertEqual(bar.selected?.title, "a")
    }

    func testCloseOthersKeepsPinned() {
        var bar = TabBar()
        bar.open(tab("a"))
        let pinned = bar.selected!.id
        bar.togglePin(id: pinned)
        bar.open(tab("b"))
        bar.open(tab("c"))
        bar.closeOthers(keeping: bar.selected!.id)
        XCTAssertEqual(bar.count, 2)
        XCTAssertTrue(bar.tabs.contains { $0.title == "a" })
    }

    func testCycleSelection() {
        var bar = TabBar()
        bar.open(tab("a"))
        bar.open(tab("b"))
        bar.selectNext()
        XCTAssertEqual(bar.selected?.title, "a")
        bar.selectNext(false)
        XCTAssertEqual(bar.selected?.title, "b")
    }

    func testMove() {
        var bar = TabBar()
        bar.open(tab("a"))
        bar.open(tab("b"))
        bar.move(from: 0, to: 2)
        XCTAssertEqual(bar.tabs.map(\.title), ["b", "a"])
    }

    func testPinMovesToFront() {
        var bar = TabBar()
        bar.open(tab("a"))
        bar.open(tab("b"))
        bar.togglePin(id: bar.tabs[1].id)
        XCTAssertEqual(bar.tabs.first?.title, "b")
        XCTAssertTrue(bar.tabs.first!.isPinned)
    }

    func testDirtyMark() {
        var bar = TabBar()
        bar.open(tab("a"))
        bar.update(id: bar.selected!.id) { $0.isDirty = true }
        XCTAssertEqual(bar.dirtyCount, 1)
        XCTAssertEqual(bar.selected?.label, "a •")
    }

    func testLimitClosesOldTabs() {
        var bar = TabBar(limit: 3)
        for name in ["a", "b", "c", "d"] { bar.open(tab(name)) }
        XCTAssertEqual(bar.count, 3)
        XCTAssertFalse(bar.tabs.contains { $0.title == "a" })
    }

    func testLimitKeepsDirtyAndPinned() {
        var bar = TabBar(limit: 2)
        bar.open(tab("a"))
        bar.update(id: bar.selected!.id) { $0.isDirty = true }
        bar.open(tab("b"))
        bar.open(tab("c"))
        XCTAssertTrue(bar.tabs.contains { $0.title == "a" })
    }

    func testCodable() throws {
        var bar = TabBar()
        bar.open(tab("a"))
        let data = try JSONEncoder().encode(bar)
        let back = try JSONDecoder().decode(TabBar.self, from: data)
        XCTAssertEqual(back.tabs.first?.title, "a")
    }
}

final class NavigationHistoryTests: XCTestCase {
    private func place(_ path: String) -> VisitedPlace {
        VisitedPlace(location: GitHubLocation(owner: "o", repo: "r", path: path),
                     title: path)
    }

    func testVisitAndBack() {
        var history = NavigationHistory()
        history.visit(place("a"))
        history.visit(place("b"))
        XCTAssertEqual(history.current?.title, "b")
        XCTAssertTrue(history.canGoBack)
        XCTAssertEqual(history.goBack()?.title, "a")
        XCTAssertFalse(history.canGoBack)
    }

    func testForward() {
        var history = NavigationHistory()
        history.visit(place("a"))
        history.visit(place("b"))
        _ = history.goBack()
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.goForward()?.title, "b")
        XCTAssertFalse(history.canGoForward)
    }

    func testVisitingClearsForward() {
        var history = NavigationHistory()
        history.visit(place("a"))
        history.visit(place("b"))
        _ = history.goBack()
        history.visit(place("c"))
        XCTAssertFalse(history.canGoForward)
    }

    func testRecentIsNewestFirstWithoutDuplicates() {
        var history = NavigationHistory()
        history.visit(place("a"))
        history.visit(place("b"))
        history.visit(place("a"))
        XCTAssertEqual(history.recent.map(\.title), ["a", "b"])
    }

    func testRecentLimit() {
        var history = NavigationHistory(recentLimit: 2)
        for name in ["a", "b", "c"] { history.visit(place(name)) }
        XCTAssertEqual(history.recent.count, 2)
    }

    func testGoBackOnEmptyHistory() {
        var history = NavigationHistory()
        XCTAssertNil(history.goBack())
        XCTAssertNil(history.goForward())
    }

    func testClearRecent() {
        var history = NavigationHistory()
        history.visit(place("a"))
        history.clearRecent()
        XCTAssertTrue(history.recent.isEmpty)
    }
}

final class BookmarkTests: XCTestCase {
    private var location: GitHubLocation {
        GitHubLocation(owner: "o", repo: "r", path: "a.swift")
    }

    func testToggle() {
        var store = BookmarkStore()
        let bookmark = Bookmark(location: location, title: "a", line: 10)
        XCTAssertTrue(store.toggle(bookmark))
        XCTAssertEqual(store.count, 1)
        XCTAssertFalse(store.toggle(bookmark))
        XCTAssertEqual(store.count, 0)
    }

    func testContains() {
        var store = BookmarkStore()
        store.toggle(Bookmark(location: location, title: "a", line: 3))
        XCTAssertTrue(store.contains(location, line: 3))
        XCTAssertFalse(store.contains(location, line: 4))
    }

    func testLinesInFile() {
        var store = BookmarkStore()
        store.toggle(Bookmark(location: location, title: "a", line: 5))
        store.toggle(Bookmark(location: location, title: "a", line: 2))
        XCTAssertEqual(store.lines(in: location), [2, 5])
    }

    func testRemove() {
        var store = BookmarkStore()
        let bookmark = Bookmark(location: location, title: "a")
        store.toggle(bookmark)
        store.remove(id: bookmark.id)
        XCTAssertEqual(store.count, 0)
    }

    func testSubtitle() {
        XCTAssertEqual(Bookmark(location: location, title: "a", line: 12).subtitle,
                       "a.swift:12")
        XCTAssertEqual(Bookmark(location: GitHubLocation(owner: "o", repo: "r"),
                                title: "a").subtitle, "o/r")
    }
}

final class BreadcrumbTests: XCTestCase {
    func testTrail() {
        let location = GitHubLocation(owner: "o", repo: "r", ref: "main",
                                      path: "src/app/main.swift")
        let trail = Breadcrumbs.trail(for: location)
        XCTAssertEqual(trail.map(\.title), ["o/r", "src", "app", "main.swift"])
        XCTAssertEqual(trail[1].location.path, "src")
        XCTAssertTrue(trail[1].location.isDirectory)
        XCTAssertFalse(trail.last!.location.isDirectory)
    }

    func testRootOnly() {
        let trail = Breadcrumbs.trail(for: GitHubLocation(owner: "o", repo: "r"))
        XCTAssertEqual(trail.count, 1)
    }
}

final class TreeExpansionTests: XCTestCase {
    func testToggle() {
        var tree = TreeExpansion()
        XCTAssertTrue(tree.toggle("src"))
        XCTAssertTrue(tree.isExpanded("src"))
        XCTAssertFalse(tree.toggle("src"))
    }

    func testRevealOpensThePathAbove() {
        var tree = TreeExpansion()
        tree.reveal(path: "a/b/c.swift")
        XCTAssertTrue(tree.isExpanded("a"))
        XCTAssertTrue(tree.isExpanded("a/b"))
        XCTAssertFalse(tree.isExpanded("a/b/c.swift"))
    }

    func testCollapseAll() {
        var tree = TreeExpansion()
        tree.setExpanded(true, for: "a")
        tree.collapseAll()
        XCTAssertTrue(tree.expandedPaths.isEmpty)
    }

    func testCodable() throws {
        var tree = TreeExpansion()
        tree.setExpanded(true, for: "a")
        let data = try JSONEncoder().encode(tree)
        let back = try JSONDecoder().decode(TreeExpansion.self, from: data)
        XCTAssertTrue(back.isExpanded("a"))
    }
}

final class SidebarStateTests: XCTestCase {
    func testToggle() {
        var sidebar = SidebarState()
        sidebar.toggle()
        XCTAssertFalse(sidebar.isVisible)
    }

    func testWidthIsClamped() {
        var sidebar = SidebarState()
        sidebar.setWidth(10)
        XCTAssertEqual(sidebar.width, SidebarState.minimumWidth)
        sidebar.setWidth(9999)
        XCTAssertEqual(sidebar.width, SidebarState.maximumWidth)
    }

    func testInitialWidthIsClamped() {
        XCTAssertEqual(SidebarState(width: 1).width, SidebarState.minimumWidth)
    }
}

final class WorkspaceTests: XCTestCase {
    func testAddAndActivate() {
        var workspace = Workspace()
        workspace.add(WorkspaceEntry(owner: "a", repo: "x"))
        workspace.add(WorkspaceEntry(owner: "b", repo: "y"))
        XCTAssertEqual(workspace.entries.count, 2)
        XCTAssertEqual(workspace.active?.id, "b/y")
        workspace.activate(id: "a/x")
        XCTAssertEqual(workspace.active?.id, "a/x")
    }

    func testAddingTheSameRepoReplacesIt() {
        var workspace = Workspace()
        workspace.add(WorkspaceEntry(owner: "a", repo: "x"))
        workspace.add(WorkspaceEntry(owner: "a", repo: "x", nickname: "私の"))
        XCTAssertEqual(workspace.entries.count, 1)
        XCTAssertEqual(workspace.active?.displayName, "私の")
    }

    func testRemove() {
        var workspace = Workspace()
        workspace.add(WorkspaceEntry(owner: "a", repo: "x"))
        workspace.add(WorkspaceEntry(owner: "b", repo: "y"))
        workspace.remove(id: "b/y")
        XCTAssertEqual(workspace.active?.id, "a/x")
    }

    func testRename() {
        var workspace = Workspace()
        workspace.add(WorkspaceEntry(owner: "a", repo: "x"))
        workspace.rename(id: "a/x", to: "実験")
        XCTAssertEqual(workspace.active?.displayName, "実験")
        workspace.rename(id: "a/x", to: nil)
        XCTAssertEqual(workspace.active?.displayName, "a/x")
    }

    func testRootLocation() {
        let entry = WorkspaceEntry(owner: "a", repo: "x", ref: "dev")
        XCTAssertTrue(entry.rootLocation.isDirectory)
        XCTAssertEqual(entry.rootLocation.ref, "dev")
    }
}
