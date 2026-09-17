import Foundation

// MARK: - 36 / 37. タブ

/// 開いているファイル 1 つぶん。
public struct EditorTab: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    /// 何を開いているか。
    public var location: GitHubLocation?
    /// 画面に出す名前。
    public var title: String
    /// 言語 ID (色分けと実行に使う)。
    public var languageID: String?
    /// 33. 保存していない変更があるか。
    public var isDirty: Bool
    /// 37. ピン留め。
    public var isPinned: Bool
    /// 34. 読み取り専用。
    public var isReadOnly: Bool
    /// 最後に見ていた場所。
    public var caretLocation: Int
    public var scrollLine: Int

    public init(id: UUID = UUID(), location: GitHubLocation? = nil, title: String,
                languageID: String? = nil, isDirty: Bool = false,
                isPinned: Bool = false, isReadOnly: Bool = false,
                caretLocation: Int = 0, scrollLine: Int = 1) {
        self.id = id
        self.location = location
        self.title = title
        self.languageID = languageID
        self.isDirty = isDirty
        self.isPinned = isPinned
        self.isReadOnly = isReadOnly
        self.caretLocation = caretLocation
        self.scrollLine = scrollLine
    }

    /// 同じファイルを指しているか。
    public func points(at other: GitHubLocation?) -> Bool {
        guard let location, let other else { return false }
        return location.owner == other.owner && location.repo == other.repo
            && location.path == other.path
    }

    /// タブに出す名前 (未保存なら印を付ける)。
    public var label: String { isDirty ? "\(title) •" : title }
}

/// タブの並び。ピン留めしたものは前に寄せる。
public struct TabBar: Equatable, Codable, Sendable {
    public private(set) var tabs: [EditorTab]
    public private(set) var selectedID: UUID?
    /// 一度に開いておける数。
    public var limit: Int

    public init(tabs: [EditorTab] = [], selectedID: UUID? = nil, limit: Int = 12) {
        self.tabs = tabs
        self.selectedID = selectedID ?? tabs.first?.id
        self.limit = limit
    }

    public var selected: EditorTab? {
        guard let selectedID else { return tabs.first }
        return tabs.first { $0.id == selectedID } ?? tabs.first
    }

    public var isEmpty: Bool { tabs.isEmpty }
    public var count: Int { tabs.count }
    public var dirtyCount: Int { tabs.filter(\.isDirty).count }

    /// 開く。すでに開いていればそれを選ぶ。
    public mutating func open(_ tab: EditorTab) {
        if let index = tabs.firstIndex(where: { $0.points(at: tab.location) }) {
            selectedID = tabs[index].id
            return
        }
        tabs.append(tab)
        selectedID = tab.id
        trim()
    }

    /// 閉じる。ピン留めや未保存のものは、呼ぶ側が確かめる。
    public mutating func close(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedID == id {
            selectedID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    /// ほかを全部閉じる (ピン留めは残す)。
    public mutating func closeOthers(keeping id: UUID) {
        tabs = tabs.filter { $0.id == id || $0.isPinned }
        selectedID = id
    }

    public mutating func select(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// 次 / 前のタブへ。
    public mutating func selectNext(_ forward: Bool = true) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedID } ?? 0
        let next = forward ? (current + 1) % tabs.count
                           : (current - 1 + tabs.count) % tabs.count
        selectedID = tabs[next].id
    }

    /// 並べ替え。
    public mutating func move(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source) else { return }
        let tab = tabs.remove(at: source)
        let index = Swift.min(Swift.max(0, destination), tabs.count)
        tabs.insert(tab, at: index)
    }

    /// ピン留めを切り替える。ピン留めしたものは前に寄せる。
    public mutating func togglePin(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPinned.toggle()
        let pinned = tabs.filter(\.isPinned)
        let others = tabs.filter { !$0.isPinned }
        tabs = pinned + others
    }

    /// 中身を書き換える。
    public mutating func update(id: UUID, _ change: (inout EditorTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }

    /// 上限を超えたぶんを、古い順に閉じる (ピン留めと未保存は残す)。
    private mutating func trim() {
        while tabs.count > limit,
              let index = tabs.firstIndex(where: {
                  !$0.isPinned && !$0.isDirty && $0.id != selectedID
              }) {
            tabs.remove(at: index)
        }
    }
}

// MARK: - 38 / 39 / 40. 履歴・最近開いたもの・ブックマーク

/// 見た場所 1 つ。
public struct VisitedPlace: Identifiable, Equatable, Codable, Sendable {
    public var location: GitHubLocation
    public var title: String
    public var visitedAt: Date
    /// 何行目を見ていたか。
    public var line: Int

    public var id: String {
        "\(location.owner)/\(location.repo)@\(location.ref ?? "-")/\(location.path)"
    }

    public init(location: GitHubLocation, title: String, visitedAt: Date = Date(),
                line: Int = 1) {
        self.location = location
        self.title = title
        self.visitedAt = visitedAt
        self.line = line
    }
}

/// 「戻る」「進む」と、最近開いたものを覚えておく。
public struct NavigationHistory: Equatable, Codable, Sendable {
    /// いま見ているものを含む、たどってきた道。
    public private(set) var backward: [VisitedPlace]
    /// 「戻る」で外した先。
    public private(set) var forward: [VisitedPlace]
    /// 38. 最近開いたもの (新しい順、重複なし)。
    public private(set) var recent: [VisitedPlace]
    public var recentLimit: Int

    public init(backward: [VisitedPlace] = [], forward: [VisitedPlace] = [],
                recent: [VisitedPlace] = [], recentLimit: Int = 30) {
        self.backward = backward
        self.forward = forward
        self.recent = recent
        self.recentLimit = recentLimit
    }

    public var current: VisitedPlace? { backward.last }
    public var canGoBack: Bool { backward.count > 1 }
    public var canGoForward: Bool { !forward.isEmpty }

    /// 新しい場所へ進む。
    public mutating func visit(_ place: VisitedPlace) {
        if backward.last?.id == place.id {
            backward[backward.count - 1] = place
        } else {
            backward.append(place)
            forward.removeAll()
        }
        addRecent(place)
    }

    /// 戻る。
    @discardableResult
    public mutating func goBack() -> VisitedPlace? {
        guard canGoBack else { return nil }
        let leaving = backward.removeLast()
        forward.append(leaving)
        return backward.last
    }

    /// 40. 進む。
    @discardableResult
    public mutating func goForward() -> VisitedPlace? {
        guard let place = forward.popLast() else { return nil }
        backward.append(place)
        return place
    }

    private mutating func addRecent(_ place: VisitedPlace) {
        recent.removeAll { $0.id == place.id }
        recent.insert(place, at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
    }

    public mutating func clearRecent() { recent.removeAll() }
}

/// 39. ブックマーク。
public struct Bookmark: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var location: GitHubLocation
    public var title: String
    /// 行に付けたブックマークなら、その行。
    public var line: Int?
    public var note: String
    public var addedAt: Date

    public init(id: UUID = UUID(), location: GitHubLocation, title: String,
                line: Int? = nil, note: String = "", addedAt: Date = Date()) {
        self.id = id
        self.location = location
        self.title = title
        self.line = line
        self.note = note
        self.addedAt = addedAt
    }

    /// 同じ場所か。
    public func matches(_ other: GitHubLocation, line: Int? = nil) -> Bool {
        location.owner == other.owner && location.repo == other.repo
            && location.path == other.path && self.line == line
    }

    public var subtitle: String {
        let place = location.path.isEmpty ? "\(location.owner)/\(location.repo)"
                                          : location.path
        return line.map { "\(place):\($0)" } ?? place
    }
}

/// ブックマークの入れ物。
public struct BookmarkStore: Equatable, Codable, Sendable {
    public private(set) var bookmarks: [Bookmark]

    public init(bookmarks: [Bookmark] = []) {
        self.bookmarks = bookmarks
    }

    public var count: Int { bookmarks.count }

    @discardableResult
    public mutating func toggle(_ bookmark: Bookmark) -> Bool {
        if let index = bookmarks.firstIndex(where: {
            $0.matches(bookmark.location, line: bookmark.line)
        }) {
            bookmarks.remove(at: index)
            return false
        }
        bookmarks.append(bookmark)
        return true
    }

    public mutating func remove(id: UUID) {
        bookmarks.removeAll { $0.id == id }
    }

    public func contains(_ location: GitHubLocation, line: Int? = nil) -> Bool {
        bookmarks.contains { $0.matches(location, line: line) }
    }

    /// あるファイルに付いた行ブックマーク。
    public func lines(in location: GitHubLocation) -> [Int] {
        bookmarks.filter {
            $0.location.owner == location.owner && $0.location.repo == location.repo
                && $0.location.path == location.path
        }.compactMap(\.line).sorted()
    }

    public mutating func clear() { bookmarks.removeAll() }
}

// MARK: - 41. パンくずリスト

/// パンくずの 1 段。
public struct Breadcrumb: Identifiable, Equatable, Sendable {
    public var title: String
    public var location: GitHubLocation

    public var id: String { "\(location.repo)/\(location.path)" }

    public init(title: String, location: GitHubLocation) {
        self.title = title
        self.location = location
    }
}

public enum Breadcrumbs {
    /// 場所を、たどれる段に分ける。
    public static func trail(for location: GitHubLocation) -> [Breadcrumb] {
        var result = [Breadcrumb(title: "\(location.owner)/\(location.repo)",
                                 location: GitHubLocation(owner: location.owner,
                                                          repo: location.repo,
                                                          ref: location.ref,
                                                          path: "",
                                                          isDirectory: true))]
        var parts: [String] = []
        let components = location.path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            parts.append(component)
            let isLast = index == components.count - 1
            result.append(Breadcrumb(
                title: component,
                location: GitHubLocation(owner: location.owner, repo: location.repo,
                                         ref: location.ref,
                                         path: parts.joined(separator: "/"),
                                         isDirectory: isLast ? location.isDirectory
                                                             : true)))
        }
        return result
    }
}

// MARK: - 42. ファイルツリーの展開状態

/// どのフォルダを開いているかを覚えておく。
public struct TreeExpansion: Equatable, Codable, Sendable {
    private var expanded: Set<String>

    public init(expanded: Set<String> = []) {
        self.expanded = expanded
    }

    public func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    public mutating func setExpanded(_ value: Bool, for path: String) {
        if value { expanded.insert(path) } else { expanded.remove(path) }
    }

    @discardableResult
    public mutating func toggle(_ path: String) -> Bool {
        let value = !isExpanded(path)
        setExpanded(value, for: path)
        return value
    }

    /// あるファイルまでの道をすべて開く。
    public mutating func reveal(path: String) {
        var parts: [String] = []
        for component in path.split(separator: "/").dropLast() {
            parts.append(String(component))
            expanded.insert(parts.joined(separator: "/"))
        }
    }

    public mutating func collapseAll() { expanded.removeAll() }

    public var expandedPaths: [String] { expanded.sorted() }
}

// MARK: - 55 / 56. サイドバー

/// サイドバーの見せ方。
public struct SidebarState: Equatable, Codable, Sendable {
    public var isVisible: Bool
    /// 幅 (点)。
    public var width: Double
    public static let minimumWidth: Double = 180
    public static let maximumWidth: Double = 520

    public init(isVisible: Bool = true, width: Double = 280) {
        self.isVisible = isVisible
        self.width = Swift.min(SidebarState.maximumWidth,
                               Swift.max(SidebarState.minimumWidth, width))
    }

    public mutating func toggle() { isVisible.toggle() }

    public mutating func setWidth(_ value: Double) {
        width = Swift.min(SidebarState.maximumWidth,
                          Swift.max(SidebarState.minimumWidth, value))
    }
}

// MARK: - 57. 複数リポジトリのワークスペース

/// ワークスペースに入れたリポジトリ 1 つ。
public struct WorkspaceEntry: Identifiable, Equatable, Codable, Sendable {
    public var owner: String
    public var repo: String
    public var ref: String?
    /// 表示名 (付けていなければ owner/repo)。
    public var nickname: String?
    public var addedAt: Date

    public var id: String { "\(owner)/\(repo)" }

    public init(owner: String, repo: String, ref: String? = nil,
                nickname: String? = nil, addedAt: Date = Date()) {
        self.owner = owner
        self.repo = repo
        self.ref = ref
        self.nickname = nickname
        self.addedAt = addedAt
    }

    public var displayName: String { nickname ?? id }

    public var rootLocation: GitHubLocation {
        GitHubLocation(owner: owner, repo: repo, ref: ref, path: "", isDirectory: true)
    }
}

/// 複数のリポジトリをまとめて開いておく。
public struct Workspace: Equatable, Codable, Sendable {
    public private(set) var entries: [WorkspaceEntry]
    public private(set) var activeID: String?

    public init(entries: [WorkspaceEntry] = [], activeID: String? = nil) {
        self.entries = entries
        self.activeID = activeID ?? entries.first?.id
    }

    public var active: WorkspaceEntry? {
        guard let activeID else { return entries.first }
        return entries.first { $0.id == activeID } ?? entries.first
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func add(_ entry: WorkspaceEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        activeID = entry.id
    }

    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
        if activeID == id { activeID = entries.first?.id }
    }

    public mutating func activate(id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    public mutating func rename(id: String, to nickname: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].nickname = nickname?.isEmpty == true ? nil : nickname
    }
}
