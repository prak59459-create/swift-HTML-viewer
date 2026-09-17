import Foundation

// MARK: - 105 / 106. テストと期待出力

/// 1 つのテスト。入力を与えて、出てくるものを確かめる。
public struct RunTestCase: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var input: String
    public var arguments: [String]
    /// 期待する標準出力。nil なら中身は見ない。
    public var expectedOutput: String?
    /// 期待する終了コード。nil なら見ない。
    public var expectedExitCode: Int32?
    /// 前後の空白を無視して比べるか。
    public var trimsWhitespace: Bool
    /// 最初から置いておくファイル。
    public var files: [String: String]

    public init(id: UUID = UUID(), name: String, input: String = "",
                arguments: [String] = [], expectedOutput: String? = nil,
                expectedExitCode: Int32? = nil, trimsWhitespace: Bool = true,
                files: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.input = input
        self.arguments = arguments
        self.expectedOutput = expectedOutput
        self.expectedExitCode = expectedExitCode
        self.trimsWhitespace = trimsWhitespace
        self.files = files
    }
}

/// テスト 1 つぶんの結果。
public struct RunTestResult: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var passed: Bool
    /// 何が違ったか。通ったときは nil。
    public var failureReason: String?
    public var actualOutput: String
    public var expectedOutput: String?
    public var exitCode: Int32
    public var duration: TimeInterval
    /// 期待と実際の差分 (違ったときだけ)。
    public var diff: [DiffLine]

    public init(id: UUID, name: String, passed: Bool, failureReason: String? = nil,
                actualOutput: String, expectedOutput: String? = nil, exitCode: Int32,
                duration: TimeInterval, diff: [DiffLine] = []) {
        self.id = id
        self.name = name
        self.passed = passed
        self.failureReason = failureReason
        self.actualOutput = actualOutput
        self.expectedOutput = expectedOutput
        self.exitCode = exitCode
        self.duration = duration
        self.diff = diff
    }
}

/// テストをひととおり走らせた結果。
public struct RunTestReport: Equatable, Sendable {
    public var results: [RunTestResult]

    public init(results: [RunTestResult] = []) {
        self.results = results
    }

    public var passedCount: Int { results.filter(\.passed).count }
    public var failedCount: Int { results.count - passedCount }
    public var allPassed: Bool { failedCount == 0 && !results.isEmpty }
    public var totalDuration: TimeInterval { results.reduce(0) { $0 + $1.duration } }

    /// 「3 / 4 件が成功 (0.12 秒)」。
    public var summary: String {
        guard !results.isEmpty else { return "テストがありません" }
        return "\(passedCount) / \(results.count) 件が成功"
            + " (\(RunFormatting.duration(totalDuration)))"
    }

    /// 人に見せる形。
    public var report: String {
        var lines = [summary]
        for result in results {
            lines.append("\(result.passed ? "✓" : "✗") \(result.name)"
                + (result.failureReason.map { " — \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}

/// テストを走らせる。
public enum TestRunner {

    /// 1 つ走らせる。
    public static func run(_ test: RunTestCase, languageID: String, source: String,
                           options: RunOptions = .default) -> RunTestResult {
        var each = options
        each.input = test.input
        each.arguments = test.arguments
        each.files = test.files.isEmpty ? options.files : test.files

        let result: RunResult
        do {
            result = try RunSession.run(languageID: languageID, source: source,
                                        options: each)
        } catch {
            return RunTestResult(id: test.id, name: test.name, passed: false,
                                 failureReason: error.localizedDescription,
                                 actualOutput: "", expectedOutput: test.expectedOutput,
                                 exitCode: -1, duration: 0)
        }

        let actual = ANSIParser.strip(result.output)

        if let failure = result.failureText, !failure.isEmpty {
            return RunTestResult(id: test.id, name: test.name, passed: false,
                                 failureReason: failure
                                     .components(separatedBy: "\n").first ?? failure,
                                 actualOutput: actual,
                                 expectedOutput: test.expectedOutput,
                                 exitCode: result.exitCode, duration: result.duration)
        }

        if let expectedCode = test.expectedExitCode, expectedCode != result.exitCode {
            return RunTestResult(id: test.id, name: test.name, passed: false,
                                 failureReason: "終了コードが \(expectedCode) ではなく "
                                     + "\(result.exitCode) でした",
                                 actualOutput: actual,
                                 expectedOutput: test.expectedOutput,
                                 exitCode: result.exitCode, duration: result.duration)
        }

        if let expected = test.expectedOutput {
            let left = normalize(expected, trims: test.trimsWhitespace)
            let right = normalize(actual, trims: test.trimsWhitespace)
            if left != right {
                return RunTestResult(id: test.id, name: test.name, passed: false,
                                     failureReason: "出力が期待と違います",
                                     actualOutput: actual, expectedOutput: expected,
                                     exitCode: result.exitCode,
                                     duration: result.duration,
                                     diff: DiffEngine.diff(old: left, new: right))
            }
        }

        return RunTestResult(id: test.id, name: test.name, passed: true,
                             actualOutput: actual, expectedOutput: test.expectedOutput,
                             exitCode: result.exitCode, duration: result.duration)
    }

    /// まとめて走らせる。
    public static func run(_ tests: [RunTestCase], languageID: String, source: String,
                           options: RunOptions = .default) -> RunTestReport {
        RunTestReport(results: tests.map {
            run($0, languageID: languageID, source: source, options: options)
        })
    }

    /// 行末の空白と末尾の改行をそろえる。
    static func normalize(_ text: String, trims: Bool) -> String {
        guard trims else { return text }
        return text.components(separatedBy: "\n")
            .map { line -> String in
                var copy = line
                while copy.hasSuffix(" ") || copy.hasSuffix("\t") { copy.removeLast() }
                return copy
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 実行した結果をそのまま期待値にする (「これでいい」を押したとき)。
    public static func accepting(_ test: RunTestCase,
                                 output: String) -> RunTestCase {
        var updated = test
        updated.expectedOutput = ANSIParser.strip(output)
        return updated
    }
}

// MARK: - 104. 入力を変えながら繰り返し実行

/// 入力の組を順に流して結果を並べる。
public struct BatchRun: Equatable, Sendable {
    public var inputs: [String]
    public var results: [RunResult]

    public init(inputs: [String], results: [RunResult]) {
        self.inputs = inputs
        self.results = results
    }

    /// 入力 → 出力の対応表。
    public var pairs: [(input: String, output: String)] {
        zip(inputs, results).map { ($0, ANSIParser.strip($1.output)) }
    }

    public static func == (lhs: BatchRun, rhs: BatchRun) -> Bool {
        lhs.inputs == rhs.inputs && lhs.results == rhs.results
    }

    /// Markdown の表にする。
    public var table: String {
        var rows = ["| 入力 | 出力 |", "| --- | --- |"]
        for (input, output) in pairs {
            rows.append("| \(escape(input)) | \(escape(output)) |")
        }
        return rows.joined(separator: "\n")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " / ")
    }
}

extension RunSession {
    /// 入力を取り替えながら動かして、まとめて返す。
    public static func batch(languageID: String, source: String, inputs: [String],
                             options: RunOptions = .default) throws -> BatchRun {
        BatchRun(inputs: inputs,
                 results: try run(languageID: languageID, source: source,
                                  inputs: inputs, options: options))
    }
}
