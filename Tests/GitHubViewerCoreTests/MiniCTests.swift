import XCTest
@testable import GitHubViewerCore

/// 内蔵 C コンパイラのテスト。
final class MiniCTests: XCTestCase {
    // MARK: - 補助

    @discardableResult
    private func execute(_ source: String, input: String = "",
                         file: StaticString = #filePath, line: UInt = #line) -> MiniC.Execution {
        let execution = MiniC.execute(source: source, input: input)
        if !execution.compiled {
            XCTFail("コンパイルに失敗しました:\n\(execution.diagnosticsText)", file: file, line: line)
        } else if let runtimeError = execution.runtimeError {
            XCTFail("実行時エラー: \(runtimeError)\n出力: \(execution.output)", file: file, line: line)
        }
        return execution
    }

    private func expect(_ source: String, output expected: String, input: String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
        let execution = execute(source, input: input, file: file, line: line)
        XCTAssertEqual(execution.output, expected, file: file, line: line)
    }

    private func expectCompileError(_ source: String, containing fragment: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let execution = MiniC.execute(source: source)
        XCTAssertFalse(execution.compiled, "コンパイルが通ってしまいました", file: file, line: line)
        XCTAssertTrue(execution.diagnosticsText.contains(fragment),
                      "エラーメッセージに \"\(fragment)\" がありません:\n\(execution.diagnosticsText)",
                      file: file, line: line)
    }

    private func expectRuntimeError(_ source: String, containing fragment: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let execution = MiniC.execute(source: source)
        XCTAssertTrue(execution.compiled, "コンパイルに失敗しました:\n\(execution.diagnosticsText)",
                      file: file, line: line)
        guard let runtimeError = execution.runtimeError else {
            XCTFail("実行時エラーになりませんでした (出力: \(execution.output))", file: file, line: line)
            return
        }
        XCTAssertTrue(runtimeError.contains(fragment),
                      "実行時エラーに \"\(fragment)\" がありません: \(runtimeError)", file: file, line: line)
    }

    // MARK: - 基本

    func testHelloWorld() {
        expect("""
        #include <stdio.h>
        int main(void) {
            printf("hello, world\\n");
            return 0;
        }
        """, output: "hello, world\n")
    }

    func testExitCodeIsReturnValueOfMain() {
        let execution = execute("int main(void) { return 42; }")
        XCTAssertEqual(execution.exitCode, 42)
    }

    func testArithmeticPrecedence() {
        expect("""
        #include <stdio.h>
        int main(void) {
            printf("%d %d %d %d\\n", 2 + 3 * 4, (2 + 3) * 4, 17 / 5, 17 % 5);
            printf("%d %d\\n", -3 * -3, 1 << 10);
            return 0;
        }
        """, output: "14 20 3 2\n9 1024\n")
    }

    func testIntegerOverflowWrapsLike32Bit() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int big = 2147483647;
            big = big + 1;
            printf("%d\\n", big);
            long wide = 2147483647;
            wide = wide + 1;
            printf("%ld\\n", wide);
            return 0;
        }
        """, output: "-2147483648\n2147483648\n")
    }

    func testComparisonAndLogicalOperators() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int a = 3, b = 7;
            printf("%d%d%d%d%d%d\\n", a < b, a > b, a <= 3, b >= 8, a == 3, a != 3);
            printf("%d%d%d\\n", a && b, a && 0, !a);
            return 0;
        }
        """, output: "101010\n100\n")
    }

    func testShortCircuitEvaluation() {
        expect("""
        #include <stdio.h>
        int calls = 0;
        int bump(void) { calls = calls + 1; return 1; }
        int main(void) {
            if (0 && bump()) { }
            if (1 || bump()) { }
            printf("%d\\n", calls);
            return 0;
        }
        """, output: "0\n")
    }

    // MARK: - 制御構造

    func testWhileAndFor() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int sum = 0;
            for (int i = 1; i <= 10; i++) sum += i;
            printf("%d\\n", sum);
            int n = 5, factorial = 1;
            while (n > 1) { factorial *= n; n--; }
            printf("%d\\n", factorial);
            return 0;
        }
        """, output: "55\n120\n")
    }

    func testDoWhileRunsAtLeastOnce() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int count = 0;
            do { count++; } while (0);
            printf("%d\\n", count);
            return 0;
        }
        """, output: "1\n")
    }

    func testBreakAndContinue() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int sum = 0;
            for (int i = 0; i < 20; i++) {
                if (i % 2 == 0) continue;
                if (i > 10) break;
                sum += i;
            }
            printf("%d\\n", sum);
            return 0;
        }
        """, output: "25\n")
    }

    func testNestedLoopsWithBreak() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int found = 0;
            for (int i = 1; i <= 5; i++) {
                for (int j = 1; j <= 5; j++) {
                    if (i * j == 12) { found = i * 10 + j; break; }
                }
                if (found) break;
            }
            printf("%d\\n", found);
            return 0;
        }
        """, output: "34\n")
    }

    func testSwitchWithFallthroughAndDefault() {
        expect("""
        #include <stdio.h>
        void classify(int value) {
            switch (value) {
            case 1:
            case 2:
                printf("small ");
                break;
            case 10:
                printf("ten ");
                break;
            default:
                printf("other ");
            }
        }
        int main(void) {
            classify(1); classify(2); classify(10); classify(99);
            printf("\\n");
            return 0;
        }
        """, output: "small small ten other \n")
    }

    func testSwitchInsideLoopBreakBindsToSwitch() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int total = 0;
            for (int i = 0; i < 4; i++) {
                switch (i) {
                case 2:
                    break;
                default:
                    total += i;
                }
                total += 10;
            }
            printf("%d\\n", total);
            return 0;
        }
        """, output: "44\n")
    }

    func testTernaryOperator() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int a = 5, b = 9;
            printf("%d %d\\n", a > b ? a : b, a < b ? a : b);
            return 0;
        }
        """, output: "9 5\n")
    }

    // MARK: - 関数

    func testRecursiveFibonacci() {
        expect("""
        #include <stdio.h>
        int fib(int n) {
            if (n < 2) return n;
            return fib(n - 1) + fib(n - 2);
        }
        int main(void) {
            for (int i = 0; i < 10; i++) printf("%d ", fib(i));
            printf("\\n");
            return 0;
        }
        """, output: "0 1 1 2 3 5 8 13 21 34 \n")
    }

    func testMutualRecursionWithPrototypes() {
        expect("""
        #include <stdio.h>
        int isOdd(int n);
        int isEven(int n) { return n == 0 ? 1 : isOdd(n - 1); }
        int isOdd(int n) { return n == 0 ? 0 : isEven(n - 1); }
        int main(void) {
            printf("%d %d\\n", isEven(10), isOdd(7));
            return 0;
        }
        """, output: "1 1\n")
    }

    func testVoidFunctionAndGlobals() {
        expect("""
        #include <stdio.h>
        int counter = 10;
        void bump(int amount) { counter += amount; }
        int main(void) {
            bump(5); bump(7);
            printf("%d\\n", counter);
            return 0;
        }
        """, output: "22\n")
    }

    // MARK: - 配列とポインタ

    func testArraysAndIndexing() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int values[5] = {3, 1, 4, 1, 5};
            int sum = 0;
            for (int i = 0; i < 5; i++) sum += values[i];
            printf("%d %d %d\\n", sum, values[0], values[4]);
            return 0;
        }
        """, output: "14 3 5\n")
    }

    func testArrayInitializerZeroFills() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int values[5] = {1, 2};
            printf("%d %d %d %d %d\\n", values[0], values[1], values[2], values[3], values[4]);
            return 0;
        }
        """, output: "1 2 0 0 0\n")
    }

    func testTwoDimensionalArray() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int grid[3][3];
            for (int i = 0; i < 3; i++)
                for (int j = 0; j < 3; j++)
                    grid[i][j] = (i + 1) * (j + 1);
            for (int i = 0; i < 3; i++) {
                for (int j = 0; j < 3; j++) printf("%d ", grid[i][j]);
                printf("\\n");
            }
            return 0;
        }
        """, output: "1 2 3 \n2 4 6 \n3 6 9 \n")
    }

    func testPointerBasics() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int value = 41;
            int *pointer = &value;
            *pointer = *pointer + 1;
            printf("%d %d\\n", value, *pointer);
            return 0;
        }
        """, output: "42 42\n")
    }

    func testPointerArithmeticWalksArray() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int values[4] = {10, 20, 30, 40};
            int *cursor = values;
            int sum = 0;
            while (cursor < values + 4) {
                sum += *cursor;
                cursor++;
            }
            printf("%d %d\\n", sum, (int)(cursor - values));
            return 0;
        }
        """, output: "100 4\n")
    }

    func testPassArrayToFunction() {
        expect("""
        #include <stdio.h>
        int total(int *values, int count) {
            int sum = 0;
            for (int i = 0; i < count; i++) sum += values[i];
            return sum;
        }
        void doubleAll(int values[], int count) {
            for (int i = 0; i < count; i++) values[i] *= 2;
        }
        int main(void) {
            int values[4] = {1, 2, 3, 4};
            doubleAll(values, 4);
            printf("%d\\n", total(values, 4));
            return 0;
        }
        """, output: "20\n")
    }

    func testSwapThroughPointers() {
        expect("""
        #include <stdio.h>
        void swap(int *a, int *b) { int t = *a; *a = *b; *b = t; }
        int main(void) {
            int x = 1, y = 2;
            swap(&x, &y);
            printf("%d %d\\n", x, y);
            return 0;
        }
        """, output: "2 1\n")
    }

    func testBubbleSort() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int values[8] = {5, 3, 8, 1, 9, 2, 7, 4};
            for (int i = 0; i < 8; i++) {
                for (int j = 0; j < 7 - i; j++) {
                    if (values[j] > values[j + 1]) {
                        int t = values[j];
                        values[j] = values[j + 1];
                        values[j + 1] = t;
                    }
                }
            }
            for (int i = 0; i < 8; i++) printf("%d", values[i]);
            printf("\\n");
            return 0;
        }
        """, output: "12345789\n")
    }

    // MARK: - 文字列

    func testStringLiteralsAndStrlen() {
        expect("""
        #include <stdio.h>
        #include <string.h>
        int main(void) {
            char *text = "MiniC";
            printf("%s %d %c\\n", text, (int)strlen(text), text[1]);
            return 0;
        }
        """, output: "MiniC 5 i\n")
    }

    func testCharArrayAndManualReverse() {
        expect("""
        #include <stdio.h>
        #include <string.h>
        int main(void) {
            char text[16] = "abcdef";
            int length = (int)strlen(text);
            for (int i = 0; i < length / 2; i++) {
                char t = text[i];
                text[i] = text[length - 1 - i];
                text[length - 1 - i] = t;
            }
            printf("%s\\n", text);
            return 0;
        }
        """, output: "fedcba\n")
    }

    func testStringBuiltins() {
        expect("""
        #include <stdio.h>
        #include <string.h>
        int main(void) {
            char buffer[32];
            strcpy(buffer, "abc");
            strcat(buffer, "def");
            printf("%s %d %d\\n", buffer, strcmp("abc", "abd") < 0, strcmp("x", "x"));
            return 0;
        }
        """, output: "abcdef 1 0\n")
    }

    // MARK: - 構造体

    func testStructMembersAndPointers() {
        expect("""
        #include <stdio.h>
        struct Point { int x; int y; };
        int main(void) {
            struct Point p;
            p.x = 3;
            p.y = 4;
            struct Point *q = &p;
            q->x = 10;
            printf("%d %d\\n", p.x, q->y);
            return 0;
        }
        """, output: "10 4\n")
    }

    func testStructAssignmentCopies() {
        expect("""
        #include <stdio.h>
        struct Point { int x; int y; };
        int main(void) {
            struct Point a;
            a.x = 1; a.y = 2;
            struct Point b = a;
            b.x = 99;
            printf("%d %d %d %d\\n", a.x, a.y, b.x, b.y);
            return 0;
        }
        """, output: "1 2 99 2\n")
    }

    func testStructPassedByValue() {
        expect("""
        #include <stdio.h>
        struct Point { int x; int y; };
        int distanceSquared(struct Point p) {
            p.x = 0;
            return p.x * p.x + p.y * p.y;
        }
        int main(void) {
            struct Point p;
            p.x = 3; p.y = 4;
            printf("%d %d\\n", distanceSquared(p), p.x);
            return 0;
        }
        """, output: "16 3\n")
    }

    func testTypedefStructAndArrayOfStructs() {
        expect("""
        #include <stdio.h>
        typedef struct { char name[8]; int score; } Student;
        int main(void) {
            Student students[2];
            students[0].score = 80;
            students[1].score = 95;
            int best = students[0].score > students[1].score ? 0 : 1;
            printf("%d %d\\n", best, students[best].score);
            return 0;
        }
        """, output: "1 95\n")
    }

    func testStructInitializerList() {
        expect("""
        #include <stdio.h>
        struct Point { int x; int y; };
        int main(void) {
            struct Point p = {7, 8};
            printf("%d %d\\n", p.x, p.y);
            return 0;
        }
        """, output: "7 8\n")
    }

    func testLinkedListWithMalloc() {
        expect("""
        #include <stdio.h>
        #include <stdlib.h>
        struct Node { int value; struct Node *next; };
        int main(void) {
            struct Node *head = 0;
            for (int i = 3; i >= 1; i--) {
                struct Node *node = (struct Node *)malloc(sizeof(struct Node));
                node->value = i;
                node->next = head;
                head = node;
            }
            int sum = 0;
            struct Node *cursor = head;
            while (cursor != 0) {
                printf("%d ", cursor->value);
                sum += cursor->value;
                cursor = cursor->next;
            }
            printf("= %d\\n", sum);
            while (head != 0) {
                struct Node *next = head->next;
                free(head);
                head = next;
            }
            return 0;
        }
        """, output: "1 2 3 = 6\n")
    }

    // MARK: - 浮動小数点と math

    func testDoubleArithmeticAndPrintf() {
        expect("""
        #include <stdio.h>
        int main(void) {
            double a = 1.5, b = 4.0;
            printf("%.2f %.3f %.1f\\n", a + b, a / b, a * 2);
            return 0;
        }
        """, output: "5.50 0.375 3.0\n")
    }

    func testIntegerAndDoubleMixing() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int n = 7;
            double half = n / 2;
            double exact = n / 2.0;
            printf("%.1f %.1f %d\\n", half, exact, (int)exact);
            return 0;
        }
        """, output: "3.0 3.5 3\n")
    }

    func testMathBuiltins() {
        expect("""
        #include <stdio.h>
        #include <math.h>
        int main(void) {
            printf("%.3f %.3f %.3f\\n", sqrt(2.0), pow(2.0, 10.0), fabs(-1.25));
            printf("%.0f %.0f\\n", floor(2.7), ceil(2.1));
            return 0;
        }
        """, output: "1.414 1024.000 1.250\n2 3\n")
    }

    // MARK: - printf の書式

    func testPrintfFormatting() {
        expect("""
        #include <stdio.h>
        int main(void) {
            printf("[%5d][%-5d][%05d]\\n", 42, 42, 42);
            printf("[%x][%X][%o]\\n", 255, 255, 8);
            printf("[%s][%10s][%-10s]\\n", "hi", "hi", "hi");
            printf("[%c][%%]\\n", 65);
            printf("[%+d][%+d]\\n", 5, -5);
            return 0;
        }
        """, output: "[   42][42   ][00042]\n[ff][FF][10]\n[hi][        hi][hi        ]\n[A][%]\n[+5][-5]\n")
    }

    // MARK: - プリプロセッサ

    func testObjectLikeMacro() {
        expect("""
        #include <stdio.h>
        #define SIZE 4
        #define GREETING "hello"
        int main(void) {
            int values[SIZE];
            for (int i = 0; i < SIZE; i++) values[i] = i * i;
            printf("%s %d\\n", GREETING, values[SIZE - 1]);
            return 0;
        }
        """, output: "hello 9\n")
    }

    func testFunctionLikeMacro() {
        expect("""
        #include <stdio.h>
        #define MAX(a, b) ((a) > (b) ? (a) : (b))
        #define SQUARE(x) ((x) * (x))
        int main(void) {
            printf("%d %d\\n", MAX(3, 9), SQUARE(1 + 2));
            return 0;
        }
        """, output: "9 9\n")
    }

    func testConditionalCompilation() {
        expect("""
        #include <stdio.h>
        #define DEBUG
        int main(void) {
        #ifdef DEBUG
            printf("debug\\n");
        #else
            printf("release\\n");
        #endif
        #ifndef DEBUG
            printf("never\\n");
        #endif
            return 0;
        }
        """, output: "debug\n")
    }

    // MARK: - enum, sizeof, キャスト

    func testEnumConstants() {
        expect("""
        #include <stdio.h>
        enum Color { RED, GREEN, BLUE = 10, PURPLE };
        int main(void) {
            printf("%d %d %d %d\\n", RED, GREEN, BLUE, PURPLE);
            return 0;
        }
        """, output: "0 1 10 11\n")
    }

    func testSizeofTypesAndExpressions() {
        expect("""
        #include <stdio.h>
        struct Pair { int a; double b; };
        int main(void) {
            int values[10];
            printf("%d %d %d %d\\n", (int)sizeof(char), (int)sizeof(int), (int)sizeof(double),
                   (int)sizeof(int *));
            printf("%d %d\\n", (int)sizeof(values), (int)sizeof(struct Pair));
            return 0;
        }
        """, output: "1 4 8 8\n40 16\n")
    }

    func testCasts() {
        expect("""
        #include <stdio.h>
        int main(void) {
            double value = 3.99;
            int truncated = (int)value;
            char small = (char)300;
            printf("%d %d %.1f\\n", truncated, small, (double)truncated);
            return 0;
        }
        """, output: "3 44 3.0\n")
    }

    // MARK: - 入力

    func testScanfReadsIntegers() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int a, b;
            scanf("%d %d", &a, &b);
            printf("%d\\n", a + b);
            return 0;
        }
        """, output: "30\n", input: "12 18\n")
    }

    func testGetcharReadsInput() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int c;
            int count = 0;
            while ((c = getchar()) != -1) count++;
            printf("%d\\n", count);
            return 0;
        }
        """, output: "5\n", input: "abcde")
    }

    // MARK: - コンパイルエラー

    func testUndeclaredVariableIsReported() {
        expectCompileError("int main(void) { return missing; }", containing: "知らない名前です")
    }

    func testUnknownFunctionIsReported() {
        expectCompileError("int main(void) { return nothing(1); }", containing: "知らない関数です")
    }

    func testWrongArgumentCountIsReported() {
        expectCompileError("""
        int twice(int n) { return n * 2; }
        int main(void) { return twice(1, 2); }
        """, containing: "引数は 1 個")
    }

    func testMissingMainIsReported() {
        expectCompileError("int helper(void) { return 0; }", containing: "main 関数が見つかりません")
    }

    func testTypeMismatchIsReported() {
        expectCompileError("""
        struct Point { int x; };
        int main(void) { struct Point p; int n = p; return n; }
        """, containing: "型が合いません")
    }

    func testSyntaxErrorPointsAtLine() {
        let execution = MiniC.execute(source: """
        int main(void) {
            int x = ;
            return x;
        }
        """)
        XCTAssertFalse(execution.compiled)
        XCTAssertTrue(execution.diagnosticsText.contains("2:"), execution.diagnosticsText)
    }

    // MARK: - 実行時エラー

    func testDivisionByZeroIsCaught() {
        expectRuntimeError("""
        int main(void) {
            int zero = 0;
            return 10 / zero;
        }
        """, containing: "0 で割ろうとしました")
    }

    func testNullPointerIsCaught() {
        expectRuntimeError("""
        int main(void) {
            int *pointer = 0;
            *pointer = 1;
            return 0;
        }
        """, containing: "NULL ポインタ")
    }

    func testInfiniteLoopIsStopped() {
        let execution = MiniC.execute(source: "int main(void) { while (1) { } return 0; }",
                                      limits: MiniCLimits(maximumSteps: 100_000))
        XCTAssertNotNil(execution.runtimeError)
        XCTAssertTrue(execution.runtimeError?.contains("実行が長すぎます") == true,
                      execution.runtimeError ?? "")
    }

    func testDeepRecursionIsStopped() {
        let execution = MiniC.execute(source: """
        int down(int n) { return down(n + 1); }
        int main(void) { return down(0); }
        """)
        XCTAssertNotNil(execution.runtimeError)
    }

    func testDoubleFreeIsCaught() {
        expectRuntimeError("""
        #include <stdlib.h>
        int main(void) {
            int *block = (int *)malloc(16);
            free(block);
            free(block);
            return 0;
        }
        """, containing: "2 回 free")
    }

    // MARK: - まとまったプログラム

    func testSieveOfEratosthenes() {
        expect("""
        #include <stdio.h>
        #define LIMIT 50
        int main(void) {
            int sieve[LIMIT];
            for (int i = 0; i < LIMIT; i++) sieve[i] = 1;
            sieve[0] = 0;
            sieve[1] = 0;
            for (int i = 2; i * i < LIMIT; i++) {
                if (!sieve[i]) continue;
                for (int j = i * i; j < LIMIT; j += i) sieve[j] = 0;
            }
            for (int i = 0; i < LIMIT; i++) if (sieve[i]) printf("%d ", i);
            printf("\\n");
            return 0;
        }
        """, output: "2 3 5 7 11 13 17 19 23 29 31 37 41 43 47 \n")
    }

    func testMatrixMultiplication() {
        expect("""
        #include <stdio.h>
        int main(void) {
            int a[2][2] = {{1, 2}, {3, 4}};
            int b[2][2] = {{5, 6}, {7, 8}};
            int c[2][2];
            for (int i = 0; i < 2; i++)
                for (int j = 0; j < 2; j++) {
                    c[i][j] = 0;
                    for (int k = 0; k < 2; k++) c[i][j] += a[i][k] * b[k][j];
                }
            printf("%d %d %d %d\\n", c[0][0], c[0][1], c[1][0], c[1][1]);
            return 0;
        }
        """, output: "19 22 43 50\n")
    }

    func testStackMachineStyleProgram() {
        expect("""
        #include <stdio.h>
        #include <stdlib.h>
        int main(void) {
            int *stack = (int *)malloc(sizeof(int) * 16);
            int top = 0;
            stack[top++] = 4;
            stack[top++] = 5;
            int right = stack[--top];
            int left = stack[--top];
            stack[top++] = left * right;
            printf("%d %d\\n", stack[0], top);
            free(stack);
            return 0;
        }
        """, output: "20 1\n")
    }

    func testDisassemblyIsProduced() throws {
        let text = try MiniC.disassemble(source: """
        int main(void) { int x = 1; return x + 1; }
        """)
        XCTAssertTrue(text.contains("main:"), text)
        XCTAssertTrue(text.contains("ret"), text)
    }

    func testRepositoryExampleCompilesAndRuns() {
        expect("""
        /* Examples/demo.c と同じ内容 */
        #include <stdio.h>
        int main(void) {
            printf("hello from C\\n");
            for (int i = 1; i <= 5; i++) {
                printf("%d の 2 乗は %d\\n", i, i * i);
            }
            return 0;
        }
        """, output: """
        hello from C
        1 の 2 乗は 1
        2 の 2 乗は 4
        3 の 2 乗は 9
        4 の 2 乗は 16
        5 の 2 乗は 25

        """)
    }
}

// MARK: - 未対応機能の報告

extension MiniCTests {
    func testGotoIsReportedAsUnsupported() {
        let execution = MiniC.execute(source: """
        int main(void) {
            int i = 0;
        again:
            i++;
            if (i < 3) goto again;
            return i;
        }
        """)
        XCTAssertFalse(execution.compiled)
        XCTAssertTrue(execution.diagnosticsText.contains("goto"), execution.diagnosticsText)
    }

    func testUnionIsReportedAsUnsupported() {
        let execution = MiniC.execute(source: """
        union Value { int number; char bytes[4]; };
        int main(void) { return 0; }
        """)
        XCTAssertFalse(execution.compiled)
        XCTAssertTrue(execution.diagnosticsText.contains("union"), execution.diagnosticsText)
    }

    func testStructReturnIsReportedAsUnsupported() {
        let execution = MiniC.execute(source: """
        struct Point { int x; int y; };
        struct Point makePoint(int x, int y) { struct Point p; p.x = x; p.y = y; return p; }
        int main(void) { return makePoint(1, 2).x; }
        """)
        XCTAssertFalse(execution.compiled)
        XCTAssertTrue(execution.diagnosticsText.contains("戻り値"), execution.diagnosticsText)
    }

    func testFunctionPointerCallIsReportedAsUnsupported() {
        let execution = MiniC.execute(source: """
        int twice(int n) { return n * 2; }
        int main(void) {
            int (*f)(int) = twice;
            return f(3);
        }
        """)
        XCTAssertFalse(execution.compiled)
    }
}
