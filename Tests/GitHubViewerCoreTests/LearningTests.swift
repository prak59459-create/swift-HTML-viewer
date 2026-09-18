import XCTest
@testable import GitHubViewerCore

/// 236. 対応言語一覧。
final class LanguageGuideTests: XCTestCase {

    func testEveryCatalogLanguageIsListed() {
        XCTAssertEqual(LanguageGuide.all.count, LanguageCatalog.all.count)
        for support in LanguageGuide.all {
            XCTAssertFalse(support.name.isEmpty)
            XCTAssertFalse(support.engineName.isEmpty)
            XCTAssertFalse(support.summary.isEmpty)
        }
    }

    func testBuiltInLanguagesWorkOffline() {
        let go = try! XCTUnwrap(LanguageGuide.support(languageID: "go"))
        XCTAssertEqual(go.place, .builtIn)
        XCTAssertTrue(go.worksOffline)
        XCTAssertFalse(go.place.needsNetwork)
        XCTAssertTrue(go.covered.contains { $0.contains("error") })
        XCTAssertTrue(go.notCovered.contains { $0.contains("goroutine") })
    }

    /// 内蔵処理系のある言語は、一覧にあって動かせること。
    ///
    /// JavaScript のように、端末内の本物の処理系を先に使う言語もあるので、
    /// 「通信なしで動く」とまでは言い切らない。
    func testEveryBuiltInEngineIsListedAndRunnable() {
        for languageID in MiniLangRegistry.supportedLanguageIDs {
            guard let support = LanguageGuide.all.first(where: {
                LanguageCatalog.builtinLanguageID(for: $0.languageID) == languageID
            }) else {
                XCTFail("\(languageID) が一覧にありません")
                continue
            }
            XCTAssertTrue(support.isRunnable, "\(support.languageID) を動かせません")
        }
    }

    /// 内蔵と書いてあるものは、本当に内蔵の処理系を持っていること。
    func testBuiltInPlaceMeansABuiltInCompiler() {
        for support in LanguageGuide.all where support.place == .builtIn {
            let language = try! XCTUnwrap(
                LanguageCatalog.language(id: support.languageID))
            XCTAssertNotNil(language.builtin, "\(support.languageID)")
        }
    }

    func testServerLanguagesNeedNetwork() {
        let server = LanguageGuide.all.filter { $0.place == .server }
        for support in server {
            XCTAssertTrue(support.place.needsNetwork)
            XCTAssertTrue(support.notCovered.contains { $0.contains("通信") })
        }
    }

    func testOfflineReadyIsNotEmptyAndIsASubset() {
        let offline = LanguageGuide.offlineReady
        XCTAssertFalse(offline.isEmpty)
        XCTAssertLessThanOrEqual(offline.count, LanguageGuide.all.count)
        XCTAssertTrue(offline.allSatisfy(\.worksOffline))
    }

    func testSearchByNameAndExtension() {
        XCTAssertTrue(LanguageGuide.search("Kotlin").contains {
            $0.languageID == "kotlin"
        })
        XCTAssertTrue(LanguageGuide.search("rs").contains { $0.languageID == "rust" })
        XCTAssertEqual(LanguageGuide.search("", limit: 4).count, 4)
    }

    func testPlaceDisplayNames() {
        for place in [LanguageSupport.Place.builtIn, .onDevice, .server, .none] {
            XCTAssertFalse(place.displayName.isEmpty)
        }
    }
}

/// 237. チュートリアル。
final class TutorialTests: XCTestCase {

    /// 書いてあるコードが、書いてあるとおりに動くこと。
    func testEveryStepRunsAsWritten() throws {
        for tutorial in TutorialLibrary.all {
            guard RunSession.hasEngine(for: tutorial.languageID) else {
                XCTFail("\(tutorial.id): \(tutorial.languageID) を動かせません")
                continue
            }
            for step in tutorial.steps {
                let result = try RunSession.run(languageID: tutorial.languageID,
                                                source: step.code)
                XCTAssertNil(result.failureText, "\(step.id) が失敗しました")
                guard let expected = step.expectedOutput else { continue }
                XCTAssertEqual(
                    TestRunner.normalize(ANSIParser.strip(result.output), trims: true),
                    TestRunner.normalize(expected, trims: true),
                    "\(step.id) の出力が違います")
            }
        }
    }

    func testEveryTutorialIsWellFormed() {
        for tutorial in TutorialLibrary.all {
            XCTAssertFalse(tutorial.title.isEmpty)
            XCTAssertFalse(tutorial.summary.isEmpty)
            XCTAssertGreaterThanOrEqual(tutorial.stepCount, 2)
            for step in tutorial.steps {
                XCTAssertFalse(step.title.isEmpty)
                XCTAssertFalse(step.explanation.isEmpty)
                XCTAssertFalse(step.code.isEmpty)
            }
        }
    }

    func testNoDuplicateIDs() {
        let tutorialIDs = TutorialLibrary.all.map(\.id)
        XCTAssertEqual(Set(tutorialIDs).count, tutorialIDs.count)
        let stepIDs = TutorialLibrary.all.flatMap { $0.steps.map(\.id) }
        XCTAssertEqual(Set(stepIDs).count, stepIDs.count)
    }

    func testLookupAndProgress() {
        let tutorial = try! XCTUnwrap(TutorialLibrary.tutorial(id: "go-basics"))
        XCTAssertEqual(tutorial.languageID, "go")
        XCTAssertNotNil(tutorial.step(id: "go-1"))
        XCTAssertNil(tutorial.step(id: "go-999"))
        XCTAssertEqual(tutorial.progress(completed: []), 0)
        XCTAssertEqual(tutorial.progress(completed: ["go-1", "go-2"]),
                       2.0 / Double(tutorial.stepCount), accuracy: 0.0001)
        XCTAssertEqual(tutorial.progress(completed: Set(tutorial.steps.map(\.id))), 1)
    }

    func testTutorialsByLanguage() {
        XCTAssertFalse(TutorialLibrary.tutorials(languageID: "go").isEmpty)
        XCTAssertTrue(TutorialLibrary.tutorials(languageID: "cobol").isEmpty)
        XCTAssertTrue(TutorialLibrary.languageIDs.contains("rust"))
    }
}

/// 238. 未対応の構文。
final class UnsupportedSyntaxTests: XCTestCase {

    func testGoroutineIsReported() {
        let source = """
        package main

        func main() {
            go func() {
                println("あ")
            }()
        }
        """
        let hints = UnsupportedSyntax.hints(in: source, languageID: "go")
        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints[0].line, 4)
        XCTAssertTrue(hints[0].message.contains("goroutine"))
        XCTAssertNotNil(hints[0].suggestion)
    }

    func testChannelIsReported() {
        let hints = UnsupportedSyntax.hints(in: "ch := make(chan int)",
                                            languageID: "go")
        XCTAssertFalse(hints.isEmpty)
    }

    /// ほかの言語の規則は当てないこと。
    func testRulesAreLanguageSpecific() {
        let source = "go func() {}"
        XCTAssertTrue(UnsupportedSyntax.hints(in: source,
                                              languageID: "rust").isEmpty)
    }

    func testCommentsAreIgnored() {
        let source = "// go func() { }"
        XCTAssertTrue(UnsupportedSyntax.hints(in: source, languageID: "go").isEmpty)
    }

    func testPlainCodeHasNoHints() {
        let source = """
        package main

        import "fmt"

        func main() {
            fmt.Println("こんにちは")
        }
        """
        XCTAssertTrue(UnsupportedSyntax.hints(in: source, languageID: "go").isEmpty)
        XCTAssertNil(UnsupportedSyntax.summary(in: source, languageID: "go"))
    }

    func testSummaryCountsTheRest() {
        let source = """
        ch := make(chan int)
        go func() {}()
        """
        let summary = try! XCTUnwrap(UnsupportedSyntax.summary(in: source,
                                                              languageID: "go"))
        XCTAssertTrue(summary.contains("ほかに 1 件"))
    }

    func testEveryRulePatternIsValid() {
        for rule in UnsupportedSyntax.rules {
            XCTAssertNoThrow(try NSRegularExpression(pattern: rule.pattern),
                             "\(rule.message) の正規表現が壊れています")
            XCTAssertFalse(rule.advice.isEmpty)
        }
    }
}

/// 239. 修正候補。
final class FixAdvisorTests: XCTestCase {

    func testSuggestsTheNearestName() {
        let source = """
        count := 1
        println(cout)
        """
        let suggestions = FixAdvisor.suggestions(
            forMessage: "2:9 未定義の変数 cout", source: source, languageID: "go")
        let rename = try! XCTUnwrap(suggestions.first { $0.title.contains("count") })
        XCTAssertTrue(rename.isApplicable)
        XCTAssertEqual(rename.apply(to: source), """
        count := 1
        println(count)
        """)
    }

    func testSuggestsDefiningWhenNothingIsClose() {
        let suggestions = FixAdvisor.suggestions(
            forMessage: "1:1 未定義の変数 zzzzzzzz", source: "println(zzzzzzzz)",
            languageID: "go")
        XCTAssertTrue(suggestions.contains { $0.title.contains("用意する") })
    }

    func testDivisionByZero() {
        let suggestions = FixAdvisor.suggestions(forMessage: "3:5 0 で割れません",
                                                 source: "a / b", languageID: "go")
        XCTAssertTrue(suggestions.contains { $0.title.contains("0 かどうか") })
        XCTAssertEqual(suggestions.first?.line, 3)
    }

    func testOutOfRange() {
        let suggestions = FixAdvisor.suggestions(
            forMessage: "2:3 添字 5 は範囲外です (要素数 3)",
            source: "values[5]", languageID: "go")
        XCTAssertTrue(suggestions.contains { $0.title.contains("添字") })
    }

    func testUnbalancedBracketIsFound() {
        let suggestions = FixAdvisor.suggestions(forMessage: "1:1 } が必要です",
                                                 source: "func main() {",
                                                 languageID: "go")
        XCTAssertTrue(suggestions.contains { $0.title.contains("{") })
        XCTAssertTrue(suggestions.contains { $0.title.contains("閉じ中括弧") })
    }

    func testNoFailureMeansNoSuggestions() throws {
        let result = try RunSession.run(languageID: "go", source: """
        package main

        import "fmt"

        func main() {
            fmt.Println("よし")
        }
        """)
        XCTAssertTrue(FixAdvisor.suggestions(for: result, source: "").isEmpty)
    }

    /// 本当に動かなかったコードから、候補が出ること。
    func testSuggestionsFromARealFailure() throws {
        let source = """
        package main

        import "fmt"

        func main() {
            count := 1
            fmt.Println(cout)
        }
        """
        let result = try RunSession.run(languageID: "go", source: source)
        XCTAssertNotNil(result.failureText)
        let suggestions = FixAdvisor.suggestions(for: result, source: source)
        XCTAssertFalse(suggestions.isEmpty)
    }

    func testApplyRefusesBadLines() {
        let suggestion = FixSuggestion(title: "t", detail: "d", line: 99,
                                       replacing: "a", replacement: "b")
        XCTAssertNil(suggestion.apply(to: "a"))
        let unusable = FixSuggestion(title: "t", detail: "d")
        XCTAssertFalse(unusable.isApplicable)
        XCTAssertNil(unusable.apply(to: "a"))
    }

    func testEditDistance() {
        XCTAssertEqual(FixAdvisor.editDistance("count", "cout"), 1)
        XCTAssertEqual(FixAdvisor.editDistance("", "abc"), 3)
        XCTAssertEqual(FixAdvisor.editDistance("abc", "abc"), 0)
    }

    func testLineNumberFromMessage() {
        XCTAssertEqual(FixAdvisor.lineNumber(in: "12:3 なにか"), 12)
        XCTAssertNil(FixAdvisor.lineNumber(in: "なにか"))
    }
}

/// 240 / 241. 例とリファレンス。
final class ReferenceTests: XCTestCase {

    func testReferenceIsWellFormed() {
        for entry in ReferenceLibrary.all {
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertFalse(entry.summary.isEmpty)
            XCTAssertFalse(entry.example.isEmpty)
        }
        let ids = ReferenceLibrary.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// 言語を指定しても、共通の項目は残ること。
    func testEntriesForLanguageIncludeCommonOnes() {
        let go = ReferenceLibrary.entries(languageID: "go")
        XCTAssertTrue(go.contains { $0.id == "go-slice" })
        XCTAssertTrue(go.contains { $0.languageID == nil })
        XCTAssertFalse(go.contains { $0.languageID == "rust" })
    }

    func testSearchAndFilter() {
        XCTAssertTrue(ReferenceLibrary.search("match").contains {
            $0.id == "rust-match"
        })
        let concepts = ReferenceLibrary.search("", kind: .concept)
        XCTAssertTrue(concepts.allSatisfy { $0.kind == .concept })
        XCTAssertNotNil(ReferenceLibrary.entry(id: "concept-variable"))
        XCTAssertNil(ReferenceLibrary.entry(id: "ない"))
    }

    func testKindDisplayNames() {
        for kind in ReferenceEntry.Kind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty)
        }
    }

    func testExampleSearchLooksEverywhere() {
        let sources = Set(ExampleSearch.candidates().map(\.source))
        XCTAssertEqual(sources, [.sample, .snippet, .reference, .tutorial])
    }

    func testExampleSearchByLanguage() {
        let go = ExampleSearch.search("", languageID: "go")
        XCTAssertFalse(go.isEmpty)
        XCTAssertTrue(go.allSatisfy { $0.languageID == "go" })
    }

    func testExampleSearchBySource() {
        let onlyTutorials = ExampleSearch.search("", sources: [.tutorial])
        XCTAssertFalse(onlyTutorials.isEmpty)
        XCTAssertTrue(onlyTutorials.allSatisfy { $0.source == .tutorial })
    }

    func testExampleSearchFindsAKnownTitle() {
        XCTAssertTrue(ExampleSearch.search("辞書を数える").contains {
            $0.id == "sample:map-kotlin"
        })
    }

    func testUserSamplesAreSearchable() {
        var library = SampleLibrary()
        library.add(SampleLibrary.makeSample(title: "ぼくのれい", languageID: "go",
                                             source: "package main"))
        XCTAssertTrue(ExampleSearch.search("ぼくのれい", library: library).contains {
            $0.title == "ぼくのれい"
        })
    }
}

/// 242. 実行できない理由。
final class RunAvailabilityTests: XCTestCase {

    func testBuiltInLanguageRunsWithoutNetwork() {
        let availability = RunAvailability.check(fileName: "main.go",
                                                 allowsRemoteExecution: false,
                                                 isOnline: false)
        XCTAssertTrue(availability.canRun)
        XCTAssertTrue(availability.text.contains("通信は要りません"))
    }

    func testUnknownExtensionExplainsItself() {
        let availability = RunAvailability.check(fileName: "notes.xyz",
                                                 allowsRemoteExecution: true)
        XCTAssertFalse(availability.canRun)
        XCTAssertTrue(availability.reason.contains(".xyz"))
        XCTAssertNotNil(availability.remedy)
    }

    func testNoExtensionSuggestsAddingOne() {
        let availability = RunAvailability.check(fileName: "LICENSE",
                                                 allowsRemoteExecution: true)
        XCTAssertFalse(availability.canRun)
        XCTAssertTrue(try! XCTUnwrap(availability.remedy).contains("拡張子"))
    }

    func testOfflineBlocksTheServerAndTheWebRuntime() {
        let remote = RunAvailability.check(plan: .remote(
            RemoteSpec(pistonLanguage: "cobol", wandboxLanguage: nil,
                       fileName: "main.cob"),
            ProgrammingLanguage(id: "cobol", name: "COBOL",
                                fileExtensions: ["cob"])),
                                           fileName: "main.cob", isOnline: false)
        XCTAssertFalse(remote.canRun)
        XCTAssertTrue(remote.reason.contains("通信"))

        let local = RunAvailability.check(
            plan: .local(.python, ProgrammingLanguage(id: "python", name: "Python",
                                                      fileExtensions: ["py"])),
            fileName: "main.py", isOnline: false)
        XCTAssertFalse(local.canRun)
    }

    func testServerRunSaysWhereTheCodeGoes() {
        let availability = RunAvailability.check(plan: .remote(
            RemoteSpec(pistonLanguage: "cobol", wandboxLanguage: nil,
                       fileName: "main.cob"),
            ProgrammingLanguage(id: "cobol", name: "COBOL",
                                fileExtensions: ["cob"])),
                                                fileName: "main.cob")
        XCTAssertTrue(availability.canRun)
        XCTAssertTrue(availability.text.contains("サーバーに送られます"))
    }

    func testHTMLRunsInTheWebView() {
        let availability = RunAvailability.check(fileName: "index.html", kind: .web,
                                                 allowsRemoteExecution: false)
        XCTAssertTrue(availability.canRun)
        XCTAssertTrue(availability.reason.contains("WebView"))
    }
}
