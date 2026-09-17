import XCTest
@testable import GitHubViewerCore

final class DebuggerTests: XCTestCase {
    let source = """
    function twice(x) {
        return x * 2;
    }
    let a = 1;
    let b = twice(a);
    console.log(b);
    """

    // MARK: - 131. ブレークポイント

    func testBreakpointPauses() throws {
        let debugger = Debugger(breakpoints: [6])
        var stops: [DebugSnapshot] = []
        debugger.onPause = { snapshot in
            stops.append(snapshot)
            return .resume
        }
        let result = try RunSession.run(languageID: "javascript", source: source,
                                        debugger: debugger)
        XCTAssertNil(result.failureText)
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.line, 6)
        XCTAssertEqual(stops.first?.reason, .breakpoint(line: 6))
    }

    func testNoBreakpointsMeansNoStops() throws {
        let debugger = Debugger()
        var stops = 0
        debugger.onPause = { _ in
            stops += 1
            return .resume
        }
        _ = try RunSession.run(languageID: "javascript", source: source,
                               debugger: debugger)
        XCTAssertEqual(stops, 0)
    }

    func testToggle() {
        let debugger = Debugger()
        XCTAssertTrue(debugger.toggleBreakpoint(line: 3))
        XCTAssertEqual(debugger.breakpointLines, [3])
        XCTAssertFalse(debugger.toggleBreakpoint(line: 3))
        XCTAssertTrue(debugger.breakpointLines.isEmpty)
    }

    func testAddAndRemove() {
        let debugger = Debugger()
        debugger.addBreakpoint(line: 1)
        debugger.addBreakpoint(line: 5)
        debugger.removeBreakpoint(line: 1)
        XCTAssertEqual(debugger.breakpointLines, [5])
        debugger.clearBreakpoints()
        XCTAssertTrue(debugger.breakpointLines.isEmpty)
    }

    // MARK: - 132. ステップ実行

    func testStepIntoGoesLineByLine() throws {
        let debugger = Debugger(pausesAtEntry: true)
        var lines: [Int] = []
        debugger.onPause = { snapshot in
            lines.append(snapshot.line)
            return lines.count < 6 ? .stepInto : .resume
        }
        _ = try RunSession.run(languageID: "javascript", source: source,
                               debugger: debugger)
        // 関数の中 (2 行目) にも入る。
        XCTAssertTrue(lines.contains(2), "\(lines)")
        XCTAssertGreaterThan(lines.count, 2)
    }

    func testStepOverStaysAtTheSameDepth() throws {
        let debugger = Debugger(breakpoints: [5])
        var lines: [Int] = []
        debugger.onPause = { snapshot in
            lines.append(snapshot.line)
            return lines.count < 3 ? .stepOver : .resume
        }
        _ = try RunSession.run(languageID: "javascript", source: source,
                               debugger: debugger)
        // 5 行目で止まったあと、関数の中 (2 行目) には入らない。
        XCTAssertFalse(lines.dropFirst().contains(2), "\(lines)")
    }

    func testStopEndsTheRun() throws {
        let debugger = Debugger(breakpoints: [4])
        debugger.onPause = { _ in .stop }
        let result = try RunSession.run(languageID: "javascript", source: source,
                                        debugger: debugger)
        XCTAssertTrue(result.execution.wasCancelled)
        XCTAssertFalse(result.output.contains("2"))
    }

    func testPauseAtEntry() throws {
        let debugger = Debugger(pausesAtEntry: true)
        var reasons: [PauseReason] = []
        debugger.onPause = { snapshot in
            reasons.append(snapshot.reason)
            return .resume
        }
        _ = try RunSession.run(languageID: "javascript", source: "let a = 1;",
                               debugger: debugger)
        XCTAssertEqual(reasons.first, .entry)
    }

    // MARK: - 133 / 150. 変数と型

    func testVariablesAreVisible() throws {
        let debugger = Debugger(breakpoints: [6])
        var seen: [WatchedVariable] = []
        debugger.onPause = { snapshot in
            seen = snapshot.variables
            return .resume
        }
        _ = try RunSession.run(languageID: "javascript", source: source,
                               debugger: debugger)
        XCTAssertEqual(seen.first { $0.name == "a" }?.displayValue, "1")
        XCTAssertEqual(seen.first { $0.name == "b" }?.displayValue, "2")
    }

    func testTypeNamesAreShown() throws {
        let debugger = Debugger(breakpoints: [4])
        var seen: [WatchedVariable] = []
        debugger.onPause = { snapshot in
            seen = snapshot.variables
            return .resume
        }
        _ = try RunSession.run(languageID: "javascript", source: """
        let n = 1;
        let s = "あ";
        let list = [1, 2];
        console.log(n);
        """, debugger: debugger)
        XCTAssertFalse(seen.first { $0.name == "n" }?.typeName.isEmpty ?? true)
        XCTAssertFalse(seen.first { $0.name == "s" }?.typeName.isEmpty ?? true)
    }

    func testWatchedNamesNarrowTheList() throws {
        let debugger = Debugger(breakpoints: [3])
        debugger.watchedNames = ["b"]
        var seen: [WatchedVariable] = []
        debugger.onPause = { snapshot in
            seen = snapshot.variables
            return .resume
        }
        _ = try RunSession.run(languageID: "javascript",
                               source: "let a = 1;\nlet b = 2;\nconsole.log(a + b);",
                               debugger: debugger)
        XCTAssertEqual(seen.map(\.name), ["b"])
    }

    // MARK: - 134. コールスタック

    func testCallStack() throws {
        let debugger = Debugger(breakpoints: [2])
        var stack: [StackFrame] = []
        debugger.onPause = { snapshot in
            stack = snapshot.callStack
            return .resume
        }
        _ = try RunSession.run(languageID: "javascript", source: source,
                               debugger: debugger)
        XCTAssertEqual(stack.count, 1)
        XCTAssertEqual(stack.first?.functionName, "twice")
        XCTAssertTrue(stack.first?.description.contains("twice") == true)
    }

    func testNestedCallStack() throws {
        let debugger = Debugger(breakpoints: [3])
        var names: [String] = []
        debugger.onPause = { snapshot in
            names = snapshot.callStack.map(\.functionName)
            return .resume
        }
        _ = try RunSession.run(languageID: "javascript", source: """
        function outer() { return inner(); }
        function inner() {
            return 1;
        }
        console.log(outer());
        """, debugger: debugger)
        XCTAssertEqual(names, ["outer", "inner"])
    }

    // MARK: - 136 / 143. トレースとタイムトラベル

    func testTraceRecordsEveryLine() throws {
        let debugger = Debugger()
        _ = try RunSession.run(languageID: "javascript",
                               source: "let a = 1;\nlet b = 2;\nconsole.log(a + b);",
                               debugger: debugger)
        XCTAssertEqual(debugger.visitedLines.prefix(3).map { $0 }, [1, 2, 3])
    }

    func testTraceKeepsVariablesWhenAsked() throws {
        let debugger = Debugger(recordsVariables: true)
        _ = try RunSession.run(languageID: "javascript",
                               source: "let a = 1;\na = 2;\na = 3;",
                               debugger: debugger)
        let history = debugger.history(of: "a")
        XCTAssertEqual(history.map(\.value), ["1", "2"])
    }

    func testSnapshotAtStep() throws {
        let debugger = Debugger(recordsVariables: true)
        _ = try RunSession.run(languageID: "javascript",
                               source: "let a = 1;\nlet b = 2;",
                               debugger: debugger)
        XCTAssertEqual(debugger.snapshot(atStep: 0)?.line, 1)
        XCTAssertNil(debugger.snapshot(atStep: 999))
    }

    func testTraceLimit() throws {
        let debugger = Debugger(traceLimit: 5)
        _ = try RunSession.run(languageID: "javascript",
                               source: "for (let i = 0; i < 100; i++) { }",
                               debugger: debugger)
        XCTAssertEqual(debugger.steps.count, 5)
    }

    func testReset() throws {
        let debugger = Debugger()
        _ = try RunSession.run(languageID: "javascript", source: "let a = 1;",
                               debugger: debugger)
        debugger.reset()
        XCTAssertTrue(debugger.steps.isEmpty)
        XCTAssertEqual(debugger.maximumHitCount, 0)
    }

    // MARK: - 137. ヒートマップ

    func testHeatmapCountsLines() throws {
        let debugger = Debugger()
        _ = try RunSession.run(languageID: "javascript", source: """
        let total = 0;
        for (let i = 0; i < 5; i++) {
            total = total + i;
        }
        console.log(total);
        """, debugger: debugger)
        let counts = debugger.lineHitCounts
        XCTAssertGreaterThanOrEqual(counts[3] ?? 0, 5)
        XCTAssertEqual(counts[1], 1)
        // 濃さは「いちばん多く通った行」を 1 とした割合。
        XCTAssertGreaterThan(debugger.heat(forLine: 3), debugger.heat(forLine: 1))
        XCTAssertGreaterThan(debugger.heat(forLine: 3), 0.5)
        XCTAssertLessThanOrEqual(debugger.heat(forLine: 3), 1)
    }

    func testHeatOfUnvisitedLineIsZero() {
        XCTAssertEqual(Debugger().heat(forLine: 99), 0)
    }

    // MARK: - 144. スタックトレース

    func testStackTraceOnError() throws {
        let result = try RunSession.run(languageID: "javascript", source: """
        function bad() { return ないやつ(); }
        function middle() { return bad(); }
        console.log(middle());
        """)
        XCTAssertNotNil(result.execution.errorStack)
        let names = result.execution.errorStack?.frames.map(\.functionName) ?? []
        XCTAssertEqual(names, ["middle", "bad"])
        XCTAssertTrue(result.execution.errorStack?.description.contains("bad") == true)
    }

    func testNoStackTraceWhenEverythingWorks() throws {
        let result = try RunSession.run(languageID: "javascript",
                                        source: "console.log(1);")
        XCTAssertNil(result.execution.errorStack)
    }

    func testTopLevelErrorStillHasADescription() throws {
        let result = try RunSession.run(languageID: "javascript", source: "ないやつ();")
        XCTAssertTrue(result.execution.errorStack?.description.contains("大域") == true,
                      result.execution.errorStack?.description ?? "なし")
    }

    // MARK: - 149. 実行時の警告

    func testDeepRecursionWarning() throws {
        var options = RunOptions()
        options.maximumCallDepth = 40
        let result = try RunSession.run(languageID: "javascript", source: """
        function down(n) { return n <= 0 ? 0 : down(n - 1); }
        console.log(down(100));
        """, options: options)
        XCTAssertTrue(result.execution.warnings.contains { $0.kind == .deepRecursion },
                      "\(result.execution.warnings)")
    }

    func testNoWarningsForOrdinaryCode() throws {
        let result = try RunSession.run(languageID: "javascript",
                                        source: "console.log(1);")
        XCTAssertTrue(result.execution.warnings.isEmpty)
    }

    // MARK: - 155. 式を選んで値を見る

    func testEvaluateExpressionWhilePaused() throws {
        let debugger = Debugger(breakpoints: [3])
        var value: ExpressionValue?
        debugger.onPause = { _ in
            value = debugger.evaluate("a + b")
            return .resume
        }
        _ = try RunSession.run(languageID: "javascript",
                               source: "let a = 1;\nlet b = 2;\nconsole.log(a + b);",
                               debugger: debugger)
        XCTAssertEqual(value?.text, "3")
        XCTAssertTrue(value?.succeeded == true)
    }

    func testEvaluateBadExpression() throws {
        let debugger = Debugger(breakpoints: [1])
        var value: ExpressionValue?
        debugger.onPause = { _ in
            value = debugger.evaluate("どこにもない")
            return .resume
        }
        _ = try RunSession.run(languageID: "javascript", source: "let a = 1;",
                               debugger: debugger)
        XCTAssertEqual(value?.succeeded, false)
        XCTAssertNotNil(value?.failureText)
    }

    func testEvaluateReturnsAnInspectableValue() throws {
        let debugger = Debugger(breakpoints: [2])
        var value: ExpressionValue?
        debugger.onPause = { _ in
            value = debugger.evaluate("list")
            return .resume
        }
        _ = try RunSession.run(languageID: "javascript",
                               source: "let list = [1, 2, 3];\nconsole.log(list);",
                               debugger: debugger)
        XCTAssertEqual(value?.node?.children.count, 3)
    }

    func testEvaluatorIsUnavailableOutsideAPause() {
        XCTAssertNil(Debugger().evaluate("1 + 1"))
    }
}

final class WarningCollectorTests: XCTestCase {
    func testAddAndRead() {
        let collector = WarningCollector()
        collector.add(.divisionByZero, "0 で割りました", line: 3)
        XCTAssertEqual(collector.all.count, 1)
        XCTAssertEqual(collector.all.first?.line, 3)
    }

    func testDuplicatesAreDropped() {
        let collector = WarningCollector()
        collector.add(.overflow, "あふれました", line: 1)
        collector.add(.overflow, "あふれました", line: 1)
        XCTAssertEqual(collector.all.count, 1)
    }

    func testDifferentLinesAreKept() {
        let collector = WarningCollector()
        collector.add(.overflow, "あふれました", line: 1)
        collector.add(.overflow, "あふれました", line: 2)
        XCTAssertEqual(collector.all.count, 2)
    }

    func testLimit() {
        let collector = WarningCollector(limit: 2)
        for line in 1...5 { collector.add(.other, "警告", line: line) }
        XCTAssertEqual(collector.all.count, 2)
    }

    func testClear() {
        let collector = WarningCollector()
        collector.add(.other, "x")
        collector.clear()
        XCTAssertTrue(collector.all.isEmpty)
    }
}
