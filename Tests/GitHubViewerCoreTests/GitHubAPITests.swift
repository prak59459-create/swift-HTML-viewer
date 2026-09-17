import XCTest
@testable import GitHubViewerCore

final class GitHubReadTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: - 61

    func testBranches() async throws {
        StubURLProtocol.stubJSON("/branches", """
        [{"name":"main","commit":{"sha":"aaa"},"protected":true},
         {"name":"dev","commit":{"sha":"bbb"}}]
        """)
        let branches = try await StubURLProtocol.makeClient()
            .branches(owner: "o", repo: "r")
        XCTAssertEqual(branches.map(\.name), ["main", "dev"])
        XCTAssertTrue(branches[0].isProtected)
        XCTAssertFalse(branches[1].isProtected)
    }

    func testPageQueryIsSent() async throws {
        StubURLProtocol.stubJSON("/branches", "[]")
        _ = try await StubURLProtocol.makeClient().branches(owner: "o", repo: "r",
                                                            page: 2, perPage: 500)
        let url = StubURLProtocol.requests.last?.url ?? ""
        XCTAssertTrue(url.contains("page=2"), url)
        XCTAssertTrue(url.contains("per_page=100"), url)   // 100 で頭打ち。
    }

    // MARK: - 62

    func testTagsAndReleases() async throws {
        StubURLProtocol.stubJSON("/tags", #"[{"name":"v1.0","commit":{"sha":"c1"}}]"#)
        StubURLProtocol.stubJSON("/releases", """
        [{"id":1,"tag_name":"v1.0","name":"最初の版","body":"説明",
          "prerelease":false,"published_at":"2026-01-02T03:04:05Z",
          "html_url":"https://github.com/o/r/releases/tag/v1.0"}]
        """)
        let client = StubURLProtocol.makeClient()
        let tags = try await client.tags(owner: "o", repo: "r")
        XCTAssertEqual(tags.first?.name, "v1.0")

        let releases = try await client.releases(owner: "o", repo: "r")
        XCTAssertEqual(releases.first?.name, "最初の版")
        XCTAssertFalse(releases.first!.isPrerelease)
        XCTAssertNotNil(releases.first?.publishedAt)
    }

    func testReleaseWithoutNameFallsBackToTag() async throws {
        StubURLProtocol.stubJSON("/releases", #"[{"id":1,"tag_name":"v2"}]"#)
        let releases = try await StubURLProtocol.makeClient()
            .releases(owner: "o", repo: "r")
        XCTAssertEqual(releases.first?.name, "v2")
        XCTAssertEqual(releases.first?.body, "")
    }

    // MARK: - 63 / 65

    func testCommits() async throws {
        StubURLProtocol.stubJSON("/commits", """
        [{"sha":"1234567890abcdef",
          "commit":{"message":"直した\\n\\n詳しい説明","author":{"name":"私","date":"2026-01-01T00:00:00Z"}},
          "author":{"login":"me","avatar_url":"https://x/a.png"},
          "html_url":"https://github.com/o/r/commit/123"}]
        """)
        let commits = try await StubURLProtocol.makeClient()
            .commits(owner: "o", repo: "r")
        XCTAssertEqual(commits.first?.summary, "直した")
        XCTAssertEqual(commits.first?.shortSHA, "1234567")
        XCTAssertEqual(commits.first?.authorLogin, "me")
        XCTAssertNotNil(commits.first?.date)
    }

    func testFileHistorySendsPath() async throws {
        StubURLProtocol.stubJSON("/commits", "[]")
        _ = try await StubURLProtocol.makeClient()
            .commits(owner: "o", repo: "r", ref: "dev", path: "src/main.swift")
        let url = StubURLProtocol.requests.last?.url ?? ""
        XCTAssertTrue(url.contains("sha=dev"), url)
        XCTAssertTrue(url.contains("path=src"), url)
    }

    // MARK: - 64

    func testCommitDetailWithFiles() async throws {
        StubURLProtocol.stubJSON("/commits/abc", """
        {"sha":"abc","commit":{"message":"変更","author":{"name":"私"}},
         "stats":{"additions":3,"deletions":1},
         "files":[{"filename":"a.txt","status":"modified","additions":3,"deletions":1,
                   "patch":"@@ -1,2 +1,4 @@\\n a\\n-b\\n+B\\n+c\\n+d"}]}
        """)
        let detail = try await StubURLProtocol.makeClient()
            .commit(owner: "o", repo: "r", sha: "abc")
        XCTAssertEqual(detail.additions, 3)
        XCTAssertEqual(detail.deletions, 1)
        XCTAssertEqual(detail.files.count, 1)

        let lines = detail.files[0].diffLines
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["B", "c", "d"])
        XCTAssertEqual(lines.filter { $0.kind == .removed }.map(\.text), ["b"])
    }

    func testCommitDetailComputesStatsWhenMissing() async throws {
        StubURLProtocol.stubJSON("/commits/abc", """
        {"sha":"abc","commit":{"message":"m"},
         "files":[{"filename":"a","additions":2,"deletions":1},
                  {"filename":"b","additions":5,"deletions":0}]}
        """)
        let detail = try await StubURLProtocol.makeClient()
            .commit(owner: "o", repo: "r", sha: "abc")
        XCTAssertEqual(detail.additions, 7)
        XCTAssertEqual(detail.deletions, 1)
    }

    func testCompare() async throws {
        StubURLProtocol.stubJSON("/compare/", """
        {"files":[{"filename":"x.swift","status":"added","additions":10,"deletions":0}]}
        """)
        let files = try await StubURLProtocol.makeClient()
            .compare(owner: "o", repo: "r", base: "main", head: "dev")
        XCTAssertEqual(files.first?.filename, "x.swift")
        XCTAssertEqual(files.first?.status, "added")
    }

    // MARK: - 66

    func testBlame() async throws {
        StubURLProtocol.stubJSON("/graphql", """
        {"data":{"repository":{"object":{"blame":{"ranges":[
          {"startingLine":1,"endingLine":2,
           "commit":{"oid":"abcdef1234","committedDate":"2026-01-01T00:00:00Z",
                     "author":{"name":"私"}}},
          {"startingLine":3,"endingLine":3,
           "commit":{"oid":"9999999999","committedDate":null,"author":null}}
        ]}}}}}
        """)
        let lines = try await StubURLProtocol.makeClient()
            .blame(owner: "o", repo: "r", ref: "main", path: "a.txt",
                   fileText: "一行目\n二行目\n三行目")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].text, "一行目")
        XCTAssertEqual(lines[0].shortSHA, "abcdef1")
        XCTAssertEqual(lines[0].authorName, "私")
        XCTAssertEqual(lines[2].text, "三行目")
        XCTAssertEqual(lines[2].authorName, "")
    }

    func testBlameUsesPost() async throws {
        StubURLProtocol.stubJSON("/graphql",
            #"{"data":{"repository":{"object":{"blame":{"ranges":[]}}}}}"#)
        _ = try await StubURLProtocol.makeClient()
            .blame(owner: "o", repo: "r", ref: "main", path: "a", fileText: "")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        let body = StubURLProtocol.lastBody()
        XCTAssertNotNil(body?["query"])
        XCTAssertEqual((body?["variables"] as? [String: String])?["path"], "a")
    }

    // MARK: - 67 / 68

    func testIssuesHidePullRequestsByDefault() async throws {
        StubURLProtocol.stubJSON("/issues", """
        [{"number":1,"title":"不具合","state":"open","user":{"login":"me"},
          "labels":[{"name":"bug"}],"comments":2},
         {"number":2,"title":"PR です","state":"open","user":{"login":"me"},
          "pull_request":{"url":"https://x"}}]
        """)
        let client = StubURLProtocol.makeClient()
        let issues = try await client.issues(owner: "o", repo: "r")
        XCTAssertEqual(issues.map(\.number), [1])
        XCTAssertEqual(issues[0].labels, ["bug"])
        XCTAssertEqual(issues[0].commentCount, 2)
        XCTAssertTrue(issues[0].isOpen)

        let all = try await client.issues(owner: "o", repo: "r",
                                          includePullRequests: true)
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all[1].isPullRequest)
    }

    func testIssueComments() async throws {
        StubURLProtocol.stubJSON("/issues/5/comments", """
        [{"id":11,"user":{"login":"a"},"body":"どうも","created_at":"2026-01-01T00:00:00Z"}]
        """)
        let comments = try await StubURLProtocol.makeClient()
            .comments(owner: "o", repo: "r", issue: 5)
        XCTAssertEqual(comments.first?.body, "どうも")
        XCTAssertEqual(comments.first?.authorLogin, "a")
    }

    // MARK: - 69 / 70 / 71

    func testPullRequests() async throws {
        StubURLProtocol.stubJSON("/pulls", """
        [{"number":7,"title":"直した","state":"open","user":{"login":"me"},
          "head":{"ref":"fix"},"base":{"ref":"main"},"draft":true,
          "additions":10,"deletions":2,"changed_files":3}]
        """)
        let pulls = try await StubURLProtocol.makeClient()
            .pullRequests(owner: "o", repo: "r")
        XCTAssertEqual(pulls.first?.headRef, "fix")
        XCTAssertEqual(pulls.first?.baseRef, "main")
        XCTAssertTrue(pulls.first!.isDraft)
        XCTAssertFalse(pulls.first!.isMerged)
        XCTAssertEqual(pulls.first?.changedFiles, 3)
        XCTAssertTrue(pulls.first!.issue.isPullRequest)
    }

    func testMergedIsDerivedFromMergedAt() async throws {
        StubURLProtocol.stubJSON("/pulls/7", """
        {"number":7,"title":"t","state":"closed","head":{"ref":"a"},"base":{"ref":"b"},
         "merged_at":"2026-01-01T00:00:00Z"}
        """)
        let pull = try await StubURLProtocol.makeClient()
            .pullRequest(owner: "o", repo: "r", number: 7)
        XCTAssertTrue(pull.isMerged)
    }

    func testPullRequestFiles() async throws {
        StubURLProtocol.stubJSON("/pulls/7/files", """
        [{"filename":"a.swift","status":"modified","additions":1,"deletions":1,
          "patch":"@@ -1 +1 @@\\n-old\\n+new"}]
        """)
        let files = try await StubURLProtocol.makeClient()
            .pullRequestFiles(owner: "o", repo: "r", number: 7)
        XCTAssertEqual(files.first?.diffLines.count, 2)
    }

    func testReviewComments() async throws {
        StubURLProtocol.stubJSON("/pulls/7/comments", """
        [{"id":3,"user":{"login":"r"},"body":"ここ直して","path":"a.swift","line":12}]
        """)
        let comments = try await StubURLProtocol.makeClient()
            .reviewComments(owner: "o", repo: "r", number: 7)
        XCTAssertEqual(comments.first?.path, "a.swift")
        XCTAssertEqual(comments.first?.line, 12)
    }

    func testReviewCommentFallsBackToOriginalLine() async throws {
        StubURLProtocol.stubJSON("/pulls/7/comments",
            #"[{"id":3,"body":"x","path":"a","original_line":40}]"#)
        let comments = try await StubURLProtocol.makeClient()
            .reviewComments(owner: "o", repo: "r", number: 7)
        XCTAssertEqual(comments.first?.line, 40)
    }

    // MARK: - 73

    func testRepositorySummary() async throws {
        StubURLProtocol.stubJSON("/repos/o/r", """
        {"full_name":"o/r","description":"説明","language":"Swift",
         "stargazers_count":12,"forks_count":3,"subscribers_count":4,
         "open_issues_count":5,"license":{"spdx_id":"MIT"},"default_branch":"main",
         "private":false,"fork":false,"topics":["ios","swift"],
         "updated_at":"2026-01-01T00:00:00Z","html_url":"https://github.com/o/r"}
        """)
        let repo = try await StubURLProtocol.makeClient().repository(owner: "o", repo: "r")
        XCTAssertEqual(repo.owner, "o")
        XCTAssertEqual(repo.name, "r")
        XCTAssertEqual(repo.stars, 12)
        XCTAssertEqual(repo.license, "MIT")
        XCTAssertEqual(repo.topics, ["ios", "swift"])
    }

    func testLanguagesAreSortedByBytes() async throws {
        StubURLProtocol.stubJSON("/languages", #"{"Swift":900,"C":100,"Shell":500}"#)
        let languages = try await StubURLProtocol.makeClient()
            .languages(owner: "o", repo: "r")
        XCTAssertEqual(languages.map(\.name), ["Swift", "Shell", "C"])
    }

    func testContributors() async throws {
        StubURLProtocol.stubJSON("/contributors", #"[{"login":"a"},{"login":"b"}]"#)
        let users = try await StubURLProtocol.makeClient()
            .contributors(owner: "o", repo: "r")
        XCTAssertEqual(users.map(\.login), ["a", "b"])
    }

    // MARK: - 75 / 76 / 77 / 79

    func testGists() async throws {
        StubURLProtocol.stubJSON("/gists", """
        [{"id":"g1","description":"メモ","public":true,
          "files":{"b.txt":{"filename":"b.txt"},"a.txt":{"filename":"a.txt"}}}]
        """)
        let gists = try await StubURLProtocol.makeClient().myGists()
        XCTAssertEqual(gists.first?.files, ["a.txt", "b.txt"])
        XCTAssertTrue(gists.first!.isPublic)
    }

    func testStarredAndOwnRepositories() async throws {
        StubURLProtocol.stubJSON("/user/starred", #"[{"full_name":"a/b"}]"#)
        StubURLProtocol.stubJSON("/user/repos", #"[{"full_name":"me/x"}]"#)
        let client = StubURLProtocol.makeClient()
        let starred = try await client.starredRepositories()
        let mine = try await client.myRepositories()
        XCTAssertEqual(starred.first?.fullName, "a/b")
        XCTAssertEqual(mine.first?.fullName, "me/x")
    }

    func testUser() async throws {
        StubURLProtocol.stubJSON("/users/me", """
        {"login":"me","name":"私","bio":"紹介","public_repos":7,"followers":2,
         "following":3,"avatar_url":"https://x/a.png"}
        """)
        let user = try await StubURLProtocol.makeClient().user("me")
        XCTAssertEqual(user.name, "私")
        XCTAssertEqual(user.publicRepos, 7)
        XCTAssertNotNil(user.avatarURL)
    }

    // MARK: - 78

    func testSearchRepositories() async throws {
        StubURLProtocol.stubJSON("/search/repositories", """
        {"total_count":1,"items":[{"full_name":"o/r","stargazers_count":5}]}
        """)
        let found = try await StubURLProtocol.makeClient()
            .searchRepositories("swift editor")
        XCTAssertEqual(found.first?.fullName, "o/r")
        XCTAssertTrue(StubURLProtocol.requests.last?.url.contains("q=swift") == true)
    }

    func testSearchCode() async throws {
        StubURLProtocol.stubJSON("/search/code", """
        {"items":[{"path":"a/b.swift","repository":{"full_name":"o/r"},
                   "html_url":"https://github.com/o/r/blob/main/a/b.swift"}]}
        """)
        let found = try await StubURLProtocol.makeClient().searchCode("func main")
        XCTAssertEqual(found.first?.path, "a/b.swift")
        XCTAssertEqual(found.first?.repositoryName, "o/r")
    }

    // MARK: - 84 / 85

    func testWorkflowRuns() async throws {
        StubURLProtocol.stubJSON("/actions/runs", """
        {"workflow_runs":[
          {"id":1,"name":"CI","status":"completed","conclusion":"success",
           "head_branch":"main","display_title":"直した"},
          {"id":2,"name":"CI","status":"in_progress","conclusion":null,
           "head_branch":"dev","display_title":"試し"}]}
        """)
        let runs = try await StubURLProtocol.makeClient()
            .workflowRuns(owner: "o", repo: "r")
        XCTAssertEqual(runs.map(\.symbol), ["✓", "…"])
        XCTAssertEqual(runs[0].commitMessage, "直した")
    }

    func testWorkflowJobsAndDuration() async throws {
        StubURLProtocol.stubJSON("/runs/1/jobs", """
        {"jobs":[{"id":9,"name":"build","status":"completed","conclusion":"failure",
                  "started_at":"2026-01-01T00:00:00Z",
                  "completed_at":"2026-01-01T00:02:00Z"}]}
        """)
        let jobs = try await StubURLProtocol.makeClient()
            .workflowJobs(owner: "o", repo: "r", runID: 1)
        XCTAssertEqual(jobs.first?.duration, 120)
    }

    func testJobLogIsPlainText() async throws {
        StubURLProtocol.stub("/actions/jobs/9/logs",
                             .init(status: 200, body: Data("build ok\nline 2".utf8)))
        let log = try await StubURLProtocol.makeClient()
            .jobLog(owner: "o", repo: "r", jobID: 9)
        XCTAssertTrue(log.hasPrefix("build ok"))
    }

    // MARK: - 89

    func testRateLimitEndpoint() async throws {
        StubURLProtocol.stubJSON("/rate_limit", """
        {"resources":{"core":{"limit":5000,"remaining":4000,"reset":1800000000}}}
        """)
        let status = try await StubURLProtocol.makeClient().rateLimit()
        XCTAssertEqual(status.remaining, 4000)
        XCTAssertEqual(status.used, 1000)
        XCTAssertFalse(status.isLow)
    }

    func testMonitorReadsHeaders() async throws {
        let monitor = RateLimitMonitor()
        StubURLProtocol.stubJSON("/branches", "[]", headers: [
            "x-ratelimit-limit": "60",
            "x-ratelimit-remaining": "7",
            "x-ratelimit-reset": "1800000000"
        ])
        _ = try await StubURLProtocol.makeClient(monitor: monitor)
            .branches(owner: "o", repo: "r")
        XCTAssertEqual(monitor.current?.limit, 60)
        XCTAssertEqual(monitor.current?.remaining, 7)
        XCTAssertTrue(monitor.current!.isLow)
        XCTAssertNotNil(monitor.current?.resetDate)
    }

    func testRateLimitErrorIsReported() async {
        StubURLProtocol.stubJSON("/branches", #"{"message":"API rate limit exceeded"}"#,
                                 status: 403,
                                 headers: ["x-ratelimit-remaining": "0"])
        do {
            _ = try await StubURLProtocol.makeClient().branches(owner: "o", repo: "r")
            XCTFail("エラーになるはずです")
        } catch GitHubClientError.rateLimited {
            // 期待どおり。
        } catch {
            XCTFail("違うエラーです: \(error)")
        }
    }

    // MARK: - 92 / 93

    func testNotifications() async throws {
        StubURLProtocol.stubJSON("/notifications", """
        [{"id":"n1","subject":{"title":"レビューして","type":"PullRequest"},
          "repository":{"full_name":"o/r"},"reason":"review_requested","unread":true}]
        """)
        let items = try await StubURLProtocol.makeClient().notifications()
        XCTAssertEqual(items.first?.title, "レビューして")
        XCTAssertEqual(items.first?.subjectType, "PullRequest")
        XCTAssertTrue(items.first!.isUnread)
    }

    func testStarStateAndToggle() async throws {
        StubURLProtocol.stub("/user/starred/o/r", .init(status: 204))
        let client = StubURLProtocol.makeClient()
        let starred = try await client.isStarred(owner: "o", repo: "r")
        XCTAssertTrue(starred)

        try await client.setStar(false, owner: "o", repo: "r")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "DELETE")

        try await client.setStar(true, owner: "o", repo: "r")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "PUT")
    }

    func testNotStarredWhenNotFound() async throws {
        let starred = try await StubURLProtocol.makeClient()
            .isStarred(owner: "o", repo: "r")
        XCTAssertFalse(starred)
    }

    func testWatch() async throws {
        StubURLProtocol.stubJSON("/subscription", #"{"subscribed":true}"#)
        let client = StubURLProtocol.makeClient()
        let watching = try await client.isWatching(owner: "o", repo: "r")
        XCTAssertTrue(watching)

        try await client.setWatch(true, owner: "o", repo: "r")
        XCTAssertEqual(StubURLProtocol.lastBody()?["subscribed"] as? Bool, true)
    }

    // MARK: - 見当違いの応答

    func testBadJSONBecomesBadResponse() async {
        StubURLProtocol.stubJSON("/branches", "これは JSON ではありません")
        do {
            _ = try await StubURLProtocol.makeClient().branches(owner: "o", repo: "r")
            XCTFail("エラーになるはずです")
        } catch GitHubClientError.badResponse {
            // 期待どおり。
        } catch {
            XCTFail("違うエラーです: \(error)")
        }
    }

    func testTokenIsSent() async throws {
        StubURLProtocol.stubJSON("/branches", "[]")
        _ = try await StubURLProtocol.makeClient(token: "abc")
            .branches(owner: "o", repo: "r")
        XCTAssertFalse(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - 90 (Enterprise ホスト)

    func testEnterpriseHostIsUsed() async throws {
        StubURLProtocol.stubJSON("/branches", "[]")
        let client = GitHubClient(token: nil, session: StubURLProtocol.makeSession(),
                                  apiHost: "ghe.example.com")
        _ = try await client.branches(owner: "o", repo: "r")
        XCTAssertTrue(StubURLProtocol.requests.last?.url
            .hasPrefix("https://ghe.example.com/") == true,
                      StubURLProtocol.requests.last?.url ?? "")
    }
}

final class GitHubWriteTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: - 68

    func testCreateIssue() async throws {
        StubURLProtocol.stubJSON("/issues", """
        {"number":3,"title":"新しい issue","state":"open","user":{"login":"me"}}
        """)
        let issue = try await StubURLProtocol.makeClient()
            .createIssue(owner: "o", repo: "r", title: "新しい issue", body: "本文",
                         labels: ["bug"])
        XCTAssertEqual(issue.number, 3)
        let body = StubURLProtocol.lastBody()
        XCTAssertEqual(body?["title"] as? String, "新しい issue")
        XCTAssertEqual(body?["labels"] as? [String], ["bug"])
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
    }

    func testAddComment() async throws {
        StubURLProtocol.stubJSON("/issues/3/comments",
                                 #"{"id":1,"body":"どうも","user":{"login":"me"}}"#)
        let comment = try await StubURLProtocol.makeClient()
            .addComment(owner: "o", repo: "r", issue: 3, body: "どうも")
        XCTAssertEqual(comment.body, "どうも")
    }

    func testCloseIssue() async throws {
        StubURLProtocol.stubJSON("/issues/3", #"{"number":3,"title":"t","state":"closed"}"#)
        let issue = try await StubURLProtocol.makeClient()
            .setIssueState(owner: "o", repo: "r", number: 3, open: false)
        XCTAssertFalse(issue.isOpen)
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "PATCH")
        XCTAssertEqual(StubURLProtocol.lastBody()?["state"] as? String, "closed")
    }

    // MARK: - 74

    func testCreateGist() async throws {
        StubURLProtocol.stubJSON("/gists",
                                 #"{"id":"g1","description":"メモ","public":false,"files":{}}"#)
        let gist = try await StubURLProtocol.makeClient()
            .createGist(files: ["a.swift": "print(1)"], description: "メモ")
        XCTAssertEqual(gist.id, "g1")
        let files = StubURLProtocol.lastBody()?["files"] as? [String: Any]
        let file = files?["a.swift"] as? [String: Any]
        XCTAssertEqual(file?["content"] as? String, "print(1)")
    }

    func testEmptyGistFileGetsASpace() async throws {
        StubURLProtocol.stubJSON("/gists", #"{"id":"g","files":{}}"#)
        _ = try await StubURLProtocol.makeClient().createGist(files: ["a": ""])
        let files = StubURLProtocol.lastBody()?["files"] as? [String: Any]
        XCTAssertEqual((files?["a"] as? [String: Any])?["content"] as? String, " ")
    }

    // MARK: - 80

    func testCommitFileLooksUpExistingSHA() async throws {
        StubURLProtocol.stubJSON("/contents/a.swift", method: "GET",
                                 #"{"sha":"old-sha"}"#)
        StubURLProtocol.stubJSON("/contents/a.swift", method: "PUT",
                                 #"{"commit":{"sha":"new-sha","html_url":"https://x"}}"#)
        let result = try await StubURLProtocol.makeClient()
            .commitFile(owner: "o", repo: "r", path: "a.swift",
                        data: Data("hello".utf8), message: "更新", branch: "main")
        XCTAssertEqual(result.sha, "new-sha")
        // 1 回目は取得、2 回目が書き込み。
        XCTAssertEqual(StubURLProtocol.requests.map(\.method), ["GET", "PUT"])
        let body = StubURLProtocol.lastBody()
        XCTAssertEqual(body?["sha"] as? String, "old-sha")
        XCTAssertEqual(body?["branch"] as? String, "main")
        XCTAssertEqual(body?["content"] as? String, Data("hello".utf8).base64EncodedString())
    }

    func testCommitNewFileHasNoSHA() async throws {
        // GET が 404 (= まだ無いファイル) なら、sha を付けずに PUT する。
        StubURLProtocol.stub("/contents/new.txt", method: "GET",
                             .init(status: 404,
                                   body: Data(#"{"message":"Not Found"}"#.utf8)))
        StubURLProtocol.stubJSON("/contents/new.txt", method: "PUT",
                                 #"{"commit":{"sha":"s"}}"#)
        let result = try await StubURLProtocol.makeClient()
            .commitFile(owner: "o", repo: "r", path: "new.txt",
                        data: Data("x".utf8), message: "追加", branch: "main")
        XCTAssertEqual(result.sha, "s")
        XCTAssertEqual(StubURLProtocol.requests.map(\.method), ["GET", "PUT"])
        XCTAssertNil(StubURLProtocol.lastBody()?["sha"])
    }

    func testDeleteFile() async throws {
        StubURLProtocol.stubJSON("/contents/a.txt", #"{"commit":{"sha":"d"}}"#)
        let result = try await StubURLProtocol.makeClient()
            .deleteFile(owner: "o", repo: "r", path: "a.txt", message: "消した",
                        branch: "main", sha: "old")
        XCTAssertEqual(result.sha, "d")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "DELETE")
    }

    func testPathIsPercentEncoded() async throws {
        StubURLProtocol.stubJSON("/contents/", #"{"commit":{"sha":"x"}}"#)
        _ = try await StubURLProtocol.makeClient()
            .commitFile(owner: "o", repo: "r", path: "資料/メモ.txt", data: Data(),
                        message: "m", branch: "main", sha: "s")
        let url = StubURLProtocol.requests.last?.url ?? ""
        XCTAssertTrue(url.contains("%E8%B3%87%E6%96%99/"), url)
    }

    // MARK: - 81

    func testCreateBranch() async throws {
        StubURLProtocol.stubJSON("/git/ref/heads/main", #"{"object":{"sha":"base-sha"}}"#)
        StubURLProtocol.stubJSON("/git/refs",
                                 #"{"ref":"refs/heads/feature","object":{"sha":"base-sha"}}"#)
        let branch = try await StubURLProtocol.makeClient()
            .createBranch(owner: "o", repo: "r", name: "feature", from: "main")
        XCTAssertEqual(branch.name, "feature")
        XCTAssertEqual(branch.sha, "base-sha")
        XCTAssertEqual(StubURLProtocol.lastBody()?["ref"] as? String,
                       "refs/heads/feature")
        XCTAssertEqual(StubURLProtocol.lastBody()?["sha"] as? String, "base-sha")
    }

    func testCreatePullRequest() async throws {
        StubURLProtocol.stubJSON("/pulls", """
        {"number":9,"title":"直した","state":"open","head":{"ref":"feature"},
         "base":{"ref":"main"}}
        """)
        let pull = try await StubURLProtocol.makeClient()
            .createPullRequest(owner: "o", repo: "r", title: "直した", head: "feature",
                               base: "main", draft: true)
        XCTAssertEqual(pull.issue.number, 9)
        XCTAssertEqual(StubURLProtocol.lastBody()?["draft"] as? Bool, true)
    }

    // MARK: - 82

    func testCommitFilesUsesGitDataAPI() async throws {
        StubURLProtocol.stubJSON("/git/ref/heads/main", #"{"object":{"sha":"head-sha"}}"#)
        StubURLProtocol.stubJSON("/git/commits/head-sha", #"{"tree":{"sha":"tree-sha"}}"#)
        StubURLProtocol.stubJSON("/git/blobs", #"{"sha":"blob-sha"}"#)
        StubURLProtocol.stubJSON("/git/trees", #"{"sha":"new-tree"}"#)
        StubURLProtocol.stubJSON("/git/commits", #"{"sha":"new-commit","html_url":"https://x"}"#)
        StubURLProtocol.stubJSON("/git/refs/heads/main", #"{"ref":"refs/heads/main"}"#)

        let result = try await StubURLProtocol.makeClient()
            .commitFiles(owner: "o", repo: "r", branch: "main", message: "まとめて",
                         edits: [FileEdit(path: "a.txt", text: "A"),
                                 FileEdit(path: "b.txt", text: "B"),
                                 .removal(path: "c.txt")])
        XCTAssertEqual(result.sha, "new-commit")

        // blob は 2 つだけ (削除は blob を作らない)。
        let blobCalls = StubURLProtocol.requests.filter { $0.url.contains("/git/blobs") }
        XCTAssertEqual(blobCalls.count, 2)

        // ツリーには 3 つの項目が入り、削除は sha が null。
        let treeBody = StubURLProtocol.bodies().first {
            $0["base_tree"] != nil
        }
        let entries = treeBody?["tree"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 3)
        XCTAssertEqual(treeBody?["base_tree"] as? String, "tree-sha")
        let removal = entries?.first { $0["path"] as? String == "c.txt" }
        XCTAssertTrue(removal?["sha"] is NSNull)

        // 最後にブランチを進める。
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "PATCH")
        XCTAssertEqual(StubURLProtocol.lastBody()?["sha"] as? String, "new-commit")
    }

    func testCommitFilesRejectsEmptyEdits() async {
        do {
            _ = try await StubURLProtocol.makeClient()
                .commitFiles(owner: "o", repo: "r", branch: "main", message: "m",
                             edits: [])
            XCTFail("エラーになるはずです")
        } catch GitHubClientError.badResponse {
            // 期待どおり。
        } catch {
            XCTFail("違うエラーです: \(error)")
        }
    }

    func testProposeChangesDoesEverythingInOrder() async throws {
        StubURLProtocol.stubJSON("/git/ref/heads/main", #"{"object":{"sha":"head"}}"#)
        StubURLProtocol.stubJSON("/git/refs", #"{"ref":"refs/heads/feat","object":{"sha":"head"}}"#)
        StubURLProtocol.stubJSON("/git/ref/heads/feat", #"{"object":{"sha":"head"}}"#)
        StubURLProtocol.stubJSON("/git/commits/head", #"{"tree":{"sha":"t"}}"#)
        StubURLProtocol.stubJSON("/git/blobs", #"{"sha":"b"}"#)
        StubURLProtocol.stubJSON("/git/trees", #"{"sha":"t2"}"#)
        StubURLProtocol.stubJSON("/git/commits", #"{"sha":"c2"}"#)
        StubURLProtocol.stubJSON("/git/refs/heads/feat", #"{"ref":"refs/heads/feat"}"#)
        StubURLProtocol.stubJSON("/pulls", """
        {"number":4,"title":"t","state":"open","head":{"ref":"feat"},"base":{"ref":"main"}}
        """)

        let pull = try await StubURLProtocol.makeClient()
            .proposeChanges(owner: "o", repo: "r", branch: "feat", base: "main",
                            message: "変更", title: "t",
                            edits: [FileEdit(path: "a", text: "x")])
        XCTAssertEqual(pull.issue.number, 4)
        XCTAssertTrue(StubURLProtocol.requests.last?.url.contains("/pulls") == true)
    }
}

final class FileEditTests: XCTestCase {
    func testTextInitialiser() {
        XCTAssertEqual(FileEdit(path: "a", text: "あ").data, Data("あ".utf8))
    }

    func testRemoval() {
        let edit = FileEdit.removal(path: "a")
        XCTAssertTrue(edit.isRemoval)
        XCTAssertNil(edit.data)
    }
}
