import Foundation

/// ブランチ。
public struct GitBranch: Identifiable, Equatable, Sendable {
    public var name: String
    public var sha: String
    public var isProtected: Bool

    public var id: String { name }

    public init(name: String, sha: String, isProtected: Bool = false) {
        self.name = name
        self.sha = sha
        self.isProtected = isProtected
    }
}

/// タグ。
public struct GitTag: Identifiable, Equatable, Sendable {
    public var name: String
    public var sha: String

    public var id: String { name }

    public init(name: String, sha: String) {
        self.name = name
        self.sha = sha
    }
}

/// リリース。
public struct GitRelease: Identifiable, Equatable, Sendable {
    public var id: Int
    public var tagName: String
    public var name: String
    public var body: String
    public var isPrerelease: Bool
    public var publishedAt: Date?
    public var htmlURL: URL?

    public init(id: Int, tagName: String, name: String, body: String,
                isPrerelease: Bool, publishedAt: Date?, htmlURL: URL?) {
        self.id = id
        self.tagName = tagName
        self.name = name
        self.body = body
        self.isPrerelease = isPrerelease
        self.publishedAt = publishedAt
        self.htmlURL = htmlURL
    }
}

/// コミット 1 つぶん。
public struct GitCommit: Identifiable, Equatable, Sendable {
    public var sha: String
    public var message: String
    public var authorName: String
    public var authorLogin: String?
    public var authorAvatarURL: URL?
    public var date: Date?
    public var htmlURL: URL?

    public var id: String { sha }

    /// コミットメッセージの 1 行目。
    public var summary: String {
        message.components(separatedBy: "\n").first ?? message
    }

    /// 短い SHA。
    public var shortSHA: String { String(sha.prefix(7)) }

    public init(sha: String, message: String, authorName: String,
                authorLogin: String? = nil, authorAvatarURL: URL? = nil,
                date: Date? = nil, htmlURL: URL? = nil) {
        self.sha = sha
        self.message = message
        self.authorName = authorName
        self.authorLogin = authorLogin
        self.authorAvatarURL = authorAvatarURL
        self.date = date
        self.htmlURL = htmlURL
    }
}

/// コミットや PR で変わったファイル。
public struct GitFileChange: Identifiable, Equatable, Sendable {
    public var filename: String
    public var status: String
    public var additions: Int
    public var deletions: Int
    /// unified diff の本文 (GitHub が返す `patch`)。
    public var patch: String?

    public var id: String { filename }

    public init(filename: String, status: String, additions: Int, deletions: Int,
                patch: String?) {
        self.filename = filename
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
    }

    /// 差分の行に分解する。
    public var diffLines: [DiffLine] {
        guard let patch else { return [] }
        return GitPatchParser.lines(from: patch)
    }
}

/// コミットの詳細 (変更ファイルつき)。
public struct GitCommitDetail: Equatable, Sendable {
    public var commit: GitCommit
    public var files: [GitFileChange]
    public var additions: Int
    public var deletions: Int

    public init(commit: GitCommit, files: [GitFileChange], additions: Int,
                deletions: Int) {
        self.commit = commit
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }
}

/// Issue と Pull Request で共通の中身。
public struct GitIssue: Identifiable, Equatable, Sendable {
    public var number: Int
    public var title: String
    public var body: String
    public var state: String
    public var authorLogin: String
    public var authorAvatarURL: URL?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var commentCount: Int
    public var labels: [String]
    public var htmlURL: URL?
    /// Pull Request なら true。
    public var isPullRequest: Bool

    public var id: Int { number }

    public var isOpen: Bool { state == "open" }

    public init(number: Int, title: String, body: String, state: String,
                authorLogin: String, authorAvatarURL: URL? = nil,
                createdAt: Date? = nil, updatedAt: Date? = nil, commentCount: Int = 0,
                labels: [String] = [], htmlURL: URL? = nil, isPullRequest: Bool = false) {
        self.number = number
        self.title = title
        self.body = body
        self.state = state
        self.authorLogin = authorLogin
        self.authorAvatarURL = authorAvatarURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.commentCount = commentCount
        self.labels = labels
        self.htmlURL = htmlURL
        self.isPullRequest = isPullRequest
    }
}

/// Issue / PR のコメント。
public struct GitComment: Identifiable, Equatable, Sendable {
    public var id: Int
    public var authorLogin: String
    public var authorAvatarURL: URL?
    public var body: String
    public var createdAt: Date?
    /// レビューコメントのときの位置。
    public var path: String?
    public var line: Int?

    public init(id: Int, authorLogin: String, authorAvatarURL: URL? = nil, body: String,
                createdAt: Date? = nil, path: String? = nil, line: Int? = nil) {
        self.id = id
        self.authorLogin = authorLogin
        self.authorAvatarURL = authorAvatarURL
        self.body = body
        self.createdAt = createdAt
        self.path = path
        self.line = line
    }
}

/// Pull Request の追加情報。
public struct GitPullRequest: Identifiable, Equatable, Sendable {
    public var issue: GitIssue
    public var headRef: String
    public var baseRef: String
    public var isDraft: Bool
    public var isMerged: Bool
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int

    public var id: Int { issue.number }

    public init(issue: GitIssue, headRef: String, baseRef: String, isDraft: Bool,
                isMerged: Bool, additions: Int = 0, deletions: Int = 0,
                changedFiles: Int = 0) {
        self.issue = issue
        self.headRef = headRef
        self.baseRef = baseRef
        self.isDraft = isDraft
        self.isMerged = isMerged
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
    }
}

/// リポジトリの概要。
public struct GitRepository: Identifiable, Equatable, Sendable {
    public var fullName: String
    public var description: String
    public var language: String?
    public var stars: Int
    public var forks: Int
    public var watchers: Int
    public var openIssues: Int
    public var license: String?
    public var defaultBranch: String
    public var isPrivate: Bool
    public var isFork: Bool
    public var updatedAt: Date?
    public var htmlURL: URL?
    public var topics: [String]

    public var id: String { fullName }

    public var owner: String { fullName.components(separatedBy: "/").first ?? "" }
    public var name: String { fullName.components(separatedBy: "/").last ?? fullName }

    public init(fullName: String, description: String = "", language: String? = nil,
                stars: Int = 0, forks: Int = 0, watchers: Int = 0, openIssues: Int = 0,
                license: String? = nil, defaultBranch: String = "main",
                isPrivate: Bool = false, isFork: Bool = false, updatedAt: Date? = nil,
                htmlURL: URL? = nil, topics: [String] = []) {
        self.fullName = fullName
        self.description = description
        self.language = language
        self.stars = stars
        self.forks = forks
        self.watchers = watchers
        self.openIssues = openIssues
        self.license = license
        self.defaultBranch = defaultBranch
        self.isPrivate = isPrivate
        self.isFork = isFork
        self.updatedAt = updatedAt
        self.htmlURL = htmlURL
        self.topics = topics
    }
}

/// 利用者 / Organization。
public struct GitUser: Identifiable, Equatable, Sendable {
    public var login: String
    public var name: String?
    public var bio: String?
    public var avatarURL: URL?
    public var publicRepos: Int
    public var followers: Int
    public var following: Int
    public var htmlURL: URL?

    public var id: String { login }

    public init(login: String, name: String? = nil, bio: String? = nil,
                avatarURL: URL? = nil, publicRepos: Int = 0, followers: Int = 0,
                following: Int = 0, htmlURL: URL? = nil) {
        self.login = login
        self.name = name
        self.bio = bio
        self.avatarURL = avatarURL
        self.publicRepos = publicRepos
        self.followers = followers
        self.following = following
        self.htmlURL = htmlURL
    }
}

/// Gist。
public struct GitGist: Identifiable, Equatable, Sendable {
    public var id: String
    public var description: String
    public var isPublic: Bool
    public var files: [String]
    public var htmlURL: URL?
    public var updatedAt: Date?

    public init(id: String, description: String, isPublic: Bool, files: [String],
                htmlURL: URL? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.description = description
        self.isPublic = isPublic
        self.files = files
        self.htmlURL = htmlURL
        self.updatedAt = updatedAt
    }
}

/// GitHub Actions の実行。
public struct GitWorkflowRun: Identifiable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var status: String
    public var conclusion: String?
    public var branch: String
    public var commitMessage: String
    public var createdAt: Date?
    public var htmlURL: URL?

    public init(id: Int, name: String, status: String, conclusion: String?,
                branch: String, commitMessage: String, createdAt: Date?, htmlURL: URL?) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.branch = branch
        self.commitMessage = commitMessage
        self.createdAt = createdAt
        self.htmlURL = htmlURL
    }

    /// 表示用の記号。
    public var symbol: String {
        switch conclusion {
        case "success": return "✓"
        case "failure": return "✗"
        case "cancelled": return "－"
        case "skipped": return "⤼"
        default: return status == "in_progress" ? "…" : "•"
        }
    }
}

/// 通知。
public struct GitNotification: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var repositoryName: String
    public var reason: String
    public var isUnread: Bool
    public var updatedAt: Date?
    public var subjectType: String

    public init(id: String, title: String, repositoryName: String, reason: String,
                isUnread: Bool, updatedAt: Date?, subjectType: String) {
        self.id = id
        self.title = title
        self.repositoryName = repositoryName
        self.reason = reason
        self.isUnread = isUnread
        self.updatedAt = updatedAt
        self.subjectType = subjectType
    }
}

/// API のレート制限。
public struct RateLimitStatus: Equatable, Sendable {
    public var limit: Int
    public var remaining: Int
    public var resetDate: Date?

    public init(limit: Int, remaining: Int, resetDate: Date?) {
        self.limit = limit
        self.remaining = remaining
        self.resetDate = resetDate
    }

    public var used: Int { Swift.max(0, limit - remaining) }

    /// 残りの割合 (0〜1)。
    public var fraction: Double {
        guard limit > 0 else { return 1 }
        return Double(remaining) / Double(limit)
    }

    /// 残りが少ないか。
    public var isLow: Bool { fraction < 0.2 }

    /// 「あと 42 回 (13:05 に回復)」のような説明。
    public var description: String {
        var text = "あと \(remaining) / \(limit) 回"
        if let resetDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            text += " (\(formatter.string(from: resetDate)) に回復)"
        }
        return text
    }

    /// 応答のヘッダから読み取る。
    public static func from(headers: [String: String]) -> RateLimitStatus? {
        func value(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name }?.value
        }
        guard let limitText = value("x-ratelimit-limit"),
              let remainingText = value("x-ratelimit-remaining"),
              let limit = Int(limitText), let remaining = Int(remainingText) else {
            return nil
        }
        var reset: Date?
        if let resetText = value("x-ratelimit-reset"), let seconds = Double(resetText) {
            reset = Date(timeIntervalSince1970: seconds)
        }
        return RateLimitStatus(limit: limit, remaining: remaining, resetDate: reset)
    }
}

/// blame の 1 行。
public struct BlameLine: Equatable, Sendable {
    public var lineNumber: Int
    public var text: String
    public var commitSHA: String
    public var authorName: String
    public var date: Date?

    public init(lineNumber: Int, text: String, commitSHA: String, authorName: String,
                date: Date?) {
        self.lineNumber = lineNumber
        self.text = text
        self.commitSHA = commitSHA
        self.authorName = authorName
        self.date = date
    }

    public var shortSHA: String { String(commitSHA.prefix(7)) }
}

/// コード検索の結果 1 件。
public struct CodeSearchResult: Identifiable, Equatable, Sendable {
    public var path: String
    public var repositoryName: String
    public var htmlURL: URL?
    /// 一致した行 (GitHub が返すとき)。
    public var fragments: [String]

    public var id: String { repositoryName + "/" + path }

    public init(path: String, repositoryName: String, htmlURL: URL? = nil,
                fragments: [String] = []) {
        self.path = path
        self.repositoryName = repositoryName
        self.htmlURL = htmlURL
        self.fragments = fragments
    }
}

/// GitHub が返す `patch` を差分の行に直す。
public enum GitPatchParser {
    public static func lines(from patch: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var oldLine = 0
        var newLine = 0

        for raw in patch.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                // `@@ -12,7 +12,9 @@`
                let parts = raw.components(separatedBy: " ")
                for part in parts {
                    if part.hasPrefix("-"), let value = Int(part.dropFirst()
                        .components(separatedBy: ",").first ?? "") {
                        oldLine = value
                    }
                    if part.hasPrefix("+"), let value = Int(part.dropFirst()
                        .components(separatedBy: ",").first ?? "") {
                        newLine = value
                    }
                }
                continue
            }
            guard let marker = raw.first else {
                result.append(DiffLine(kind: .unchanged, text: "", oldLine: oldLine,
                                       newLine: newLine))
                oldLine += 1
                newLine += 1
                continue
            }
            let text = String(raw.dropFirst())
            switch marker {
            case "+":
                result.append(DiffLine(kind: .added, text: text, oldLine: nil,
                                       newLine: newLine))
                newLine += 1
            case "-":
                result.append(DiffLine(kind: .removed, text: text, oldLine: oldLine,
                                       newLine: nil))
                oldLine += 1
            case "\\":
                continue    // 「\ No newline at end of file」
            default:
                result.append(DiffLine(kind: .unchanged, text: text, oldLine: oldLine,
                                       newLine: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        return result
    }
}

/// 日付のやりとり。
public enum GitHubDate {
    public static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        return formatter.date(from: text)
    }

    /// 「3 分前」のような表示。
    public static func relative(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "たった今" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 時間前" }
        if seconds < 86400 * 30 { return "\(Int(seconds / 86400)) 日前" }
        if seconds < 86400 * 365 { return "\(Int(seconds / (86400 * 30))) か月前" }
        return "\(Int(seconds / (86400 * 365))) 年前"
    }
}
