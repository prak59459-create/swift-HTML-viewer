import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// コミットに含める 1 ファイル。
public struct FileEdit: Equatable, Sendable {
    public var path: String
    /// 新しい中身。nil ならそのファイルを消す。
    public var data: Data?

    public init(path: String, data: Data?) {
        self.path = path
        self.data = data
    }

    public init(path: String, text: String) {
        self.init(path: path, data: Data(text.utf8))
    }

    /// 削除を表す。
    public static func removal(path: String) -> FileEdit {
        FileEdit(path: path, data: nil)
    }

    public var isRemoval: Bool { data == nil }
}

/// 書き込みの結果。
public struct CommitResult: Equatable, Sendable {
    public var sha: String
    public var htmlURL: URL?

    public init(sha: String, htmlURL: URL?) {
        self.sha = sha
        self.htmlURL = htmlURL
    }
}

// GitHub REST API の書き込み系。
extension GitHubClient {

    // MARK: - 下請け

    /// JSON を送って、返ってきた JSON を型に直す。
    func post<T: Decodable>(_ type: T.Type, path: String, method: String = "POST",
                            body: [String: Any]) async throws -> T {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await send(apiURL(path), method: method,
                                       accept: "application/vnd.github+json",
                                       body: payload)
        return try decode(type, from: data)
    }

    // MARK: - 68. Issue の作成とコメント

    /// Issue を立てる。
    public func createIssue(owner: String, repo: String, title: String,
                            body: String = "",
                            labels: [String] = []) async throws -> GitIssue {
        var payload: [String: Any] = ["title": title, "body": body]
        if !labels.isEmpty { payload["labels"] = labels }
        return try await post(IssueJSON.self, path: "/repos/\(owner)/\(repo)/issues",
                              body: payload).model
    }

    /// Issue / PR にコメントする。
    public func addComment(owner: String, repo: String, issue number: Int,
                           body: String) async throws -> GitComment {
        try await post(CommentJSON.self,
                       path: "/repos/\(owner)/\(repo)/issues/\(number)/comments",
                       body: ["body": body]).model
    }

    /// Issue を閉じる / 開け直す。
    public func setIssueState(owner: String, repo: String, number: Int,
                              open: Bool) async throws -> GitIssue {
        try await post(IssueJSON.self,
                       path: "/repos/\(owner)/\(repo)/issues/\(number)",
                       method: "PATCH",
                       body: ["state": open ? "open" : "closed"]).model
    }

    // MARK: - 74. Gist として保存

    /// 中身を Gist にする。
    public func createGist(files: [String: String], description: String = "",
                           isPublic: Bool = false) async throws -> GitGist {
        var contents: [String: Any] = [:]
        for (name, text) in files {
            // 空のファイルは GitHub に拒まれるので、空白を 1 つ入れておく。
            contents[name] = ["content": text.isEmpty ? " " : text]
        }
        return try await post(GistJSON.self, path: "/gists",
                              body: ["description": description,
                                     "public": isPublic,
                                     "files": contents]).model
    }

    /// 既存の Gist を書き換える。
    public func updateGist(id: String, files: [String: String],
                           description: String? = nil) async throws -> GitGist {
        var contents: [String: Any] = [:]
        for (name, text) in files {
            contents[name] = ["content": text.isEmpty ? " " : text]
        }
        var payload: [String: Any] = ["files": contents]
        if let description { payload["description"] = description }
        return try await post(GistJSON.self, path: "/gists/\(id)", method: "PATCH",
                              body: payload).model
    }

    // MARK: - 80. 1 ファイルをコミットして push

    /// ファイルの現在の blob SHA を調べる (書き換えに必要)。
    public func fileSHA(owner: String, repo: String, path: String,
                        ref: String) async throws -> String? {
        struct Item: Decodable { let sha: String }
        do {
            let item = try await fetchJSON(
                Item.self, path: "/repos/\(owner)/\(repo)/contents/\(path)",
                query: ["ref": ref])
            return item.sha
        } catch GitHubClientError.notFound {
            return nil    // 新規ファイル。
        }
    }

    /// 1 ファイルをコミットする。`sha` を省くと自動で調べる。
    @discardableResult
    public func commitFile(owner: String, repo: String, path: String, data: Data,
                           message: String, branch: String,
                           sha: String? = nil) async throws -> CommitResult {
        var existing = sha
        if existing == nil {
            existing = try await fileSHA(owner: owner, repo: repo, path: path,
                                         ref: branch)
        }
        var payload: [String: Any] = [
            "message": message,
            "content": data.base64EncodedString(),
            "branch": branch
        ]
        if let existing { payload["sha"] = existing }

        struct Response: Decodable {
            struct Commit: Decodable {
                let sha: String
                let html_url: String?
            }
            let commit: Commit
        }
        let response = try await post(
            Response.self, path: "/repos/\(owner)/\(repo)/contents/\(path)",
            method: "PUT", body: payload)
        return CommitResult(sha: response.commit.sha,
                            htmlURL: response.commit.html_url.flatMap(URL.init(string:)))
    }

    /// 1 ファイルを消す。
    @discardableResult
    public func deleteFile(owner: String, repo: String, path: String, message: String,
                           branch: String, sha: String? = nil) async throws -> CommitResult {
        var found = sha
        if found == nil {
            found = try await fileSHA(owner: owner, repo: repo, path: path, ref: branch)
        }
        guard let existing = found else { throw GitHubClientError.notFound(path) }
        struct Response: Decodable {
            struct Commit: Decodable {
                let sha: String
                let html_url: String?
            }
            let commit: Commit
        }
        let response = try await post(
            Response.self, path: "/repos/\(owner)/\(repo)/contents/\(path)",
            method: "DELETE",
            body: ["message": message, "branch": branch, "sha": existing])
        return CommitResult(sha: response.commit.sha,
                            htmlURL: response.commit.html_url.flatMap(URL.init(string:)))
    }

    // MARK: - 81. ブランチを作って PR を出す

    /// ブランチの先端の SHA。
    public func branchHead(owner: String, repo: String,
                          branch: String) async throws -> String {
        struct Ref: Decodable {
            struct Object: Decodable { let sha: String }
            let object: Object
        }
        let ref = try await fetchJSON(
            Ref.self, path: "/repos/\(owner)/\(repo)/git/ref/heads/\(branch)")
        return ref.object.sha
    }

    /// 新しいブランチを作る。
    @discardableResult
    public func createBranch(owner: String, repo: String, name: String,
                             from base: String) async throws -> GitBranch {
        let sha = try await branchHead(owner: owner, repo: repo, branch: base)
        struct Ref: Decodable {
            struct Object: Decodable { let sha: String }
            let ref: String
            let object: Object
        }
        let created = try await post(Ref.self, path: "/repos/\(owner)/\(repo)/git/refs",
                                     body: ["ref": "refs/heads/\(name)", "sha": sha])
        return GitBranch(name: name, sha: created.object.sha)
    }

    /// Pull Request を出す。
    public func createPullRequest(owner: String, repo: String, title: String,
                                  body: String = "", head: String, base: String,
                                  draft: Bool = false) async throws -> GitPullRequest {
        try await post(PullRequestJSON.self, path: "/repos/\(owner)/\(repo)/pulls",
                       body: ["title": title, "body": body, "head": head,
                              "base": base, "draft": draft]).model
    }

    /// 「ブランチを作る → まとめてコミット → PR を出す」を続けて行う。
    public func proposeChanges(owner: String, repo: String, branch: String,
                               base: String, message: String, title: String,
                               body: String = "", edits: [FileEdit],
                               draft: Bool = false) async throws -> GitPullRequest {
        try await createBranch(owner: owner, repo: repo, name: branch, from: base)
        try await commitFiles(owner: owner, repo: repo, branch: branch,
                              message: message, edits: edits)
        return try await createPullRequest(owner: owner, repo: repo, title: title,
                                           body: body, head: branch, base: base,
                                           draft: draft)
    }

    // MARK: - 82. 複数ファイルをまとめてコミット

    /// 複数のファイルを 1 つのコミットにまとめて push する (Git Data API)。
    @discardableResult
    public func commitFiles(owner: String, repo: String, branch: String,
                            message: String,
                            edits: [FileEdit]) async throws -> CommitResult {
        guard !edits.isEmpty else { throw GitHubClientError.badResponse }

        let head = try await branchHead(owner: owner, repo: repo, branch: branch)
        let baseTree = try await commitTree(owner: owner, repo: repo, sha: head)

        // 1. 中身を blob にする。
        var entries: [[String: Any]] = []
        for edit in edits {
            guard let data = edit.data else {
                // 削除は sha を null にする。
                entries.append(["path": edit.path, "mode": "100644", "type": "blob",
                                "sha": NSNull()])
                continue
            }
            let blob = try await createBlob(owner: owner, repo: repo, data: data)
            entries.append(["path": edit.path, "mode": "100644", "type": "blob",
                            "sha": blob])
        }

        // 2. 新しいツリーを作る。
        struct TreeResponse: Decodable { let sha: String }
        let tree = try await post(TreeResponse.self,
                                  path: "/repos/\(owner)/\(repo)/git/trees",
                                  body: ["base_tree": baseTree, "tree": entries])

        // 3. コミットを作る。
        struct CommitResponse: Decodable {
            let sha: String
            let html_url: String?
        }
        let commit = try await post(CommitResponse.self,
                                    path: "/repos/\(owner)/\(repo)/git/commits",
                                    body: ["message": message, "tree": tree.sha,
                                           "parents": [head]])

        // 4. ブランチを進める。
        struct RefResponse: Decodable { let ref: String }
        _ = try await post(RefResponse.self,
                           path: "/repos/\(owner)/\(repo)/git/refs/heads/\(branch)",
                           method: "PATCH",
                           body: ["sha": commit.sha, "force": false])

        return CommitResult(sha: commit.sha,
                            htmlURL: commit.html_url.flatMap(URL.init(string:)))
    }

    /// コミットが指しているツリーの SHA。
    private func commitTree(owner: String, repo: String,
                            sha: String) async throws -> String {
        struct Response: Decodable {
            struct Tree: Decodable { let sha: String }
            let tree: Tree
        }
        return try await fetchJSON(Response.self,
                                   path: "/repos/\(owner)/\(repo)/git/commits/\(sha)")
            .tree.sha
    }

    /// blob を 1 つ作って SHA を返す。
    private func createBlob(owner: String, repo: String,
                            data: Data) async throws -> String {
        struct Response: Decodable { let sha: String }
        return try await post(Response.self, path: "/repos/\(owner)/\(repo)/git/blobs",
                              body: ["content": data.base64EncodedString(),
                                     "encoding": "base64"]).sha
    }
}
