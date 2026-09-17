import XCTest
@testable import GitHubViewerCore

final class SyntaxTreeTests: XCTestCase {
    func testSimpleProgram() throws {
        let tree = try SyntaxTreeBuilder.tree(languageID: "javascript", source: """
        let a = 1;
        console.log(a);
        """)
        XCTAssertEqual(tree.kind, "プログラム")
        XCTAssertEqual(tree.children.count, 2)
        XCTAssertEqual(tree.children[0].kind, "変数宣言")
    }

    func testFunctionHasParametersAndBody() throws {
        let tree = try SyntaxTreeBuilder.tree(languageID: "javascript", source: """
        function add(a, b) { return a + b; }
        """)
        let function = tree.children.first { $0.kind == "関数" }
        XCTAssertEqual(function?.detail, "add")
        XCTAssertEqual(function?.children.first?.detail, "a, b")
    }

    func testIfHasBranches() throws {
        let tree = try SyntaxTreeBuilder.tree(languageID: "javascript", source: """
        if (a) { b(); } else { c(); }
        """)
        let kinds = tree.children.first?.children.map(\.kind) ?? []
        XCTAssertEqual(kinds, ["条件", "真のとき", "偽のとき"])
    }

    func testBinaryOperator() throws {
        let tree = try SyntaxTreeBuilder.tree(languageID: "javascript", source: "a + b;")
        let expression = tree.children.first?.children.first
        XCTAssertEqual(expression?.kind, "二項演算")
        XCTAssertEqual(expression?.detail, "+")
        XCTAssertEqual(expression?.children.count, 2)
    }

    func testNodeCountAndDepth() throws {
        let tree = try SyntaxTreeBuilder.tree(languageID: "javascript", source: "a + b;")
        XCTAssertGreaterThan(tree.nodeCount, 3)
        XCTAssertGreaterThan(tree.depth, 2)
    }

    func testOutlineText() throws {
        let tree = try SyntaxTreeBuilder.tree(languageID: "javascript", source: "let a = 1;")
        XCTAssertTrue(tree.text().hasPrefix("プログラム\n  変数宣言"))
    }

    func testSyntaxErrorIsReported() {
        XCTAssertThrowsError(try SyntaxTreeBuilder.tree(languageID: "javascript",
                                                        source: "function ("))
    }

    func testUnknownLanguage() {
        XCTAssertThrowsError(try SyntaxTreeBuilder.tree(languageID: "cobol", source: ""))
    }

    func testEveryEngineEitherParsesOrSaysItCannot() {
        for engine in MiniLangRegistry.all {
            let diagnostics = DiagnosticBag(source: "")
            // 空のソースでも、投げるか木を返すかのどちらかで、落ちないこと。
            _ = try? engine.parse(source: "", diagnostics: diagnostics)
        }
    }

    func testGoProgram() throws {
        let tree = try SyntaxTreeBuilder.tree(languageID: "go", source: """
        package main
        func main() { println(1) }
        """)
        XCTAssertTrue(tree.children.contains { $0.kind == "関数" && $0.detail == "main" })
    }
}

final class TokenListingTests: XCTestCase {
    func testTokensAreListed() {
        let tokens = TokenListing.tokens(languageID: "javascript",
                                         source: "let a = 1;")
        XCTAssertTrue(tokens.contains { $0.text == "let" && $0.kind == .keyword })
        XCTAssertTrue(tokens.contains { $0.text == "1" && $0.kind == .number })
    }

    func testLineNumbers() {
        let tokens = TokenListing.tokens(languageID: "javascript",
                                         source: "let a = 1;\nlet b = 2;")
        XCTAssertEqual(tokens.first { $0.text == "b" }?.line, 2)
    }

    func testColumnIsWithinTheLine() {
        let tokens = TokenListing.tokens(languageID: "javascript",
                                         source: "let a = 1;\nlet b = 2;")
        let token = tokens.first { $0.text == "b" }
        XCTAssertEqual(token?.location, 4)
    }

    func testKindNames() {
        XCTAssertEqual(DisplayToken.name(for: .keyword), "キーワード")
        XCTAssertEqual(DisplayToken.name(for: .string), "文字列")
        for kind in HighlightKind.allCases {
            XCTAssertFalse(DisplayToken.name(for: kind).isEmpty)
        }
    }

    func testHistogram()  {
        let tokens = TokenListing.tokens(languageID: "javascript",
                                         source: "let a = 1; let b = 2;")
        let histogram = TokenListing.histogram(tokens)
        XCTAssertFalse(histogram.isEmpty)
        XCTAssertEqual(histogram.first { $0.0 == "キーワード" }?.1, 2)
    }

    func testEmptySource() {
        XCTAssertTrue(TokenListing.tokens(languageID: "javascript", source: "").isEmpty)
    }
}

final class ErrorHelpTests: XCTestCase {
    func testDivisionByZero() {
        let explanation = ErrorHelp.explanation(for: "0 で割ることはできません")
        XCTAssertNotNil(explanation)
        XCTAssertTrue(explanation?.remedy.contains("確かめて") == true)
    }

    func testUnknownName() {
        XCTAssertNotNil(ErrorHelp.explanation(for: "1:5 foo が見つかりません"))
    }

    func testOutOfRange() {
        let explanation = ErrorHelp.explanation(for: "添字が範囲外です")
        XCTAssertTrue(explanation?.example?.contains("i < n") == true)
    }

    func testDeepRecursion() {
        XCTAssertNotNil(ErrorHelp.explanation(for: "関数呼び出しが深くなりすぎました"))
    }

    func testStepLimit() {
        XCTAssertNotNil(ErrorHelp.explanation(for: "実行ステップが上限 (5) を超えました"))
    }

    func testUnknownMessageHasNoExplanation() {
        XCTAssertNil(ErrorHelp.explanation(for: "まったく知らないできごと"))
    }

    func testAnnotatedKeepsTheOriginal() {
        let text = ErrorHelp.annotated("0 で割ることはできません")
        XCTAssertTrue(text.hasPrefix("0 で割ることはできません"))
        XCTAssertTrue(text.contains("直し方"))
    }

    func testAnnotatedLeavesUnknownAlone() {
        XCTAssertEqual(ErrorHelp.annotated("なぞの失敗"), "なぞの失敗")
    }
}

final class CommonMistakeTests: XCTestCase {
    func testAssignmentInCondition() {
        let hints = CommonMistakes.hints(in: "if (a = 1) { }", languageID: "c")
        XCTAssertTrue(hints.contains { $0.ruleID == "assign-in-condition" })
    }

    func testProperComparisonIsFine() {
        let hints = CommonMistakes.hints(in: "if (a == 1) { }", languageID: "c")
        XCTAssertFalse(hints.contains { $0.ruleID == "assign-in-condition" })
    }

    func testStringIdentityInJava() {
        let hints = CommonMistakes.hints(in: #"if (s == "あ") { }"#, languageID: "java")
        XCTAssertTrue(hints.contains { $0.ruleID == "string-identity" })
    }

    func testStringComparisonIsFineInJavaScript() {
        let hints = CommonMistakes.hints(in: #"if (s == "あ") { }"#,
                                         languageID: "javascript")
        XCTAssertFalse(hints.contains { $0.ruleID == "string-identity" })
    }

    func testOffByOne() {
        let hints = CommonMistakes.hints(in: "for (int i = 0; i <= a.length; i++) { }",
                                         languageID: "java")
        XCTAssertTrue(hints.contains { $0.ruleID == "off-by-one" })
    }

    func testEmptyBody() {
        let hints = CommonMistakes.hints(in: "for (int i = 0; i < 3; i++);",
                                         languageID: "c")
        XCTAssertTrue(hints.contains { $0.ruleID == "empty-body" })
    }

    func testFloatEquality() {
        let hints = CommonMistakes.hints(in: "if (x == 0.1) { }", languageID: "c")
        XCTAssertTrue(hints.contains { $0.ruleID == "float-equality" })
    }

    func testIntegerDivision() {
        let hints = CommonMistakes.hints(in: "int x = 1 / 2;", languageID: "c")
        XCTAssertTrue(hints.contains { $0.ruleID == "integer-division" })
    }

    func testUnbalancedBrackets() {
        let hints = CommonMistakes.hints(in: "void f() { if (a) { }", languageID: "c")
        XCTAssertTrue(hints.contains { $0.ruleID == "unbalanced-brackets" })
    }

    func testBalancedBracketsAreFine() {
        let hints = CommonMistakes.hints(in: "void f() { }", languageID: "c")
        XCTAssertFalse(hints.contains { $0.ruleID == "unbalanced-brackets" })
    }

    func testBracketsInStringsAreIgnored() {
        let hints = CommonMistakes.hints(in: #"void f() { puts("{"); }"#,
                                         languageID: "c")
        XCTAssertFalse(hints.contains { $0.ruleID == "unbalanced-brackets" })
    }

    func testCommentsAreIgnored() {
        let hints = CommonMistakes.hints(in: "// if (a = 1) { }\nvoid f() { }",
                                         languageID: "c")
        XCTAssertTrue(hints.isEmpty, "\(hints.map(\.ruleID))")
    }

    func testHintsAreSortedByLine() {
        let source = "if (x == 0.1) { }\nif (a = 1) { }"
        let hints = CommonMistakes.hints(in: source, languageID: "c")
        XCTAssertEqual(hints.map(\.line), hints.map(\.line).sorted())
    }

    func testLevelNames() {
        XCTAssertEqual(SourceHint.Level.mistake.displayName, "間違いかも")
    }
}

final class LintTests: XCTestCase {
    func testLongLine() {
        var options = LintOptions()
        options.maximumLineLength = 10
        let findings = Lint.check("あいうえおかきくけこさしすせそ", languageID: "c",
                                  options: options)
        XCTAssertTrue(findings.contains { $0.ruleID == "line-length" })
    }

    func testTrailingWhitespace() {
        let findings = Lint.check("let a = 1  \n", languageID: "javascript")
        XCTAssertTrue(findings.contains { $0.ruleID == "trailing-whitespace" })
    }

    func testMixedIndent() {
        let findings = Lint.check("f() {\n \tx();\n}\n", languageID: "c")
        XCTAssertTrue(findings.contains { $0.ruleID == "mixed-indent" })
    }

    func testTodo() {
        let findings = Lint.check("// TODO: あとで\n", languageID: "c")
        XCTAssertTrue(findings.contains { $0.ruleID == "todo" })
    }

    func testMissingFinalNewline() {
        XCTAssertTrue(Lint.check("a", languageID: "c")
            .contains { $0.ruleID == "trailing-newline" })
        XCTAssertFalse(Lint.check("a\n", languageID: "c")
            .contains { $0.ruleID == "trailing-newline" })
    }

    func testTooManyBlankLines() {
        let findings = Lint.check("a\n\n\n\nb\n", languageID: "c")
        XCTAssertTrue(findings.contains { $0.ruleID == "blank-lines" })
    }

    func testDisabledRulesAreSkipped() {
        var options = LintOptions()
        options.disabledRules = ["trailing-whitespace"]
        let findings = Lint.check("a  \n", languageID: "c", options: options)
        XCTAssertFalse(findings.contains { $0.ruleID == "trailing-whitespace" })
    }

    func testDeepNesting() {
        var options = LintOptions()
        options.maximumNestingDepth = 2
        let source = "a {\n b {\n  c {\n   d {\n   }\n  }\n }\n}\n"
        let findings = Lint.check(source, languageID: "c", options: options)
        XCTAssertTrue(findings.contains { $0.ruleID == "nesting" })
    }

    func testUnusedVariable() {
        let findings = Lint.check("let unused = 1;\nconsole.log(2);\n",
                                  languageID: "javascript")
        XCTAssertTrue(findings.contains { $0.ruleID == "unused-variable" })
    }

    func testUsedVariableIsFine() {
        let findings = Lint.check("let used = 1;\nconsole.log(used);\n",
                                  languageID: "javascript")
        XCTAssertFalse(findings.contains { $0.ruleID == "unused-variable" })
    }

    func testUnusedVariableIsNotCheckedForUnknownLanguages() {
        let findings = Lint.check("let x = 1;\n", languageID: "cobol")
        XCTAssertFalse(findings.contains { $0.ruleID == "unused-variable" })
    }

    func testFindingsAreSorted() {
        let findings = Lint.check("a  \n\n\n\nb  \n", languageID: "c")
        XCTAssertEqual(findings.map(\.line), findings.map(\.line).sorted())
    }

    func testCleanSourceHasNoFindings() {
        let findings = Lint.check("let used = 1;\nconsole.log(used);\n",
                                  languageID: "javascript")
        XCTAssertTrue(findings.isEmpty, "\(findings.map(\.ruleID))")
    }

    func testWordBoundaryCounting() {
        XCTAssertEqual(Lint.occurrences(of: "a", in: "a + ab + a"), 2)
        XCTAssertEqual(Lint.occurrences(of: "ab", in: "abc"), 0)
    }
}

final class FormatterTests: XCTestCase {
    func testReindent() {
        let source = "function f() {\nreturn 1;\n}\n"
        let formatted = CodeFormatter.format(source, languageID: "javascript")
        XCTAssertEqual(formatted, "function f() {\n    return 1;\n}\n")
    }

    func testNestedIndent() {
        let source = "a {\nb {\nc();\n}\n}\n"
        let formatted = CodeFormatter.format(source, languageID: "c")
        XCTAssertTrue(formatted.contains("\n        c();"), formatted)
    }

    func testTabIndent() {
        var options = FormatOptions()
        options.indent = IndentStyle(usesSpaces: false, width: 4)
        let formatted = CodeFormatter.format("f() {\nx();\n}\n", languageID: "c",
                                             options: options)
        XCTAssertTrue(formatted.contains("\n\tx();"), formatted)
    }

    func testTrailingWhitespaceIsRemoved() {
        XCTAssertEqual(CodeFormatter.format("a();   \n", languageID: "c"), "a();\n")
    }

    func testFinalNewlineIsAdded() {
        XCTAssertTrue(CodeFormatter.format("a();", languageID: "c").hasSuffix("\n"))
    }

    func testBlankLinesAreCollapsed() {
        let formatted = CodeFormatter.format("a();\n\n\n\nb();\n", languageID: "c")
        XCTAssertEqual(formatted, "a();\n\nb();\n")
    }

    func testSpaceAfterComma() {
        XCTAssertEqual(CodeFormatter.format("f(1,2);\n", languageID: "c"),
                       "f(1, 2);\n")
    }

    func testCommaInStringIsLeftAlone() {
        let formatted = CodeFormatter.format("f(\"1,2\");\n", languageID: "c")
        XCTAssertEqual(formatted, "f(\"1,2\");\n")
    }

    func testOperatorSpacing() {
        var options = FormatOptions()
        options.spacesAroundOperators = true
        XCTAssertEqual(CodeFormatter.format("x=a+b;\n", languageID: "c",
                                            options: options),
                       "x = a + b;\n")
    }

    func testOperatorSpacingKeepsDoubleSymbols() {
        var options = FormatOptions()
        options.spacesAroundOperators = true
        let formatted = CodeFormatter.format("i++;\nif (a == b) {}\n", languageID: "c",
                                             options: options)
        XCTAssertTrue(formatted.contains("i++;"), formatted)
        XCTAssertTrue(formatted.contains("a == b"), formatted)
    }

    func testClosingBraceGoesBack() {
        let formatted = CodeFormatter.format("f() {\ng();\n}\n", languageID: "c")
        XCTAssertTrue(formatted.hasSuffix("}\n"))
        XCTAssertFalse(formatted.contains("    }"))
    }

    func testBracesInStringsDoNotChangeIndent() {
        let source = "f() {\nputs(\"{\");\ng();\n}\n"
        let formatted = CodeFormatter.format(source, languageID: "c")
        XCTAssertTrue(formatted.contains("\n    g();"), formatted)
    }

    func testIndentationLanguagesAreLeftAlone() {
        let source = "def f():\n    return 1\n"
        XCTAssertEqual(CodeFormatter.format(source, languageID: "python"), source)
    }

    func testFormattingTwiceIsStable() {
        let source = "function f() {\nif (a) {\nb();\n}\n}\n"
        let once = CodeFormatter.format(source, languageID: "javascript")
        XCTAssertEqual(CodeFormatter.format(once, languageID: "javascript"), once)
    }

    func testEmptySource() {
        XCTAssertEqual(CodeFormatter.format("", languageID: "c"), "")
    }
}

final class CallGraphTests: XCTestCase {
    let source = """
    function a() { return b(); }
    function b() { return c() + c(); }
    function c() { return 1; }
    console.log(a());
    """

    func testStaticGraph() throws {
        let graph = try CallGraphBuilder.graph(languageID: "javascript", source: source)
        XCTAssertTrue(graph.nodes.contains("a"))
        XCTAssertEqual(graph.callees(of: "a"), ["b"])
        XCTAssertEqual(graph.callees(of: "b"), ["c"])
        XCTAssertEqual(graph.callers(of: "c"), ["b"])
    }

    func testCallCount() throws {
        let graph = try CallGraphBuilder.graph(languageID: "javascript", source: source)
        XCTAssertEqual(graph.edges.first { $0.caller == "b" }?.count, 2)
    }

    func testTopLevelIsARoot() throws {
        let graph = try CallGraphBuilder.graph(languageID: "javascript", source: source)
        XCTAssertTrue(graph.roots.contains("(大域)"))
    }

    func testRecursionIsFound() throws {
        let graph = try CallGraphBuilder.graph(languageID: "javascript", source: """
        function loop(n) { return n <= 0 ? 0 : loop(n - 1); }
        """)
        XCTAssertEqual(graph.recursive, ["loop"])
    }

    func testMermaid() throws {
        let graph = try CallGraphBuilder.graph(languageID: "javascript", source: source)
        let text = graph.mermaid
        XCTAssertTrue(text.hasPrefix("graph TD"))
        XCTAssertTrue(text.contains("\"a\""))
        XCTAssertTrue(text.contains("-->"))
    }

    func testGraphFromTrace() throws {
        let debugger = Debugger()
        _ = try RunSession.run(languageID: "javascript", source: source,
                               debugger: debugger)
        let graph = CallGraphBuilder.graph(fromTrace: debugger.steps)
        XCTAssertTrue(graph.nodes.contains("a"))
        XCTAssertTrue(graph.nodes.contains("c"))
    }

    func testEmptyProgram() throws {
        let graph = try CallGraphBuilder.graph(languageID: "javascript", source: "")
        XCTAssertTrue(graph.nodes.isEmpty)
        XCTAssertTrue(graph.edges.isEmpty)
    }
}

final class ValueInspectorTests: XCTestCase {
    func testScalar() {
        let node = ValueInspector.node(for: .int(42))
        XCTAssertEqual(node.text, "42")
        XCTAssertTrue(node.isLeaf)
        XCTAssertEqual(node.typeName, "整数")
    }

    func testArray() {
        let node = ValueInspector.node(for: .array(MLArray([.int(1), .int(2)])))
        XCTAssertEqual(node.children.count, 2)
        XCTAssertEqual(node.children[0].label, "[0]")
        XCTAssertTrue(node.text.contains("2 個"))
    }

    func testNestedArray() {
        let inner = MLValue.array(MLArray([.int(1)]))
        let node = ValueInspector.node(for: .array(MLArray([inner])))
        XCTAssertEqual(node.children.first?.children.count, 1)
    }

    func testDepthLimit() {
        var value = MLValue.int(1)
        for _ in 0..<10 { value = .array(MLArray([value])) }
        // 3 段まで開いて、その先は「…」1 節にまとめる。
        let node = ValueInspector.node(for: value, maximumDepth: 3)
        XCTAssertEqual(node.depthOfTree, 4)
    }

    func testChildLimit() {
        let items = (0..<50).map { MLValue.int(Int64($0)) }
        let node = ValueInspector.node(for: .array(MLArray(items)), maximumChildren: 5)
        // 5 個 + 「ほか …」の 1 個。
        XCTAssertEqual(node.children.count, 6)
        XCTAssertTrue(node.children.last?.text.contains("ほか") == true)
    }

    func testMap() {
        let map = MLMap([(MLKey.string("a"), MLValue.int(1))])
        let node = ValueInspector.node(for: .map(map))
        XCTAssertEqual(node.children.count, 1)
        XCTAssertTrue(node.text.contains("1 組"))
    }

    func testTuple() {
        let node = ValueInspector.node(for: .tuple([.int(1), .string("あ")]))
        XCTAssertEqual(node.children.count, 2)
        XCTAssertEqual(node.children[1].text, "あ")
    }

    func testOutline() {
        let node = ValueInspector.node(for: .array(MLArray([.int(1)])))
        XCTAssertTrue(node.outline().contains("\n  [0]: 1"))
    }
}

private extension ValueNode {
    /// 木の深さ (テスト用)。
    var depthOfTree: Int {
        1 + (children.map(\.depthOfTree).max() ?? 0)
    }
}

final class ChartingTests: XCTestCase {
    func testSeriesFromLines() {
        let series = OutputCharting.series(from: "1\n2\n3\n")
        XCTAssertEqual(series?.values, [1, 2, 3])
        XCTAssertEqual(series?.average, 2)
        XCTAssertEqual(series?.maximum, 3)
    }

    func testNonNumericOutputIsNotASeries() {
        XCTAssertNil(OutputCharting.series(from: "1\nあ\n"))
    }

    func testEmptyOutput() {
        XCTAssertNil(OutputCharting.series(from: "\n\n"))
    }

    func testNormalized() {
        let series = NumberSeries(name: "x", values: [0, 5, 10])
        XCTAssertEqual(series.normalized, [0, 0.5, 1])
    }

    func testNormalizedWhenAllTheSame() {
        let series = NumberSeries(name: "x", values: [3, 3])
        XCTAssertEqual(series.normalized, [0.5, 0.5])
    }

    func testNamedColumns() {
        let series = OutputCharting.columns(from: "速さ: 1\n速さ: 2\n重さ: 5\n")
        XCTAssertEqual(series.first { $0.name == "速さ" }?.values, [1, 2])
        XCTAssertEqual(series.first { $0.name == "重さ" }?.values, [5])
    }

    func testCSVColumns() {
        let series = OutputCharting.columns(from: "1,2\n3,4\n")
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0].values, [1, 3])
        XCTAssertEqual(series[1].values, [2, 4])
    }

    func testSparkline() {
        let text = OutputCharting.sparkline([1, 2, 3])
        XCTAssertEqual(text.count, 3)
        XCTAssertEqual(text.first, "▁")
        XCTAssertEqual(text.last, "█")
    }

    func testSparklineOfEmpty() {
        XCTAssertEqual(OutputCharting.sparkline([]), "")
    }

    func testSparklineOfFlatValues() {
        XCTAssertEqual(OutputCharting.sparkline([2, 2, 2]).count, 3)
    }
}

final class AlgorithmTraceTests: XCTestCase {
    func testNumbersFromArrayText() {
        XCTAssertEqual(AlgorithmTrace.numbers(from: "[1, 2, 3]"), [1, 2, 3])
        XCTAssertEqual(AlgorithmTrace.numbers(from: "[]"), [])
        XCTAssertNil(AlgorithmTrace.numbers(from: "[a, b]"))
        XCTAssertNil(AlgorithmTrace.numbers(from: "1, 2"))
    }

    func testTimelines() throws {
        let debugger = Debugger(recordsVariables: true)
        _ = try RunSession.run(languageID: "javascript", source: """
        let list = [3, 1];
        list = [1, 3];
        console.log(list);
        """, debugger: debugger)
        let timelines = AlgorithmTrace.timelines(from: debugger, names: ["list"])
        XCTAssertEqual(timelines.count, 1)
        XCTAssertGreaterThan(timelines[0].changeCount, 0)
    }

    func testFrames() {
        let timeline = ValueTimeline(name: "a", points: [(0, "[1, 2]"), (1, "[2, 1]")])
        XCTAssertEqual(AlgorithmTrace.frames(of: timeline), [[1, 2], [2, 1]])
    }
}

final class DisassemblyTests: XCTestCase {
    private func program() throws -> MiniCProgram {
        try MiniC.compile(source: """
        int add(int a, int b) { return a + b; }
        int main(void) { return add(1, 2); }
        """).program
    }

    func testLines() throws {
        let lines = Disassembly.lines(of: try program())
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.contains { $0.functionName == "add" })
        XCTAssertTrue(lines.allSatisfy { !$0.mnemonic.isEmpty })
    }

    func testSourceLinesAreAttached() throws {
        let lines = Disassembly.lines(of: try program())
        XCTAssertTrue(lines.contains { $0.sourceLine > 0 })
    }

    func testTextFormat() throws {
        let line = Disassembly.lines(of: try program()).first
        XCTAssertTrue(line?.text.contains("|") == true)
    }

    func testAddressesBySourceLine() throws {
        let table = Disassembly.addressesBySourceLine(of: try program())
        XCTAssertFalse(table.isEmpty)
        XCTAssertTrue(table.values.allSatisfy { !$0.isEmpty })
    }

    func testByFunction() throws {
        let groups = Disassembly.byFunction(try program())
        XCTAssertTrue(groups.contains { $0.name == "add" })
        XCTAssertTrue(groups.allSatisfy { !$0.lines.isEmpty })
    }

    func testHistogram() throws {
        let histogram = Disassembly.histogram(of: try program())
        XCTAssertFalse(histogram.isEmpty)
        // 多い順に並んでいる。
        XCTAssertEqual(histogram.map(\.1), histogram.map(\.1).sorted(by: >))
    }
}

final class VMSnapshotTests: XCTestCase {
    func testSnapshotBeforeRunning() throws {
        let compiled = try MiniC.compile(source: "int main(void) { return 0; }")
        let vm = MiniCVM(program: compiled.program)
        let snapshot = vm.snapshot
        XCTAssertEqual(snapshot.programCounter, 0)
        XCTAssertTrue(snapshot.stack.isEmpty)
        XCTAssertEqual(snapshot.regions.count, 3)
    }

    func testMemoryRegions() throws {
        let compiled = try MiniC.compile(source: "int main(void) { return 0; }")
        let vm = MiniCVM(program: compiled.program)
        let kinds = vm.memoryRegions.map(\.kind)
        XCTAssertEqual(kinds, [.staticData, .heap, .stack])
        for region in vm.memoryRegions {
            XCTAssertGreaterThanOrEqual(region.fraction, 0)
            XCTAssertLessThanOrEqual(region.fraction, 1)
            XCTAssertFalse(region.description.isEmpty)
        }
    }

    func testHeapUseGrowsAfterMalloc() throws {
        let compiled = try MiniC.compile(source: """
        #include <stdlib.h>
        int main(void) {
            int *p = malloc(1024);
            p[0] = 1;
            return p[0];
        }
        """)
        let vm = MiniCVM(program: compiled.program)
        let before = vm.memoryRegions.first { $0.kind == .heap }?.used ?? 0
        _ = vm.run()
        let after = vm.memoryRegions.first { $0.kind == .heap }?.used ?? 0
        XCTAssertEqual(before, 0)
        XCTAssertGreaterThan(after, 0)
    }

    func testRegionNames() {
        XCTAssertEqual(MemoryRegion.Kind.heap.displayName, "ヒープ")
        XCTAssertEqual(MemoryRegion.Kind.stack.displayName, "スタック")
    }

    func testSnapshotTotals() throws {
        let compiled = try MiniC.compile(source: "int g = 5;\nint main(void) { return g; }")
        let vm = MiniCVM(program: compiled.program)
        XCTAssertGreaterThan(vm.snapshot.usedBytes, 0)
    }
}
