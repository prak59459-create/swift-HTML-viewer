import XCTest
@testable import GitHubViewerCore

final class ShortcutTests: XCTestCase {
    func testChordDisplay() {
        XCTAssertEqual(KeyChord("s", command: true).displayText, "⌘S")
        XCTAssertEqual(KeyChord("s", command: true, shift: true).displayText, "⇧⌘S")
        XCTAssertEqual(KeyChord("return", command: true, control: true).displayText,
                       "⌃⌘↩")
    }

    func testNoModifiers() {
        XCTAssertTrue(KeyChord("a").hasNoModifiers)
        XCTAssertFalse(KeyChord("a", command: true).hasNoModifiers)
    }

    func testDefaultBindings() {
        let map = ShortcutMap()
        XCTAssertEqual(map.chord(for: .run), KeyChord("r", command: true))
        XCTAssertEqual(map.action(for: KeyChord("s", command: true)), .save)
        XCTAssertNil(map.action(for: KeyChord("q", command: true, shift: true,
                                              option: true, control: true)))
    }

    func testEveryActionHasAKey() {
        XCTAssertTrue(ShortcutMap().coversEveryAction)
    }

    func testEveryActionHasANameAndCategory() {
        for action in ShortcutAction.allCases {
            XCTAssertFalse(action.displayName.isEmpty)
            XCTAssertFalse(action.category.isEmpty)
        }
    }

    func testNoDuplicateDefaults() {
        let chords = ShortcutAction.allCases.compactMap {
            ShortcutMap.defaultBindings[$0]
        }
        XCTAssertEqual(Set(chords).count, chords.count, "同じ組み合わせが重なっています")
    }

    func testAssigningTakesOverAnExistingKey() {
        var map = ShortcutMap()
        let taken = map.assign(KeyChord("s", command: true), to: .run)
        XCTAssertEqual(taken, .save)
        XCTAssertEqual(map.action(for: KeyChord("s", command: true)), .run)
        XCTAssertNil(map.chord(for: .save))
    }

    func testAssigningTheSameActionKeepsIt() {
        var map = ShortcutMap()
        XCTAssertNil(map.assign(KeyChord("x", command: true), to: .run))
        XCTAssertEqual(map.chord(for: .run), KeyChord("x", command: true))
    }

    func testCustomizedList() {
        var map = ShortcutMap()
        XCTAssertTrue(map.customized.isEmpty)
        map.assign(KeyChord("x", command: true), to: .run)
        XCTAssertEqual(map.customized, [.run])
        map.reset(.run)
        XCTAssertTrue(map.customized.isEmpty)
    }

    func testResetAll() {
        var map = ShortcutMap()
        map.remove(.run)
        map.resetToDefaults()
        XCTAssertNotNil(map.chord(for: .run))
    }

    func testListing() {
        let groups = ShortcutMap().listing()
        XCTAssertFalse(groups.isEmpty)
        XCTAssertTrue(groups.contains { $0.category == "実行" })
        for group in groups { XCTAssertFalse(group.items.isEmpty) }
    }

    func testCodable() throws {
        var map = ShortcutMap()
        map.assign(KeyChord("k", command: true), to: .run)
        let data = try JSONEncoder().encode(map)
        let back = try JSONDecoder().decode(ShortcutMap.self, from: data)
        XCTAssertEqual(back.chord(for: .run), KeyChord("k", command: true))
    }
}

final class ContextMenuTests: XCTestCase {
    func testFileMenu() {
        let items = ContextMenus.fileItems(isDirectory: false, isBookmarked: false)
        XCTAssertTrue(items.contains { $0.id == "open-split" })
        XCTAssertTrue(items.contains { $0.id == "download" })
        XCTAssertNotNil(items.first { $0.id == "copy-link" }?.shortcut)
    }

    func testDirectoryMenuHasNoFileOnlyItems() {
        let items = ContextMenus.fileItems(isDirectory: true, isBookmarked: false)
        XCTAssertFalse(items.contains { $0.id == "open-split" })
        XCTAssertFalse(items.contains { $0.id == "download" })
    }

    func testBookmarkTitleFlips() {
        let on = ContextMenus.fileItems(isDirectory: false, isBookmarked: true)
        XCTAssertEqual(on.first { $0.id == "bookmark" }?.title, "ブックマークを外す")
    }

    func testSelectionMenu() {
        let items = ContextMenus.selectionItems(hasSelection: true,
                                                languageID: "swift")
        XCTAssertTrue(items.contains { $0.id == "copy" })
        XCTAssertTrue(items.contains { $0.id == "run-selection" })
    }

    func testMenuWithoutSelection() {
        let items = ContextMenus.selectionItems(hasSelection: false, languageID: nil)
        XCTAssertFalse(items.contains { $0.id == "copy" })
        XCTAssertTrue(items.contains { $0.id == "paste" })
    }

    func testTabMenu() {
        let clean = ContextMenus.tabItems(isPinned: false, isDirty: false)
        XCTAssertFalse(clean.contains { $0.id == "discard" })
        let dirty = ContextMenus.tabItems(isPinned: true, isDirty: true)
        XCTAssertTrue(dirty.contains { $0.id == "discard" && $0.isDestructive })
        XCTAssertEqual(dirty.first { $0.id == "pin" }?.title, "ピンを外す")
    }
}

final class GestureAndHapticTests: XCTestCase {
    func testGesturesHaveNamesAndEffects() {
        for gesture in Gesture.allCases {
            XCTAssertFalse(gesture.displayName.isEmpty)
            XCTAssertFalse(gesture.effect.isEmpty)
        }
    }

    func testHapticForEvents() {
        XCTAssertEqual(HapticFeedback.forEvent(.runSucceeded), .success)
        XCTAssertEqual(HapticFeedback.forEvent(.runFailed), .failure)
        XCTAssertNil(HapticFeedback.forEvent(.none))
    }
}

final class AccessibilityTests: XCTestCase {
    func testContentSizeScaling() {
        XCTAssertEqual(ContentSizeCategory.large.scale, 1.0)
        XCTAssertGreaterThan(ContentSizeCategory.accessibilityLarge.scale, 1.5)
        XCTAssertTrue(ContentSizeCategory.accessibilityLarge.isAccessibilitySize)
        XCTAssertFalse(ContentSizeCategory.large.isAccessibilitySize)
    }

    func testFontSizeFollowsTheSetting() {
        let size = ContentSizeCategory.extraExtraLarge
            .fontSize(base: FontSize(points: 10))
        XCTAssertEqual(size.points, 12.4, accuracy: 0.01)
    }

    func testEveryCategoryHasAScale() {
        for category in ContentSizeCategory.allCases {
            XCTAssertGreaterThan(category.scale, 0)
        }
    }

    func testLineDescription() {
        let text = AccessibilityText.line(number: 3, text: "  let a = 1",
                                          hasBreakpoint: true)
        XCTAssertTrue(text.contains("3 行目"))
        XCTAssertTrue(text.contains("let a = 1"))
        XCTAssertTrue(text.contains("ブレークポイント"))
    }

    func testEmptyLineDescription() {
        XCTAssertTrue(AccessibilityText.line(number: 1, text: "   ")
            .contains("空の行"))
    }

    func testDiagnosticIsRead() {
        let diagnostic = InlineDiagnostic(line: 1, severity: .error, message: "まずい")
        let text = AccessibilityText.line(number: 1, text: "a", diagnostic: diagnostic)
        XCTAssertTrue(text.contains("エラー: まずい"))
    }

    func testSpokenCode() {
        let spoken = AccessibilityText.spoken("if (a) { b = 1; }")
        XCTAssertTrue(spoken.contains("丸括弧ひらく"))
        XCTAssertTrue(spoken.contains("波括弧とじる"))
        XCTAssertTrue(spoken.contains("イコール"))
        XCTAssertFalse(spoken.contains("  "))
    }

    func testButtonDescription() {
        XCTAssertEqual(AccessibilityText.button("実行", shortcut: nil), "実行")
        XCTAssertTrue(AccessibilityText.button("実行",
                                               shortcut: KeyChord("r", command: true))
            .contains("⌘R"))
    }
}

final class ReachabilityAndPowerTests: XCTestCase {
    func testReachability() {
        XCTAssertTrue(ReachabilitySide.right.alignsTrailing)
        XCTAssertFalse(ReachabilitySide.off.isEnabled)
        for side in ReachabilitySide.allCases {
            XCTAssertFalse(side.displayName.isEmpty)
        }
    }

    func testPowerSavingIsOffByDefault() {
        let policy = PowerSavingPolicy()
        XCTAssertFalse(policy.disablesAutoRun)
        XCTAssertFalse(policy.hidesMinimap)
    }

    func testPowerSavingLimitsRuns() {
        let policy = PowerSavingPolicy(isLowPower: true)
        var options = RunOptions()
        options.maximumSteps = 50_000_000
        options.timeLimit = 60
        let adjusted = policy.adjusted(options)
        XCTAssertEqual(adjusted.maximumSteps, 1_000_000)
        XCTAssertEqual(adjusted.timeLimit, 5)
    }

    func testPowerSavingSimplifiesSettings() {
        let policy = PowerSavingPolicy(isLowPower: true)
        var settings = EditorSettings()
        settings.showsMinimap = true
        settings.autoRun = .onPause
        let adjusted = policy.adjusted(settings)
        XCTAssertFalse(adjusted.showsMinimap)
        XCTAssertEqual(adjusted.autoRun, .onSave)
    }

    func testNormalPowerLeavesThingsAlone() {
        let policy = PowerSavingPolicy()
        var settings = EditorSettings()
        settings.showsMinimap = true
        XCTAssertTrue(policy.adjusted(settings).showsMinimap)
    }
}

final class DropHandlingTests: XCTestCase {
    func testAcceptsKnownExtensions() {
        XCTAssertTrue(DropHandling.canAccept(fileName: "a.swift"))
        XCTAssertTrue(DropHandling.canAccept(fileName: "README"))
        XCTAssertFalse(DropHandling.canAccept(fileName: "a.exe"))
    }

    func testTextFileOpens() {
        let outcome = DropHandling.handle(.file(name: "main.swift",
                                                data: Data("let a = 1".utf8)))
        guard case .openFile(let name, let text, let languageID) = outcome else {
            return XCTFail("開けるはずです")
        }
        XCTAssertEqual(name, "main.swift")
        XCTAssertEqual(text, "let a = 1")
        XCTAssertEqual(languageID, "swift")
    }

    func testImageIsShownAsIs() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])
        let outcome = DropHandling.handle(.file(name: "a.png", data: png))
        guard case .showBinary = outcome else { return XCTFail("画像のはずです") }
    }

    func testPlainTextIsInserted() {
        guard case .insertText(let text) = DropHandling.handle(.text("こんにちは")) else {
            return XCTFail("差し込むはずです")
        }
        XCTAssertEqual(text, "こんにちは")
    }

    func testURLTextOpensTheRepository() {
        let outcome = DropHandling.handle(.text("https://github.com/o/r"))
        guard case .openTarget = outcome else { return XCTFail("開くはずです") }
    }

    func testURLItem() {
        let outcome = DropHandling.handle(.url(URL(string: "https://github.com/o/r")!))
        guard case .openTarget = outcome else { return XCTFail("開くはずです") }
    }

    func testUnsupportedURL() {
        let outcome = DropHandling.handle(.url(URL(string: "ftp://example.com")!))
        guard case .unsupported = outcome else { return XCTFail("扱えないはずです") }
    }

    func testDisplayNames() {
        XCTAssertEqual(DroppedItem.file(name: "a.txt", data: Data()).displayName,
                       "a.txt")
        XCTAssertEqual(DroppedItem.text("あいう").displayName, "あいう")
    }
}

final class WindowContextTests: XCTestCase {
    func testSizeClass() {
        XCTAssertEqual(SizeClass.from(width: 320), .compact)
        XCTAssertEqual(SizeClass.from(width: 1024), .regular)
    }

    func testNarrowWindowShowsOnlyTheEditor() {
        let context = WindowContext(width: 320, height: 800)
        XCTAssertTrue(context.isNarrow)
        XCTAssertEqual(context.suggestedLayout, .editorOnly)
        XCTAssertTrue(context.sidebarOverlays)
    }

    func testWideWindow() {
        let context = WindowContext(width: 1366, height: 1024)
        XCTAssertFalse(context.isNarrow)
        XCTAssertEqual(context.suggestedLayout, .sideBySide)
        XCTAssertTrue(context.isLandscape)
    }

    func testSlideOverIsNarrow() {
        let context = WindowContext(width: 800, height: 1000, isSlideOver: true)
        XCTAssertTrue(context.isNarrow)
    }

    func testExternalDisplay() {
        XCTAssertEqual(WindowContext(width: 100, height: 100).externalDisplayContent,
                       .none)
        XCTAssertEqual(WindowContext(width: 100, height: 100,
                                     hasExternalDisplay: true).externalDisplayContent,
                       .output)
        for content in [ExternalDisplayContent.none, .output, .preview, .mirror] {
            XCTAssertFalse(content.displayName.isEmpty)
        }
    }
}

final class AppIntentTests: XCTestCase {
    func testCatalog() {
        XCTAssertFalse(AppIntents.all.isEmpty)
        XCTAssertNotNil(AppIntents.intent(id: "run-code"))
        XCTAssertNil(AppIntents.intent(id: "どこにもない"))
        for intent in AppIntents.all {
            XCTAssertFalse(intent.title.isEmpty)
            XCTAssertFalse(intent.result.isEmpty)
        }
    }

    func testRunCode() {
        let output = AppIntents.runCode(languageID: "javascript",
                                        source: "console.log(6 * 7);")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    func testRunCodeWithInput() {
        let output = AppIntents.runCode(languageID: "javascript",
                                        source: "console.log(readLine());",
                                        input: "やあ")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "やあ")
    }

    func testRunUnknownLanguage() {
        XCTAssertTrue(AppIntents.runCode(languageID: "cobol", source: "")
            .contains("実行できません"))
    }

    func testRunFailure() {
        let output = AppIntents.runCode(languageID: "javascript", source: "ないやつ();")
        XCTAssertTrue(output.contains("見つかりません"))
    }

    func testFormat() {
        let formatted = AppIntents.formatCode(languageID: "c", source: "f() {\ng();\n}")
        XCTAssertTrue(formatted.contains("    g();"))
    }

    func testCheckSyntax() {
        XCTAssertEqual(AppIntents.checkSyntax(languageID: "javascript",
                                              source: "let a = 1;"),
                       "問題は見つかりませんでした")
        XCTAssertNotEqual(AppIntents.checkSyntax(languageID: "javascript",
                                                 source: "function ("),
                          "問題は見つかりませんでした")
    }
}

final class ActivityAndWidgetTests: XCTestCase {
    private var location: GitHubLocation {
        GitHubLocation(owner: "o", repo: "r", ref: "main", path: "src/main.swift")
    }

    func testActivityFromFile() {
        let activity = ActivityInfo.forFile(location, line: 12, languageID: "swift")
        XCTAssertEqual(activity.title, "main.swift")
        XCTAssertTrue(activity.keywords.contains("swift"))
        XCTAssertTrue(activity.keywords.contains("src"))
        XCTAssertEqual(activity.searchDescription, "o/r — src/main.swift")
    }

    func testHandoffURLKeepsTheLine() {
        let activity = ActivityInfo.forFile(location, line: 12)
        XCTAssertTrue(activity.handoffURL?.absoluteString.hasSuffix("#L12") == true)
    }

    func testHandoffURLWithoutALine() {
        let activity = ActivityInfo.forFile(location, line: 1)
        XCTAssertFalse(activity.handoffURL?.absoluteString.contains("#") == true)
    }

    func testWidgetSnapshot() {
        var history = NavigationHistory()
        history.visit(VisitedPlace(location: location, title: "main.swift"))
        let runs = RunHistory()
        runs.add(RunHistoryEntry(languageID: "swift", source: "", output: "42"))

        let snapshot = WidgetSnapshot.make(history: history, runs: runs,
                                           rateLimit: RateLimitStatus(limit: 60,
                                                                      remaining: 30,
                                                                      resetDate: nil))
        XCTAssertEqual(snapshot.recent, ["main.swift"])
        XCTAssertTrue(snapshot.lastRunSummary?.contains("42") == true)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testEmptyWidget() {
        XCTAssertTrue(WidgetSnapshot().isEmpty)
    }
}

final class HoveringTests: XCTestCase {
    func testLineWithDiagnostic() {
        let set = DiagnosticSet(items: [
            InlineDiagnostic(line: 3, severity: .error, message: "まずい",
                             suggestion: "こう直す")
        ])
        let info = Hovering.forLine(3, diagnostics: set)
        XCTAssertEqual(info?.title, "まずい")
        XCTAssertEqual(info?.detail, "こう直す")
    }

    func testLineWithoutAnything() {
        XCTAssertNil(Hovering.forLine(3, diagnostics: DiagnosticSet()))
    }

    func testHeatIsShown() {
        let info = Hovering.forLine(3, diagnostics: DiagnosticSet(), heat: 0.5)
        XCTAssertTrue(info?.text.contains("50%") == true)
    }

    func testVariable() {
        let info = Hovering.forVariable(WatchedVariable(name: "a", displayValue: "1",
                                                        typeName: "整数"))
        XCTAssertEqual(info.title, "a")
        XCTAssertTrue(info.text.contains("整数"))
    }

    func testFile() {
        let item = FileListItem(entry: RepositoryEntry(
            name: "a.swift", isDirectory: false, size: 100,
            location: GitHubLocation(owner: "o", repo: "r", path: "src/a.swift")))
        XCTAssertTrue(Hovering.forFile(item).text.contains("src/a.swift"))
    }
}

final class SessionStateTests: XCTestCase {
    func testRoundTrip() {
        var state = SessionState()
        state.display.setZoom(1.5)
        state.sidebar.setWidth(300)
        var tabs = TabBar()
        tabs.open(EditorTab(title: "a.swift"))
        state.tabs = tabs

        let restored = SessionState.decoded(state.encoded())
        XCTAssertEqual(restored.display.zoom, 1.5)
        XCTAssertEqual(restored.sidebar.width, 300)
        XCTAssertEqual(restored.tabs.count, 1)
    }

    func testDecodingNothing() {
        XCTAssertEqual(SessionState.decoded(nil).tabs.count, 0)
        XCTAssertEqual(SessionState.decoded(Data("こわれている".utf8)).tabs.count, 0)
    }

    func testFutureVersionIsIgnored() {
        var state = SessionState()
        state.version = SessionState.currentVersion + 1
        XCTAssertEqual(SessionState.decoded(state.encoded()).version,
                       SessionState.currentVersion)
    }

    func testRotationKeepsTheSplitButChangesTheDirection() {
        var state = SessionState()
        state.display.layout = .sideBySide
        let portrait = state.adaptedToRotation(WindowContext(width: 800, height: 1200))
        XCTAssertEqual(portrait.display.layout, .stacked)
    }

    func testRotationHidesTheSidebarWhenNarrow() {
        var state = SessionState()
        state.sidebar.isVisible = true
        let narrow = state.adaptedToRotation(WindowContext(width: 320, height: 800))
        XCTAssertFalse(narrow.sidebar.isVisible)
    }

    func testNonSplitLayoutIsKept() {
        var state = SessionState()
        state.display.layout = .editorOnly
        let rotated = state.adaptedToRotation(WindowContext(width: 1200, height: 800))
        XCTAssertEqual(rotated.display.layout, .editorOnly)
    }

    func testStaleness() {
        var state = SessionState()
        state.savedAt = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(state.isStale())
        state.savedAt = Date()
        XCTAssertFalse(state.isStale())
    }
}

final class AnnotationTests: XCTestCase {
    private func note(_ line: Int, file: String = "a.swift",
                      text: String = "メモ") -> Annotation {
        Annotation(kind: .note, fileKey: file, line: line, text: text)
    }

    func testSaveAndRead() {
        let store = AnnotationStore()
        store.save(note(3))
        XCTAssertEqual(store.all.count, 1)
        XCTAssertEqual(store.annotations(forFile: "a.swift", line: 3).count, 1)
        XCTAssertEqual(store.lines(forFile: "a.swift"), [3])
    }

    func testEmptyAnnotationIsDropped() {
        let store = AnnotationStore()
        store.save(Annotation(kind: .note, fileKey: "a", line: 1, text: "  "))
        XCTAssertTrue(store.all.isEmpty)
    }

    func testRemove() {
        let store = AnnotationStore()
        let annotation = note(1)
        store.save(annotation)
        store.remove(id: annotation.id)
        XCTAssertTrue(store.all.isEmpty)
    }

    func testRemoveByFile() {
        let store = AnnotationStore()
        store.save(note(1, file: "a"))
        store.save(note(2, file: "a"))
        store.save(note(3, file: "b"))
        XCTAssertEqual(store.removeAll(forFile: "a"), 2)
        XCTAssertEqual(store.all.count, 1)
    }

    func testShiftLines() {
        let store = AnnotationStore()
        store.save(note(2))
        store.save(note(10))
        store.shift(fileKey: "a.swift", afterLine: 5, by: 3)
        XCTAssertEqual(store.lines(forFile: "a.swift"), [2, 13])
    }

    func testShiftUpwardsStopsAtOne() {
        let store = AnnotationStore()
        store.save(note(3))
        store.shift(fileKey: "a.swift", afterLine: 1, by: -100)
        XCTAssertEqual(store.lines(forFile: "a.swift"), [1])
    }

    func testPersistence() {
        let store = AnnotationStore()
        store.save(note(1))
        let restored = AnnotationStore(json: store.encoded())
        XCTAssertEqual(restored.all.count, 1)
    }

    func testDrawingAnnotation() {
        let annotation = Annotation(kind: .drawing, fileKey: "a", line: 1,
                                    drawingData: Data([1, 2, 3]))
        XCTAssertFalse(annotation.isEmpty)
        XCTAssertEqual(annotation.summary, "手書きのメモ")
    }

    func testKindNames() {
        for kind in [Annotation.Kind.drawing, .note, .highlight] {
            XCTAssertFalse(kind.displayName.isEmpty)
        }
    }
}

final class ScribbleTests: XCTestCase {
    func testFullWidthSymbolsAreFixed() {
        XCTAssertEqual(Scribble.clean("ｉｆ（ａ）｛"), "ｉｆ(ａ)｛".replacingOccurrences(
            of: "｛", with: "{"))
    }

    func testCommonSymbols() {
        XCTAssertEqual(Scribble.clean("a＝b＋c；"), "a=b+c;")
    }

    func testFullWidthSpace() {
        XCTAssertEqual(Scribble.clean("a　b"), "a b")
    }

    func testOrdinaryTextIsUnchanged() {
        XCTAssertEqual(Scribble.clean("let a = 1"), "let a = 1")
        XCTAssertFalse(Scribble.needsCleaning("let a = 1"))
        XCTAssertTrue(Scribble.needsCleaning("a（b）"))
    }

    func testInsert() {
        let result = Scribble.insert("（", into: "ab", at: 1)
        XCTAssertEqual(result.replacement, "(")
        XCTAssertEqual(result.applied(to: "ab"), "a(b")
        XCTAssertEqual(result.selectionLocation, 2)
    }

    func testInsertReplacingASelection() {
        let result = Scribble.insert("x", into: "abc", at: 0, length: 2)
        XCTAssertEqual(result.applied(to: "abc"), "xc")
    }
}

final class LocalProjectTests: XCTestCase {
    func testFromTemplate() {
        guard let template = FileTemplateCatalog.template(for: "go") else {
            return XCTFail("テンプレートがありません")
        }
        let project = LocalProject.fromTemplate(template)
        XCTAssertEqual(project.entryFile, "main.go")
        XCTAssertEqual(project.languageID, "go")
        XCTAssertNotNil(project.runProject)
    }

    func testRunnable() throws {
        var project = LocalProject(name: "テスト", languageID: "javascript")
        project.setFile("main.js", text: "console.log(1);")
        project.entryFile = "main.js"
        let runnable = project.runProject
        XCTAssertNotNil(runnable)
        let result = try ProjectRunner.run(runnable!)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "1")
    }

    func testNotRunnableWithoutAnEntry() {
        let project = LocalProject(name: "x", files: ["a.js": "1"],
                                   languageID: "javascript")
        XCTAssertNil(project.runProject)
    }

    func testRemovingTheEntryPicksAnother() {
        var project = LocalProject(name: "x", files: ["a.js": "1", "b.js": "2"],
                                   entryFile: "a.js")
        project.setFile("a.js", text: nil)
        XCTAssertEqual(project.entryFile, "b.js")
    }

    func testRename() {
        var project = LocalProject(name: "x", files: ["a.js": "1"], entryFile: "a.js")
        project.rename(file: "a.js", to: "main.js")
        XCTAssertEqual(project.fileNames, ["main.js"])
        XCTAssertEqual(project.entryFile, "main.js")
    }

    func testRenameToAnExistingNameDoesNothing() {
        var project = LocalProject(name: "x", files: ["a.js": "1", "b.js": "2"])
        project.rename(file: "a.js", to: "b.js")
        XCTAssertEqual(project.fileNames, ["a.js", "b.js"])
    }

    func testSummary() {
        let project = LocalProject(name: "x", files: ["a": "12345"])
        XCTAssertTrue(project.summary.contains("1 ファイル"))
        XCTAssertEqual(project.byteCount, 5)
    }

    func testStorageNames() {
        for storage in StorageLocation.allCases {
            XCTAssertFalse(storage.displayName.isEmpty)
        }
        XCTAssertTrue(StorageLocation.iCloud.isShared)
        XCTAssertFalse(StorageLocation.local.isShared)
    }

    func testCodable() throws {
        let project = LocalProject(name: "x", files: ["a": "1"])
        let data = try JSONEncoder().encode(project)
        let back = try JSONDecoder().decode(LocalProject.self, from: data)
        XCTAssertEqual(back.name, "x")
    }
}
