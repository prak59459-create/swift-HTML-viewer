import Foundation

/// リポジトリ内の 1 つの場所 (owner/repo + ref + パス) を表す。
public struct GitHubLocation: Equatable, Hashable, Codable, Sendable {
    public var owner: String
    public var repo: String
    /// nil のときはデフォルトブランチ。
    public var ref: String?
    /// リポジトリルートからの相対パス。ルートは "" 。
    public var path: String
    /// URL 上で tree/ と書かれていた等、ディレクトリだと分かっている場合 true。
    public var isDirectory: Bool

    public init(owner: String, repo: String, ref: String? = nil, path: String = "", isDirectory: Bool = false) {
        self.owner = owner
        self.repo = repo
        self.ref = ref
        self.path = path
        self.isDirectory = isDirectory
    }

    /// 1 つ上の階層。ルートに居る場合は nil。
    public var parent: GitHubLocation? {
        guard !path.isEmpty else { return nil }
        var components = path.split(separator: "/").map(String.init)
        components.removeLast()
        var up = self
        up.path = components.joined(separator: "/")
        up.isDirectory = true
        return up
    }

    public var displayName: String {
        let name = path.split(separator: "/").last.map(String.init)
        return name ?? "\(owner)/\(repo)"
    }
}

/// 入力された URL を解決した結果。
public enum GitHubTarget: Equatable, Hashable {
    /// github.com / raw.githubusercontent.com のリポジトリ上の場所。
    case repository(GitHubLocation)
    /// gist.github.com の Gist。
    case gist(id: String)
    /// 上記以外の、そのまま取得する URL (raw リンクや任意の HTML など)。
    case rawURL(URL)
}

public enum GitHubURLError: LocalizedError, Equatable {
    case empty
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "URL が空です。"
        case .unsupported(let input):
            return "この入力は解釈できませんでした: \(input)"
        }
    }
}

/// GitHub の各種 URL 表記を `GitHubTarget` に変換する。
///
/// 対応している書き方:
/// - `https://github.com/owner/repo`
/// - `https://github.com/owner/repo/blob/main/path/to/index.html`
/// - `https://github.com/owner/repo/tree/main/docs`
/// - `https://raw.githubusercontent.com/owner/repo/main/index.html`
/// - `https://gist.github.com/user/<gist id>`
/// - `owner/repo` / `owner/repo/path/to/file` (ホスト名の省略形)
/// - その他の http(s) URL はそのまま取得する
public enum GitHubURLParser {
    public static func parse(_ input: String) throws -> GitHubTarget {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GitHubURLError.empty }

        // 末尾の余計な記号を落とす。
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }

        if !text.contains("://") {
            if text.hasPrefix("github.com/") || text.hasPrefix("www.github.com/")
                || text.hasPrefix("raw.githubusercontent.com/") || text.hasPrefix("gist.github.com/") {
                text = "https://" + text
            } else if let shorthand = parseShorthand(text) {
                return shorthand
            } else {
                throw GitHubURLError.unsupported(input)
            }
        }

        guard let url = URL(string: text), let host = url.host?.lowercased() else {
            throw GitHubURLError.unsupported(input)
        }

        let parts = url.path.split(separator: "/").map(String.init)

        switch host {
        case "github.com", "www.github.com":
            return try parseGitHubDotCom(parts: parts, original: input)
        case "raw.githubusercontent.com", "raw.github.com":
            // owner / repo / ref / path...
            guard parts.count >= 3 else { throw GitHubURLError.unsupported(input) }
            let path = parts.dropFirst(3).joined(separator: "/")
            return .repository(GitHubLocation(owner: parts[0], repo: parts[1], ref: parts[2],
                                              path: path, isDirectory: path.isEmpty))
        case "gist.github.com", "gist.githubusercontent.com":
            guard let id = parts.last, !id.isEmpty else { throw GitHubURLError.unsupported(input) }
            return .gist(id: id)
        default:
            guard url.scheme == "http" || url.scheme == "https" else {
                throw GitHubURLError.unsupported(input)
            }
            return .rawURL(url)
        }
    }

    private static func parseGitHubDotCom(parts: [String], original: String) throws -> GitHubTarget {
        guard parts.count >= 2 else { throw GitHubURLError.unsupported(original) }
        let owner = parts[0]
        let repo = parts[1]
        guard parts.count >= 3 else {
            return .repository(GitHubLocation(owner: owner, repo: repo, isDirectory: true))
        }

        let kind = parts[2]
        switch kind {
        case "blob", "tree", "raw", "blame":
            guard parts.count >= 4 else {
                return .repository(GitHubLocation(owner: owner, repo: repo, isDirectory: true))
            }
            // ref にスラッシュを含むブランチ (feature/foo) は区別できないため、
            // 先頭 1 要素を ref として扱う。
            let ref = parts[3]
            let path = parts.dropFirst(4).joined(separator: "/")
            let isDirectory = (kind == "tree") || path.isEmpty
            return .repository(GitHubLocation(owner: owner, repo: repo, ref: ref,
                                              path: path, isDirectory: isDirectory))
        default:
            // /owner/repo/releases など、ファイルとして扱えないページはリポジトリルートを開く。
            return .repository(GitHubLocation(owner: owner, repo: repo, isDirectory: true))
        }
    }

    /// "owner/repo" や "owner/repo/docs/index.html" のような省略形。
    private static func parseShorthand(_ text: String) -> GitHubTarget? {
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts[0].unicodeScalars.allSatisfy({ allowed.contains($0) }),
              parts[1].unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let path = parts.dropFirst(2).joined(separator: "/")
        return .repository(GitHubLocation(owner: parts[0], repo: parts[1],
                                          path: path, isDirectory: path.isEmpty))
    }
}
