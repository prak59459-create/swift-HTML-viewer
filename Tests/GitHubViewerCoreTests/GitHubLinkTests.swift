import XCTest
@testable import GitHubViewerCore

final class LineRangeTests: XCTestCase {
    func testSingleLine() {
        let range = LineRange(start: 12)
        XCTAssertTrue(range.isSingleLine)
        XCTAssertEqual(range.fragment, "L12")
        XCTAssertEqual(range.count, 1)
    }

    func testRange() {
        let range = LineRange(start: 3, end: 7)
        XCTAssertEqual(range.fragment, "L3-L7")
        XCTAssertEqual(range.count, 5)
    }

    func testEndBeforeStartIsClamped() {
        let range = LineRange(start: 10, end: 2)
        XCTAssertEqual(range.start, 10)
        XCTAssertEqual(range.end, 10)
    }

    func testZeroBecomesOne() {
        XCTAssertEqual(LineRange(start: 0).start, 1)
    }
}

final class GitHubLinkTests: XCTestCase {
    let location = GitHubLocation(owner: "o", repo: "r", ref: "main",
                                  path: "src/main.swift")

    func testRawURL() {
        XCTAssertEqual(GitHubLinks.rawURL(location)?.absoluteString,
                       "https://raw.githubusercontent.com/o/r/main/src/main.swift")
    }

    func testRawURLWithoutRef() {
        let bare = GitHubLocation(owner: "o", repo: "r", path: "a.txt")
        XCTAssertEqual(GitHubLinks.rawURL(bare)?.absoluteString,
                       "https://raw.githubusercontent.com/o/r/HEAD/a.txt")
    }

    func testBlobURL() {
        XCTAssertEqual(GitHubLinks.blobURL(location)?.absoluteString,
                       "https://github.com/o/r/blob/main/src/main.swift")
    }

    func testTreeURLForDirectory() {
        var directory = location
        directory.path = "src"
        directory.isDirectory = true
        XCTAssertEqual(GitHubLinks.blobURL(directory)?.absoluteString,
                       "https://github.com/o/r/tree/main/src")
    }

    func testBlobURLWithLines() {
        let url = GitHubLinks.blobURL(location, lines: LineRange(start: 4, end: 9))
        XCTAssertEqual(url?.absoluteString,
                       "https://github.com/o/r/blob/main/src/main.swift#L4-L9")
    }

    func testDirectoryLinkHasNoLineFragment() {
        var directory = location
        directory.isDirectory = true
        let url = GitHubLinks.blobURL(directory, lines: LineRange(start: 1))
        XCTAssertFalse(url!.absoluteString.contains("#"))
    }

    func testPermalinkPinsTheCommit() {
        let url = GitHubLinks.permalink(location, commitSHA: "abc123",
                                        lines: LineRange(start: 10))
        XCTAssertEqual(url?.absoluteString,
                       "https://github.com/o/r/blob/abc123/src/main.swift#L10")
    }

    func testBlameURL() {
        XCTAssertEqual(GitHubLinks.blameURL(location)?.absoluteString,
                       "https://github.com/o/r/blame/main/src/main.swift")
    }

    func testCommitAndIssueURLs() {
        XCTAssertEqual(GitHubLinks.commitURL(owner: "o", repo: "r", sha: "s")?
            .absoluteString, "https://github.com/o/r/commit/s")
        XCTAssertEqual(GitHubLinks.issueURL(owner: "o", repo: "r", number: 4)?
            .absoluteString, "https://github.com/o/r/issues/4")
        XCTAssertEqual(GitHubLinks.issueURL(owner: "o", repo: "r", number: 4,
                                            isPullRequest: true)?.absoluteString,
                       "https://github.com/o/r/pull/4")
    }

    func testEnterpriseHost() {
        let url = GitHubLinks.blobURL(location, host: "ghe.example.com")
        XCTAssertEqual(url?.absoluteString,
                       "https://ghe.example.com/o/r/blob/main/src/main.swift")
    }

    func testJapanesePathIsEncoded() {
        var japanese = location
        japanese.path = "資料/メモ.txt"
        let text = GitHubLinks.rawURL(japanese)?.absoluteString ?? ""
        XCTAssertTrue(text.contains("%E8%B3%87%E6%96%99/%E3%83%A1%E3%83%A2.txt"), text)
    }

    // MARK: - 行範囲の読み取り

    func testReadSingleLineFragment() {
        XCTAssertEqual(GitHubLinks.lineRange(fromFragment: "L42")?.start, 42)
        XCTAssertEqual(GitHubLinks.lineRange(fromFragment: "#L42")?.start, 42)
    }

    func testReadLineRangeFragment() {
        let range = GitHubLinks.lineRange(fromFragment: "L5-L9")
        XCTAssertEqual(range?.start, 5)
        XCTAssertEqual(range?.end, 9)
    }

    func testReadFromURL() {
        let url = URL(string: "https://github.com/o/r/blob/main/a.swift#L3-L4")!
        XCTAssertEqual(GitHubLinks.lineRange(from: url)?.end, 4)
    }

    func testReadFromText() {
        XCTAssertEqual(GitHubLinks.lineRange(fromText:
            "https://github.com/o/r/blob/main/a.swift#L7")?.start, 7)
    }

    func testIgnoresOtherFragments() {
        XCTAssertNil(GitHubLinks.lineRange(fromFragment: "readme"))
        XCTAssertNil(GitHubLinks.lineRange(fromFragment: ""))
        XCTAssertNil(GitHubLinks.lineRange(fromFragment: nil))
    }

    func testHalfBrokenRangeStillGivesTheStart() {
        XCTAssertEqual(GitHubLinks.lineRange(fromFragment: "L5-xyz")?.start, 5)
    }

    func testRoundTrip() {
        let original = LineRange(start: 11, end: 20)
        let url = GitHubLinks.permalink(location, commitSHA: "c", lines: original)!
        XCTAssertEqual(GitHubLinks.lineRange(from: url), original)
    }

    func testQuotedSnippet() {
        let text = GitHubLinks.quotedSnippet(location, commitSHA: "abc",
                                             lines: LineRange(start: 1, end: 2),
                                             text: "let a = 1\nlet b = 2",
                                             languageID: "swift")
        XCTAssertTrue(text.hasPrefix("https://github.com/o/r/blob/abc/src/main.swift#L1-L2\n```swift\n"))
        XCTAssertTrue(text.hasSuffix("```"))
    }
}

final class ReadmeBadgeTests: XCTestCase {
    func testLinkedBadge() {
        let markdown = "[![CI](https://img.shields.io/badge/ci-ok-green)](https://github.com/o/r/actions)"
        let badges = ReadmeBadgeScanner.badges(inMarkdown: markdown)
        XCTAssertEqual(badges.count, 1)
        XCTAssertEqual(badges[0].altText, "CI")
        XCTAssertEqual(badges[0].imageURL.host, "img.shields.io")
        XCTAssertEqual(badges[0].linkURL?.absoluteString,
                       "https://github.com/o/r/actions")
    }

    func testPlainBadge() {
        let badges = ReadmeBadgeScanner.badges(
            inMarkdown: "![版](https://badge.fury.io/js/x.svg)")
        XCTAssertEqual(badges.count, 1)
        XCTAssertNil(badges[0].linkURL)
    }

    func testSeveralBadgesOnOneLine() {
        let markdown = """
        [![a](https://img.shields.io/a)](https://x) [![b](https://img.shields.io/b)](https://y)
        """
        XCTAssertEqual(ReadmeBadgeScanner.badges(inMarkdown: markdown).count, 2)
    }

    func testOrdinaryImagesAreSkipped() {
        let markdown = "![screenshot](https://example.com/shot.png)"
        XCTAssertTrue(ReadmeBadgeScanner.badges(inMarkdown: markdown).isEmpty)
        XCTAssertEqual(ReadmeBadgeScanner.badges(inMarkdown: markdown,
                                                 onlyKnownHosts: false).count, 1)
    }

    func testDuplicatesAreRemoved() {
        let markdown = """
        ![a](https://img.shields.io/x)
        ![a](https://img.shields.io/x)
        """
        XCTAssertEqual(ReadmeBadgeScanner.badges(inMarkdown: markdown).count, 1)
    }

    func testRelativeImagesAreIgnored() {
        XCTAssertTrue(ReadmeBadgeScanner.badges(inMarkdown: "![x](docs/a.png)",
                                                onlyKnownHosts: false).isEmpty)
    }

    func testTitleAfterURLIsDropped() {
        let badges = ReadmeBadgeScanner.badges(
            inMarkdown: #"![a](https://img.shields.io/x "説明")"#)
        XCTAssertEqual(badges.first?.imageURL.absoluteString,
                       "https://img.shields.io/x")
    }

    func testBadgesInLongReadme() {
        let markdown = """
        # タイトル

        [![build](https://img.shields.io/github/actions/workflow/status/o/r/ci.yml)](https://github.com/o/r/actions)
        [![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

        本文です。![図](https://example.com/a.png) もあります。
        """
        let badges = ReadmeBadgeScanner.badges(inMarkdown: markdown)
        XCTAssertEqual(badges.map(\.altText), ["build", "license"])
        // 飛び先は相対パスのままでも覚えておく (リポジトリ内で解決できる)。
        XCTAssertEqual(badges[1].linkURL?.relativeString, "LICENSE")
    }

    func testKnownHostCheck() {
        let badge = ReadmeBadge(altText: "x",
                                imageURL: URL(string: "https://img.shields.io/a")!)
        XCTAssertTrue(badge.isKnownBadgeHost)
        let other = ReadmeBadge(altText: "x",
                                imageURL: URL(string: "https://example.com/a")!)
        XCTAssertFalse(other.isKnownBadgeHost)
    }
}
