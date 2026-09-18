import XCTest
@testable import GitHubViewerCore

/// 243. 初回ガイド。
final class OnboardingTests: XCTestCase {

    func testWalksThroughEveryPage() {
        var flow = OnboardingFlow()
        XCTAssertEqual(flow.current?.id, "welcome")
        XCTAssertEqual(flow.progress, 0)
        for _ in 0..<(OnboardingFlow.defaultPages.count - 1) { flow.advance() }
        XCTAssertTrue(flow.isLast)
        XCTAssertFalse(flow.isFinished)
        flow.advance()
        XCTAssertTrue(flow.isFinished)
        XCTAssertNil(flow.current)
        XCTAssertEqual(flow.progress, 1)
    }

    func testBack() {
        var flow = OnboardingFlow()
        flow.advance()
        flow.advance()
        XCTAssertEqual(flow.index, 2)
        flow.back()
        XCTAssertEqual(flow.index, 1)
        // 最初より前には戻らない。
        flow.back()
        flow.back()
        XCTAssertEqual(flow.index, 0)
    }

    func testBackAfterFinishingReopensTheFlow() {
        var flow = OnboardingFlow()
        flow.skip()
        XCTAssertTrue(flow.isFinished)
        flow.back()
        XCTAssertEqual(flow.index, 0)
        XCTAssertTrue(flow.isFinished, "最初のページで戻っても、終わったままにする")
    }

    func testSkipEndsItAtOnce() {
        var flow = OnboardingFlow()
        flow.skip()
        XCTAssertTrue(flow.isFinished)
        XCTAssertNil(flow.current)
        // 終わったあとに進めても、何も起きない。
        flow.advance()
        XCTAssertTrue(flow.isFinished)
    }

    func testEmptyFlowIsAlreadyFinished() {
        let flow = OnboardingFlow(pages: [])
        XCTAssertTrue(flow.isFinished)
        XCTAssertEqual(flow.progress, 1)
    }

    func testShowsOnlyOnce() {
        XCTAssertTrue(OnboardingFlow.shouldShow(hasSeen: false))
        XCTAssertFalse(OnboardingFlow.shouldShow(hasSeen: true))
    }

    func testPagesAreWellFormed() {
        for page in OnboardingFlow.defaultPages {
            XCTAssertFalse(page.title.isEmpty)
            XCTAssertFalse(page.body.isEmpty)
        }
        XCTAssertFalse(OnboardingFlow.defaultPages[0].isSkippable)
    }
}

/// 244. 今日のヒント。
final class TipTests: XCTestCase {

    private func date(_ day: Int) -> Date {
        Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200)
    }

    func testSameDayGivesTheSameTip() {
        XCTAssertEqual(TipLibrary.tip(on: date(10)).id,
                       TipLibrary.tip(on: date(10)).id)
    }

    func testTipsRotateAcrossDays() {
        let ids = (0..<TipLibrary.all.count).map { TipLibrary.tip(on: date($0)).id }
        XCTAssertEqual(Set(ids).count, TipLibrary.all.count,
                       "ひと回りすると、全部出ること")
    }

    func testUnseenTipsComeFirst() {
        let seen = Set(TipLibrary.all.dropLast().map(\.id))
        let tip = TipLibrary.nextUnseen(seen: seen, on: date(3))
        XCTAssertEqual(tip.id, TipLibrary.all.last?.id)
    }

    func testAllSeenFallsBackToTheDailyTip() {
        let seen = Set(TipLibrary.all.map(\.id))
        XCTAssertEqual(TipLibrary.nextUnseen(seen: seen, on: date(3)).id,
                       TipLibrary.tip(on: date(3)).id)
    }

    func testCategories() {
        XCTAssertFalse(TipLibrary.categories.isEmpty)
        for category in TipLibrary.categories {
            XCTAssertFalse(TipLibrary.tips(category: category).isEmpty)
        }
    }

    func testTipsAreWellFormed() {
        let ids = TipLibrary.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for tip in TipLibrary.all { XCTAssertFalse(tip.text.isEmpty) }
    }
}

/// 245. 使い方。
final class HelpCenterTests: XCTestCase {

    func testSearchFindsATopic() {
        XCTAssertTrue(HelpCenter.search("動かす").contains { $0.id == "help-run" })
        XCTAssertTrue(HelpCenter.search("shortcut").isEmpty
                        || !HelpCenter.search("ショートカット").isEmpty)
    }

    func testEmptyQueryReturnsEverything() {
        XCTAssertEqual(HelpCenter.search("", limit: 100).count, HelpCenter.all.count)
    }

    func testCategoriesCoverEveryTopic() {
        let counted = HelpCenter.categories
            .reduce(0) { $0 + HelpCenter.topics(category: $1).count }
        XCTAssertEqual(counted, HelpCenter.all.count)
    }

    func testLookupByID() {
        XCTAssertNotNil(HelpCenter.topic(id: "help-open"))
        XCTAssertNil(HelpCenter.topic(id: "ない"))
    }

    func testTopicsAreWellFormed() {
        let ids = HelpCenter.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for topic in HelpCenter.all {
            XCTAssertFalse(topic.title.isEmpty)
            XCTAssertFalse(topic.body.isEmpty)
            XCTAssertFalse(topic.category.isEmpty)
        }
    }
}

/// 246. フィードバック。
final class FeedbackComposerTests: XCTestCase {

    private let environment = FeedbackComposer.Environment(
        appVersion: "1.2.3", systemVersion: "iPadOS 17.0", deviceModel: "iPad")

    private func report(_ kind: FeedbackReport.Kind = .bug) -> FeedbackReport {
        FeedbackReport(kind: kind, title: "実行が止まらない",
                       body: "長い繰り返しを動かすと止まりません。",
                       context: ["言語": "go", "画面": "エディタ"])
    }

    func testBodyIncludesContextAndEnvironment() {
        let text = FeedbackComposer.body(for: report(), environment: environment)
        XCTAssertTrue(text.contains("長い繰り返し"))
        XCTAssertTrue(text.contains("- 言語: go"))
        XCTAssertTrue(text.contains("1.2.3"))
        XCTAssertTrue(text.contains("iPad"))
    }

    func testEnvironmentCanBeLeftOut() {
        var quiet = report()
        quiet.includesEnvironment = false
        let text = FeedbackComposer.body(for: quiet, environment: environment)
        XCTAssertFalse(text.contains("1.2.3"))
        XCTAssertTrue(text.contains("- 言語: go"))
    }

    func testIssueURLCarriesTitleBodyAndLabel() throws {
        let location = GitHubLocation(owner: "owner", repo: "repo")
        let url = try XCTUnwrap(FeedbackComposer.issueURL(for: report(),
                                                          repository: location,
                                                          environment: environment))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/owner/repo/issues/new")
        let items = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "実行が止まらない")
        XCTAssertEqual(items.first { $0.name == "labels" }?.value, "bug")
        XCTAssertTrue(try XCTUnwrap(items.first { $0.name == "body" }?.value)
            .contains("長い繰り返し"))
    }

    func testIdeaAndQuestionUseTheirOwnLabels() throws {
        let location = GitHubLocation(owner: "owner", repo: "repo")
        for (kind, label) in [(FeedbackReport.Kind.idea, "enhancement"),
                              (.question, "question")] {
            let url = try XCTUnwrap(FeedbackComposer.issueURL(for: report(kind),
                                                              repository: location))
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "labels" }?.value, label)
        }
    }

    func testMailURL() throws {
        let url = try XCTUnwrap(FeedbackComposer.mailURL(for: report(),
                                                         to: "support@example.com"))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.contains("support@example.com"))
    }

    func testEmptyReportMakesNoURL() {
        let empty = FeedbackReport(kind: .bug, title: "  ", body: "")
        XCTAssertFalse(empty.isValid)
        XCTAssertNil(FeedbackComposer.issueURL(
            for: empty, repository: GitHubLocation(owner: "o", repo: "r")))
        XCTAssertNil(FeedbackComposer.mailURL(for: empty, to: "a@example.com"))
    }

    func testKindsAreDescribed() {
        for kind in FeedbackReport.Kind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty)
            XCTAssertEqual(kind.id, kind.rawValue)
        }
    }
}

/// 247 / 248. 利用統計とバッジ。
final class UsageStatisticsTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    func testRecordingRuns() {
        var statistics = UsageStatistics()
        statistics.recordRun(languageID: "go", succeeded: true, duration: 0.5, at: day)
        statistics.recordRun(languageID: "go", succeeded: false, at: day)
        statistics.recordRun(languageID: "rust", succeeded: true, at: day)
        XCTAssertEqual(statistics.totalRuns, 3)
        XCTAssertEqual(statistics.successfulRuns, 2)
        XCTAssertEqual(statistics.failedRuns, 1)
        XCTAssertEqual(statistics.languageCount, 2)
        XCTAssertEqual(statistics.languagesByUse.first?.languageID, "go")
        XCTAssertEqual(statistics.totalRunSeconds, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try! XCTUnwrap(statistics.successRate), 2.0 / 3, accuracy: 0.001)
    }

    func testRecordingARealRun() throws {
        var statistics = UsageStatistics()
        let result = try RunSession.run(languageID: "go", source: """
        package main

        import "fmt"

        func main() {
            fmt.Println("あ")
        }
        """)
        statistics.record(result, at: day)
        XCTAssertEqual(statistics.runsByLanguage["go"], 1)
        XCTAssertEqual(statistics.successfulRuns, 1)
    }

    func testNoRunsHasNoSuccessRate() {
        XCTAssertNil(UsageStatistics().successRate)
    }

    func testFilesAndRepositoriesAndEdits() {
        var statistics = UsageStatistics()
        statistics.recordFileOpened(repository: "apple/swift", at: day)
        statistics.recordFileOpened(repository: "apple/swift", at: day)
        statistics.recordFileOpened(repository: "apple/swift-format", at: day)
        statistics.recordEdit(at: day)
        XCTAssertEqual(statistics.filesOpened, 3)
        XCTAssertEqual(statistics.repositories.count, 2)
        XCTAssertEqual(statistics.edits, 1)
    }

    func testActiveDaysCountsCalendarDays() {
        var statistics = UsageStatistics()
        statistics.recordEdit(at: day)
        statistics.recordEdit(at: day.addingTimeInterval(60))
        statistics.recordEdit(at: day.addingTimeInterval(86_400 * 2))
        XCTAssertEqual(statistics.activeDays.count, 2)
        XCTAssertEqual(statistics.firstUsedAt, day)
        XCTAssertEqual(statistics.lastUsedAt, day.addingTimeInterval(86_400 * 2))
    }

    func testEncodeRoundTrip() throws {
        var statistics = UsageStatistics()
        statistics.recordRun(languageID: "go", succeeded: true, at: day)
        let restored = UsageStatistics.decoded(try XCTUnwrap(statistics.encoded()))
        XCTAssertEqual(restored, statistics)
    }

    func testDecodeGarbageGivesAnEmptyRecord() {
        XCTAssertEqual(UsageStatistics.decoded(Data("だめ".utf8)), UsageStatistics())
        XCTAssertEqual(UsageStatistics.decoded(nil), UsageStatistics())
    }

    func testResetForgetsEverything() {
        var statistics = UsageStatistics()
        statistics.recordRun(languageID: "go", succeeded: true, at: day)
        statistics.reset()
        XCTAssertEqual(statistics, UsageStatistics())
    }

    func testSummaryLines() {
        var statistics = UsageStatistics()
        statistics.recordRun(languageID: "go", succeeded: true, at: day)
        let lines = statistics.summaryLines
        XCTAssertTrue(lines.contains { $0.contains("1 回") })
        XCTAssertTrue(lines.contains { $0.contains("100 %") })
    }
}

final class BadgeTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func statistics(runs: Int, languages: Int = 1) -> UsageStatistics {
        var statistics = UsageStatistics()
        for index in 0..<runs {
            statistics.recordRun(languageID: "lang\(index % Swift.max(1, languages))",
                                 succeeded: true, at: day)
        }
        return statistics
    }

    func testFirstRunBadge() {
        XCTAssertTrue(BadgeCatalog.earned(UsageStatistics()).isEmpty)
        let earned = BadgeCatalog.earned(statistics(runs: 1))
        XCTAssertEqual(earned.map(\.id), ["badge-first-run"])
    }

    func testProgressAndRemaining() {
        let badge = try! XCTUnwrap(BadgeCatalog.badge(id: "badge-ten-runs"))
        let stats = statistics(runs: 5)
        XCTAssertEqual(badge.progress(stats), 0.5, accuracy: 0.0001)
        XCTAssertEqual(badge.remaining(stats), 5)
        XCTAssertFalse(badge.isEarned(stats))
        XCTAssertEqual(badge.remaining(statistics(runs: 50)), 0)
        XCTAssertEqual(badge.progress(statistics(runs: 50)), 1)
    }

    func testPolyglotNeedsManyLanguages() {
        let badge = try! XCTUnwrap(BadgeCatalog.badge(id: "badge-polyglot"))
        XCTAssertFalse(badge.isEarned(statistics(runs: 20, languages: 2)))
        XCTAssertTrue(badge.isEarned(statistics(runs: 20, languages: 5)))
    }

    func testUpcomingIsSortedByHowCloseItIs() {
        let stats = statistics(runs: 9)
        let upcoming = BadgeCatalog.upcoming(stats, limit: 2)
        XCTAssertEqual(upcoming.first?.id, "badge-ten-runs")
        XCTAssertTrue(upcoming.allSatisfy { !$0.isEarned(stats) })
    }

    func testNewlyEarned() {
        let before = statistics(runs: 9)
        let after = statistics(runs: 10)
        let fresh = BadgeCatalog.newlyEarned(before: before, after: after)
        XCTAssertEqual(fresh.map(\.id), ["badge-ten-runs"])
        XCTAssertTrue(BadgeCatalog.newlyEarned(before: after, after: after).isEmpty)
    }

    func testBadgesAreWellFormed() {
        let ids = BadgeCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for badge in BadgeCatalog.all {
            XCTAssertFalse(badge.name.isEmpty)
            XCTAssertFalse(badge.requirement.isEmpty)
            XCTAssertGreaterThan(badge.goal, 0)
        }
    }
}

/// 249. 表示言語。
final class LocalizationTests: XCTestCase {

    func testJapaneseAndEnglish() {
        XCTAssertEqual(L10n.string("action.run", language: .japanese), "実行")
        XCTAssertEqual(L10n.string("action.run", language: .english), "Run")
    }

    func testSystemFollowsThePreferredLanguage() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ja-JP"]),
                       .japanese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-US"]),
                       .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: []), .english)
        // 選んであるなら、端末の設定には引きずられない。
        XCTAssertEqual(AppLanguage.japanese.resolved(preferredLanguages: ["en-US"]),
                       .japanese)
    }

    func testUnknownKeyComesBackAsItself() {
        XCTAssertEqual(L10n.string("ない.鍵", language: .english), "ない.鍵")
    }

    /// 片方だけの訳がないこと。
    func testEveryKeyIsTranslatedBothWays() {
        XCTAssertEqual(L10n.missingTranslations, [])
    }

    func testPlaceholders() {
        XCTAssertEqual(L10n.string("storage.total", ["3 MB"], language: .japanese),
                       "合計 3 MB")
        XCTAssertEqual(L10n.string("storage.total", ["3 MB"], language: .english),
                       "3 MB in total")
    }

    func testDisplayNames() {
        for language in AppLanguage.allCases {
            XCTAssertFalse(language.displayName.isEmpty)
            XCTAssertEqual(language.id, language.rawValue)
        }
    }

    func testNoEmptyTranslations() {
        for (key, value) in L10n.japanese { XCTAssertFalse(value.isEmpty, key) }
        for (key, value) in L10n.english { XCTAssertFalse(value.isEmpty, key) }
    }
}

/// 250. 設定のプリセット。
final class SettingsPresetTests: XCTestCase {

    func testApplyReplacesTheSettings() {
        var settings = EditorSettings()
        let preset = try! XCTUnwrap(
            SettingsPresetCatalog.preset(id: "preset-presentation"))
        preset.apply(to: &settings)
        XCTAssertEqual(settings.fontSize.points, 26)
        XCTAssertFalse(settings.showsLineNumbers)
        XCTAssertTrue(preset.matches(settings))
    }

    func testCurrentFindsTheMatchingPreset() {
        XCTAssertEqual(SettingsPresetCatalog.current(for: EditorSettings())?.id,
                       "preset-default")
        var custom = EditorSettings()
        custom.rulerColumn = 37
        XCTAssertNil(SettingsPresetCatalog.current(for: custom))
    }

    func testPresetsDifferFromEachOther() {
        let settings = SettingsPresetCatalog.all.map(\.settings)
        for (index, one) in settings.enumerated() {
            for other in settings[(index + 1)...] {
                XCTAssertNotEqual(one, other)
            }
        }
    }

    func testMakeFromCurrentSettings() {
        var settings = EditorSettings()
        settings.fontSize = FontSize(points: 22)
        let preset = SettingsPresetCatalog.make(name: "わたし好み", from: settings)
        XCTAssertEqual(preset.name, "わたし好み")
        XCTAssertTrue(preset.matches(settings))
        XCTAssertNil(SettingsPresetCatalog.preset(id: preset.id),
                     "作っただけでは、一覧には入らない")
    }

    func testPresetsAreWellFormed() {
        let ids = SettingsPresetCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for preset in SettingsPresetCatalog.all {
            XCTAssertFalse(preset.name.isEmpty)
            XCTAssertFalse(preset.summary.isEmpty)
            XCTAssertGreaterThanOrEqual(preset.settings.fontSize.points,
                                        FontSize.minimum)
            XCTAssertLessThanOrEqual(preset.settings.fontSize.points,
                                     FontSize.maximum)
        }
    }
}
