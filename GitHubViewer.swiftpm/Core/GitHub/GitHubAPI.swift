import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// GitHub REST API の読み取り系。JSON の形は `GitHubModels.swift` の型に移し替える。
extension GitHubClient {

    // MARK: - 下請け

    /// JSON を取って型に直す。
    func fetchJSON<T: Decodable>(_ type: T.Type, path: String,
                                 query: [String: String] = [:]) async throws -> T {
        let data = try await get(apiURL(path, query: query),
                                 accept: "application/vnd.github+json")
        return try decode(type, from: data)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubClientError.badResponse
        }
    }

    /// 1 ページぶんの JSON 配列を取る。
    private func page<T: Decodable>(_ type: [T].Type, _ path: String,
                                    _ query: [String: String]) async throws -> [T] {
        let data = try await get(apiURL(path, query: query),
                                 accept: "application/vnd.github+json")
        return try decode([T].self, from: data)
    }

    /// ページ番号つきの問い合わせ用の共通パラメータ。
    static func pageQuery(page: Int, perPage: Int,
                          extra: [String: String] = [:]) -> [String: String] {
        var query = extra
        query["page"] = String(Swift.max(1, page))
        query["per_page"] = String(Swift.min(100, Swift.max(1, perPage)))
        return query
    }

    // MARK: - 61. ブランチ

    /// ブランチの一覧。
    public func branches(owner: String, repo: String, page: Int = 1,
                         perPage: Int = 100) async throws -> [GitBranch] {
        let items = try await self.page([BranchJSON].self,
                                        "/repos/\(owner)/\(repo)/branches",
                                        Self.pageQuery(page: page, perPage: perPage))
        return items.map {
            GitBranch(name: $0.name, sha: $0.commit.sha, isProtected: $0.protected ?? false)
        }
    }

    // MARK: - 62. タグとリリース

    /// タグの一覧。
    public func tags(owner: String, repo: String, page: Int = 1,
                     perPage: Int = 100) async throws -> [GitTag] {
        let items = try await self.page([TagJSON].self, "/repos/\(owner)/\(repo)/tags",
                                        Self.pageQuery(page: page, perPage: perPage))
        return items.map { GitTag(name: $0.name, sha: $0.commit.sha) }
    }

    /// リリースの一覧。
    public func releases(owner: String, repo: String, page: Int = 1,
                         perPage: Int = 30) async throws -> [GitRelease] {
        let items = try await self.page([ReleaseJSON].self,
                                        "/repos/\(owner)/\(repo)/releases",
                                        Self.pageQuery(page: page, perPage: perPage))
        return items.map { $0.model }
    }

    // MARK: - 63. コミット履歴 / 65. ファイル単位の履歴

    /// コミットの一覧。`path` を渡すとそのファイルの履歴になる。
    public func commits(owner: String, repo: String, ref: String? = nil,
                        path: String? = nil, page: Int = 1,
                        perPage: Int = 30) async throws -> [GitCommit] {
        var extra: [String: String] = [:]
        if let ref, !ref.isEmpty { extra["sha"] = ref }
        if let path, !path.isEmpty { extra["path"] = path }
        let items = try await self.page([CommitJSON].self,
                                        "/repos/\(owner)/\(repo)/commits",
                                        Self.pageQuery(page: page, perPage: perPage,
                                                       extra: extra))
        return items.map { $0.model }
    }

    // MARK: - 64. コミットの差分

    /// コミット 1 つの詳細 (変更ファイルつき)。
    public func commit(owner: String, repo: String,
                       sha: String) async throws -> GitCommitDetail {
        let json = try await fetchJSON(CommitDetailJSON.self,
                                       path: "/repos/\(owner)/\(repo)/commits/\(sha)")
        return json.model
    }

    /// 2 つの地点の差分。
    public func compare(owner: String, repo: String, base: String,
                        head: String) async throws -> [GitFileChange] {
        let json = try await fetchJSON(
            CompareJSON.self,
            path: "/repos/\(owner)/\(repo)/compare/\(base)...\(head)")
        return json.files?.map { $0.model } ?? []
    }

    // MARK: - 66. blame

    /// blame を GraphQL で取る。行の本文は渡された内容から補う。
    public func blame(owner: String, repo: String, ref: String, path: String,
                      fileText: String) async throws -> [BlameLine] {
        let query = """
        query($owner:String!,$repo:String!,$ref:String!,$path:String!){\
        repository(owner:$owner,name:$repo){object(expression:$ref){\
        ... on Commit{blame(path:$path){ranges{startingLine endingLine commit{\
        oid committedDate author{name}}}}}}}}
        """
        let variables: [String: String] = ["owner": owner, "repo": repo,
                                           "ref": ref, "path": path]
        let data = try await graphQL(query: query, variables: variables)
        let response = try decode(BlameResponse.self, from: data)
        guard let ranges = response.data?.repository?.object?.blame?.ranges else {
            throw GitHubClientError.badResponse
        }

        let lines = fileText.components(separatedBy: "\n")
        var result: [BlameLine] = []
        for range in ranges {
            for number in range.startingLine...Swift.max(range.startingLine,
                                                         range.endingLine) {
                let text = number - 1 < lines.count ? lines[number - 1] : ""
                result.append(BlameLine(lineNumber: number, text: text,
                                        commitSHA: range.commit.oid,
                                        authorName: range.commit.author?.name ?? "",
                                        date: GitHubDate.parse(range.commit.committedDate)))
            }
        }
        return result.sorted { $0.lineNumber < $1.lineNumber }
    }

    /// GraphQL に問い合わせる。
    public func graphQL(query: String,
                        variables: [String: String] = [:]) async throws -> Data {
        var payload: [String: Any] = ["query": query]
        if !variables.isEmpty { payload["variables"] = variables }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let host = apiHost == "api.github.com" ? "api.github.com/graphql"
                                               : "\(apiHost)/api/graphql"
        guard let url = URL(string: "https://\(host)") else {
            throw GitHubClientError.badResponse
        }
        return try await send(url, method: "POST", accept: "application/json",
                              body: body).0
    }

    // MARK: - 67. Issue

    /// Issue の一覧。Pull Request も混ざるので `includePullRequests` で選ぶ。
    public func issues(owner: String, repo: String, state: String = "open",
                       labels: [String] = [], includePullRequests: Bool = false,
                       page: Int = 1, perPage: Int = 30) async throws -> [GitIssue] {
        var extra = ["state": state]
        if !labels.isEmpty { extra["labels"] = labels.joined(separator: ",") }
        let items = try await self.page([IssueJSON].self,
                                        "/repos/\(owner)/\(repo)/issues",
                                        Self.pageQuery(page: page, perPage: perPage,
                                                       extra: extra))
        let models = items.map { $0.model }
        return includePullRequests ? models : models.filter { !$0.isPullRequest }
    }

    /// Issue 1 件。
    public func issue(owner: String, repo: String, number: Int) async throws -> GitIssue {
        try await fetchJSON(IssueJSON.self,
                            path: "/repos/\(owner)/\(repo)/issues/\(number)").model
    }

    /// Issue のコメント。
    public func comments(owner: String, repo: String, issue number: Int,
                         page: Int = 1, perPage: Int = 100) async throws -> [GitComment] {
        let items = try await self.page([CommentJSON].self,
                                        "/repos/\(owner)/\(repo)/issues/\(number)/comments",
                                        Self.pageQuery(page: page, perPage: perPage))
        return items.map { $0.model }
    }

    // MARK: - 69. Pull Request

    /// Pull Request の一覧。
    public func pullRequests(owner: String, repo: String, state: String = "open",
                             page: Int = 1,
                             perPage: Int = 30) async throws -> [GitPullRequest] {
        let items = try await self.page([PullRequestJSON].self,
                                        "/repos/\(owner)/\(repo)/pulls",
                                        Self.pageQuery(page: page, perPage: perPage,
                                                       extra: ["state": state]))
        return items.map { $0.model }
    }

    /// Pull Request 1 件 (差分の数まで入る)。
    public func pullRequest(owner: String, repo: String,
                            number: Int) async throws -> GitPullRequest {
        try await fetchJSON(PullRequestJSON.self,
                            path: "/repos/\(owner)/\(repo)/pulls/\(number)").model
    }

    // MARK: - 70. PR の差分

    /// Pull Request で変わったファイル。
    public func pullRequestFiles(owner: String, repo: String, number: Int,
                                 page: Int = 1,
                                 perPage: Int = 100) async throws -> [GitFileChange] {
        let items = try await self.page([FileChangeJSON].self,
                                        "/repos/\(owner)/\(repo)/pulls/\(number)/files",
                                        Self.pageQuery(page: page, perPage: perPage))
        return items.map { $0.model }
    }

    // MARK: - 71. レビューコメント

    /// Pull Request のレビューコメント (行についたもの)。
    public func reviewComments(owner: String, repo: String, number: Int,
                               page: Int = 1,
                               perPage: Int = 100) async throws -> [GitComment] {
        let items = try await self.page([CommentJSON].self,
                                        "/repos/\(owner)/\(repo)/pulls/\(number)/comments",
                                        Self.pageQuery(page: page, perPage: perPage))
        return items.map { $0.model }
    }

    // MARK: - 73. リポジトリ概要

    /// リポジトリの概要。
    public func repository(owner: String, repo: String) async throws -> GitRepository {
        try await fetchJSON(RepositoryJSON.self, path: "/repos/\(owner)/\(repo)").model
    }

    /// 言語ごとのバイト数。
    public func languages(owner: String,
                          repo: String) async throws -> [(name: String, bytes: Int)] {
        let data = try await get(apiURL("/repos/\(owner)/\(repo)/languages"),
                                 accept: "application/vnd.github+json")
        let map = try decode([String: Int].self, from: data)
        return map.sorted { $0.value > $1.value }.map { (name: $0.key, bytes: $0.value) }
    }

    /// 参加者の多い順のユーザー。
    public func contributors(owner: String, repo: String,
                             perPage: Int = 10) async throws -> [GitUser] {
        let items = try await self.page([UserJSON].self,
                                        "/repos/\(owner)/\(repo)/contributors",
                                        Self.pageQuery(page: 1, perPage: perPage))
        return items.map { $0.model }
    }

    // MARK: - 75. Gist 一覧

    /// 自分の Gist。
    public func myGists(page: Int = 1, perPage: Int = 30) async throws -> [GitGist] {
        let items = try await self.page([GistJSON].self, "/gists",
                                        Self.pageQuery(page: page, perPage: perPage))
        return items.map { $0.model }
    }

    /// 誰かの公開 Gist。
    public func gists(user login: String, page: Int = 1,
                      perPage: Int = 30) async throws -> [GitGist] {
        let items = try await self.page([GistJSON].self, "/users/\(login)/gists",
                                        Self.pageQuery(page: page, perPage: perPage))
        return items.map { $0.model }
    }

    // MARK: - 76 / 77. スターと自分のリポジトリ

    /// スターを付けたリポジトリ。
    public func starredRepositories(page: Int = 1,
                                    perPage: Int = 30) async throws -> [GitRepository] {
        let items = try await self.page([RepositoryJSON].self, "/user/starred",
                                        Self.pageQuery(page: page, perPage: perPage))
        return items.map { $0.model }
    }

    /// 自分のリポジトリ。
    public func myRepositories(sort: String = "updated", page: Int = 1,
                               perPage: Int = 30) async throws -> [GitRepository] {
        let items = try await self.page([RepositoryJSON].self, "/user/repos",
                                        Self.pageQuery(page: page, perPage: perPage,
                                                       extra: ["sort": sort]))
        return items.map { $0.model }
    }

    /// 誰かの公開リポジトリ。
    public func repositories(user login: String, sort: String = "updated",
                             page: Int = 1,
                             perPage: Int = 30) async throws -> [GitRepository] {
        let items = try await self.page([RepositoryJSON].self, "/users/\(login)/repos",
                                        Self.pageQuery(page: page, perPage: perPage,
                                                       extra: ["sort": sort]))
        return items.map { $0.model }
    }

    // MARK: - 78. 検索

    /// リポジトリを探す。
    public func searchRepositories(_ text: String, sort: String? = nil, page: Int = 1,
                                   perPage: Int = 30) async throws -> [GitRepository] {
        var extra = ["q": text]
        if let sort { extra["sort"] = sort }
        let data = try await get(apiURL("/search/repositories",
                                        query: Self.pageQuery(page: page,
                                                              perPage: perPage,
                                                              extra: extra)),
                                 accept: "application/vnd.github+json")
        let result = try decode(SearchResult<RepositoryJSON>.self, from: data)
        return result.items.map { $0.model }
    }

    /// コードを探す。
    public func searchCode(_ text: String, page: Int = 1,
                           perPage: Int = 30) async throws -> [CodeSearchResult] {
        let data = try await get(apiURL("/search/code",
                                        query: Self.pageQuery(page: page,
                                                              perPage: perPage,
                                                              extra: ["q": text])),
                                 accept: "application/vnd.github+json")
        let result = try decode(SearchResult<CodeSearchJSON>.self, from: data)
        return result.items.map { $0.model }
    }

    // MARK: - 79. ユーザー / Organization

    /// ユーザーの情報。
    public func user(_ login: String) async throws -> GitUser {
        try await fetchJSON(UserJSON.self, path: "/users/\(login)").model
    }

    /// トークンの持ち主。
    public func currentUser() async throws -> GitUser {
        try await fetchJSON(UserJSON.self, path: "/user").model
    }

    // MARK: - 84. Actions

    /// ワークフローの実行一覧。
    public func workflowRuns(owner: String, repo: String, branch: String? = nil,
                             page: Int = 1,
                             perPage: Int = 20) async throws -> [GitWorkflowRun] {
        var extra: [String: String] = [:]
        if let branch, !branch.isEmpty { extra["branch"] = branch }
        let data = try await get(apiURL("/repos/\(owner)/\(repo)/actions/runs",
                                        query: Self.pageQuery(page: page,
                                                              perPage: perPage,
                                                              extra: extra)),
                                 accept: "application/vnd.github+json")
        let result = try decode(WorkflowRunsJSON.self, from: data)
        return result.workflow_runs.map { $0.model }
    }

    /// 実行 1 つのジョブ。
    public func workflowJobs(owner: String, repo: String,
                             runID: Int) async throws -> [GitWorkflowJob] {
        let data = try await get(
            apiURL("/repos/\(owner)/\(repo)/actions/runs/\(runID)/jobs",
                   query: ["per_page": "100"]),
            accept: "application/vnd.github+json")
        let result = try decode(WorkflowJobsJSON.self, from: data)
        return result.jobs.map { $0.model }
    }

    // MARK: - 85. Actions のログ

    /// ジョブのログ (プレーンテキスト)。
    public func jobLog(owner: String, repo: String, jobID: Int) async throws -> String {
        let data = try await get(
            apiURL("/repos/\(owner)/\(repo)/actions/jobs/\(jobID)/logs"), accept: nil)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 89. レート制限

    /// いまのレート制限を問い合わせる。
    public func rateLimit() async throws -> RateLimitStatus {
        let json = try await fetchJSON(RateLimitJSON.self, path: "/rate_limit")
        let core = json.resources.core
        return RateLimitStatus(limit: core.limit, remaining: core.remaining,
                               resetDate: Date(timeIntervalSince1970: Double(core.reset)))
    }

    // MARK: - 92. 通知

    /// 通知の一覧。
    public func notifications(all: Bool = false, page: Int = 1,
                              perPage: Int = 30) async throws -> [GitNotification] {
        let items = try await self.page(
            [NotificationJSON].self, "/notifications",
            Self.pageQuery(page: page, perPage: perPage,
                           extra: ["all": all ? "true" : "false"]))
        return items.map { $0.model }
    }

    /// 通知を既読にする。
    public func markNotificationRead(id: String) async throws {
        try await send(apiURL("/notifications/threads/\(id)"), method: "PATCH",
                       accept: "application/vnd.github+json", body: nil)
    }

    // MARK: - 93. Star / Watch

    /// スターを付けているか。
    public func isStarred(owner: String, repo: String) async throws -> Bool {
        do {
            let (_, http) = try await send(apiURL("/user/starred/\(owner)/\(repo)"),
                                           method: "GET",
                                           accept: "application/vnd.github+json",
                                           body: nil)
            return http.statusCode == 204
        } catch GitHubClientError.notFound {
            return false
        }
    }

    /// スターを付ける / 外す。
    public func setStar(_ starred: Bool, owner: String, repo: String) async throws {
        try await send(apiURL("/user/starred/\(owner)/\(repo)"),
                       method: starred ? "PUT" : "DELETE",
                       accept: "application/vnd.github+json", body: nil)
    }

    /// Watch を付ける / 外す。
    public func setWatch(_ watching: Bool, owner: String, repo: String) async throws {
        if watching {
            let body = try JSONSerialization.data(
                withJSONObject: ["subscribed": true, "ignored": false])
            try await send(apiURL("/repos/\(owner)/\(repo)/subscription"), method: "PUT",
                           accept: "application/vnd.github+json", body: body)
        } else {
            try await send(apiURL("/repos/\(owner)/\(repo)/subscription"),
                           method: "DELETE", accept: "application/vnd.github+json",
                           body: nil)
        }
    }

    /// Watch しているか。
    public func isWatching(owner: String, repo: String) async throws -> Bool {
        do {
            let json = try await fetchJSON(SubscriptionJSON.self,
                                           path: "/repos/\(owner)/\(repo)/subscription")
            return json.subscribed
        } catch GitHubClientError.notFound {
            return false
        }
    }
}

/// Actions のジョブ。
public struct GitWorkflowJob: Identifiable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var status: String
    public var conclusion: String?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(id: Int, name: String, status: String, conclusion: String?,
                startedAt: Date?, completedAt: Date?) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// かかった時間 (秒)。
    public var duration: TimeInterval? {
        guard let startedAt, let completedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }
}

// MARK: - JSON の形

struct BranchJSON: Decodable {
    struct Commit: Decodable { let sha: String }
    let name: String
    let commit: Commit
    let protected: Bool?
}

struct TagJSON: Decodable {
    struct Commit: Decodable { let sha: String }
    let name: String
    let commit: Commit
}

struct ReleaseJSON: Decodable {
    let id: Int
    let tag_name: String
    let name: String?
    let body: String?
    let prerelease: Bool?
    let published_at: String?
    let html_url: String?

    var model: GitRelease {
        GitRelease(id: id, tagName: tag_name, name: name ?? tag_name, body: body ?? "",
                   isPrerelease: prerelease ?? false,
                   publishedAt: GitHubDate.parse(published_at),
                   htmlURL: html_url.flatMap(URL.init(string:)))
    }
}

struct AuthorJSON: Decodable {
    let login: String?
    let avatar_url: String?
}

struct CommitJSON: Decodable {
    struct Inner: Decodable {
        struct Person: Decodable {
            let name: String?
            let date: String?
        }
        let message: String
        let author: Person?
    }
    let sha: String
    let commit: Inner
    let author: AuthorJSON?
    let html_url: String?

    var model: GitCommit {
        GitCommit(sha: sha, message: commit.message,
                  authorName: commit.author?.name ?? author?.login ?? "",
                  authorLogin: author?.login,
                  authorAvatarURL: author?.avatar_url.flatMap(URL.init(string:)),
                  date: GitHubDate.parse(commit.author?.date),
                  htmlURL: html_url.flatMap(URL.init(string:)))
    }
}

struct FileChangeJSON: Decodable {
    let filename: String
    let status: String?
    let additions: Int?
    let deletions: Int?
    let patch: String?

    var model: GitFileChange {
        GitFileChange(filename: filename, status: status ?? "modified",
                      additions: additions ?? 0, deletions: deletions ?? 0, patch: patch)
    }
}

struct CommitDetailJSON: Decodable {
    struct Stats: Decodable {
        let additions: Int?
        let deletions: Int?
    }
    let sha: String
    let commit: CommitJSON.Inner
    let author: AuthorJSON?
    let html_url: String?
    let stats: Stats?
    let files: [FileChangeJSON]?

    var model: GitCommitDetail {
        let base = GitCommit(sha: sha, message: commit.message,
                             authorName: commit.author?.name ?? author?.login ?? "",
                             authorLogin: author?.login,
                             authorAvatarURL: author?.avatar_url
                                 .flatMap(URL.init(string:)),
                             date: GitHubDate.parse(commit.author?.date),
                             htmlURL: html_url.flatMap(URL.init(string:)))
        let changes = files?.map { $0.model } ?? []
        return GitCommitDetail(
            commit: base, files: changes,
            additions: stats?.additions ?? changes.reduce(0) { $0 + $1.additions },
            deletions: stats?.deletions ?? changes.reduce(0) { $0 + $1.deletions })
    }
}

struct CompareJSON: Decodable {
    let files: [FileChangeJSON]?
}

struct LabelJSON: Decodable {
    let name: String
}

struct IssueJSON: Decodable {
    struct PullMarker: Decodable { let url: String? }
    let number: Int
    let title: String
    let body: String?
    let state: String
    let user: AuthorJSON?
    let created_at: String?
    let updated_at: String?
    let comments: Int?
    let labels: [LabelJSON]?
    let html_url: String?
    let pull_request: PullMarker?

    var model: GitIssue {
        GitIssue(number: number, title: title, body: body ?? "", state: state,
                 authorLogin: user?.login ?? "",
                 authorAvatarURL: user?.avatar_url.flatMap(URL.init(string:)),
                 createdAt: GitHubDate.parse(created_at),
                 updatedAt: GitHubDate.parse(updated_at), commentCount: comments ?? 0,
                 labels: labels?.map(\.name) ?? [],
                 htmlURL: html_url.flatMap(URL.init(string:)),
                 isPullRequest: pull_request != nil)
    }
}

struct CommentJSON: Decodable {
    let id: Int
    let user: AuthorJSON?
    let body: String?
    let created_at: String?
    let path: String?
    let line: Int?
    let original_line: Int?

    var model: GitComment {
        GitComment(id: id, authorLogin: user?.login ?? "",
                   authorAvatarURL: user?.avatar_url.flatMap(URL.init(string:)),
                   body: body ?? "", createdAt: GitHubDate.parse(created_at),
                   path: path, line: line ?? original_line)
    }
}

struct PullRequestJSON: Decodable {
    struct Side: Decodable { let ref: String }
    let number: Int
    let title: String
    let body: String?
    let state: String
    let user: AuthorJSON?
    let created_at: String?
    let updated_at: String?
    let comments: Int?
    let labels: [LabelJSON]?
    let html_url: String?
    let head: Side
    let base: Side
    let draft: Bool?
    let merged: Bool?
    let merged_at: String?
    let additions: Int?
    let deletions: Int?
    let changed_files: Int?

    var model: GitPullRequest {
        let issue = GitIssue(number: number, title: title, body: body ?? "", state: state,
                             authorLogin: user?.login ?? "",
                             authorAvatarURL: user?.avatar_url
                                 .flatMap(URL.init(string:)),
                             createdAt: GitHubDate.parse(created_at),
                             updatedAt: GitHubDate.parse(updated_at),
                             commentCount: comments ?? 0,
                             labels: labels?.map(\.name) ?? [],
                             htmlURL: html_url.flatMap(URL.init(string:)),
                             isPullRequest: true)
        return GitPullRequest(issue: issue, headRef: head.ref, baseRef: base.ref,
                              isDraft: draft ?? false,
                              isMerged: merged ?? (merged_at != nil),
                              additions: additions ?? 0, deletions: deletions ?? 0,
                              changedFiles: changed_files ?? 0)
    }
}

struct LicenseJSON: Decodable {
    let spdx_id: String?
    let name: String?
}

struct RepositoryJSON: Decodable {
    let full_name: String
    let description: String?
    let language: String?
    let stargazers_count: Int?
    let forks_count: Int?
    let subscribers_count: Int?
    let open_issues_count: Int?
    let license: LicenseJSON?
    let default_branch: String?
    let `private`: Bool?
    let fork: Bool?
    let updated_at: String?
    let html_url: String?
    let topics: [String]?

    var model: GitRepository {
        GitRepository(fullName: full_name, description: description ?? "",
                      language: language, stars: stargazers_count ?? 0,
                      forks: forks_count ?? 0, watchers: subscribers_count ?? 0,
                      openIssues: open_issues_count ?? 0,
                      license: license?.spdx_id ?? license?.name,
                      defaultBranch: default_branch ?? "main",
                      isPrivate: `private` ?? false, isFork: fork ?? false,
                      updatedAt: GitHubDate.parse(updated_at),
                      htmlURL: html_url.flatMap(URL.init(string:)),
                      topics: topics ?? [])
    }
}

struct UserJSON: Decodable {
    let login: String
    let name: String?
    let bio: String?
    let avatar_url: String?
    let public_repos: Int?
    let followers: Int?
    let following: Int?
    let html_url: String?

    var model: GitUser {
        GitUser(login: login, name: name, bio: bio,
                avatarURL: avatar_url.flatMap(URL.init(string:)),
                publicRepos: public_repos ?? 0, followers: followers ?? 0,
                following: following ?? 0, htmlURL: html_url.flatMap(URL.init(string:)))
    }
}

struct GistJSON: Decodable {
    struct File: Decodable { let filename: String? }
    let id: String
    let description: String?
    let `public`: Bool?
    let files: [String: File]?
    let html_url: String?
    let updated_at: String?

    var model: GitGist {
        GitGist(id: id, description: description ?? "", isPublic: `public` ?? false,
                files: (files?.keys.map { $0 } ?? []).sorted(),
                htmlURL: html_url.flatMap(URL.init(string:)),
                updatedAt: GitHubDate.parse(updated_at))
    }
}

struct SearchResult<Item: Decodable>: Decodable {
    let total_count: Int?
    let items: [Item]
}

struct CodeSearchJSON: Decodable {
    struct Repo: Decodable { let full_name: String }
    struct Match: Decodable { let fragment: String? }
    struct TextMatch: Decodable { let fragment: String? }
    let path: String
    let repository: Repo
    let html_url: String?
    let text_matches: [TextMatch]?

    var model: CodeSearchResult {
        CodeSearchResult(path: path, repositoryName: repository.full_name,
                         htmlURL: html_url.flatMap(URL.init(string:)),
                         fragments: text_matches?.compactMap(\.fragment) ?? [])
    }
}

struct WorkflowRunsJSON: Decodable {
    let workflow_runs: [WorkflowRunJSON]
}

struct WorkflowRunJSON: Decodable {
    let id: Int
    let name: String?
    let status: String?
    let conclusion: String?
    let head_branch: String?
    let created_at: String?
    let html_url: String?
    let display_title: String?

    var model: GitWorkflowRun {
        GitWorkflowRun(id: id, name: name ?? "workflow", status: status ?? "",
                       conclusion: conclusion, branch: head_branch ?? "",
                       commitMessage: display_title ?? "",
                       createdAt: GitHubDate.parse(created_at),
                       htmlURL: html_url.flatMap(URL.init(string:)))
    }
}

struct WorkflowJobsJSON: Decodable {
    let jobs: [WorkflowJobJSON]
}

struct WorkflowJobJSON: Decodable {
    let id: Int
    let name: String?
    let status: String?
    let conclusion: String?
    let started_at: String?
    let completed_at: String?

    var model: GitWorkflowJob {
        GitWorkflowJob(id: id, name: name ?? "job", status: status ?? "",
                       conclusion: conclusion, startedAt: GitHubDate.parse(started_at),
                       completedAt: GitHubDate.parse(completed_at))
    }
}

struct NotificationJSON: Decodable {
    struct Subject: Decodable {
        let title: String
        let type: String?
    }
    struct Repo: Decodable { let full_name: String }
    let id: String
    let subject: Subject
    let repository: Repo
    let reason: String?
    let unread: Bool?
    let updated_at: String?

    var model: GitNotification {
        GitNotification(id: id, title: subject.title,
                        repositoryName: repository.full_name, reason: reason ?? "",
                        isUnread: unread ?? false,
                        updatedAt: GitHubDate.parse(updated_at),
                        subjectType: subject.type ?? "")
    }
}

struct SubscriptionJSON: Decodable {
    let subscribed: Bool
}

struct RateLimitJSON: Decodable {
    struct Resources: Decodable { let core: Core }
    struct Core: Decodable {
        let limit: Int
        let remaining: Int
        let reset: Int
    }
    let resources: Resources
}

struct BlameResponse: Decodable {
    struct Root: Decodable { let repository: Repository? }
    struct Repository: Decodable { let object: Object? }
    struct Object: Decodable { let blame: Blame? }
    struct Blame: Decodable { let ranges: [Range] }
    struct Range: Decodable {
        let startingLine: Int
        let endingLine: Int
        let commit: Commit
    }
    struct Commit: Decodable {
        struct Author: Decodable { let name: String? }
        let oid: String
        let committedDate: String?
        let author: Author?
    }
    let data: Root?
}
