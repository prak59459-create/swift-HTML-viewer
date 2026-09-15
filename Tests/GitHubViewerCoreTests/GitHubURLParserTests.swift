import XCTest
@testable import GitHubViewerCore

final class GitHubURLParserTests: XCTestCase {
    func testRepositoryRoot() throws {
        let target = try GitHubURLParser.parse("https://github.com/apple/swift")
        XCTAssertEqual(target, .repository(GitHubLocation(owner: "apple", repo: "swift", isDirectory: true)))
    }

    func testTrailingSlashAndDotGit() throws {
        let target = try GitHubURLParser.parse("https://github.com/apple/swift.git/")
        XCTAssertEqual(target, .repository(GitHubLocation(owner: "apple", repo: "swift", isDirectory: true)))
    }

    func testBlobURL() throws {
        let target = try GitHubURLParser.parse("https://github.com/owner/repo/blob/main/docs/index.html")
        XCTAssertEqual(target, .repository(GitHubLocation(owner: "owner", repo: "repo", ref: "main",
                                                          path: "docs/index.html", isDirectory: false)))
    }

    func testTreeURL() throws {
        let target = try GitHubURLParser.parse("https://github.com/owner/repo/tree/dev/docs")
        XCTAssertEqual(target, .repository(GitHubLocation(owner: "owner", repo: "repo", ref: "dev",
                                                          path: "docs", isDirectory: true)))
    }

    func testRawURL() throws {
        let target = try GitHubURLParser.parse("https://raw.githubusercontent.com/owner/repo/main/a/b.html")
        XCTAssertEqual(target, .repository(GitHubLocation(owner: "owner", repo: "repo", ref: "main",
                                                          path: "a/b.html", isDirectory: false)))
    }

    func testGist() throws {
        let target = try GitHubURLParser.parse("https://gist.github.com/someone/abc123")
        XCTAssertEqual(target, .gist(id: "abc123"))
    }

    func testShorthand() throws {
        let target = try GitHubURLParser.parse("owner/repo/docs/index.html")
        XCTAssertEqual(target, .repository(GitHubLocation(owner: "owner", repo: "repo",
                                                          path: "docs/index.html", isDirectory: false)))
    }

    func testHostWithoutScheme() throws {
        let target = try GitHubURLParser.parse("github.com/owner/repo/blob/main/index.html")
        XCTAssertEqual(target, .repository(GitHubLocation(owner: "owner", repo: "repo", ref: "main",
                                                          path: "index.html", isDirectory: false)))
    }

    func testOtherURLPassesThrough() throws {
        let target = try GitHubURLParser.parse("https://example.com/demo.html")
        XCTAssertEqual(target, .rawURL(URL(string: "https://example.com/demo.html")!))
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try GitHubURLParser.parse("   "))
    }

    func testParentNavigation() {
        let location = GitHubLocation(owner: "o", repo: "r", ref: "main", path: "a/b/c.html")
        XCTAssertEqual(location.parent?.path, "a/b")
        XCTAssertEqual(location.parent?.parent?.path, "a")
        XCTAssertEqual(location.parent?.parent?.parent?.path, "")
        XCTAssertNil(location.parent?.parent?.parent?.parent)
    }
}
