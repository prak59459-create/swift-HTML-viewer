import Foundation

// MARK: - 216 / 217. 開いたファイルのキャッシュ

/// 取ってきたファイルを覚えておく (通信を減らし、オフラインでも読めるようにする)。
public final class FileCache: @unchecked Sendable {
    /// 覚えている 1 件。
    public struct Entry: Equatable, Codable, Sendable {
        public var key: String
        public var data: Data
        /// 取ってきた時刻。
        public var fetchedAt: Date
        /// サーバーが付けた印 (変わっていなければ取り直さない)。
        public var etag: String?

        public init(key: String, data: Data, fetchedAt: Date = Date(),
                    etag: String? = nil) {
            self.key = key
            self.data = data
            self.fetchedAt = fetchedAt
            self.etag = etag
        }

        public var byteCount: Int { data.count }

        /// 古くなっているか。
        public func isStale(at date: Date = Date(),
                            maximumAge: TimeInterval) -> Bool {
            date.timeIntervalSince(fetchedAt) > maximumAge
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// ためておく上限 (バイト)。
    public let byteLimit: Int
    /// この秒数を過ぎたら取り直す。
    public var maximumAge: TimeInterval

    public init(byteLimit: Int = 32 << 20, maximumAge: TimeInterval = 60 * 60) {
        self.byteLimit = byteLimit
        self.maximumAge = maximumAge
    }

    /// ファイルの場所から鍵を作る。
    public static func key(for location: GitHubLocation) -> String {
        "\(location.owner)/\(location.repo)@\(location.ref ?? "-")/\(location.path)"
    }

    public func store(_ data: Data, for key: String, etag: String? = nil,
                      now: Date = Date()) {
        lock.lock()
        entries[key] = Entry(key: key, data: data, fetchedAt: now, etag: etag)
        lock.unlock()
        trim()
    }

    /// 取り出す。古すぎるものは返さない (`ignoringAge` で無視できる)。
    public func data(for key: String, now: Date = Date(),
                     ignoringAge: Bool = false) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        if !ignoringAge, entry.isStale(at: now, maximumAge: maximumAge) { return nil }
        return entry.data
    }

    /// 217. 通信できないときは、古くても出す。
    public func offlineData(for key: String) -> Data? {
        data(for: key, ignoringAge: true)
    }

    public func entry(for key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    public func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key] != nil
    }

    public func remove(_ key: String) {
        lock.lock()
        entries[key] = nil
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    // MARK: - 227. 容量

    public var totalBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.byteCount }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// 「12 件 · 3.4 MB」。
    public var summary: String {
        "\(count) 件 · \(OfflineCache.sizeText(totalBytes))"
    }

    /// 古いものから消して、上限に収める。
    @discardableResult
    public func trim() -> Int {
        lock.lock()
        var total = entries.values.reduce(0) { $0 + $1.byteCount }
        var removed = 0
        while total > byteLimit,
              let oldest = entries.values.min(by: { $0.fetchedAt < $1.fetchedAt }) {
            entries[oldest.key] = nil
            total -= oldest.byteCount
            removed += 1
        }
        lock.unlock()
        return removed
    }

    /// 古くなったものを片付ける。
    @discardableResult
    public func removeStale(at date: Date = Date()) -> Int {
        lock.lock()
        let stale = entries.filter { $0.value.isStale(at: date, maximumAge: maximumAge) }
        for key in stale.keys { entries[key] = nil }
        lock.unlock()
        return stale.count
    }
}

// MARK: - 229. 事前ダウンロード

/// 先に取っておくものを決める。
public enum Prefetching {

    /// いま見ているものから、次に見そうなものを選ぶ。
    ///
    /// 同じフォルダのファイルと、README のような目立つものを優先する。
    public static func candidates(current: GitHubLocation, siblings: [FileListItem],
                                  limit: Int = 5) -> [GitHubLocation] {
        var scored: [(location: GitHubLocation, score: Int)] = []
        for item in siblings {
            guard let location = item.entry.location, !item.isDirectory,
                  location.path != current.path else { continue }
            var score = 0
            let name = item.name.lowercased()
            if name.hasPrefix("readme") { score += 10 }
            if name.hasPrefix("index") || name.hasPrefix("main") { score += 6 }
            // 大きすぎるものは後回し。
            if item.size > 0, item.size < 200_000 { score += 3 }
            // 同じ拡張子は関係が深いことが多い。
            if let currentSuffix = current.path.split(separator: ".").last,
               name.hasSuffix(".\(currentSuffix)") { score += 4 }
            scored.append((location, score))
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.location)
    }

    /// いま取っておいてよいか (電池と通信を気づかう)。
    public static func shouldPrefetch(isLowPower: Bool, isMetered: Bool,
                                      cache: FileCache) -> Bool {
        guard !isLowPower, !isMetered else { return false }
        return cache.totalBytes < cache.byteLimit / 2
    }
}

// MARK: - 220 / 221. バックアップとスナップショット

/// ある時点の中身。
public struct Snapshot: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var fileKey: String
    public var text: String
    public var takenAt: Date
    /// なぜ取ったか (「保存前」「自動」など)。
    public var reason: String

    public init(id: UUID = UUID(), fileKey: String, text: String,
                takenAt: Date = Date(), reason: String = "自動") {
        self.id = id
        self.fileKey = fileKey
        self.text = text
        self.takenAt = takenAt
        self.reason = reason
    }

    public var byteCount: Int { text.utf8.count }

    /// 別の時点との差分。
    public func diff(to other: Snapshot) -> [DiffLine] {
        DiffEngine.diff(old: text, new: other.text)
    }
}

/// 編集の履歴を、時々まるごと残しておく。
///
/// undo はアプリを閉じると消えるので、戻したいときの最後の頼みとして使う。
public final class SnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [Snapshot] = []
    /// ファイルごとに残す数。
    public let limitPerFile: Int
    /// 前に取ってから、これだけたったら取る。
    public var interval: TimeInterval

    public init(snapshots: [Snapshot] = [], limitPerFile: Int = 20,
                interval: TimeInterval = 300) {
        self.snapshots = snapshots
        self.limitPerFile = limitPerFile
        self.interval = interval
    }

    public convenience init(json: Data?, limitPerFile: Int = 20,
                            interval: TimeInterval = 300) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = json.flatMap { try? decoder.decode([Snapshot].self, from: $0) }
        self.init(snapshots: loaded ?? [], limitPerFile: limitPerFile,
                  interval: interval)
    }

    public var all: [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.sorted { $0.takenAt > $1.takenAt }
    }

    /// あるファイルの履歴 (新しい順)。
    public func snapshots(forFile key: String) -> [Snapshot] {
        all.filter { $0.fileKey == key }
    }

    /// 取る。中身が同じか、前から間がないときは取らない。
    @discardableResult
    public func take(fileKey: String, text: String, reason: String = "自動",
                     now: Date = Date(), force: Bool = false) -> Snapshot? {
        lock.lock()
        let existing = snapshots.filter { $0.fileKey == fileKey }
            .sorted { $0.takenAt > $1.takenAt }
        if !force, let last = existing.first {
            if last.text == text || now.timeIntervalSince(last.takenAt) < interval {
                lock.unlock()
                return nil
            }
        }
        let snapshot = Snapshot(fileKey: fileKey, text: text, takenAt: now,
                                reason: reason)
        snapshots.append(snapshot)

        // ファイルごとの上限を守る。
        let mine = snapshots.filter { $0.fileKey == fileKey }
            .sorted { $0.takenAt > $1.takenAt }
        if mine.count > limitPerFile {
            let extra = Set(mine.dropFirst(limitPerFile).map(\.id))
            snapshots.removeAll { extra.contains($0.id) }
        }
        lock.unlock()
        return snapshot
    }

    /// 戻す。
    public func restore(id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.first { $0.id == id }?.text
    }

    public func remove(id: UUID) {
        lock.lock()
        snapshots.removeAll { $0.id == id }
        lock.unlock()
    }

    public func removeAll(forFile key: String) {
        lock.lock()
        snapshots.removeAll { $0.fileKey == key }
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        snapshots.removeAll()
        lock.unlock()
    }

    public var totalBytes: Int {
        all.reduce(0) { $0 + $1.byteCount }
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        lock.lock()
        let snapshot = snapshots
        lock.unlock()
        return try? encoder.encode(snapshot)
    }

    /// 220. 全部まとめて zip にする。
    public func backupArchive(at date: Date = Date()) -> Data {
        var files: [String: String] = [:]
        for snapshot in all {
            let stamp = ISO8601DateFormatter().string(from: snapshot.takenAt)
                .replacingOccurrences(of: ":", with: "-")
            let safeKey = snapshot.fileKey.replacingOccurrences(of: "/", with: "_")
            files["\(safeKey)/\(stamp).txt"] = snapshot.text
        }
        return Zip.archive(files: files, modifiedAt: date)
    }
}

// MARK: - 222. 設定の同期

/// 端末をまたいで持っていきたい設定。
public struct SyncedSettings: Equatable, Codable, Sendable {
    public var editor: EditorSettings
    public var shortcuts: ShortcutMap
    public var bookmarks: BookmarkStore
    public var workspace: Workspace
    public var urlHistory: URLHistory
    /// いつ書いたか (新しいほうを残す)。
    public var updatedAt: Date
    /// どの端末が書いたか。
    public var deviceName: String

    public init(editor: EditorSettings = .default, shortcuts: ShortcutMap = .default,
                bookmarks: BookmarkStore = BookmarkStore(),
                workspace: Workspace = Workspace(),
                urlHistory: URLHistory = URLHistory(),
                updatedAt: Date = Date(), deviceName: String = "この端末") {
        self.editor = editor
        self.shortcuts = shortcuts
        self.bookmarks = bookmarks
        self.workspace = workspace
        self.urlHistory = urlHistory
        self.updatedAt = updatedAt
        self.deviceName = deviceName
    }

    /// ほかの端末のものと突き合わせる。
    ///
    /// 設定は新しいほうを採り、ブックマークとワークスペースは
    /// 両方を合わせる (消えて困るもののほうが多いため)。
    public func merged(with other: SyncedSettings) -> SyncedSettings {
        let newer = updatedAt >= other.updatedAt ? self : other
        var result = newer

        var bookmarks = BookmarkStore(bookmarks: self.bookmarks.bookmarks)
        for bookmark in other.bookmarks.bookmarks
        where !bookmarks.contains(bookmark.location, line: bookmark.line) {
            bookmarks.toggle(bookmark)
        }
        result.bookmarks = bookmarks

        var workspace = self.workspace
        for entry in other.workspace.entries
        where !workspace.entries.contains(where: { $0.id == entry.id }) {
            workspace.add(entry)
        }
        if let active = newer.workspace.active { workspace.activate(id: active.id) }
        result.workspace = workspace

        var history = self.urlHistory
        for url in other.urlHistory.entries.reversed() { history.add(url) }
        result.urlHistory = history

        result.updatedAt = Swift.max(updatedAt, other.updatedAt)
        return result
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    public static func decoded(_ data: Data?) -> SyncedSettings? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SyncedSettings.self, from: data)
    }
}

// MARK: - 226. URL 履歴の整理

extension URLHistory {
    /// 開けなくなったものや、重なっているものを片付ける。
    public mutating func tidy(keeping limit: Int = 30) {
        var seen: Set<String> = []
        var kept: [String] = []
        for entry in entries {
            // 同じ場所を指すものは 1 つにまとめる。
            let key = URLHistory.normalized(entry)
            guard seen.insert(key).inserted else { continue }
            // 解釈できないものは捨てる。
            guard (try? GitHubURLParser.parse(entry)) != nil else { continue }
            kept.append(entry)
            if kept.count >= limit { break }
        }
        self = URLHistory(entries: kept, limit: self.limit)
    }

    /// 同じ場所を指すかどうかの見分け方。
    static func normalized(_ text: String) -> String {
        guard let target = try? GitHubURLParser.parse(text) else {
            return text.lowercased()
        }
        switch target {
        case .repository(let location):
            return "\(location.owner)/\(location.repo)/\(location.path)".lowercased()
        case .gist(let id): return "gist:\(id)"
        case .rawURL(let url): return url.absoluteString.lowercased()
        }
    }

    /// 種類ごとに分ける。
    public func grouped() -> [(kind: String, entries: [String])] {
        var groups: [String: [String]] = [:]
        var order: [String] = []
        for entry in entries {
            let kind = URLHistory.kind(of: entry)
            if groups[kind] == nil { order.append(kind) }
            groups[kind, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

// MARK: - 227 / 228 / 230. 置いてあるものの片付け

/// 消せるものの種類。
public enum StorageCategory: String, CaseIterable, Identifiable, Equatable, Sendable {
    case fileCache
    case offlineRepositories
    case drafts
    case snapshots
    case runHistory
    case annotations
    case urlHistory
    /// 228. 処理系が使う一時的なもの。
    case runtimeCache

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fileCache: return "開いたファイル"
        case .offlineRepositories: return "端末に保存したリポジトリ"
        case .drafts: return "編集中の下書き"
        case .snapshots: return "編集の履歴"
        case .runHistory: return "実行の履歴"
        case .annotations: return "メモ"
        case .urlHistory: return "URL の履歴"
        case .runtimeCache: return "処理系の一時ファイル"
        }
    }

    /// 消しても困らないか。
    public var isSafeToDelete: Bool {
        switch self {
        case .drafts, .snapshots, .annotations: return false
        default: return true
        }
    }

    /// 消すときの注意。
    public var warning: String? {
        switch self {
        case .drafts: return "保存していない編集が消えます。"
        case .snapshots: return "戻せる履歴が消えます。"
        case .annotations: return "書いたメモが消えます。"
        default: return nil
        }
    }
}

/// 置いてあるものの内訳。
public struct StorageUsage: Equatable, Sendable {
    public var items: [(category: StorageCategory, bytes: Int, count: Int)]

    public init(items: [(category: StorageCategory, bytes: Int, count: Int)] = []) {
        self.items = items
    }

    public static func == (lhs: StorageUsage, rhs: StorageUsage) -> Bool {
        lhs.items.count == rhs.items.count
            && zip(lhs.items, rhs.items).allSatisfy {
                $0.category == $1.category && $0.bytes == $1.bytes
                    && $0.count == $1.count
            }
    }

    public var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }

    public var totalText: String { OfflineCache.sizeText(totalBytes) }

    /// 大きい順。
    public var sorted: [(category: StorageCategory, bytes: Int, count: Int)] {
        items.sorted { $0.bytes > $1.bytes }
    }

    /// 全体に占める割合。
    public func fraction(of category: StorageCategory) -> Double {
        guard totalBytes > 0 else { return 0 }
        let bytes = items.first { $0.category == category }?.bytes ?? 0
        return Double(bytes) / Double(totalBytes)
    }

    public func bytes(of category: StorageCategory) -> Int {
        items.first { $0.category == category }?.bytes ?? 0
    }
}

/// 置いてあるものを数えて、消す。
public final class StorageManager: @unchecked Sendable {
    public let fileCache: FileCache
    public let offline: OfflineCache?
    public let drafts: DraftStore
    public let snapshots: SnapshotStore
    public let runs: RunHistory
    public let annotations: AnnotationStore

    public init(fileCache: FileCache = FileCache(), offline: OfflineCache? = nil,
                drafts: DraftStore = DraftStore(),
                snapshots: SnapshotStore = SnapshotStore(),
                runs: RunHistory = RunHistory(),
                annotations: AnnotationStore = AnnotationStore()) {
        self.fileCache = fileCache
        self.offline = offline
        self.drafts = drafts
        self.snapshots = snapshots
        self.runs = runs
        self.annotations = annotations
    }

    /// 227. いまの内訳。
    public func usage(urlHistory: URLHistory = URLHistory()) -> StorageUsage {
        var items: [(StorageCategory, Int, Int)] = []
        items.append((.fileCache, fileCache.totalBytes, fileCache.count))
        if let offline {
            let snapshots = offline.snapshots()
            items.append((.offlineRepositories,
                          snapshots.reduce(0) { $0 + $1.byteCount }, snapshots.count))
        }
        let draftList = drafts.all
        items.append((.drafts, draftList.reduce(0) { $0 + $1.text.utf8.count },
                      draftList.count))
        items.append((.snapshots, snapshots.totalBytes, snapshots.all.count))
        let runList = runs.all
        items.append((.runHistory,
                      runList.reduce(0) { $0 + $1.output.utf8.count
                          + $1.source.utf8.count }, runList.count))
        let annotationList = annotations.all
        items.append((.annotations,
                      annotationList.reduce(0) { $0 + $1.text.utf8.count
                          + ($1.drawingData?.count ?? 0) }, annotationList.count))
        items.append((.urlHistory,
                      urlHistory.entries.reduce(0) { $0 + $1.utf8.count },
                      urlHistory.entries.count))
        return StorageUsage(items: items)
    }

    /// 種類を選んで消す。
    public func clear(_ categories: Set<StorageCategory>) {
        if categories.contains(.fileCache) { fileCache.removeAll() }
        if categories.contains(.offlineRepositories) { try? offline?.removeAll() }
        if categories.contains(.drafts) { drafts.removeAll() }
        if categories.contains(.snapshots) { snapshots.removeAll() }
        if categories.contains(.runHistory) { runs.clear() }
        if categories.contains(.annotations) { annotations.removeAll() }
    }

    /// 230. 全部消す。
    public func clearEverything() {
        clear(Set(StorageCategory.allCases))
    }

    /// 消しても困らないものだけ片付ける。
    public func clearSafely() {
        clear(Set(StorageCategory.allCases.filter(\.isSafeToDelete)))
    }

    /// 220. まとめてバックアップする。
    public func backupArchive(settings: SyncedSettings? = nil,
                              at date: Date = Date()) -> Data {
        var entries: [ZipEntry] = []
        for draft in drafts.all {
            let name = draft.key.replacingOccurrences(of: "/", with: "_")
            entries.append(ZipEntry(path: "drafts/\(name).txt", text: draft.text,
                                    modifiedAt: draft.savedAt))
        }
        if let data = snapshots.encoded() {
            entries.append(ZipEntry(path: "snapshots.json", data: data,
                                    modifiedAt: date))
        }
        if let data = annotations.encoded() {
            entries.append(ZipEntry(path: "annotations.json", data: data,
                                    modifiedAt: date))
        }
        if let data = settings?.encoded() {
            entries.append(ZipEntry(path: "settings.json", data: data,
                                    modifiedAt: date))
        }
        return Zip.archive(entries)
    }
}
