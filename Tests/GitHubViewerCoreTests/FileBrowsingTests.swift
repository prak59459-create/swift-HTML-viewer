import XCTest
@testable import GitHubViewerCore

final class FileListingTests: XCTestCase {
    private func item(_ name: String, isDirectory: Bool = false, size: Int = 0,
                      modified: Date? = nil) -> FileListItem {
        FileListItem(entry: RepositoryEntry(
            name: name, isDirectory: isDirectory, size: size,
            location: GitHubLocation(owner: "o", repo: "r", path: name,
                                     isDirectory: isDirectory)),
                     modifiedAt: modified)
    }

    private var items: [FileListItem] {
        [item("b.txt", size: 300), item("a.swift", size: 100),
         item("src", isDirectory: true), item(".hidden", size: 50)]
    }

    func testHiddenFilesAreOutByDefault() {
        let result = FileListing.arrange(items)
        XCTAssertFalse(result.contains { $0.name == ".hidden" })
    }

    func testShowingHidden() {
        var options = FileListOptions()
        options.showsHidden = true
        XCTAssertTrue(FileListing.arrange(items, options: options)
            .contains { $0.name == ".hidden" })
    }

    func testDirectoriesComeFirst() {
        XCTAssertEqual(FileListing.arrange(items).first?.name, "src")
    }

    func testNameOrder() {
        let result = FileListing.arrange(items).filter { !$0.isDirectory }
        XCTAssertEqual(result.map(\.name), ["a.swift", "b.txt"])
    }

    func testDescendingOrder() {
        var options = FileListOptions()
        options.isAscending = false
        let result = FileListing.arrange(items, options: options)
            .filter { !$0.isDirectory }
        XCTAssertEqual(result.map(\.name), ["b.txt", "a.swift"])
    }

    func testSizeOrder() {
        var options = FileListOptions()
        options.sort = .size
        let result = FileListing.arrange(items, options: options)
            .filter { !$0.isDirectory }
        XCTAssertEqual(result.map(\.name), ["a.swift", "b.txt"])
    }

    func testModifiedOrder() {
        var options = FileListOptions()
        options.sort = .modified
        options.isAscending = false
        let listed = [item("old.txt", modified: Date(timeIntervalSince1970: 100)),
                      item("new.txt", modified: Date(timeIntervalSince1970: 200))]
        XCTAssertEqual(FileListing.arrange(listed, options: options).map(\.name),
                       ["new.txt", "old.txt"])
    }

    func testKindOrder() {
        var options = FileListOptions()
        options.sort = .kind
        let listed = [item("b.txt"), item("a.swift")]
        XCTAssertEqual(FileListing.arrange(listed, options: options).map(\.name),
                       ["a.swift", "b.txt"])
    }

    func testFilter() {
        var options = FileListOptions()
        options.filterText = "swift"
        let result = FileListing.arrange(items, options: options)
        XCTAssertEqual(result.map(\.name), ["a.swift"])
    }

    func testDetails() {
        let listed = item("a.txt", size: 2048,
                          modified: Date().addingTimeInterval(-3600))
        XCTAssertEqual(listed.sizeText, "2.0 KB")
        XCTAssertTrue(listed.modifiedText.contains("時間前"))
        XCTAssertTrue(listed.detailText.contains("·"))
    }

    func testDirectoryHasNoSizeText() {
        XCTAssertEqual(item("src", isDirectory: true).sizeText, "")
    }

    func testFileExtension() {
        XCTAssertEqual(item("a.tar.gz").fileExtension, "gz")
        XCTAssertEqual(item("README").fileExtension, "")
        XCTAssertEqual(item("src", isDirectory: true).fileExtension, "")
    }

    func testNeighbour() {
        let files = [item("a.txt"), item("src", isDirectory: true), item("b.txt")]
        XCTAssertEqual(FileListing.neighbour(of: "a.txt", in: files,
                                             forward: true)?.name, "b.txt")
        XCTAssertEqual(FileListing.neighbour(of: "b.txt", in: files,
                                             forward: false)?.name, "a.txt")
        XCTAssertNil(FileListing.neighbour(of: "b.txt", in: files, forward: true))
    }

    func testSortNames() {
        for order in FileSortOrder.allCases {
            XCTAssertFalse(order.displayName.isEmpty)
        }
    }
}

final class LinkResolverTests: XCTestCase {
    private let location = GitHubLocation(owner: "o", repo: "r", ref: "main",
                                          path: "docs/guide/index.md")

    func testAnchor() {
        XCTAssertEqual(LinkResolver.resolve("#使い方", from: location),
                       .anchor("使い方"))
    }

    func testRelativeSibling() {
        let destination = LinkResolver.resolve("next.md", from: location)
        XCTAssertEqual(destination?.location?.path, "docs/guide/next.md")
    }

    func testParentDirectory() {
        let destination = LinkResolver.resolve("../top.md", from: location)
        XCTAssertEqual(destination?.location?.path, "docs/top.md")
    }

    func testCurrentDirectoryPrefix() {
        let destination = LinkResolver.resolve("./a.md", from: location)
        XCTAssertEqual(destination?.location?.path, "docs/guide/a.md")
    }

    func testRootRelative() {
        let destination = LinkResolver.resolve("/README.md", from: location)
        XCTAssertEqual(destination?.location?.path, "README.md")
    }

    func testRefIsKept() {
        XCTAssertEqual(LinkResolver.resolve("a.md", from: location)?.location?.ref,
                       "main")
    }

    func testExternalURL() {
        let destination = LinkResolver.resolve("https://example.com/a", from: location)
        if case .external(let url) = destination {
            XCTAssertEqual(url.host, "example.com")
        } else {
            XCTFail("外のリンクになるはずです")
        }
    }

    func testGitHubURLOpensInside() {
        let destination = LinkResolver.resolve(
            "https://github.com/x/y/blob/main/a.md", from: location)
        XCTAssertEqual(destination?.location?.repo, "y")
    }

    func testLinkWithFragment() {
        let destination = LinkResolver.resolve("other.md#節", from: location)
        XCTAssertEqual(destination?.location?.path, "docs/guide/other.md")
    }

    func testFragmentOnlyAfterStrippingPath() {
        XCTAssertEqual(LinkResolver.resolve("#top", from: location), .anchor("top"))
    }

    func testDirectoryLink() {
        let destination = LinkResolver.resolve("../images/", from: location)
        XCTAssertTrue(destination?.location?.isDirectory == true)
    }

    func testEmptyLink() {
        XCTAssertNil(LinkResolver.resolve("  ", from: location))
    }

    func testMarkdownLinks() {
        let markdown = """
        [使い方](guide.md) と [外](https://example.com) と ![図](a.png)
        """
        let links = LinkResolver.links(inMarkdown: markdown)
        XCTAssertEqual(links.map(\.href), ["guide.md", "https://example.com"])
    }

    func testMarkdownLinkWithTitle() {
        let links = LinkResolver.links(inMarkdown: #"[a](b.md "説明")"#)
        XCTAssertEqual(links.first?.href, "b.md")
    }

    func testNestedBracketsInLinkText() {
        let links = LinkResolver.links(inMarkdown: "[a [b] c](d.md)")
        XCTAssertEqual(links.first?.href, "d.md")
    }
}

final class URLHistoryTests: XCTestCase {
    func testAddIsNewestFirstWithoutDuplicates() {
        var history = URLHistory()
        history.add("a")
        history.add("b")
        history.add("a")
        XCTAssertEqual(history.entries, ["a", "b"])
    }

    func testBlankIsIgnored() {
        var history = URLHistory()
        history.add("   ")
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testLimit() {
        var history = URLHistory(limit: 2)
        for name in ["a", "b", "c"] { history.add(name) }
        XCTAssertEqual(history.entries.count, 2)
    }

    func testSuggestions() {
        var history = URLHistory()
        history.add("https://github.com/apple/swift")
        history.add("https://github.com/apple/swift-nio")
        history.add("https://example.com")
        let suggestions = history.suggestions(for: "swift")
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertTrue(suggestions.allSatisfy { $0.text.contains("swift") })
    }

    func testSuggestionKinds() {
        var history = URLHistory()
        history.add("https://github.com/o/r")
        history.add("https://github.com/o/r/blob/main/a.swift")
        history.add("https://gist.github.com/me/abc123")
        let kinds = history.suggestions(for: "").map(\.kind)
        XCTAssertTrue(kinds.contains("リポジトリ"))
        XCTAssertTrue(kinds.contains("ファイル"))
        XCTAssertTrue(kinds.contains("Gist"))
    }

    func testEmptyQueryReturnsEverything() {
        var history = URLHistory()
        history.add("a")
        history.add("b")
        XCTAssertEqual(history.suggestions(for: "").count, 2)
    }

    func testRemoveAndClear() {
        var history = URLHistory()
        history.add("a")
        history.add("b")
        history.remove("a")
        XCTAssertEqual(history.entries, ["b"])
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
    }
}

final class SharedInputTests: XCTestCase {
    func testPlainURL() {
        let target = SharedInput.target(from: "https://github.com/o/r")
        XCTAssertEqual(target, .repository(GitHubLocation(owner: "o", repo: "r",
                                                          isDirectory: true)))
    }

    func testShorthand() {
        XCTAssertNotNil(SharedInput.target(from: "apple/swift"))
    }

    func testFindsTheURLInSeveralLines() {
        let text = """
        おすすめのリポジトリ
        https://github.com/o/r
        """
        XCTAssertNotNil(SharedInput.target(from: text))
    }

    func testEmpty() {
        XCTAssertNil(SharedInput.target(from: "   "))
    }

    func testExtractURLs() {
        let text = "見て: https://example.com/a と http://b.example.com/c です。"
        let urls = SharedInput.urls(in: text)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls.first?.absoluteString, "https://example.com/a")
    }

    func testTrailingPunctuationIsDropped() {
        let urls = SharedInput.urls(in: "これ https://example.com/a。")
        XCTAssertEqual(urls.first?.absoluteString, "https://example.com/a")
    }

    func testNoURLs() {
        XCTAssertTrue(SharedInput.urls(in: "ただの文章です").isEmpty)
    }
}

final class DraftStoreTests: XCTestCase {
    func testUpdateAndRead() {
        let store = DraftStore()
        store.update(key: "a", text: "新しい", original: "もとの")
        let draft = store.draft(for: "a")
        XCTAssertEqual(draft?.text, "新しい")
        XCTAssertTrue(draft!.isDirty)
    }

    func testNotDirtyWhenTheSame() {
        let store = DraftStore()
        store.update(key: "a", text: "同じ", original: "同じ")
        XCTAssertFalse(store.draft(for: "a")!.isDirty)
        XCTAssertTrue(store.dirty.isEmpty)
    }

    func testDiff() {
        let store = DraftStore()
        store.update(key: "a", text: "1\n2\n3", original: "1\n3")
        let draft = store.draft(for: "a")!
        XCTAssertEqual(draft.diffSummary.added, 1)
        XCTAssertEqual(draft.changeText, "+1 -0")
    }

    func testDiscardReturnsTheOriginal() {
        let store = DraftStore()
        store.update(key: "a", text: "変えた", original: "もとの")
        XCTAssertEqual(store.discard(key: "a"), "もとの")
        XCTAssertNil(store.draft(for: "a"))
    }

    func testDiscardUnknownKey() {
        XCTAssertNil(DraftStore().discard(key: "ない"))
    }

    func testMarkSaved() {
        let store = DraftStore()
        store.update(key: "a", text: "新しい", original: "もとの")
        store.markSaved(key: "a")
        XCTAssertFalse(store.draft(for: "a")!.isDirty)
    }

    func testWritingIsThrottled() {
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let store = DraftStore(saveInterval: 100) { _ in box.count += 1 }
        let now = Date()
        XCTAssertTrue(store.update(key: "a", text: "1", original: "", now: now))
        XCTAssertFalse(store.update(key: "a", text: "12", original: "", now: now))
        XCTAssertTrue(store.update(key: "a", text: "123", original: "", now: now,
                                   force: true))
        XCTAssertEqual(box.count, 2)
    }

    func testSaveAndRestore() {
        let store = DraftStore()
        store.update(key: "a", text: "覚えて", original: "")
        let restored = DraftStore(json: store.encoded())
        XCTAssertEqual(restored.draft(for: "a")?.text, "覚えて")
    }

    func testRestoreFromNothing() {
        XCTAssertTrue(DraftStore(json: nil).all.isEmpty)
    }

    func testRemoveOldCleanDrafts() {
        let store = DraftStore()
        store.update(key: "old", text: "同じ", original: "同じ",
                     now: Date(timeIntervalSince1970: 0))
        store.update(key: "dirty", text: "変えた", original: "もと",
                     now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(store.removeOlder(than: Date()), 1)
        XCTAssertNotNil(store.draft(for: "dirty"))
    }

    func testRemoveAll() {
        let store = DraftStore()
        store.update(key: "a", text: "x", original: "")
        store.removeAll()
        XCTAssertTrue(store.all.isEmpty)
    }

    func testKeyFromLocation() {
        let key = DraftStore.key(for: GitHubLocation(owner: "o", repo: "r",
                                                     ref: "main", path: "a.swift"))
        XCTAssertEqual(key, "o/r@main/a.swift")
    }
}

final class RepositorySearchTests: XCTestCase {
    private let files = [
        "src/main.swift": "func main() {\n    print(\"あ\")\n}\n",
        "src/util.swift": "func helper() {}\n",
        "README.md": "# タイトル\n\nfunc の説明。\n",
        "node_modules/x.js": "func\n"
    ]

    func testFindsAcrossFiles() {
        let results = RepositorySearch.search("func", in: files)
        XCTAssertEqual(results.count, 3)   // node_modules は外れる。
        XCTAssertEqual(RepositorySearch.total(results), 3)
    }

    func testExtensionFilter() {
        var options = RepositorySearchOptions()
        options.fileExtensions = ["swift"]
        let results = RepositorySearch.search("func", in: files, options: options)
        XCTAssertEqual(results.map(\.path), ["src/main.swift", "src/util.swift"])
    }

    func testHitHasLineAndPosition() {
        let results = RepositorySearch.search("print", in: files)
        let hit = results.first?.hits.first
        XCTAssertEqual(hit?.line, 2)
        XCTAssertEqual(hit?.location, 4)
        XCTAssertTrue(hit?.text.contains("print") == true)
    }

    func testCaseInsensitiveByDefault() {
        XCTAssertFalse(RepositorySearch.search("FUNC", in: files).isEmpty)
    }

    func testCaseSensitive() {
        var options = RepositorySearchOptions()
        options.search.isCaseSensitive = true
        XCTAssertTrue(RepositorySearch.search("FUNC", in: files,
                                              options: options).isEmpty)
    }

    func testRegularExpression() {
        var options = RepositorySearchOptions()
        options.search.isRegularExpression = true
        let results = RepositorySearch.search("func [a-z]+\\(", in: files,
                                              options: options)
        XCTAssertEqual(RepositorySearch.total(results), 2)
    }

    func testHitLimit() {
        var options = RepositorySearchOptions()
        options.maximumHits = 1
        XCTAssertEqual(RepositorySearch.total(
            RepositorySearch.search("func", in: files, options: options)), 1)
    }

    func testPerFileLimit() {
        var options = RepositorySearchOptions()
        options.maximumHitsPerFile = 1
        let results = RepositorySearch.search("a", in: ["x.txt": "a a a a"],
                                              options: options)
        XCTAssertEqual(results.first?.count, 1)
    }

    func testEmptyQuery() {
        XCTAssertTrue(RepositorySearch.search("", in: files).isEmpty)
    }

    func testSummary() {
        let results = RepositorySearch.search("func", in: files)
        XCTAssertEqual(RepositorySearch.summary(results), "3 ファイルで 3 件")
        XCTAssertEqual(RepositorySearch.summary([]), "見つかりませんでした")
    }

    func testPreviewShortensLongLines() {
        let long = String(repeating: "あ", count: 400) + "めじるし"
        let results = RepositorySearch.search("めじるし", in: ["a.txt": long])
        let preview = results.first!.hits.first!.preview(maximumLength: 60)
        XCTAssertLessThan(preview.count, 100)
        XCTAssertTrue(preview.contains("めじるし"))
    }

    func testSearchInOfflineCache() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = OfflineCache(root: root)
        _ = try cache.save(files: ["a.swift": Data("func a() {}".utf8),
                                   "b.txt": Data("なにもなし".utf8)],
                           owner: "o", repo: "r", ref: "main")

        let results = RepositorySearch.search("func", owner: "o", repo: "r",
                                              ref: "main", in: cache)
        XCTAssertEqual(results.map(\.path), ["a.swift"])
    }

    func testSearchInMissingSnapshot() {
        let cache = OfflineCache(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("none-\(UUID().uuidString)"))
        XCTAssertTrue(RepositorySearch.search("x", owner: "o", repo: "r", ref: "main",
                                              in: cache).isEmpty)
    }
}
