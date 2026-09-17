import XCTest
@testable import GitHubViewerCore

final class OfflineCacheTests: XCTestCase {
    var root: URL!
    var cache: OfflineCache!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-\(UUID().uuidString)", isDirectory: true)
        cache = OfflineCache(root: root)
        StubURLProtocol.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testStoreAndLoad() throws {
        try cache.store(Data("こんにちは".utf8), owner: "o", repo: "r", ref: "main",
                        path: "docs/a.txt")
        let loaded = cache.load(owner: "o", repo: "r", ref: "main", path: "docs/a.txt")
        XCTAssertEqual(loaded.map { String(decoding: $0, as: UTF8.self) }, "こんにちは")
        XCTAssertTrue(cache.contains(owner: "o", repo: "r", ref: "main",
                                     path: "docs/a.txt"))
    }

    func testMissingFileIsNil() {
        XCTAssertNil(cache.load(owner: "o", repo: "r", ref: "main", path: "none"))
        XCTAssertFalse(cache.contains(owner: "o", repo: "r", ref: "main", path: "none"))
    }

    func testSaveWritesASnapshot() throws {
        let snapshot = try cache.save(files: ["a.txt": Data("ab".utf8),
                                              "b/c.txt": Data("cde".utf8)],
                                      owner: "o", repo: "r", ref: "main",
                                      commitSHA: "abc")
        XCTAssertEqual(snapshot.paths, ["a.txt", "b/c.txt"])
        XCTAssertEqual(snapshot.byteCount, 5)
        XCTAssertEqual(snapshot.commitSHA, "abc")
        XCTAssertEqual(snapshot.title, "o/r")

        let read = cache.snapshot(owner: "o", repo: "r", ref: "main")
        XCTAssertEqual(read?.paths, snapshot.paths)
        XCTAssertEqual(read?.byteCount, 5)
    }

    func testSnapshotsAreNewestFirst() throws {
        let old = Date(timeIntervalSince1970: 1000)
        let recent = Date(timeIntervalSince1970: 2000)
        _ = try cache.save(files: ["a": Data()], owner: "o", repo: "old", ref: "main",
                           now: old)
        _ = try cache.save(files: ["a": Data()], owner: "o", repo: "new", ref: "main",
                           now: recent)
        XCTAssertEqual(cache.snapshots().map(\.repo), ["new", "old"])
    }

    func testRemoveOne() throws {
        _ = try cache.save(files: ["a": Data("x".utf8)], owner: "o", repo: "r",
                           ref: "main")
        try cache.remove(owner: "o", repo: "r", ref: "main")
        XCTAssertNil(cache.snapshot(owner: "o", repo: "r", ref: "main"))
        XCTAssertFalse(cache.contains(owner: "o", repo: "r", ref: "main", path: "a"))
    }

    func testRemovingSomethingMissingIsFine() {
        XCTAssertNoThrow(try cache.remove(owner: "x", repo: "y", ref: "z"))
        XCTAssertNoThrow(try cache.removeAll())
    }

    func testRemoveAll() throws {
        _ = try cache.save(files: ["a": Data()], owner: "o", repo: "r", ref: "main")
        try cache.removeAll()
        XCTAssertTrue(cache.snapshots().isEmpty)
    }

    func testTotalBytes() throws {
        _ = try cache.save(files: ["a": Data(count: 100)], owner: "o", repo: "one",
                           ref: "main")
        _ = try cache.save(files: ["a": Data(count: 200)], owner: "o", repo: "two",
                           ref: "main")
        XCTAssertEqual(cache.totalBytes(), 300)
    }

    func testTrimDropsTheOldestFirst() throws {
        _ = try cache.save(files: ["a": Data(count: 100)], owner: "o", repo: "old",
                           ref: "main", now: Date(timeIntervalSince1970: 1))
        _ = try cache.save(files: ["a": Data(count: 100)], owner: "o", repo: "mid",
                           ref: "main", now: Date(timeIntervalSince1970: 2))
        _ = try cache.save(files: ["a": Data(count: 100)], owner: "o", repo: "new",
                           ref: "main", now: Date(timeIntervalSince1970: 3))

        let removed = try cache.trim(toBytes: 150)
        XCTAssertEqual(removed.map(\.repo), ["old", "mid"])
        XCTAssertEqual(cache.snapshots().map(\.repo), ["new"])
    }

    func testTrimKeepsEverythingWhenUnderTheLimit() throws {
        _ = try cache.save(files: ["a": Data(count: 10)], owner: "o", repo: "r",
                           ref: "main")
        XCTAssertTrue(try cache.trim(toBytes: 1000).isEmpty)
    }

    func testPathTraversalIsBlocked() throws {
        try cache.store(Data("危ない".utf8), owner: "..", repo: "..", ref: "..",
                        path: "../../escape.txt")
        // root の外に出ていないことを確かめる。
        let escaped = root.deletingLastPathComponent()
            .appendingPathComponent("escape.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
        XCTAssertNotNil(cache.load(owner: "..", repo: "..", ref: "..",
                                   path: "../../escape.txt"))
    }

    func testSizeText() {
        XCTAssertEqual(OfflineCache.sizeText(512), "512 B")
        XCTAssertEqual(OfflineCache.sizeText(2048), "2.0 KB")
        XCTAssertEqual(OfflineCache.sizeText(1024 * 1024 * 3), "3.0 MB")
    }

    // MARK: - 取り込み

    func testDownloadForOffline() async throws {
        StubURLProtocol.stubJSON("/git/ref/heads/main", #"{"object":{"sha":"head"}}"#)
        StubURLProtocol.stubJSON("/git/trees/head", """
        {"tree":[{"path":"a.txt","type":"blob","size":3},
                 {"path":"docs","type":"tree"},
                 {"path":"docs/b.txt","type":"blob","size":4},
                 {"path":"huge.bin","type":"blob","size":99999999}]}
        """)
        StubURLProtocol.stub("raw.githubusercontent.com/o/r/head/a.txt",
                             .init(body: Data("abc".utf8)))
        StubURLProtocol.stub("raw.githubusercontent.com/o/r/head/docs/b.txt",
                             .init(body: Data("defg".utf8)))

        let snapshot = try await StubURLProtocol.makeClient()
            .downloadForOffline(owner: "o", repo: "r", ref: "main", into: cache)

        XCTAssertEqual(snapshot.paths, ["a.txt", "docs/b.txt"])
        XCTAssertEqual(snapshot.commitSHA, "head")
        XCTAssertEqual(snapshot.byteCount, 7)
        XCTAssertEqual(cache.load(owner: "o", repo: "r", ref: "main",
                                  path: "docs/b.txt"),
                       Data("defg".utf8))
    }

    func testDownloadRespectsTheFilter() async throws {
        StubURLProtocol.stubJSON("/git/ref/heads/main", #"{"object":{"sha":"head"}}"#)
        StubURLProtocol.stubJSON("/git/trees/head", """
        {"tree":[{"path":"a.swift","type":"blob","size":1},
                 {"path":"b.png","type":"blob","size":1}]}
        """)
        StubURLProtocol.stub("/head/a.swift", .init(body: Data("x".utf8)))

        let snapshot = try await StubURLProtocol.makeClient()
            .downloadForOffline(owner: "o", repo: "r", ref: "main", into: cache,
                                shouldInclude: { $0.hasSuffix(".swift") })
        XCTAssertEqual(snapshot.paths, ["a.swift"])
    }

    func testDownloadReportsProgress() async throws {
        StubURLProtocol.stubJSON("/git/ref/heads/main", #"{"object":{"sha":"head"}}"#)
        StubURLProtocol.stubJSON("/git/trees/head",
                                 #"{"tree":[{"path":"a","type":"blob","size":1}]}"#)
        StubURLProtocol.stub("/head/a", .init(body: Data("x".utf8)))

        final class Box: @unchecked Sendable { var steps: [Int] = [] }
        let box = Box()
        _ = try await StubURLProtocol.makeClient()
            .downloadForOffline(owner: "o", repo: "r", ref: "main", into: cache,
                                onProgress: { done, _ in box.steps.append(done) })
        XCTAssertEqual(box.steps, [0, 1])
    }

    func testDownloadStopsAtTheTotalLimit() async throws {
        StubURLProtocol.stubJSON("/git/ref/heads/main", #"{"object":{"sha":"head"}}"#)
        StubURLProtocol.stubJSON("/git/trees/head", """
        {"tree":[{"path":"a","type":"blob","size":100},
                 {"path":"b","type":"blob","size":100}]}
        """)
        StubURLProtocol.stub("/head/a", .init(body: Data(count: 100)))
        StubURLProtocol.stub("/head/b", .init(body: Data(count: 100)))

        let snapshot = try await StubURLProtocol.makeClient()
            .downloadForOffline(owner: "o", repo: "r", ref: "main", into: cache,
                                maximumTotalBytes: 150)
        XCTAssertEqual(snapshot.paths.count, 1)
    }
}
