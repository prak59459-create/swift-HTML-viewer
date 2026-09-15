import XCTest
@testable import GitHubViewerCore

/// 内蔵 Swift インタプリタのテスト。
final class MiniSwiftTests: XCTestCase {
    private func expect(_ source: String, _ expected: String, input: String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
        let execution = MiniSwift.execute(source: source, input: input)
        XCTAssertTrue(execution.parsed, "解析に失敗:\n\(execution.diagnosticsText)", file: file, line: line)
        XCTAssertNil(execution.runtimeError, execution.runtimeError ?? "", file: file, line: line)
        XCTAssertEqual(execution.output, expected, file: file, line: line)
    }

    func testPrintAndInterpolation() {
        expect("let n = 5\nprint(\"n=\\(n)\")", "n=5\n")
        expect("print(1, 2, 3)", "1 2 3\n")
        expect("print(\"a\", terminator: \"\")", "a")
    }

    func testValueFormattingMatchesSwift() {
        expect("print(1.0, 0.5, [1, 2], [\"a\"], true, 1...3)", "1.0 0.5 [1, 2] [\"a\"] true 1...3\n")
        expect("let x: Int? = nil\nprint(x ?? -1)", "-1\n")
    }

    func testIntegerAndDoubleDivision() {
        expect("print(7 / 2, 7 % 2, 7.0 / 2.0, Double(7) / 2)", "3 1 3.5 3.5\n")
    }

    func testStructsAreValueTypes() {
        expect("""
        struct Box { var value: Int }
        var a = Box(value: 1)
        var b = a
        b.value = 2
        print(a.value, b.value)
        """, "1 2\n")
    }

    func testClassesAreReferenceTypes() {
        expect("""
        class Box { var value = 1 }
        let a = Box()
        let b = a
        b.value = 42
        print(a.value)
        """, "42\n")
    }

    func testMutatingMethodWritesBack() {
        expect("""
        struct Counter {
            var value = 0
            mutating func bump() { value += 1 }
        }
        var counter = Counter()
        counter.bump()
        counter.bump()
        print(counter.value)
        """, "2\n")
    }

    func testClosuresCaptureByReference() {
        expect("""
        func makeCounter() -> () -> Int {
            var count = 0
            return { count += 1; return count }
        }
        let next = makeCounter()
        print(next(), next())
        """, "1 2\n")
    }

    func testHigherOrderFunctions() {
        expect("""
        let values = [1, 2, 3, 4, 5]
        print(values.map { $0 * $0 }.filter { $0 > 5 }.reduce(0, +))
        """, "50\n")
    }

    func testOptionalBinding() {
        expect("""
        let text = "42"
        if let number = Int(text) {
            print("ok \\(number)")
        } else {
            print("ng")
        }
        print(Int("abc") == nil)
        """, "ok 42\ntrue\n")
    }

    func testEnumWithRawValueAndSwitch() {
        expect("""
        enum Level: String { case low = "L", high = "H" }
        func describe(_ level: Level) -> String {
            switch level {
            case .low: return "low(\\(level.rawValue))"
            case .high: return "high(\\(level.rawValue))"
            }
        }
        print(describe(.low), describe(.high))
        """, "low(L) high(H)\n")
    }

    func testGuardAndEarlyReturn() {
        expect("""
        func firstEven(_ values: [Int]) -> Int? {
            for value in values where value % 2 == 0 { return value }
            return nil
        }
        guard let value = firstEven([1, 3, 6, 8]) else { fatalError() }
        print(value)
        """, "6\n")
    }

    func testRuntimeErrorForNilUnwrap() {
        let execution = MiniSwift.execute(source: "let x: Int? = nil\nprint(x!)")
        XCTAssertTrue(execution.parsed)
        XCTAssertTrue(execution.runtimeError?.contains("nil を強制アンラップ") == true,
                      execution.runtimeError ?? "")
    }

    func testRuntimeErrorForArrayBounds() {
        let execution = MiniSwift.execute(source: "let values = [1, 2]\nprint(values[5])")
        XCTAssertTrue(execution.runtimeError?.contains("範囲外") == true, execution.runtimeError ?? "")
    }

    func testConstantCannotBeChanged() {
        let execution = MiniSwift.execute(source: "let x = 1\nx = 2")
        XCTAssertTrue(execution.runtimeError?.contains("let") == true, execution.runtimeError ?? "")
    }

    func testInfiniteLoopIsStopped() {
        let execution = MiniSwift.execute(source: "while true { let x = 1 }",
                                          limits: SwiftLimits(maximumSteps: 10_000))
        XCTAssertTrue(execution.runtimeError?.contains("実行が長すぎます") == true,
                      execution.runtimeError ?? "")
    }

    func testSyntaxErrorHasLine() {
        let execution = MiniSwift.execute(source: "let x =\nprint(")
        XCTAssertFalse(execution.parsed)
        XCTAssertFalse(execution.diagnosticsText.isEmpty)
    }

    func testReadLineFromInput() {
        expect("""
        if let line = readLine() {
            print(line.uppercased())
        }
        """, "HELLO\n", input: "hello\n")
    }
}
