import XCTest
@testable import GitHubViewerCore

/// 216-223, 226-235. 置いておくもの、消すもの、持ち出すもの。
final class FileCacheTests: XCTestCase {

    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testStoreAndRead() {
        let cache = FileCache()
        cache.store(data("こんにちは"), for: "a", etag: "W/\"1\"")
        XCTAssertTrue(cache.contains("a"))
        XCTAssertEqual(cache.data(for: "a"), data("こんにちは"))
        XCTAssertEqual(cache.entry(for: "a")?.etag, "W/\"1\"")
        XCTAssertEqual(cache.count, 1)
    }

    func testMissingKey() {
        let cache = FileCache()
        XCTAssertNil(cache.data(for: "ない"))
        XCTAssertFalse(cache.contains("ない"))
    }

    /// 古くなったものは返さないが、通信できないときの備えには残る。
    func testStaleEntryIsHiddenButKeptForOffline() {
        let cache = FileCache(maximumAge: 60)
        let old = Date(timeIntervalSince1970: 0)
        cache.store(data("古い"), for: "a", now: old)
        let later = old.addingTimeInterval(600)
        XCTAssertNil(cache.data(for: "a", now: later))
        XCTAssertEqual(cache.offlineData(for: "a"), data("古い"))
    }

    func testRemoveStale() {
        let cache = FileCache(maximumAge: 60)
        let old = Date(timeIntervalSince1970: 0)
        cache.store(data("古い"), for: "a", now: old)
        cache.store(data("新しい"), for: "b", now: old.addingTimeInterval(600))
        let removed = cache.removeStale(at: old.addingTimeInterval(601))
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(cache.contains("a"))
        XCTAssertTrue(cache.contains("b"))
    }

    /// 入れすぎたら、古いものから減らす。
    func testTrimKeepsNewest() {
        let cache = FileCache(byteLimit: 20, maximumAge: .greatestFiniteMagnitude)
        let base = Date(timeIntervalSince1970: 0)
        cache.store(Data(repeating: 1, count: 10), for: "old", now: base)
        cache.store(Data(repeating: 2, count: 10), for: "mid",
                    now: base.addingTimeInterval(10))
        cache.store(Data(repeating: 3, count: 10), for: "new",
                    now: base.addingTimeInterval(20))
        // 入れた時点で上限に収まっている。
        XCTAssertLessThanOrEqual(cache.totalBytes, 20)
        XCTAssertTrue(cache.contains("new"))
        XCTAssertFalse(cache.contains("old"))
        // すでに収まっているので、もう減らすものはない。
        XCTAssertEqual(cache.trim(), 0)
    }

    func testRemoveAll() {
        let cache = FileCache()
        cache.store(data("あ"), for: "a")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalBytes, 0)
    }

    func testKeyForLocation() {
        let location = GitHubLocation(owner: "o", repo: "r", ref: "main",
                                      path: "src/a.swift")
        XCTAssertTrue(FileCache.key(for: location).contains("src/a.swift"))
    }

    func testSummaryMentionsCount() {
        let cache = FileCache()
        cache.store(data("あ"), for: "a")
        XCTAssertTrue(cache.summary.contains("1"))
    }
}

/// 218. 先に取っておく。
final class PrefetchingTests: XCTestCase {

    private func item(_ name: String, size: Int = 100,
                      isDirectory: Bool = false) -> FileListItem {
        let location = GitHubLocation(owner: "o", repo: "r", ref: "main", path: name)
        return FileListItem(entry: RepositoryEntry(name: name, isDirectory: isDirectory,
                                                   size: size, location: location))
    }

    func testReadmeComesFirst() {
        let current = GitHubLocation(owner: "o", repo: "r", ref: "main", path: "a.swift")
        let list = [item("z.txt"), item("README.md"), item("a.swift")]
        let picked = Prefetching.candidates(current: current, siblings: list)
        XCTAssertEqual(picked.first?.path, "README.md")
        // いま見ているものは選ばない。
        XCTAssertFalse(picked.contains { $0.path == "a.swift" })
    }

    func testDirectoriesAreSkipped() {
        let current = GitHubLocation(owner: "o", repo: "r", ref: "main", path: "a.swift")
        let picked = Prefetching.candidates(current: current,
                                            siblings: [item("src", isDirectory: true)])
        XCTAssertTrue(picked.isEmpty)
    }

    func testLimit() {
        let current = GitHubLocation(owner: "o", repo: "r", ref: "main", path: "a.swift")
        let list = (0..<20).map { item("f\($0).txt") }
        XCTAssertEqual(Prefetching.candidates(current: current, siblings: list,
                                              limit: 3).count, 3)
    }

    func testDoesNotPrefetchOnLowPowerOrMeteredNetwork() {
        let cache = FileCache()
        XCTAssertTrue(Prefetching.shouldPrefetch(isLowPower: false, isMetered: false,
                                                 cache: cache))
        XCTAssertFalse(Prefetching.shouldPrefetch(isLowPower: true, isMetered: false,
                                                  cache: cache))
        XCTAssertFalse(Prefetching.shouldPrefetch(isLowPower: false, isMetered: true,
                                                  cache: cache))
    }

    func testDoesNotPrefetchWhenCacheIsAlreadyFull() {
        let cache = FileCache(byteLimit: 100, maximumAge: .greatestFiniteMagnitude)
        cache.store(Data(repeating: 0, count: 80), for: "a")
        XCTAssertFalse(Prefetching.shouldPrefetch(isLowPower: false, isMetered: false,
                                                  cache: cache))
    }
}

/// 221. ある時点の中身を残す。
final class SnapshotStoreTests: XCTestCase {

    func testTakeAndList() {
        let store = SnapshotStore(interval: 0)
        let base = Date(timeIntervalSince1970: 0)
        XCTAssertNotNil(store.take(fileKey: "a", text: "1", now: base))
        XCTAssertNotNil(store.take(fileKey: "a", text: "2",
                                   now: base.addingTimeInterval(10)))
        XCTAssertEqual(store.snapshots(forFile: "a").count, 2)
        // 新しいものが先。
        XCTAssertEqual(store.snapshots(forFile: "a").first?.text, "2")
    }

    /// 同じ中身なら増やさない。
    func testSameTextIsNotStoredTwice() {
        let store = SnapshotStore(interval: 0)
        let base = Date(timeIntervalSince1970: 0)
        _ = store.take(fileKey: "a", text: "1", now: base)
        XCTAssertNil(store.take(fileKey: "a", text: "1",
                                now: base.addingTimeInterval(10)))
        XCTAssertEqual(store.snapshots(forFile: "a").count, 1)
    }

    /// 間を空けずに撮ろうとしても、取らない。
    func testIntervalIsRespected() {
        let store = SnapshotStore(interval: 60)
        let base = Date(timeIntervalSince1970: 0)
        _ = store.take(fileKey: "a", text: "1", now: base)
        XCTAssertNil(store.take(fileKey: "a", text: "2",
                                now: base.addingTimeInterval(5)))
        XCTAssertNotNil(store.take(fileKey: "a", text: "3",
                                   now: base.addingTimeInterval(120)))
    }

    func testLimitPerFile() {
        let store = SnapshotStore(limitPerFile: 3, interval: 0)
        let base = Date(timeIntervalSince1970: 0)
        for index in 0..<10 {
            _ = store.take(fileKey: "a", text: "\(index)",
                           now: base.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(store.snapshots(forFile: "a").count, 3)
        XCTAssertEqual(store.snapshots(forFile: "a").first?.text, "9")
    }

    func testRestoreAndRemove() {
        let store = SnapshotStore(interval: 0)
        let taken = store.take(fileKey: "a", text: "元の中身",
                               now: Date(timeIntervalSince1970: 0))
        let id = try! XCTUnwrap(taken).id
        XCTAssertEqual(store.restore(id: id), "元の中身")
        store.remove(id: id)
        XCTAssertNil(store.restore(id: id))
    }

    func testDiffBetweenSnapshots() {
        let first = Snapshot(fileKey: "a", text: "1\n2\n3")
        let second = Snapshot(fileKey: "a", text: "1\n9\n3")
        let changed = first.diff(to: second).filter { $0.kind != .unchanged }
        XCTAssertFalse(changed.isEmpty)
    }

    func testEncodeRoundTrip() throws {
        let store = SnapshotStore(interval: 0)
        _ = store.take(fileKey: "a", text: "x", now: Date(timeIntervalSince1970: 0))
        let data = try XCTUnwrap(store.encoded())
        let restored = SnapshotStore(json: data, interval: 0)
        XCTAssertEqual(restored.all.count, 1)
        XCTAssertEqual(restored.all.first?.text, "x")
    }

    func testBackupArchiveIsReadableZip() throws {
        let store = SnapshotStore(interval: 0)
        _ = store.take(fileKey: "a/b.swift", text: "中身",
                       now: Date(timeIntervalSince1970: 0))
        let archive = store.backupArchive(at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(Zip.looksLikeZip(archive))
        let entries = try Zip.entries(in: archive)
        XCTAssertFalse(entries.isEmpty)
    }
}

/// 222. 設定を持っていく。
final class SyncedSettingsTests: XCTestCase {

    func testEncodeRoundTrip() throws {
        var settings = SyncedSettings(deviceName: "iPad")
        settings.urlHistory.add("https://github.com/a/b")
        let data = try XCTUnwrap(settings.encoded())
        let restored = try XCTUnwrap(SyncedSettings.decoded(data))
        XCTAssertEqual(restored.deviceName, "iPad")
        XCTAssertEqual(restored.urlHistory.entries, settings.urlHistory.entries)
    }

    func testDecodeGarbage() {
        XCTAssertNil(SyncedSettings.decoded(Data("なにこれ".utf8)))
        XCTAssertNil(SyncedSettings.decoded(nil))
    }

    /// 新しいほうの設定を残しつつ、履歴は両方から集める。
    func testMergeKeepsNewerSettingsAndBothHistories() {
        let base = Date(timeIntervalSince1970: 0)
        var old = SyncedSettings(updatedAt: base, deviceName: "古い端末")
        old.urlHistory.add("https://github.com/a/b")
        var new = SyncedSettings(updatedAt: base.addingTimeInterval(100),
                                 deviceName: "新しい端末")
        new.urlHistory.add("https://github.com/c/d")

        let merged = old.merged(with: new)
        XCTAssertEqual(merged.deviceName, "新しい端末")
        XCTAssertEqual(merged.updatedAt, new.updatedAt)
        XCTAssertTrue(merged.urlHistory.entries.contains("https://github.com/a/b"))
        XCTAssertTrue(merged.urlHistory.entries.contains("https://github.com/c/d"))
    }

    func testMergeIsSymmetricAboutHistoryContents() {
        let base = Date(timeIntervalSince1970: 0)
        var left = SyncedSettings(updatedAt: base)
        left.urlHistory.add("https://github.com/a/b")
        var right = SyncedSettings(updatedAt: base.addingTimeInterval(10))
        right.urlHistory.add("https://github.com/c/d")
        XCTAssertEqual(Set(left.merged(with: right).urlHistory.entries),
                       Set(right.merged(with: left).urlHistory.entries))
    }
}

/// 226. URL 履歴の片付け。
final class URLHistoryTidyTests: XCTestCase {

    func testRemovesDuplicatesAndBrokenEntries() {
        var history = URLHistory(entries: [
            "https://github.com/apple/swift",
            "https://github.com/apple/swift/",
            "これは URL ではない",
            "https://github.com/apple/swift-format"
        ])
        history.tidy()
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.entries.first, "https://github.com/apple/swift")
    }

    func testKeepingLimit() {
        let urls = (0..<50).map { "https://github.com/o/r\($0)" }
        var history = URLHistory(entries: urls, limit: 100)
        history.tidy(keeping: 5)
        XCTAssertEqual(history.entries.count, 5)
    }

    func testGroupedByKind() {
        let history = URLHistory(entries: [
            "https://github.com/apple/swift",
            "https://gist.github.com/someone/1234567890abcdef"
        ])
        let groups = history.grouped()
        XCTAssertEqual(groups.reduce(0) { $0 + $1.entries.count }, 2)
        XCTAssertGreaterThanOrEqual(groups.count, 1)
    }
}

/// 227-230. 置いてあるものを数えて消す。
final class StorageManagerTests: XCTestCase {

    private func makeManager() -> StorageManager {
        let cache = FileCache()
        cache.store(Data(repeating: 0, count: 1000), for: "a")
        let drafts = DraftStore(drafts: [Draft(key: "f", text: "下書き",
                                               original: "もと")])
        let snapshots = SnapshotStore(interval: 0)
        _ = snapshots.take(fileKey: "f", text: "写し",
                           now: Date(timeIntervalSince1970: 0))
        return StorageManager(fileCache: cache, drafts: drafts, snapshots: snapshots)
    }

    func testUsageCountsEachCategory() {
        let usage = makeManager().usage()
        XCTAssertEqual(usage.bytes(of: .fileCache), 1000)
        XCTAssertGreaterThan(usage.bytes(of: .drafts), 0)
        XCTAssertGreaterThan(usage.bytes(of: .snapshots), 0)
        XCTAssertEqual(usage.bytes(of: .runHistory), 0)
        XCTAssertGreaterThan(usage.totalBytes, 1000)
    }

    func testUsageSortedAndFraction() {
        let usage = makeManager().usage()
        let sorted = usage.sorted
        XCTAssertEqual(sorted.first?.category, .fileCache)
        let fraction = usage.fraction(of: .fileCache)
        XCTAssertGreaterThan(fraction, 0)
        XCTAssertLessThanOrEqual(fraction, 1)
        XCTAssertEqual(usage.totalText, OfflineCache.sizeText(usage.totalBytes))
    }

    func testEmptyUsageHasNoFraction() {
        XCTAssertEqual(StorageUsage().fraction(of: .drafts), 0)
        XCTAssertEqual(StorageUsage().totalBytes, 0)
    }

    func testClearOneCategory() {
        let manager = makeManager()
        manager.clear([.fileCache])
        XCTAssertEqual(manager.usage().bytes(of: .fileCache), 0)
        // ほかは残る。
        XCTAssertGreaterThan(manager.usage().bytes(of: .drafts), 0)
    }

    func testClearEverything() {
        let manager = makeManager()
        manager.clearEverything()
        XCTAssertEqual(manager.usage().totalBytes, 0)
    }

    /// 消しても困らないものだけ片付けたときは、下書きが残る。
    func testClearSafelyKeepsDrafts() {
        let manager = makeManager()
        manager.clearSafely()
        XCTAssertGreaterThan(manager.usage().bytes(of: .drafts), 0)
        XCTAssertEqual(manager.usage().bytes(of: .fileCache), 0)
    }

    func testCategoryDescriptions() {
        for category in StorageCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty)
            XCTAssertEqual(category.id, category.rawValue)
            if !category.isSafeToDelete { XCTAssertNotNil(category.warning) }
        }
    }

    func testBackupArchiveContainsDraftsAndSettings() throws {
        let manager = makeManager()
        let archive = manager.backupArchive(settings: SyncedSettings(),
                                            at: Date(timeIntervalSince1970: 0))
        let entries = try Zip.entries(in: archive)
        let paths = entries.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasPrefix("drafts/") })
        XCTAssertTrue(paths.contains("snapshots.json"))
        XCTAssertTrue(paths.contains("settings.json"))
        let draft = try XCTUnwrap(entries.first { $0.path.hasPrefix("drafts/") })
        XCTAssertEqual(String(data: draft.data, encoding: .utf8), "下書き")
    }
}
