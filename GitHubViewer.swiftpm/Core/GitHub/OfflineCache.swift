import Foundation

/// 端末に保存したリポジトリ 1 つぶんの覚え書き。
public struct OfflineSnapshot: Identifiable, Equatable, Codable, Sendable {
    public var owner: String
    public var repo: String
    public var ref: String
    /// 保存したときのコミット SHA (分かれば)。
    public var commitSHA: String?
    public var savedAt: Date
    /// 入っているファイルのパス。
    public var paths: [String]
    /// 合計バイト数。
    public var byteCount: Int

    public var id: String { "\(owner)/\(repo)@\(ref)" }

    public init(owner: String, repo: String, ref: String, commitSHA: String? = nil,
                savedAt: Date = Date(), paths: [String] = [], byteCount: Int = 0) {
        self.owner = owner
        self.repo = repo
        self.ref = ref
        self.commitSHA = commitSHA
        self.savedAt = savedAt
        self.paths = paths
        self.byteCount = byteCount
    }

    public var title: String { "\(owner)/\(repo)" }

    /// 「1.2 MB」のような表示。
    public var sizeText: String { OfflineCache.sizeText(byteCount) }
}

/// リポジトリを端末に保存して、通信なしで読めるようにする。
///
/// 保存先は `<root>/<owner>/<repo>/<ref>/<path>`。
/// 覚え書きは同じ場所の `.snapshot.json` に置く。
public final class OfflineCache: @unchecked Sendable {
    public let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// アプリの Caches の下に作る、ふつうの保存先。
    public static func makeDefault(name: String = "OfflineRepositories") -> OfflineCache? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return OfflineCache(root: base.appendingPathComponent(name, isDirectory: true))
    }

    // MARK: - 場所

    private func directory(owner: String, repo: String, ref: String) -> URL {
        root.appendingPathComponent(safe(owner), isDirectory: true)
            .appendingPathComponent(safe(repo), isDirectory: true)
            .appendingPathComponent(safe(ref), isDirectory: true)
    }

    /// 1 ファイルの置き場所。
    public func fileURL(owner: String, repo: String, ref: String, path: String) -> URL {
        var url = directory(owner: owner, repo: repo, ref: ref)
        for part in path.split(separator: "/") {
            url.appendPathComponent(safe(String(part)))
        }
        return url
    }

    /// `/` や `..` が混ざっても安全な名前にする。
    private func safe(_ name: String) -> String {
        var clean = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        if clean == ".." || clean == "." || clean.isEmpty { clean = "_" }
        return clean
    }

    // MARK: - 読み書き

    /// 1 ファイルを保存する。
    public func store(_ data: Data, owner: String, repo: String, ref: String,
                      path: String) throws {
        let url = fileURL(owner: owner, repo: repo, ref: ref, path: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// 1 ファイルを読み出す。無ければ nil。
    public func load(owner: String, repo: String, ref: String, path: String) -> Data? {
        let url = fileURL(owner: owner, repo: repo, ref: ref, path: path)
        return try? Data(contentsOf: url)
    }

    /// 保存してあるか。
    public func contains(owner: String, repo: String, ref: String, path: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(owner: owner, repo: repo, ref: ref,
                                               path: path).path)
    }

    /// まとめて保存し、覚え書きを書く。
    @discardableResult
    public func save(files: [String: Data], owner: String, repo: String, ref: String,
                     commitSHA: String? = nil, now: Date = Date()) throws
        -> OfflineSnapshot {
        for (path, data) in files {
            try store(data, owner: owner, repo: repo, ref: ref, path: path)
        }
        let snapshot = OfflineSnapshot(owner: owner, repo: repo, ref: ref,
                                       commitSHA: commitSHA, savedAt: now,
                                       paths: files.keys.sorted(),
                                       byteCount: files.values.reduce(0) {
                                           $0 + $1.count
                                       })
        try write(snapshot)
        return snapshot
    }

    // MARK: - 覚え書き

    private func snapshotURL(owner: String, repo: String, ref: String) -> URL {
        directory(owner: owner, repo: repo, ref: ref)
            .appendingPathComponent(".snapshot.json")
    }

    public func write(_ snapshot: OfflineSnapshot) throws {
        let url = snapshotURL(owner: snapshot.owner, repo: snapshot.repo,
                              ref: snapshot.ref)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public func snapshot(owner: String, repo: String, ref: String) -> OfflineSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(owner: owner, repo: repo,
                                                           ref: ref)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OfflineSnapshot.self, from: data)
    }

    /// 保存してあるものを全部集める。
    public func snapshots() -> [OfflineSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        guard let owners = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }

        var found: [OfflineSnapshot] = []
        for owner in owners {
            guard let repos = try? fileManager.contentsOfDirectory(
                at: owner, includingPropertiesForKeys: nil) else { continue }
            for repo in repos {
                guard let refs = try? fileManager.contentsOfDirectory(
                    at: repo, includingPropertiesForKeys: nil) else { continue }
                for ref in refs {
                    let url = ref.appendingPathComponent(".snapshot.json")
                    guard let data = try? Data(contentsOf: url) else { continue }
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let snapshot = try? decoder.decode(OfflineSnapshot.self,
                                                          from: data) {
                        found.append(snapshot)
                    }
                }
            }
        }
        return found.sorted { $0.savedAt > $1.savedAt }
    }

    // MARK: - 片付け

    /// 1 つぶん消す。
    public func remove(owner: String, repo: String, ref: String) throws {
        let url = directory(owner: owner, repo: repo, ref: ref)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// 全部消す。
    public func removeAll() throws {
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }

    /// いま使っている容量。
    public func totalBytes() -> Int {
        snapshots().reduce(0) { $0 + $1.byteCount }
    }

    /// 古いものから消して、上限に収める。
    @discardableResult
    public func trim(toBytes limit: Int) throws -> [OfflineSnapshot] {
        var kept = snapshots()    // 新しい順。
        var total = kept.reduce(0) { $0 + $1.byteCount }
        var removed: [OfflineSnapshot] = []
        while total > limit, let oldest = kept.last {
            try remove(owner: oldest.owner, repo: oldest.repo, ref: oldest.ref)
            total -= oldest.byteCount
            removed.append(oldest)
            kept.removeLast()
        }
        return removed
    }

    /// 「1.2 MB」のような表示。
    public static func sizeText(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0 ? "\(bytes) B"
                          : String(format: "%.1f %@", value, units[index])
    }
}

// MARK: - 取り込み

extension GitHubClient {
    /// リポジトリの中身をまとめて取ってきて、端末に保存する。
    ///
    /// Git の tree API を 1 回叩くだけで全ファイルの一覧が取れるので、
    /// 1 つずつ `contents` を辿るより通信が少なくて済む。
    @discardableResult
    public func downloadForOffline(owner: String, repo: String, ref: String? = nil,
                                   into cache: OfflineCache,
                                   maximumFileBytes: Int = 1_000_000,
                                   maximumTotalBytes: Int = 50_000_000,
                                   shouldInclude: ((String) -> Bool)? = nil,
                                   onProgress: ((Int, Int) -> Void)? = nil) async throws
        -> OfflineSnapshot {
        var branch = ref
        if branch == nil {
            branch = try await defaultBranch(owner: owner, repo: repo)
        }
        let resolved = branch ?? "HEAD"
        let head = try await branchHead(owner: owner, repo: repo, branch: resolved)

        struct TreeJSON: Decodable {
            struct Entry: Decodable {
                let path: String
                let type: String
                let size: Int?
            }
            let tree: [Entry]
            let truncated: Bool?
        }
        let tree = try await fetchJSON(
            TreeJSON.self, path: "/repos/\(owner)/\(repo)/git/trees/\(head)",
            query: ["recursive": "1"])

        let wanted = tree.tree.filter { entry in
            guard entry.type == "blob" else { return false }
            guard (entry.size ?? 0) <= maximumFileBytes else { return false }
            return shouldInclude?(entry.path) ?? true
        }

        var files: [String: Data] = [:]
        var total = 0
        for (index, entry) in wanted.enumerated() {
            onProgress?(index, wanted.count)
            guard total + (entry.size ?? 0) <= maximumTotalBytes else { break }
            guard let url = GitHubLinks.rawURL(
                GitHubLocation(owner: owner, repo: repo, ref: head, path: entry.path),
                host: rawHost) else { continue }
            guard let data = try? await get(url, accept: nil) else { continue }
            files[entry.path] = data
            total += data.count
        }
        onProgress?(wanted.count, wanted.count)

        return try cache.save(files: files, owner: owner, repo: repo, ref: resolved,
                              commitSHA: head)
    }
}
