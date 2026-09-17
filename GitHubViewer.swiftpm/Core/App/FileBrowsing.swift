import Foundation

// MARK: - 46 / 47 / 48. 一覧の並べ方と見せ方

/// ディレクトリの並べ方。
public enum FileSortOrder: String, CaseIterable, Identifiable, Codable, Equatable,
                           Sendable {
    case name
    case size
    case modified
    case kind

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .name: return "名前順"
        case .size: return "大きさ順"
        case .modified: return "更新順"
        case .kind: return "種類順"
        }
    }
}

/// 一覧の見せ方の設定。
public struct FileListOptions: Equatable, Codable, Sendable {
    public var sort: FileSortOrder
    public var isAscending: Bool
    /// 47. `.` で始まるものを出すか。
    public var showsHidden: Bool
    /// フォルダを先に出すか。
    public var groupsDirectoriesFirst: Bool
    /// 48. 大きさと更新日時を出すか。
    public var showsDetails: Bool
    /// 絞り込みの文字。
    public var filterText: String

    public init(sort: FileSortOrder = .name, isAscending: Bool = true,
                showsHidden: Bool = false, groupsDirectoriesFirst: Bool = true,
                showsDetails: Bool = true, filterText: String = "") {
        self.sort = sort
        self.isAscending = isAscending
        self.showsHidden = showsHidden
        self.groupsDirectoriesFirst = groupsDirectoriesFirst
        self.showsDetails = showsDetails
        self.filterText = filterText
    }

    public static let `default` = FileListOptions()
}

/// 一覧に出す 1 行 (`RepositoryEntry` に見せ方の情報を足したもの)。
public struct FileListItem: Identifiable, Equatable, Sendable {
    public var entry: RepositoryEntry
    /// 48. 更新日時 (分かれば)。
    public var modifiedAt: Date?

    public var id: String { entry.id }
    public var name: String { entry.name }
    public var isDirectory: Bool { entry.isDirectory }
    public var size: Int { entry.size }

    public init(entry: RepositoryEntry, modifiedAt: Date? = nil) {
        self.entry = entry
        self.modifiedAt = modifiedAt
    }

    public var isHidden: Bool { name.hasPrefix(".") }

    /// 拡張子 (小文字、点なし)。
    public var fileExtension: String {
        guard !isDirectory, let last = name.split(separator: ".").last,
              name.contains(".") else { return "" }
        return last.lowercased()
    }

    /// 「1.2 KB」。フォルダなら空。
    public var sizeText: String {
        isDirectory ? "" : OfflineCache.sizeText(size)
    }

    /// 「3 日前」。
    public var modifiedText: String {
        GitHubDate.relative(from: modifiedAt)
    }

    /// 48. 一覧の 2 行目に出す説明。
    public var detailText: String {
        [sizeText, modifiedText].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 一覧を並べ替え、絞り込む。
public enum FileListing {

    public static func arrange(_ items: [FileListItem],
                               options: FileListOptions = .default) -> [FileListItem] {
        var result = items

        if !options.showsHidden {
            result = result.filter { !$0.isHidden }
        }
        let query = options.filterText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = FuzzySearch.search(query, in: result, limit: result.count) {
                $0.name
            }.map(\.element)
            // あいまい検索の点数順はそのまま使う。
            return result
        }

        result.sort { left, right in
            if options.groupsDirectoriesFirst, left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            let ascending = options.isAscending
            switch options.sort {
            case .name:
                let order = left.name.localizedStandardCompare(right.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            case .size:
                if left.size == right.size {
                    return left.name.localizedStandardCompare(right.name) == .orderedAscending
                }
                return ascending ? left.size < right.size : left.size > right.size
            case .modified:
                let leftDate = left.modifiedAt ?? .distantPast
                let rightDate = right.modifiedAt ?? .distantPast
                if leftDate == rightDate {
                    return left.name.localizedStandardCompare(right.name) == .orderedAscending
                }
                return ascending ? leftDate < rightDate : leftDate > rightDate
            case .kind:
                if left.fileExtension == right.fileExtension {
                    return left.name.localizedStandardCompare(right.name) == .orderedAscending
                }
                return ascending ? left.fileExtension < right.fileExtension
                                 : left.fileExtension > right.fileExtension
            }
        }
        return result
    }

    /// `DirectoryListing` から一覧を作る。
    public static func items(from listing: DirectoryListing) -> [FileListItem] {
        listing.entries.map { FileListItem(entry: $0) }
    }

    // MARK: - 54. 前後のファイルへ移動

    /// いまのファイルの次 (前) のファイル。フォルダは飛ばす。
    public static func neighbour(of path: String, in items: [FileListItem],
                                 forward: Bool) -> FileListItem? {
        let files = items.filter { !$0.isDirectory }
        guard let index = files.firstIndex(where: { $0.entry.location?.path == path })
        else { return files.first }
        let next = forward ? index + 1 : index - 1
        guard files.indices.contains(next) else { return nil }
        return files[next]
    }
}

// MARK: - 51 / 52. リンクをたどる

/// リンクを開いた先。
public enum LinkDestination: Equatable, Sendable {
    /// 同じリポジトリの中。
    case repository(GitHubLocation)
    /// 同じファイルの中の見出し。
    case anchor(String)
    /// 外の URL。
    case external(URL)

    public var location: GitHubLocation? {
        if case .repository(let location) = self { return location }
        return nil
    }
}

/// Markdown や HTML の中のリンクを、アプリの中で開ける形に直す。
public enum LinkResolver {

    /// いま開いているファイルから見た相対リンクを解決する。
    public static func resolve(_ href: String,
                               from location: GitHubLocation) -> LinkDestination? {
        let trimmed = href.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // 同じページの中の見出し。
        if trimmed.hasPrefix("#") {
            return .anchor(String(trimmed.dropFirst()))
        }

        // すでに URL の形をしているもの。
        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") {
            // GitHub の中を指していれば、アプリの中で開く。
            if let target = try? GitHubURLParser.parse(trimmed),
               case .repository(let inner) = target {
                return .repository(inner)
            }
            return URL(string: trimmed).map { .external($0) }
        }

        // リポジトリのルートから。
        if trimmed.hasPrefix("/") {
            return .repository(GitHubLocation(owner: location.owner,
                                              repo: location.repo, ref: location.ref,
                                              path: normalize(String(trimmed.dropFirst())),
                                              isDirectory: trimmed.hasSuffix("/")))
        }

        // いまのファイルから見た相対。
        var parts = location.path.split(separator: "/").map(String.init)
        if !location.isDirectory, !parts.isEmpty { parts.removeLast() }
        var fragment: String?
        var body = trimmed
        if let index = body.firstIndex(of: "#") {
            fragment = String(body[body.index(after: index)...])
            body = String(body[body.startIndex..<index])
        }
        if body.isEmpty, let fragment { return .anchor(fragment) }

        for component in body.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(component))
            }
        }
        return .repository(GitHubLocation(owner: location.owner, repo: location.repo,
                                          ref: location.ref,
                                          path: parts.joined(separator: "/"),
                                          isDirectory: body.hasSuffix("/")))
    }

    static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(component))
            }
        }
        return parts.joined(separator: "/")
    }

    /// Markdown の中のリンクを集める。
    public static func links(inMarkdown markdown: String) -> [(text: String,
                                                               href: String)] {
        var result: [(String, String)] = []
        let characters = Array(markdown)
        var index = 0
        while index < characters.count {
            // 画像 (`![...](...)`) はリンクではないので、まるごと飛ばす。
            if characters[index] == "!", index + 1 < characters.count,
               characters[index + 1] == "[" {
                if let altEnd = close(characters, from: index + 1, open: "[", shut: "]"),
                   altEnd + 1 < characters.count, characters[altEnd + 1] == "(",
                   let urlEnd = close(characters, from: altEnd + 1, open: "(",
                                      shut: ")") {
                    index = urlEnd + 1
                } else {
                    index += 2
                }
                continue
            }
            guard characters[index] == "[" else {
                index += 1
                continue
            }
            guard let textEnd = close(characters, from: index, open: "[", shut: "]"),
                  textEnd + 1 < characters.count, characters[textEnd + 1] == "(",
                  let hrefEnd = close(characters, from: textEnd + 1, open: "(",
                                      shut: ")") else {
                index += 1
                continue
            }
            let text = String(characters[(index + 1)..<textEnd])
            let href = String(characters[(textEnd + 2)..<hrefEnd])
                .components(separatedBy: " ").first ?? ""
            if !href.isEmpty { result.append((text, href)) }
            index = hrefEnd + 1
        }
        return result
    }

    private static func close(_ characters: [Character], from start: Int,
                              open: Character, shut: Character) -> Int? {
        var depth = 0
        var index = start
        while index < characters.count {
            if characters[index] == open { depth += 1 }
            else if characters[index] == shut {
                depth -= 1
                if depth == 0 { return index }
            } else if characters[index] == "\n", depth > 0 { return nil }
            index += 1
        }
        return nil
    }
}

// MARK: - 58. URL 入力欄の履歴

/// 入力欄に出す候補。
public struct URLSuggestion: Identifiable, Equatable, Sendable {
    public var text: String
    /// 何に当たるか (「リポジトリ」「Gist」など)。
    public var kind: String
    /// 一致した文字の位置 (強調用)。
    public var matchedIndices: [Int]

    public var id: String { text }

    public init(text: String, kind: String, matchedIndices: [Int] = []) {
        self.text = text
        self.kind = kind
        self.matchedIndices = matchedIndices
    }
}

/// 入れた URL を覚えて、次から候補に出す。
public struct URLHistory: Equatable, Codable, Sendable {
    public private(set) var entries: [String]
    public var limit: Int

    public init(entries: [String] = [], limit: Int = 50) {
        self.entries = entries
        self.limit = limit
    }

    public mutating func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0 == trimmed }
        entries.insert(trimmed, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    public mutating func remove(_ text: String) {
        entries.removeAll { $0 == text }
    }

    public mutating func clear() { entries.removeAll() }

    /// 打ちかけの文字から候補を出す。
    public func suggestions(for input: String, limit: Int = 8) -> [URLSuggestion] {
        let query = input.trimmingCharacters(in: .whitespaces)
        let matches = FuzzySearch.search(query, in: entries, limit: limit) { $0 }
        return matches.map {
            URLSuggestion(text: $0.element, kind: URLHistory.kind(of: $0.element),
                          matchedIndices: $0.matchedIndices)
        }
    }

    /// その文字列が何に当たるか。
    static func kind(of text: String) -> String {
        guard let target = try? GitHubURLParser.parse(text) else { return "URL" }
        switch target {
        case .repository(let location):
            return location.path.isEmpty ? "リポジトリ" : "ファイル"
        case .gist: return "Gist"
        case .rawURL: return "URL"
        }
    }
}

// MARK: - 59 / 60. 外から受け取る文字列

/// QR コードや共有シートから来た文字列を、開ける形にする。
public enum SharedInput {

    /// 受け取った文字列を解釈する。開けなければ nil。
    public static func target(from text: String) -> GitHubTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 複数行なら、URL らしい行を探す。
        for line in trimmed.components(separatedBy: .newlines) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty else { continue }
            if let target = try? GitHubURLParser.parse(candidate) { return target }
        }
        return nil
    }

    /// 文章の中から URL らしいものを拾う。
    ///
    /// 共有シートから来る文章には、URL のほかに題名などが混ざっていることが多い。
    public static func urls(in text: String) -> [URL] {
        let pattern = #"https?://[^\s<>"'\)\]]+"#
        var found: [URL] = []
        for match in TextSearch.matches(of: pattern, in: text,
                                        options: SearchOptions(isRegularExpression: true)) {
            var piece = (text as NSString).substring(
                with: NSRange(location: match.location, length: match.length))
            // 文末の句読点はリンクに含めない。
            while let last = piece.last, ".,;:!?。、".contains(last) {
                piece.removeLast()
            }
            if let url = URL(string: piece) { found.append(url) }
        }
        return found
    }
}
