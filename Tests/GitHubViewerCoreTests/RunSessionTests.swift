import XCTest
@testable import GitHubViewerCore

final class RunSessionTests: XCTestCase {

    // MARK: - 基本

    func testRunsAndMeasures() throws {
        let result = try RunSession.run(languageID: "go", source: """
        package main
        import "fmt"
        func main() { fmt.Println("こんにちは") }
        """)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "こんにちは")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.succeeded)
        XCTAssertGreaterThan(result.steps, 0)          // 100. ステップ数
        XCTAssertGreaterThan(result.duration, 0)       // 98. 実行時間
        XCTAssertEqual(result.engineName, "内蔵 Go 処理系")  // 113. どの処理系か
    }

    func testMissingEngine() {
        XCTAssertThrowsError(try RunSession.run(languageID: "cobol", source: "")) { error in
            XCTAssertEqual(error as? RunSessionError, .noEngine("cobol"))
        }
    }

    func testEveryRegisteredEngineRunsThroughTheSession() {
        for engine in MiniLangRegistry.all {
            XCTAssertTrue(RunSession.hasEngine(for: engine.languageID),
                          "\(engine.languageID) が見つかりません")
        }
    }

    // MARK: - 128. 終了コード

    func testExitCodeIsReported() throws {
        let result = try RunSession.run(languageID: "javascript",
                                        source: "console.log('前'); exit(3);")
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        // exit の前に出したものは残る。
        XCTAssertTrue(result.output.contains("前"))
    }

    // MARK: - 102. 実行制限

    func testStepLimitStopsAnInfiniteLoop() throws {
        var options = RunOptions()
        options.maximumSteps = 10_000
        let result = try RunSession.run(languageID: "javascript",
                                        source: "while (true) { }", options: options)
        XCTAssertNotNil(result.failureText)
        XCTAssertTrue(result.failureText?.contains("上限") == true,
                      result.failureText ?? "")
    }

    func testOutputLimit() throws {
        var options = RunOptions()
        options.maximumOutputBytes = 200
        let result = try RunSession.run(
            languageID: "javascript",
            source: "for (let i = 0; i < 1000; i++) { console.log('あいうえお'); }",
            options: options)
        XCTAssertTrue(result.output.contains("上限"), "打ち切られていません")
    }

    // MARK: - 129. 時間の上限

    func testTimeLimit() throws {
        var options = RunOptions()
        options.timeLimit = 0.15
        options.maximumSteps = 500_000_000
        let result = try RunSession.run(languageID: "javascript",
                                        source: "while (true) { }", options: options)
        XCTAssertTrue(result.execution.timedOut, result.failureText ?? "")
        XCTAssertLessThan(result.duration, 5)
    }

    // MARK: - 96 / 127. コマンドライン引数

    func testArgumentsReachTheProgram() throws {
        var options = RunOptions()
        options.arguments = ["alpha", "beta"]
        let result = try RunSession.run(languageID: "javascript", source: """
        for (const a of ARGV) { console.log(a); }
        """, options: options)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "alpha\nbeta")
    }

    func testProgramNameIsInFullArgv() throws {
        var options = RunOptions()
        options.arguments = ["x"]
        options.programName = "main.js"
        let result = try RunSession.run(languageID: "javascript",
                                        source: "console.log(__argv[0]);",
                                        options: options)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "main.js")
    }

    func testJavaMainReceivesArguments() throws {
        var options = RunOptions()
        options.arguments = ["ひとつ", "ふたつ"]
        let result = try RunSession.run(languageID: "java", source: """
        public class Main {
            public static void main(String[] args) {
                System.out.println(args.length);
                System.out.println(args[0]);
            }
        }
        """, options: options)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "2\nひとつ")
    }

    // MARK: - 123. 乱数の種

    func testSameSeedGivesSameNumbers() throws {
        let source = """
        for (let i = 0; i < 5; i++) { console.log(Math.random()); }
        """
        var options = RunOptions()
        options.randomSeed = 42
        let first = try RunSession.run(languageID: "javascript", source: source,
                                       options: options)
        let second = try RunSession.run(languageID: "javascript", source: source,
                                        options: options)
        XCTAssertEqual(first.output, second.output)
        XCTAssertFalse(first.output.isEmpty)

        options.randomSeed = 43
        let third = try RunSession.run(languageID: "javascript", source: source,
                                       options: options)
        XCTAssertNotEqual(first.output, third.output)
    }

    // MARK: - 122. 仮想ファイル

    func testProgramCanReadAndWriteVirtualFiles() throws {
        var options = RunOptions()
        options.files = ["入力.txt": "1\n2\n3\n"]
        let result = try RunSession.run(languageID: "javascript", source: """
        const lines = readLines("入力.txt");
        let total = 0;
        for (const line of lines) { total += Number(line); }
        writeFile("結果.txt", String(total));
        console.log(total);
        """, options: options)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "6")
        XCTAssertEqual(result.files["結果.txt"], "6")
    }

    func testMissingFileIsAnError() throws {
        let result = try RunSession.run(languageID: "javascript",
                                        source: #"readFile("ない.txt");"#)
        XCTAssertTrue(result.failureText?.contains("ファイルがありません") == true,
                      result.failureText ?? "")
    }

    func testFileExistsAndList() throws {
        var options = RunOptions()
        options.files = ["a.txt": "x"]
        let result = try RunSession.run(languageID: "javascript", source: """
        console.log(fileExists("a.txt"));
        console.log(fileExists("b.txt"));
        writeFile("b.txt", "y");
        console.log(listFiles().join(","));
        """, options: options)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "true\nfalse\na.txt,b.txt")
    }

    // MARK: - 112. 構文チェックのみ

    func testSyntaxCheckAcceptsGoodCode() throws {
        let check = try RunSession.checkSyntax(languageID: "go", source: """
        package main
        func main() {}
        """)
        XCTAssertTrue(check.isValid)
        XCTAssertEqual(check.errorCount, 0)
    }

    func testSyntaxCheckReportsErrors() throws {
        let check = try RunSession.checkSyntax(languageID: "go", source: """
        package main
        func main( {
        """)
        XCTAssertFalse(check.isValid)
        XCTAssertGreaterThan(check.errorCount, 0)
        XCTAssertFalse(check.diagnosticsText.isEmpty)
    }

    func testSyntaxCheckDoesNotRun() throws {
        // 動かしてしまうと無限ループになるコード。
        let check = try RunSession.checkSyntax(languageID: "javascript",
                                               source: "while (true) {}")
        XCTAssertTrue(check.isValid)
    }

    // MARK: - 104. 入力を変えて繰り返す

    func testBatchRun() throws {
        let batch = try RunSession.batch(
            languageID: "javascript",
            source: "console.log(Number(readLine()) * 2);",
            inputs: ["1", "5", "10"])
        XCTAssertEqual(batch.pairs.map { $0.output.trimmingCharacters(in: .whitespacesAndNewlines) },
                       ["2", "10", "20"])
        XCTAssertTrue(batch.table.contains("| 入力 | 出力 |"))
    }

    // MARK: - 110. 複数言語の比較

    func testCompareAcrossLanguages() {
        let results = RunSession.compare([
            "javascript": "console.log(6 * 7);",
            "go": """
            package main
            import "fmt"
            func main() { fmt.Println(6 * 7) }
            """
        ])
        XCTAssertEqual(results.count, 2)
        for result in results {
            XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                           "42", result.languageID)
        }
        let table = RunSharing.comparisonTable(results)
        XCTAssertTrue(table.contains("| go | 42 |"), table)
    }

    func testCompareSkipsUnknownLanguages() {
        XCTAssertTrue(RunSession.compare(["cobol": "x"]).isEmpty)
    }

    // MARK: - 状態の表示

    func testStatusLine() throws {
        let result = try RunSession.run(languageID: "javascript", source: "1 + 1;")
        XCTAssertTrue(result.statusLine.contains("ステップ"), result.statusLine)
        XCTAssertTrue(result.statusLine.contains("終了コード 0"), result.statusLine)
    }
}

final class RunFormattingTests: XCTestCase {
    func testNumber() {
        XCTAssertEqual(RunFormatting.number(5), "5")
        XCTAssertEqual(RunFormatting.number(1234), "1,234")
        XCTAssertEqual(RunFormatting.number(1234567), "1,234,567")
    }

    func testDuration() {
        XCTAssertEqual(RunFormatting.duration(0.05), "50 ミリ秒")
        XCTAssertEqual(RunFormatting.duration(1.5), "1.50 秒")
        XCTAssertTrue(RunFormatting.duration(90).contains("分"))
    }
}

final class ArgumentParserTests: XCTestCase {
    func testSimpleSplit() {
        XCTAssertEqual(ArgumentParser.split("-n 3 file.txt"), ["-n", "3", "file.txt"])
    }

    func testDoubleQuotes() {
        XCTAssertEqual(ArgumentParser.split(#"say "hello world""#),
                       ["say", "hello world"])
    }

    func testSingleQuotes() {
        XCTAssertEqual(ArgumentParser.split("say 'a b'"), ["say", "a b"])
    }

    func testEmptyArgumentIsKept() {
        XCTAssertEqual(ArgumentParser.split(#"a "" b"#), ["a", "", "b"])
    }

    func testEscapedSpace() {
        XCTAssertEqual(ArgumentParser.split(#"a\ b"#), ["a b"])
    }

    func testExtraSpacesAreIgnored() {
        XCTAssertEqual(ArgumentParser.split("  a   b  "), ["a", "b"])
    }

    func testEmptyLine() {
        XCTAssertTrue(ArgumentParser.split("   ").isEmpty)
    }

    func testJoinQuotesWhenNeeded() {
        XCTAssertEqual(ArgumentParser.join(["a", "b c"]), #"a "b c""#)
        XCTAssertEqual(ArgumentParser.join(["a", ""]), #"a """#)
    }

    func testRoundTrip() {
        let arguments = ["-o", "出力 1.txt", "plain", ""]
        XCTAssertEqual(ArgumentParser.split(ArgumentParser.join(arguments)), arguments)
    }
}

final class AutoRunPolicyTests: XCTestCase {
    func testNever() {
        XCTAssertFalse(AutoRunPolicy.never.shouldRun(on: .save))
        XCTAssertFalse(AutoRunPolicy.never.shouldRun(on: .pause))
    }

    func testOnSave() {
        XCTAssertTrue(AutoRunPolicy.onSave.shouldRun(on: .save))
        XCTAssertFalse(AutoRunPolicy.onSave.shouldRun(on: .pause))
    }

    func testOnPause() {
        XCTAssertTrue(AutoRunPolicy.onPause.shouldRun(on: .pause))
        XCTAssertNotNil(AutoRunPolicy.onPause.debounce)
        XCTAssertNil(AutoRunPolicy.onSave.debounce)
    }

    func testEveryCaseHasAName() {
        for policy in AutoRunPolicy.allCases {
            XCTAssertFalse(policy.displayName.isEmpty)
        }
    }
}

final class RunHistoryTests: XCTestCase {
    private func makeEntry(_ name: String) -> RunHistoryEntry {
        RunHistoryEntry(languageID: name, source: "print(1)", output: "1")
    }

    func testNewestFirst() {
        let history = RunHistory()
        history.add(makeEntry("go"))
        history.add(makeEntry("rust"))
        XCTAssertEqual(history.all.map(\.languageID), ["rust", "go"])
    }

    func testLimit() {
        let history = RunHistory(limit: 2)
        history.add(makeEntry("a"))
        history.add(makeEntry("b"))
        history.add(makeEntry("c"))
        XCTAssertEqual(history.all.map(\.languageID), ["c", "b"])
    }

    func testFilterByLanguage() {
        let history = RunHistory()
        history.add(makeEntry("go"))
        history.add(makeEntry("rust"))
        XCTAssertEqual(history.entries(languageID: "go").count, 1)
    }

    func testClear() {
        let history = RunHistory()
        history.add(makeEntry("go"))
        history.clear()
        XCTAssertTrue(history.all.isEmpty)
    }

    func testFindBySource() {
        let history = RunHistory()
        history.add(RunHistoryEntry(languageID: "go", source: "A", output: "1"))
        history.add(RunHistoryEntry(languageID: "go", source: "B", output: "2"))
        XCTAssertEqual(history.lastEntry(forSource: "A")?.output, "1")
        XCTAssertNil(history.lastEntry(forSource: "C"))
    }

    func testEntryFromResult() throws {
        let result = try RunSession.run(languageID: "javascript",
                                        source: "console.log(1);")
        let entry = RunHistoryEntry(result: result, source: "console.log(1);")
        XCTAssertTrue(entry.succeeded)
        XCTAssertEqual(entry.summary, "1")
    }

    func testSummaryWhenEmpty() {
        XCTAssertEqual(RunHistoryEntry(languageID: "go", source: "", output: "").summary,
                       "(出力なし)")
    }

    func testSummaryShowsFailure() {
        let entry = RunHistoryEntry(languageID: "go", source: "", output: "",
                                    failureText: "壊れています\n2 行目")
        XCTAssertEqual(entry.summary, "壊れています")
    }
}

final class RunInputStoreTests: XCTestCase {
    func testSaveAndRead() {
        let store = RunInputStore()
        store.setInput("3 4", for: "a.go")
        store.setArguments(["-v"], for: "a.go")
        XCTAssertEqual(store.entry(for: "a.go").input, "3 4")
        XCTAssertEqual(store.entry(for: "a.go").arguments, ["-v"])
    }

    func testUnknownKeyIsEmpty() {
        XCTAssertEqual(RunInputStore().entry(for: "none"), RunInputStore.Entry())
    }

    func testApplyToOptions() {
        let store = RunInputStore()
        store.setInput("hello", for: "a.go")
        let options = store.apply(to: RunOptions(), key: "a.go")
        XCTAssertEqual(options.input, "hello")
    }

    func testSaveAndRestore() {
        let store = RunInputStore()
        store.setInput("x", for: "a.go")
        let restored = RunInputStore(json: store.encoded())
        XCTAssertEqual(restored.entry(for: "a.go").input, "x")
        XCTAssertEqual(restored.keys, ["a.go"])
    }

    func testEmptyEntryIsDropped() {
        let store = RunInputStore()
        store.setInput("x", for: "a.go")
        store.setInput("", for: "a.go")
        XCTAssertTrue(store.keys.isEmpty)
    }
}

final class RunTaskTests: XCTestCase {
    func testBackgroundRunFinishes() throws {
        let task = RunTask(languageID: "javascript", source: "console.log('できた');")
        let result = try task.value(timeout: 20)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "できた")
        XCTAssertTrue(task.isFinished)
    }

    func testCancellationStopsALoop() throws {
        var options = RunOptions()
        options.maximumSteps = 500_000_000
        options.timeLimit = nil
        let task = RunTask(languageID: "javascript", source: "while (true) { }",
                           options: options)
        // 動き出すのを少し待ってから止める。
        Thread.sleep(forTimeInterval: 0.2)
        task.cancel()

        let result = task.wait(timeout: 20)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.execution.wasCancelled == true,
                      result?.failureText ?? "結果なし")
        XCTAssertTrue(task.isCancelled)
    }

    func testFinishCallback() throws {
        let expectation = expectation(description: "終わる")
        let task = RunTask(languageID: "javascript", source: "console.log(1);")
        task.onFinish = { _ in expectation.fulfill() }
        // すでに終わっていることもあるので、両方を見る。
        if task.isFinished { expectation.fulfill() }
        wait(for: [expectation], timeout: 20)
    }

    func testUnknownLanguageFails() {
        let task = RunTask(languageID: "cobol", source: "")
        XCTAssertThrowsError(try task.value(timeout: 10))
    }
}
