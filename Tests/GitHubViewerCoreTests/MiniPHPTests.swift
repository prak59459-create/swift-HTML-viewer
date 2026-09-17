import XCTest
@testable import GitHubViewerCore

/// 内蔵 PHP インタプリタのテスト。
final class MiniPHPTests: XCTestCase {
    private func expect(_ source: String, _ expected: String, input: String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
        let execution = MiniPHP.execute(source: source, input: input)
        XCTAssertTrue(execution.parsed, "解析に失敗:\n\(execution.diagnosticsText)", file: file, line: line)
        XCTAssertNil(execution.runtimeError, execution.runtimeError ?? "", file: file, line: line)
        XCTAssertEqual(execution.output, expected, file: file, line: line)
    }

    func testEchoAndInterpolation() {
        expect("<?php $n = 5; echo \"n=$n\\n\";", "n=5\n")
        expect("<?php $a = ['k' => 'v']; echo \"{$a['k']}!\\n\";", "v!\n")
    }

    func testArithmeticAndTypeJuggling() {
        expect("<?php echo 7 / 2, ' ', 8 / 2, ' ', 2 ** 10, ' ', -2 ** 2, \"\\n\";", "3.5 4 1024 -4\n")
        expect("<?php echo '10' + 5, ' ', 1 <=> 2, ' ', (int)'42abc', \"\\n\";", "15 -1 42\n")
        expect("<?php var_dump(0.1 + 0.2);", "float(0.30000000000000004)\n")
    }

    func testArraysKeepInsertionOrder() {
        expect("""
        <?php
        $a = [];
        $a['z'] = 1;
        $a['a'] = 2;
        $a[] = 3;
        echo implode(",", array_keys($a)), " ", count($a), "\\n";
        """, "z,a,0 3\n")
    }

    func testArraysAreCopiedOnAssignment() {
        expect("""
        <?php
        $a = [1, 2, 3];
        $b = $a;
        $b[] = 4;
        echo count($a), count($b), "\\n";
        """, "34\n")
    }

    func testObjectsAreReferences() {
        expect("""
        <?php
        class Box { public $value = 1; }
        $a = new Box();
        $b = $a;
        $b->value = 42;
        echo $a->value, "\\n";
        """, "42\n")
    }

    func testFunctionsAndClosures() {
        expect("""
        <?php
        function twice($x) { return $x * 2; }
        $square = fn($x) => $x * $x;
        echo twice(21), " ", $square(7), " ", implode(",", array_map('twice', [1, 2])), "\\n";
        """, "42 49 2,4\n")
    }

    func testForeachWithKeysAndReferences() {
        expect("""
        <?php
        $values = ['a' => 1, 'b' => 2];
        foreach ($values as $key => $value) echo "$key$value";
        echo "\\n";
        $numbers = [1, 2, 3];
        foreach ($numbers as &$number) $number *= 10;
        unset($number);
        echo implode(",", $numbers), "\\n";
        """, "a1b2\n10,20,30\n")
    }

    func testInlineHTMLAndShortEcho() {
        expect("<p><?= 1 + 1 ?></p>\n", "<p>2</p>\n")
    }

    func testSwitchAndLoops() {
        expect("""
        <?php
        $total = 0;
        for ($i = 0; $i < 5; $i++) {
            switch ($i % 2) {
                case 0: $total += 1; break;
                default: $total += 10;
            }
        }
        echo $total, "\\n";
        """, "23\n")
    }

    func testRuntimeErrorIsReported() {
        let execution = MiniPHP.execute(source: "<?php $x = 1 / 0;")
        XCTAssertTrue(execution.parsed)
        XCTAssertNotNil(execution.runtimeError)
        XCTAssertTrue(execution.runtimeError?.contains("0 で割ろう") == true, execution.runtimeError ?? "")
    }

    func testUnknownFunctionIsReported() {
        let execution = MiniPHP.execute(source: "<?php nonexistent_function();")
        XCTAssertNotNil(execution.runtimeError)
        XCTAssertTrue(execution.runtimeError?.contains("知らない関数") == true, execution.runtimeError ?? "")
    }

    func testSyntaxErrorHasLine() {
        let execution = MiniPHP.execute(source: "<?php\n$a = ;\n")
        XCTAssertFalse(execution.parsed)
        XCTAssertTrue(execution.diagnosticsText.contains("2:"), execution.diagnosticsText)
    }

    func testInfiniteLoopIsStopped() {
        let execution = MiniPHP.execute(source: "<?php while (true) { $i = 1; }",
                                        limits: PHPLimits(maximumSteps: 10_000))
        XCTAssertTrue(execution.parsed)
        XCTAssertTrue(execution.runtimeError?.contains("実行が長すぎます") == true, execution.runtimeError ?? "")
    }

    func testDeepRecursionIsStopped() {
        let execution = MiniPHP.execute(source: """
        <?php
        function down($n) { return down($n + 1); }
        down(0);
        """)
        XCTAssertNotNil(execution.runtimeError)
    }

    func testStandardInput() {
        expect("""
        <?php
        $line = trim(fgets(STDIN));
        echo strtoupper($line), "\\n";
        """, "HELLO\n", input: "hello\n")
    }

    func testSourceWithoutOpeningTagIsTreatedAsPHP() {
        expect("echo 1 + 1;", "2")
    }
}
