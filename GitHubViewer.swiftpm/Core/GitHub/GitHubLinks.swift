import Foundation

/// 行の範囲 (permalink の `#L10-L20`)。
public struct LineRange: Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int? = nil) {
        self.start = Swift.max(1, start)
        self.end = Swift.max(self.start, end ?? start)
    }

    public var isSingleLine: Bool { start == end }

    public var count: Int { end - start + 1 }

    /// `#L10` / `#L10-L20` の形。
    public var fragment: String {
        isSingleLine ? "L\(start)" : "L\(start)-L\(end)"
    }
}

/// GitHub の各種 URL を組み立てる / 読み取る。
public enum GitHubLinks {

    // MARK: - 94. raw URL と permalink

    /// `https://raw.githubusercontent.com/owner/repo/ref/path`
    public static func rawURL(_ location: GitHubLocation,
                              host: String = "raw.githubusercontent.com") -> URL? {
        let ref = location.ref ?? "HEAD"
        var text = "https://\(host)/\(location.owner)/\(location.repo)/\(escape(ref))"
        if !location.path.isEmpty { text += "/" + escape(location.path) }
        return URL(string: text)
    }

    /// `https://github.com/owner/repo/blob/ref/path`
    public static func blobURL(_ location: GitHubLocation, lines: LineRange? = nil,
                               host: String = "github.com") -> URL? {
        let ref = location.ref ?? "HEAD"
        let kind = location.isDirectory ? "tree" : "blob"
        var text = "https://\(host)/\(location.owner)/\(location.repo)/\(kind)/\(escape(ref))"
        if !location.path.isEmpty { text += "/" + escape(location.path) }
        if let lines, !location.isDirectory { text += "#" + lines.fragment }
        return URL(string: text)
    }

    /// ブランチ名ではなくコミット SHA を指す、変わらないリンク。
    public static func permalink(_ location: GitHubLocation, commitSHA: String,
                                 lines: LineRange? = nil,
                                 host: String = "github.com") -> URL? {
        var pinned = location
        pinned.ref = commitSHA
        return blobURL(pinned, lines: lines, host: host)
    }

    /// blame のページ。
    public static func blameURL(_ location: GitHubLocation,
                                host: String = "github.com") -> URL? {
        let ref = location.ref ?? "HEAD"
        var text = "https://\(host)/\(location.owner)/\(location.repo)/blame/\(escape(ref))"
        if !location.path.isEmpty { text += "/" + escape(location.path) }
        return URL(string: text)
    }

    /// コミットのページ。
    public static func commitURL(owner: String, repo: String, sha: String,
                                 host: String = "github.com") -> URL? {
        URL(string: "https://\(host)/\(owner)/\(repo)/commit/\(sha)")
    }

    /// Issue / Pull Request のページ。
    public static func issueURL(owner: String, repo: String, number: Int,
                                isPullRequest: Bool = false,
                                host: String = "github.com") -> URL? {
        let kind = isPullRequest ? "pull" : "issues"
        return URL(string: "https://\(host)/\(owner)/\(repo)/\(kind)/\(number)")
    }

    // MARK: - 95. 行番号つき permalink の読み取り

    /// `#L10-L20` や `#L10` を読み取る。
    public static func lineRange(fromFragment fragment: String?) -> LineRange? {
        guard var text = fragment, !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        let parts = text.components(separatedBy: "-")
        guard let first = parts.first, first.hasPrefix("L"),
              let start = Int(first.dropFirst()) else { return nil }
        guard parts.count > 1 else { return LineRange(start: start) }
        let second = parts[1]
        guard second.hasPrefix("L"), let end = Int(second.dropFirst()) else {
            return LineRange(start: start)
        }
        return LineRange(start: start, end: end)
    }

    /// URL 全体から行の範囲を取り出す。
    public static func lineRange(from url: URL) -> LineRange? {
        lineRange(fromFragment: url.fragment)
    }

    /// 文字列の URL から行の範囲を取り出す (`URL` が `#` を落とす場合にも効く)。
    public static func lineRange(fromText text: String) -> LineRange? {
        guard let index = text.lastIndex(of: "#") else { return nil }
        return lineRange(fromFragment: String(text[text.index(after: index)...]))
    }

    /// 選んだ範囲を「リンク + 引用」の形にまとめる (共有用)。
    public static func quotedSnippet(_ location: GitHubLocation, commitSHA: String,
                                     lines: LineRange, text: String,
                                     languageID: String? = nil) -> String {
        let link = permalink(location, commitSHA: commitSHA,
                             lines: lines)?.absoluteString ?? ""
        let fence = languageID.map { "```\($0)" } ?? "```"
        return "\(link)\n\(fence)\n\(text)\n```"
    }

    // MARK: - パスの組み立て

    private static func escape(_ path: String) -> String {
        path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? String($0) }
            .joined(separator: "/")
    }
}

// MARK: - 72. README のバッジ

/// README に貼られたバッジ 1 つ。
public struct ReadmeBadge: Identifiable, Equatable, Sendable {
    public var altText: String
    public var imageURL: URL
    /// クリックしたときの飛び先 (あれば)。
    public var linkURL: URL?

    public var id: String { imageURL.absoluteString }

    public init(altText: String, imageURL: URL, linkURL: URL? = nil) {
        self.altText = altText
        self.imageURL = imageURL
        self.linkURL = linkURL
    }

    /// よく使われるバッジ置き場か。
    public var isKnownBadgeHost: Bool {
        guard let host = imageURL.host?.lowercased() else { return false }
        return ReadmeBadgeScanner.badgeHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// README の先頭にあるバッジを拾う。
public enum ReadmeBadgeScanner {
    static let badgeHosts: Set<String> = [
        "img.shields.io", "shields.io", "badge.fury.io", "travis-ci.org",
        "travis-ci.com", "codecov.io", "coveralls.io", "app.codacy.com",
        "api.codeclimate.com", "badgen.net", "flat.badgen.net", "github.com",
        "gitlab.com", "circleci.com", "dl.circleci.com", "snyk.io",
        "img.buymeacoffee.com", "forthebadge.com", "opencollective.com"
    ]

    /// Markdown からバッジらしい画像を取り出す。
    ///
    /// `[![alt](image)](link)` と `![alt](image)` の両方に対応する。
    public static func badges(inMarkdown markdown: String,
                              onlyKnownHosts: Bool = true) -> [ReadmeBadge] {
        var found: [ReadmeBadge] = []
        var seen: Set<String> = []
        let characters = Array(markdown)
        var index = 0

        while index < characters.count {
            guard characters[index] == "!" || characters[index] == "[" else {
                index += 1
                continue
            }

            // `[![alt](image)](link)` のときは、外側のリンクを覚えておく。
            var linkStart: Int?
            if characters[index] == "[", index + 1 < characters.count,
               characters[index + 1] == "!" {
                linkStart = index
                index += 1
            }
            guard characters[index] == "!", index + 1 < characters.count,
                  characters[index + 1] == "[" else {
                index += 1
                continue
            }

            guard let altEnd = close(characters, from: index + 1, open: "[", shut: "]"),
                  altEnd + 1 < characters.count, characters[altEnd + 1] == "(",
                  let urlEnd = close(characters, from: altEnd + 1, open: "(",
                                     shut: ")") else {
                index += 1
                continue
            }

            let alt = String(characters[(index + 2)..<altEnd])
            let imageText = String(characters[(altEnd + 2)..<urlEnd])
                .components(separatedBy: " ").first ?? ""

            var link: URL?
            var next = urlEnd + 1
            if linkStart != nil, next < characters.count, characters[next] == "]",
               next + 1 < characters.count, characters[next + 1] == "(",
               let linkEnd = close(characters, from: next + 1, open: "(", shut: ")") {
                link = URL(string: String(characters[(next + 2)..<linkEnd])
                    .components(separatedBy: " ").first ?? "")
                next = linkEnd + 1
            }
            index = next

            guard let image = URL(string: imageText), image.scheme != nil else { continue }
            let badge = ReadmeBadge(altText: alt, imageURL: image, linkURL: link)
            if onlyKnownHosts, !badge.isKnownBadgeHost { continue }
            guard seen.insert(badge.id).inserted else { continue }
            found.append(badge)
        }
        return found
    }

    /// 対応する閉じ括弧の位置。入れ子も数える。
    private static func close(_ characters: [Character], from start: Int,
                              open: Character, shut: Character) -> Int? {
        var depth = 0
        var index = start
        while index < characters.count {
            if characters[index] == open { depth += 1 }
            else if characters[index] == shut {
                depth -= 1
                if depth == 0 { return index }
            }
            else if characters[index] == "\n", depth > 0 { return nil }
            index += 1
        }
        return nil
    }
}
