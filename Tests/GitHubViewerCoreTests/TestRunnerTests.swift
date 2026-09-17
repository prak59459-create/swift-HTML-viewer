import XCTest
@testable import GitHubViewerCore

final class TestRunnerTests: XCTestCase {
    let doubler = "console.log(Number(readLine()) * 2);"

    func testPassingCase() {
        let test = RunTestCase(name: "2 倍", input: "4", expectedOutput: "8")
        let result = TestRunner.run(test, languageID: "javascript", source: doubler)
        XCTAssertTrue(result.passed, result.failureReason ?? "")
        XCTAssertNil(result.failureReason)
        XCTAssertEqual(result.actualOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                       "8")
    }

    func testFailingCaseHasADiff() {
        let test = RunTestCase(name: "わざと違う", input: "4", expectedOutput: "9")
        let result = TestRunner.run(test, languageID: "javascript", source: doubler)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failureReason, "出力が期待と違います")
        XCTAssertFalse(result.diff.isEmpty)
    }

    func testWhitespaceIsIgnoredByDefault() {
        let test = RunTestCase(name: "空白", input: "4", expectedOutput: "  8  \n\n")
        XCTAssertTrue(TestRunner.run(test, languageID: "javascript",
                                     source: doubler).passed)
    }

    func testStrictWhitespace() {
        let test = RunTestCase(name: "厳密", input: "4", expectedOutput: "8",
                               trimsWhitespace: false)
        // 実際の出力は "8\n" なので、そのままでは通らない。
        XCTAssertFalse(TestRunner.run(test, languageID: "javascript",
                                      source: doubler).passed)
    }

    func testExpectedExitCode() {
        let test = RunTestCase(name: "終了コード", expectedExitCode: 2)
        let result = TestRunner.run(test, languageID: "javascript", source: "exit(2);")
        XCTAssertTrue(result.passed, result.failureReason ?? "")
    }

    func testWrongExitCode() {
        let test = RunTestCase(name: "終了コード", expectedExitCode: 0)
        let result = TestRunner.run(test, languageID: "javascript", source: "exit(5);")
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failureReason?.contains("終了コード") == true)
    }

    func testRuntimeErrorIsAFailure() {
        let test = RunTestCase(name: "落ちる", expectedOutput: "")
        let result = TestRunner.run(test, languageID: "javascript", source: "ないやつ();")
        XCTAssertFalse(result.passed)
        XCTAssertNotNil(result.failureReason)
    }

    func testUnknownLanguageIsAFailure() {
        let result = TestRunner.run(RunTestCase(name: "x"), languageID: "cobol",
                                    source: "")
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.exitCode, -1)
    }

    func testArgumentsAreUsed() {
        let test = RunTestCase(name: "引数", arguments: ["ほげ"], expectedOutput: "ほげ")
        let result = TestRunner.run(test, languageID: "javascript",
                                    source: "console.log(ARGV[0]);")
        XCTAssertTrue(result.passed, result.failureReason ?? "")
    }

    func testFilesAreUsed() {
        let test = RunTestCase(name: "ファイル", expectedOutput: "中身",
                               files: ["a.txt": "中身"])
        let result = TestRunner.run(test, languageID: "javascript",
                                    source: #"console.log(readFile("a.txt"));"#)
        XCTAssertTrue(result.passed, result.failureReason ?? "")
    }

    func testOutputIsNotCheckedWhenNoExpectation() {
        let test = RunTestCase(name: "見ない")
        XCTAssertTrue(TestRunner.run(test, languageID: "javascript",
                                     source: "console.log('なんでも');").passed)
    }

    func testReport() {
        let tests = [
            RunTestCase(name: "合う", input: "1", expectedOutput: "2"),
            RunTestCase(name: "合わない", input: "1", expectedOutput: "3")
        ]
        let report = TestRunner.run(tests, languageID: "javascript", source: doubler)
        XCTAssertEqual(report.passedCount, 1)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertFalse(report.allPassed)
        XCTAssertTrue(report.summary.contains("1 / 2"))
        XCTAssertTrue(report.report.contains("✓ 合う"))
        XCTAssertTrue(report.report.contains("✗ 合わない"))
    }

    func testEmptyReport() {
        let report = RunTestReport()
        XCTAssertFalse(report.allPassed)
        XCTAssertEqual(report.summary, "テストがありません")
    }

    func testAcceptingCurrentOutput() {
        let test = RunTestCase(name: "採用")
        let updated = TestRunner.accepting(test, output: "\u{1B}[32mよし\u{1B}[0m")
        XCTAssertEqual(updated.expectedOutput, "よし")
    }

    func testNormalizeDropsTrailingSpaces() {
        XCTAssertEqual(TestRunner.normalize("a  \nb\t\n\n", trims: true), "a\nb")
        XCTAssertEqual(TestRunner.normalize("a  \n", trims: false), "a  \n")
    }

    func testCasesAreCodable() throws {
        let test = RunTestCase(name: "保存", input: "1", expectedOutput: "2")
        let data = try JSONEncoder().encode([test])
        let back = try JSONDecoder().decode([RunTestCase].self, from: data)
        XCTAssertEqual(back.first?.name, "保存")
    }
}

final class REPLTests: XCTestCase {
    func testKeepsStateBetweenLines() {
        let repl = REPL(languageID: "javascript")
        repl.evaluate("let a = 10;")
        let entry = repl.evaluate("console.log(a + 5);")
        XCTAssertEqual(entry.output.trimmingCharacters(in: .whitespacesAndNewlines), "15")
        XCTAssertTrue(entry.succeeded)
    }

    func testOnlyNewOutputIsShown() {
        let repl = REPL(languageID: "javascript")
        repl.evaluate("console.log('いち');")
        let entry = repl.evaluate("console.log('に');")
        XCTAssertEqual(entry.output.trimmingCharacters(in: .whitespacesAndNewlines), "に")
    }

    func testBadLineIsNotRemembered() {
        let repl = REPL(languageID: "javascript")
        repl.evaluate("let a = 1;")
        let bad = repl.evaluate("ないやつ();")
        XCTAssertFalse(bad.succeeded)
        XCTAssertNotNil(bad.failureText)

        let good = repl.evaluate("console.log(a);")
        XCTAssertEqual(good.output.trimmingCharacters(in: .whitespacesAndNewlines), "1")
        XCTAssertFalse(repl.source.contains("ないやつ"))
    }

    func testEmptyLine() {
        let repl = REPL(languageID: "javascript")
        let entry = repl.evaluate("   ")
        XCTAssertEqual(entry.output, "")
        XCTAssertTrue(entry.succeeded)
    }

    func testHistory() {
        let repl = REPL(languageID: "javascript")
        repl.evaluate("let a = 1;")
        repl.evaluate("console.log(a);")
        XCTAssertEqual(repl.entries.count, 2)
    }

    func testUndo() {
        let repl = REPL(languageID: "javascript")
        repl.evaluate("let a = 1;")
        repl.evaluate("let b = 2;")
        XCTAssertTrue(repl.undoLast())
        XCTAssertFalse(repl.source.contains("let b"))
    }

    func testUndoOnEmptyREPL() {
        XCTAssertFalse(REPL(languageID: "javascript").undoLast())
    }

    func testReset() {
        let repl = REPL(languageID: "javascript")
        repl.evaluate("let a = 1;")
        repl.reset()
        XCTAssertTrue(repl.source.isEmpty)
        XCTAssertTrue(repl.entries.isEmpty)
    }

    func testUnknownLanguage() {
        let entry = REPL(languageID: "cobol").evaluate("x")
        XCTAssertFalse(entry.succeeded)
    }

    func testAddedText() {
        XCTAssertEqual(REPL.addedText(previous: "ab", whole: "abc"), "c")
        XCTAssertEqual(REPL.addedText(previous: "", whole: "abc"), "abc")
        // 前の出力が変わったら、まるごと見せる。
        XCTAssertEqual(REPL.addedText(previous: "xy", whole: "abc"), "abc")
    }
}

final class ScratchpadTests: XCTestCase {
    func testResultsLineUpWithLines() {
        let lines = Scratchpad.evaluate(languageID: "javascript", source: """
        let a = 2;
        console.log(a * 3);
        console.log("おわり");
        """)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].output, "")
        XCTAssertEqual(lines[1].output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "6")
        XCTAssertEqual(lines[2].output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "おわり")
    }

    func testBlankLinesAreSkipped() {
        let lines = Scratchpad.evaluate(languageID: "javascript",
                                        source: "console.log(1);\n\nconsole.log(2);")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].output, "")
    }

    func testIncompleteLineReportsAFailureButKeepsGoing() {
        let lines = Scratchpad.evaluate(languageID: "javascript", source: """
        function f() {
        return 1;
        }
        console.log(f());
        """)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[3].output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "1")
    }
}

final class ProjectRunnerTests: XCTestCase {
    func testSingleFileProject() throws {
        let project = RunProject(languageID: "javascript",
                                 files: ["main.js": "console.log('ひとつ');"],
                                 entryFile: "main.js")
        let result = try ProjectRunner.run(project)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "ひとつ")
    }

    func testDependencyComesFirst() {
        let project = RunProject(languageID: "javascript", files: [
            "main.js": "import \"helper.js\"\nconsole.log(twice(3));",
            "helper.js": "function twice(x) { return x * 2; }"
        ], entryFile: "main.js")
        XCTAssertEqual(ProjectRunner.resolveOrder(project), ["helper.js", "main.js"])
    }

    func testImportedFileIsUsable() throws {
        let project = RunProject(languageID: "javascript", files: [
            "main.js": "import \"helper.js\"\nconsole.log(twice(3));",
            "helper.js": "function twice(x) { return x * 2; }"
        ], entryFile: "main.js")
        let result = try ProjectRunner.run(project)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "6")
    }

    func testImportLineIsRemoved() {
        let project = RunProject(languageID: "javascript", files: [
            "main.js": "import \"helper.js\"\nconsole.log(1);",
            "helper.js": "// なにもしない"
        ], entryFile: "main.js")
        XCTAssertFalse(ProjectRunner.combine(project).contains("import \"helper.js\""))
    }

    func testUnknownImportIsKept() {
        let project = RunProject(languageID: "javascript",
                                 files: ["main.js": "import \"どこか.js\"\nconsole.log(1);"],
                                 entryFile: "main.js")
        XCTAssertTrue(ProjectRunner.combine(project).contains("import \"どこか.js\""))
    }

    func testDeepChain() {
        let project = RunProject(languageID: "javascript", files: [
            "a.js": "import \"b.js\"",
            "b.js": "import \"c.js\"",
            "c.js": "// 最後"
        ], entryFile: "a.js")
        XCTAssertEqual(ProjectRunner.resolveOrder(project), ["c.js", "b.js", "a.js"])
    }

    func testCyclesDoNotHang() {
        let project = RunProject(languageID: "javascript", files: [
            "a.js": "import \"b.js\"",
            "b.js": "import \"a.js\""
        ], entryFile: "a.js")
        let order = ProjectRunner.resolveOrder(project)
        XCTAssertEqual(Set(order), ["a.js", "b.js"])
        XCTAssertEqual(order.count, 2)
    }

    func testUnusedFilesStillCome() {
        let project = RunProject(languageID: "javascript", files: [
            "main.js": "console.log(1);",
            "余り.js": "// 読まれない"
        ], entryFile: "main.js")
        XCTAssertEqual(ProjectRunner.resolveOrder(project).count, 2)
        XCTAssertEqual(ProjectRunner.resolveOrder(project).first, "main.js")
    }

    func testExtensionIsGuessed() {
        let project = RunProject(languageID: "go", files: [
            "main.go": "import \"helper\"",
            "helper.go": "// ある"
        ], entryFile: "main.go")
        XCTAssertEqual(ProjectRunner.dependencies(of: "main.go", in: project),
                       ["helper.go"])
    }

    func testIncludeStyle() {
        let project = RunProject(languageID: "cpp", files: [
            "main.cpp": "#include \"util.cpp\"",
            "util.cpp": "// ある"
        ], entryFile: "main.cpp")
        XCTAssertEqual(ProjectRunner.dependencies(of: "main.cpp", in: project),
                       ["util.cpp"])
    }

    func testAngleBracketIncludeOfSystemHeaderIsIgnored() {
        let project = RunProject(languageID: "cpp",
                                 files: ["main.cpp": "#include <iostream>"],
                                 entryFile: "main.cpp")
        XCTAssertTrue(ProjectRunner.dependencies(of: "main.cpp", in: project).isEmpty)
    }

    func testFilesAreAlsoAvailableAsVirtualFiles() throws {
        let project = RunProject(languageID: "javascript", files: [
            "main.js": #"console.log(readFile("データ.txt"));"#,
            "データ.txt": "中身です"
        ], entryFile: "main.js")
        let result = try ProjectRunner.run(project)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "中身です")
    }

    func testSelfImportIsIgnored() {
        let project = RunProject(languageID: "javascript",
                                 files: ["a.js": "import \"a.js\""], entryFile: "a.js")
        XCTAssertTrue(ProjectRunner.dependencies(of: "a.js", in: project).isEmpty)
    }
}

final class VirtualFileSystemTests: XCTestCase {
    func testWriteAndRead() {
        let files = VirtualFileSystem()
        XCTAssertTrue(files.write("あいう", to: "a.txt"))
        XCTAssertEqual(files.read("a.txt"), "あいう")
        XCTAssertTrue(files.exists("a.txt"))
    }

    func testPathIsNormalised() {
        let files = VirtualFileSystem(files: ["a.txt": "x"])
        XCTAssertEqual(files.read("./a.txt"), "x")
        XCTAssertEqual(files.read("/a.txt"), "x")
    }

    func testAppend() {
        let files = VirtualFileSystem(files: ["a": "1"])
        XCTAssertTrue(files.append("2", to: "a"))
        XCTAssertEqual(files.read("a"), "12")
    }

    func testAppendToMissingFileCreatesIt() {
        let files = VirtualFileSystem()
        XCTAssertTrue(files.append("x", to: "new"))
        XCTAssertEqual(files.read("new"), "x")
    }

    func testRemove() {
        let files = VirtualFileSystem(files: ["a": "1"])
        XCTAssertTrue(files.remove("a"))
        XCTAssertFalse(files.remove("a"))
        XCTAssertNil(files.read("a"))
    }

    func testFileSizeLimit() {
        let files = VirtualFileSystem(maximumFileBytes: 4)
        XCTAssertFalse(files.write("12345", to: "a"))
        XCTAssertTrue(files.write("123", to: "a"))
    }

    func testTotalLimit() {
        let files = VirtualFileSystem(maximumFileBytes: 100, maximumTotalBytes: 6)
        XCTAssertTrue(files.write("123", to: "a"))
        XCTAssertTrue(files.write("456", to: "b"))
        XCTAssertFalse(files.write("789", to: "c"))
        // 上書きはその分を差し引いて数える。
        XCTAssertTrue(files.write("abc", to: "a"))
    }

    func testLines() {
        let files = VirtualFileSystem(files: ["a": "1\n2\n3\n"])
        XCTAssertEqual(files.lines(at: "a"), ["1", "2", "3"])
        XCTAssertNil(files.lines(at: "none"))
    }

    func testNames() {
        let files = VirtualFileSystem(files: ["b": "", "a": ""])
        XCTAssertEqual(files.fileNames, ["a", "b"])
    }

    func testTotalBytes() {
        let files = VirtualFileSystem(files: ["a": "12", "b": "345"])
        XCTAssertEqual(files.totalBytes, 5)
    }

    func testRemoveAll() {
        let files = VirtualFileSystem(files: ["a": "1"])
        files.removeAll()
        XCTAssertTrue(files.fileNames.isEmpty)
    }

    func testSnapshot() {
        let files = VirtualFileSystem(files: ["a": "1"])
        XCTAssertEqual(files.snapshot(), ["a": "1"])
    }
}

final class MLRandomTests: XCTestCase {
    func testSameSeedSameSequence() {
        let first = MLRandom(seed: 7)
        let second = MLRandom(seed: 7)
        for _ in 0..<10 { XCTAssertEqual(first.next(), second.next()) }
    }

    func testDifferentSeeds() {
        XCTAssertNotEqual(MLRandom(seed: 1).next(), MLRandom(seed: 2).next())
    }

    func testUnseededIsMarked() {
        XCTAssertFalse(MLRandom().isSeeded)
        XCTAssertTrue(MLRandom(seed: 0).isSeeded)
    }

    func testDoubleRange() {
        let random = MLRandom(seed: 5)
        for _ in 0..<200 {
            let value = random.double()
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
        }
    }

    func testIntRange() {
        let random = MLRandom(seed: 5)
        for _ in 0..<200 {
            let value = random.int(in: 3...7)
            XCTAssertGreaterThanOrEqual(value, 3)
            XCTAssertLessThanOrEqual(value, 7)
        }
    }

    func testSinglePointRange() {
        XCTAssertEqual(MLRandom(seed: 1).int(in: 4...4), 4)
    }

    func testDoubleInRange() {
        let value = MLRandom(seed: 2).double(in: 1.0..<2.0)
        XCTAssertGreaterThanOrEqual(value, 1.0)
        XCTAssertLessThan(value, 2.0)
    }

    func testShuffleKeepsEverything() {
        let shuffled = MLRandom(seed: 3).shuffled(Array(1...20))
        XCTAssertEqual(Set(shuffled), Set(1...20))
    }

    func testShuffleOfShortArray() {
        XCTAssertEqual(MLRandom(seed: 1).shuffled([9]), [9])
        XCTAssertTrue(MLRandom(seed: 1).shuffled([Int]()).isEmpty)
    }

    func testElement() {
        XCTAssertNotNil(MLRandom(seed: 1).element(of: [1, 2, 3]))
        XCTAssertNil(MLRandom(seed: 1).element(of: [Int]()))
    }

    func testSpreadIsReasonable() {
        // 0〜9 を 1000 回引いて、どの目も出ることを確かめる。
        let random = MLRandom(seed: 11)
        var seen = Set<Int64>()
        for _ in 0..<1000 { seen.insert(random.int(in: 0...9)) }
        XCTAssertEqual(seen.count, 10)
    }
}
