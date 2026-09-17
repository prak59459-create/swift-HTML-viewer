import XCTest
@testable import GitHubViewerCore

final class InteractiveRunTests: XCTestCase {

    /// 出力が書かれたそばから届く。
    func testOutputArrivesWhileRunning() {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var pieces: [String] = []
            func append(_ text: String) {
                lock.lock()
                pieces.append(text)
                lock.unlock()
            }
            var all: [String] {
                lock.lock()
                defer { lock.unlock() }
                return pieces
            }
        }
        let box = Box()
        let run = InteractiveRun(languageID: "javascript", source: """
        console.log("いち");
        console.log("に");
        console.log("さん");
        """)
        run.onOutput = { box.append($0) }
        let result = run.wait(timeout: 20)

        XCTAssertNotNil(result)
        // 1 回で全部ではなく、少しずつ届いている。
        XCTAssertGreaterThan(box.all.count, 1)
        XCTAssertTrue(box.all.joined().contains("いち"))
        XCTAssertTrue(box.all.joined().contains("さん"))
    }

    /// プログラムが入力を待ったら知らせが来て、送った行が届く。
    func testInteractiveInput() {
        let run = InteractiveRun(languageID: "javascript", source: """
        const a = readLine();
        console.log("受け取り: " + a);
        const b = readLine();
        console.log("受け取り: " + b);
        """)
        run.inputTimeout = 5
        run.onNeedsInput = { [weak run] in
            // 求められたらすぐ返す。
            run?.send("こたえ")
        }
        let result = run.wait(timeout: 20)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "受け取り: こたえ\n受け取り: こたえ")
    }

    /// 先に送っておいた入力も使われる。
    func testPreloadedInput() {
        let run = InteractiveRun(languageID: "javascript",
                                 source: "console.log(readLine());",
                                 options: RunOptions(input: "さきに"))
        run.closeInput()
        let result = run.wait(timeout: 20)
        XCTAssertEqual(result?.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "さきに")
    }

    /// 入力を打ち切ったら、プログラムには「もう無い」と伝わる。
    func testClosingInput() {
        // 入力が無いときは、その言語の「値なし」(JS なら undefined) が返る。
        let run = InteractiveRun(languageID: "javascript", source: """
        const a = readLine();
        console.log(a === undefined ? "おわり" : "まだある: " + a);
        """)
        run.inputTimeout = 3
        run.onNeedsInput = { [weak run] in run?.closeInput() }
        let result = run.wait(timeout: 20)
        XCTAssertEqual(result?.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "おわり")
    }

    func testCancellation() {
        var options = RunOptions()
        options.maximumSteps = 500_000_000
        options.timeLimit = nil
        let run = InteractiveRun(languageID: "javascript", source: "while (true) { }",
                                 options: options)
        Thread.sleep(forTimeInterval: 0.2)
        run.cancel()
        let result = run.wait(timeout: 20)
        XCTAssertTrue(result?.execution.wasCancelled == true, result?.failureText ?? "")
        XCTAssertTrue(run.isCancelled)
    }

    func testFinishCallback() {
        let expectation = expectation(description: "終わる")
        let run = InteractiveRun(languageID: "javascript", source: "console.log(1);")
        run.onFinish = { _ in expectation.fulfill() }
        if run.isFinished { expectation.fulfill() }
        wait(for: [expectation], timeout: 20)
    }

    func testHooksDoNotLeakIntoOrdinaryRuns() throws {
        // 対話実行のあとで、ふつうの実行に割り込みが残っていないこと。
        let run = InteractiveRun(languageID: "javascript", source: "console.log(1);")
        _ = run.wait(timeout: 20)
        let plain = try RunSession.run(languageID: "javascript", source: """
        console.log(readLine() === undefined ? "入力なし" : "入力あり");
        """)
        XCTAssertEqual(plain.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "入力なし")
    }
}

final class MiniLangInputTests: XCTestCase {
    func testLines() {
        let input = MiniLangInput("a\nb")
        XCTAssertEqual(input.nextLine(), "a")
        XCTAssertEqual(input.nextLine(), "b")
        XCTAssertNil(input.nextLine())
    }

    func testCharacters() {
        let input = MiniLangInput("ab")
        XCTAssertEqual(input.nextCharacter(), "a")
        XCTAssertEqual(input.nextCharacter(), "b")
        XCTAssertNil(input.nextCharacter())
    }

    func testAppend() {
        let input = MiniLangInput("a")
        XCTAssertEqual(input.nextLine(), "a")
        input.append("b")
        XCTAssertEqual(input.nextLine(), "b")
    }

    func testProviderIsAskedWhenEmpty() {
        let input = MiniLangInput("")
        var asked = 0
        input.provider = {
            asked += 1
            return asked <= 2 ? "行\(asked)" : nil
        }
        XCTAssertEqual(input.nextLine(), "行1")
        XCTAssertEqual(input.nextLine(), "行2")
        XCTAssertNil(input.nextLine())
        XCTAssertEqual(asked, 3)
    }

    func testProviderIsNotAskedWhileInputRemains() {
        let input = MiniLangInput("ある")
        var asked = false
        input.provider = {
            asked = true
            return nil
        }
        XCTAssertEqual(input.nextLine(), "ある")
        XCTAssertFalse(asked)
    }

    func testRemainingText() {
        let input = MiniLangInput("abc")
        _ = input.nextCharacter()
        XCTAssertEqual(input.remainingText, "bc")
    }

    func testRemainingTextWhenUsedUp() {
        let input = MiniLangInput("a")
        _ = input.nextCharacter()
        XCTAssertEqual(input.remainingText, "")
    }
}

final class EngineComparisonTests: XCTestCase {
    private func makeBuiltin(_ output: String) -> RunResult {
        RunResult(languageID: "go", engineName: "内蔵",
                  execution: MiniLangExecution(parsed: true, output: output))
    }

    func testMatching() {
        let comparison = EngineComparison(builtin: makeBuiltin("42\n"),
                                          remote: ExecutionOutput(stdout: "42"))
        XCTAssertEqual(comparison.outputsMatch, true)
        XCTAssertTrue(comparison.hasBothSides)
        XCTAssertTrue(comparison.summary.contains("同じ"))
    }

    func testDiffering() {
        let comparison = EngineComparison(builtin: makeBuiltin("42"),
                                          remote: ExecutionOutput(stdout: "43"))
        XCTAssertEqual(comparison.outputsMatch, false)
        XCTAssertFalse(comparison.diff.isEmpty)
        XCTAssertTrue(comparison.summary.contains("違います"))
    }

    func testOnlyOneSide() {
        let comparison = EngineComparison(builtinError: "落ちました")
        XCTAssertNil(comparison.outputsMatch)
        XCTAssertFalse(comparison.hasBothSides)
        XCTAssertTrue(comparison.summary.contains("落ちました"))
    }

    func testRemoteFailure() {
        let comparison = EngineComparison(builtin: makeBuiltin("x"),
                                          remoteError: "つながりません")
        XCTAssertTrue(comparison.summary.contains("つながりません"))
    }

    func testANSIIsIgnoredWhenComparing() {
        let comparison = EngineComparison(builtin: makeBuiltin("\u{1B}[31m42\u{1B}[0m"),
                                          remote: ExecutionOutput(stdout: "42"))
        XCTAssertEqual(comparison.outputsMatch, true)
    }
}
