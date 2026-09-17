import Foundation

// MARK: - 23 / 25 / 33. 下書きの自動保存・復元・破棄

/// 保存していない編集内容。
public struct Draft: Identifiable, Equatable, Codable, Sendable {
    /// どのファイルの下書きか。
    public var key: String
    /// 編集中の中身。
    public var text: String
    /// 取ってきたときの中身 (差分と破棄に使う)。
    public var original: String
    public var savedAt: Date
    public var caretLocation: Int

    public var id: String { key }

    public init(key: String, text: String, original: String,
                savedAt: Date = Date(), caretLocation: Int = 0) {
        self.key = key
        self.text = text
        self.original = original
        self.savedAt = savedAt
        self.caretLocation = caretLocation
    }

    /// 33. 変更があるか。
    public var isDirty: Bool { text != original }

    /// 24. 取ってきたときとの差分。
    public var diff: [DiffLine] {
        DiffEngine.diff(old: original, new: text)
    }

    public var diffSummary: DiffSummary { DiffEngine.summary(diff) }

    /// 「+3 -1」。
    public var changeText: String {
        isDirty ? diffSummary.description : "変更なし"
    }
}

/// 下書きの入れ物。
///
/// 編集のたびに全部を書き出すと重いので、`shouldSave` で間引く。
public final class DraftStore: @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [String: Draft] = [:]
    /// 書き出す先 (UserDefaults やファイル)。
    private let persist: (@Sendable (Data) -> Void)?
    /// 何秒おきに書き出すか。
    public var saveInterval: TimeInterval
    private var lastSaved: [String: Date] = [:]

    public init(drafts: [Draft] = [], saveInterval: TimeInterval = 2,
                persist: (@Sendable (Data) -> Void)? = nil) {
        for draft in drafts { self.drafts[draft.key] = draft }
        self.saveInterval = saveInterval
        self.persist = persist
    }

    /// 保存しておいた JSON から戻す。
    public convenience init(json: Data?, saveInterval: TimeInterval = 2,
                            persist: (@Sendable (Data) -> Void)? = nil) {
        let loaded = json.flatMap { try? JSONDecoder().decode([Draft].self, from: $0) }
        self.init(drafts: loaded ?? [], saveInterval: saveInterval, persist: persist)
    }

    /// ファイルの場所から鍵を作る。
    public static func key(for location: GitHubLocation) -> String {
        "\(location.owner)/\(location.repo)@\(location.ref ?? "-")/\(location.path)"
    }

    public var all: [Draft] {
        lock.lock()
        defer { lock.unlock() }
        return drafts.values.sorted { $0.savedAt > $1.savedAt }
    }

    /// 変更のあるものだけ。
    public var dirty: [Draft] { all.filter(\.isDirty) }

    public func draft(for key: String) -> Draft? {
        lock.lock()
        defer { lock.unlock() }
        return drafts[key]
    }

    /// 23. いまの中身を覚える。
    ///
    /// `force` が false のときは、前に書き出してから `saveInterval` 秒たつまで
    /// 書き出しを見送る (入力のたびに重くならないように)。
    @discardableResult
    public func update(key: String, text: String, original: String,
                       caretLocation: Int = 0, now: Date = Date(),
                       force: Bool = false) -> Bool {
        lock.lock()
        drafts[key] = Draft(key: key, text: text, original: original, savedAt: now,
                            caretLocation: caretLocation)
        let previous = lastSaved[key]
        let shouldWrite = force || previous == nil
            || now.timeIntervalSince(previous!) >= saveInterval
        if shouldWrite { lastSaved[key] = now }
        let snapshot = Array(drafts.values)
        lock.unlock()

        guard shouldWrite, let persist, let data = try? JSONEncoder().encode(snapshot)
        else { return false }
        persist(data)
        return true
    }

    /// 25. 編集を捨てて、取ってきたときの中身に戻す。
    ///
    /// 戻した中身を返す。下書きが無ければ nil。
    @discardableResult
    public func discard(key: String) -> String? {
        lock.lock()
        let original = drafts[key]?.original
        drafts[key] = nil
        lastSaved[key] = nil
        let snapshot = Array(drafts.values)
        lock.unlock()

        if let persist, let data = try? JSONEncoder().encode(snapshot) { persist(data) }
        return original
    }

    /// 保存し終えたので、いまの中身を「取ってきたとき」の中身にする。
    public func markSaved(key: String) {
        lock.lock()
        if var draft = drafts[key] {
            draft.original = draft.text
            drafts[key] = draft
        }
        let snapshot = Array(drafts.values)
        lock.unlock()
        if let persist, let data = try? JSONEncoder().encode(snapshot) { persist(data) }
    }

    public func removeAll() {
        lock.lock()
        drafts.removeAll()
        lastSaved.removeAll()
        lock.unlock()
        if let persist, let data = try? JSONEncoder().encode([Draft]()) { persist(data) }
    }

    /// 古い下書きを片付ける。
    @discardableResult
    public func removeOlder(than date: Date) -> Int {
        lock.lock()
        let removed = drafts.filter { $0.value.savedAt < date && !$0.value.isDirty }
        for key in removed.keys { drafts[key] = nil }
        let snapshot = Array(drafts.values)
        lock.unlock()
        if !removed.isEmpty, let persist,
           let data = try? JSONEncoder().encode(snapshot) {
            persist(data)
        }
        return removed.count
    }

    public func encoded() -> Data? {
        lock.lock()
        let snapshot = Array(drafts.values)
        lock.unlock()
        return try? JSONEncoder().encode(snapshot)
    }
}

// MARK: - 44. リポジトリ全体のコード検索

/// 検索で見つかった 1 行。
public struct SearchHit: Identifiable, Equatable, Sendable {
    public var path: String
    public var line: Int
    public var text: String
    /// 行の中での位置 (UTF-16)。
    public var location: Int
    public var length: Int

    public var id: String { "\(path):\(line):\(location)" }

    public init(path: String, line: Int, text: String, location: Int, length: Int) {
        self.path = path
        self.line = line
        self.text = text
        self.location = location
        self.length = length
    }

    /// 前後を省いた、見せるための行。
    public func preview(maximumLength: Int = 120) -> String {
        guard text.utf16.count > maximumLength else { return text }
        let document = TextDocument(text)
        let start = Swift.max(0, location - maximumLength / 3)
        let length = Swift.min(maximumLength, text.utf16.count - start)
        var piece = document.substring(location: start, length: length)
        if start > 0 { piece = "…" + piece }
        if start + length < text.utf16.count { piece += "…" }
        return piece
    }
}

/// ファイルごとにまとめた結果。
public struct SearchFileResult: Identifiable, Equatable, Sendable {
    public var path: String
    public var hits: [SearchHit]

    public var id: String { path }

    public init(path: String, hits: [SearchHit]) {
        self.path = path
        self.hits = hits
    }

    public var count: Int { hits.count }
}

/// 検索の絞り込み。
public struct RepositorySearchOptions: Equatable, Sendable {
    public var search: SearchOptions
    /// 対象にする拡張子 (空ならすべて)。
    public var fileExtensions: Set<String>
    /// 名前がこの語を含むファイルは飛ばす。
    public var excludedPathParts: [String]
    /// 1 ファイルあたりの上限。
    public var maximumHitsPerFile: Int
    /// 全体の上限。
    public var maximumHits: Int

    public init(search: SearchOptions = SearchOptions(),
                fileExtensions: Set<String> = [],
                excludedPathParts: [String] = [".git/", "node_modules/", "/dist/"],
                maximumHitsPerFile: Int = 50, maximumHits: Int = 1000) {
        self.search = search
        self.fileExtensions = fileExtensions
        self.excludedPathParts = excludedPathParts
        self.maximumHitsPerFile = maximumHitsPerFile
        self.maximumHits = maximumHits
    }

    public static let `default` = RepositorySearchOptions()

    /// そのファイルを調べるか。
    public func includes(path: String) -> Bool {
        for part in excludedPathParts where path.contains(part) { return false }
        guard !fileExtensions.isEmpty else { return true }
        guard let suffix = path.split(separator: ".").last, path.contains(".") else {
            return false
        }
        return fileExtensions.contains(suffix.lowercased())
    }
}

/// 端末に持っているファイルの中から探す。
///
/// GitHub のコード検索は公開リポジトリ向けで速度も読めないので、
/// オフラインに落としたものはここで探す。
public enum RepositorySearch {

    /// ファイル名 → 中身 の中から探す。
    public static func search(_ query: String, in files: [String: String],
                              options: RepositorySearchOptions = .default)
        -> [SearchFileResult] {
        guard !query.isEmpty else { return [] }
        var results: [SearchFileResult] = []
        var total = 0

        for path in files.keys.sorted() {
            guard options.includes(path: path), let text = files[path] else { continue }
            guard total < options.maximumHits else { break }

            var hits: [SearchHit] = []
            let document = TextDocument(text)
            for match in TextSearch.matches(of: query, in: text,
                                            options: options.search) {
                guard hits.count < options.maximumHitsPerFile,
                      total < options.maximumHits else { break }
                let position = document.position(at: match.location)
                let range = document.lineRange(position.line)
                hits.append(SearchHit(path: path, line: position.line,
                                      text: document.substring(location: range.location,
                                                               length: range.length),
                                      location: match.location - range.location,
                                      length: match.length))
                total += 1
            }
            if !hits.isEmpty { results.append(SearchFileResult(path: path, hits: hits)) }
        }
        return results
    }

    /// オフラインに落としたリポジトリの中から探す。
    public static func search(_ query: String, owner: String, repo: String, ref: String,
                              in cache: OfflineCache,
                              options: RepositorySearchOptions = .default)
        -> [SearchFileResult] {
        guard let snapshot = cache.snapshot(owner: owner, repo: repo, ref: ref) else {
            return []
        }
        var files: [String: String] = [:]
        for path in snapshot.paths where options.includes(path: path) {
            guard let data = cache.load(owner: owner, repo: repo, ref: ref, path: path)
            else { continue }
            // 中身が文字として読めるものだけ探す。
            guard let text = ContentClassifier.text(from: data) else { continue }
            files[path] = text
        }
        return search(query, in: files, options: options)
    }

    /// 見つかった数の合計。
    public static func total(_ results: [SearchFileResult]) -> Int {
        results.reduce(0) { $0 + $1.count }
    }

    /// 「3 ファイルで 12 件」。
    public static func summary(_ results: [SearchFileResult]) -> String {
        let count = total(results)
        guard count > 0 else { return "見つかりませんでした" }
        return "\(results.count) ファイルで \(count) 件"
    }
}
