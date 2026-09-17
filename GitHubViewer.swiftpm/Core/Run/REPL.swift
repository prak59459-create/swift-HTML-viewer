import Foundation

// MARK: - 107. REPL

/// REPL に打ち込んだ 1 回ぶん。
public struct REPLEntry: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var input: String
    public var output: String
    public var failureText: String?
    public var enteredAt: Date

    public init(id: UUID = UUID(), input: String, output: String,
                failureText: String? = nil, enteredAt: Date = Date()) {
        self.id = id
        self.input = input
        self.output = output
        self.failureText = failureText
        self.enteredAt = enteredAt
    }

    public var succeeded: Bool { failureText == nil }
}

/// 1 行ずつ打ち込んで試せる REPL。
///
/// 内蔵処理系は「ソース全体を実行する」作りなので、
/// これまでに打ったものを積み上げて毎回まとめて動かし、
/// 増えたぶんの出力だけを見せている。副作用のあるコードでも
/// 見た目が壊れないよう、出力は差分で取り出す。
public final class REPL: @unchecked Sendable {
    public let languageID: String
    public var options: RunOptions
    private let lock = NSLock()
    /// これまでに受け入れた行。
    private var accepted: [String] = []
    private var history: [REPLEntry] = []
    private var lastOutput = ""

    public init(languageID: String, options: RunOptions = RunOptions(timeLimit: 5)) {
        self.languageID = languageID
        self.options = options
    }

    /// これまでに受け入れた行をつないだソース。
    public var source: String {
        lock.lock()
        defer { lock.unlock() }
        return accepted.joined(separator: "\n")
    }

    public var entries: [REPLEntry] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    /// 1 回ぶん打ち込む。
    @discardableResult
    public func evaluate(_ line: String) -> REPLEntry {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let entry = REPLEntry(input: line, output: "")
            append(entry)
            return entry
        }

        lock.lock()
        let candidate = (accepted + [line]).joined(separator: "\n")
        let previousOutput = lastOutput
        lock.unlock()

        let result: RunResult
        do {
            result = try RunSession.run(languageID: languageID, source: candidate,
                                        options: options)
        } catch {
            let entry = REPLEntry(input: line, output: "",
                                  failureText: error.localizedDescription)
            append(entry)
            return entry
        }

        if let failure = result.failureText, !failure.isEmpty {
            // 通らなかった行は覚えない。
            let entry = REPLEntry(input: line, output: "", failureText: failure)
            append(entry)
            return entry
        }

        let whole = ANSIParser.strip(result.output)
        let fresh = Self.addedText(previous: previousOutput, whole: whole)

        lock.lock()
        accepted.append(line)
        lastOutput = whole
        lock.unlock()

        let entry = REPLEntry(input: line, output: fresh)
        append(entry)
        return entry
    }

    /// 前回の出力より後ろに増えたぶんだけを取り出す。
    static func addedText(previous: String, whole: String) -> String {
        guard !previous.isEmpty else { return whole }
        if whole.hasPrefix(previous) { return String(whole.dropFirst(previous.count)) }
        // 副作用で前の出力が変わった場合は、全部を見せる。
        return whole
    }

    /// 全部忘れる。
    public func reset() {
        lock.lock()
        accepted.removeAll()
        history.removeAll()
        lastOutput = ""
        lock.unlock()
    }

    /// 最後に受け入れた行を取り消す。
    @discardableResult
    public func undoLast() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !accepted.isEmpty else { return false }
        accepted.removeLast()
        lastOutput = ""
        return true
    }

    private func append(_ entry: REPLEntry) {
        lock.lock()
        history.append(entry)
        lock.unlock()
    }
}

// MARK: - 108. スクラッチパッド

/// 行ごとの結果を右側に並べて見せるための組。
public struct ScratchpadLine: Identifiable, Equatable, Sendable {
    public var id: Int
    public var text: String
    /// その行までで増えた出力。
    public var output: String
    public var failureText: String?

    public init(id: Int, text: String, output: String, failureText: String? = nil) {
        self.id = id
        self.text = text
        self.output = output
        self.failureText = failureText
    }
}

/// 打ちながら結果が横に出る「スクラッチパッド」。
///
/// 1 行ずつ足しながら動かして、その行で増えた出力を覚える。
public enum Scratchpad {

    /// ソース全体を行ごとに評価する。
    public static func evaluate(languageID: String, source: String,
                                options: RunOptions = RunOptions(timeLimit: 5))
        -> [ScratchpadLine] {
        let lines = source.components(separatedBy: "\n")
        var result: [ScratchpadLine] = []
        var accepted: [String] = []
        var previousOutput = ""

        for (index, line) in lines.enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                result.append(ScratchpadLine(id: index, text: line, output: ""))
                accepted.append(line)
                continue
            }
            accepted.append(line)
            let candidate = accepted.joined(separator: "\n")
            guard let run = try? RunSession.run(languageID: languageID,
                                                source: candidate, options: options)
            else {
                result.append(ScratchpadLine(id: index, text: line, output: ""))
                continue
            }
            if let failure = run.failureText, !failure.isEmpty {
                // まだ途中かもしれないので、エラーは覚えるだけで止めない。
                result.append(ScratchpadLine(id: index, text: line, output: "",
                                             failureText: failure
                                                 .components(separatedBy: "\n").first))
                continue
            }
            let whole = ANSIParser.strip(run.output)
            result.append(ScratchpadLine(id: index, text: line,
                                         output: REPL.addedText(previous: previousOutput,
                                                                whole: whole)))
            previousOutput = whole
        }
        return result
    }
}

// MARK: - 126. 複数ファイルのプロジェクト実行

/// 複数ファイルからなるプロジェクト。
public struct RunProject: Equatable, Sendable {
    public var languageID: String
    /// ファイル名 → 中身。
    public var files: [String: String]
    /// 最初に読むファイル。
    public var entryFile: String

    public init(languageID: String, files: [String: String], entryFile: String) {
        self.languageID = languageID
        self.files = files
        self.entryFile = entryFile
    }

    public var entrySource: String { files[entryFile] ?? "" }
}

/// 複数ファイルを 1 つのソースにまとめてから動かす。
///
/// 内蔵処理系はファイルを跨いだ読み込みをしないので、
/// `import` / `#include` / `require` などを見て必要なファイルを
/// 前に並べる。並べる順は依存の向きから決める。
public enum ProjectRunner {

    /// まとめたソースを作る。
    public static func combine(_ project: RunProject) -> String {
        let order = resolveOrder(project)
        var parts: [String] = []
        for name in order {
            guard let text = project.files[name] else { continue }
            parts.append(strippingImports(text, languageID: project.languageID,
                                          known: Set(project.files.keys)))
        }
        return parts.joined(separator: "\n\n")
    }

    /// 動かす。
    public static func run(_ project: RunProject,
                           options: RunOptions = .default) throws -> RunResult {
        var each = options
        // 読み込まなかったファイルも仮想ファイルとして置いておく。
        each.files = project.files.merging(options.files) { _, new in new }
        return try RunSession.run(languageID: project.languageID,
                                  source: combine(project), options: each)
    }

    /// 依存の順に並べる (深さ優先、同じものは 1 度だけ)。
    public static func resolveOrder(_ project: RunProject) -> [String] {
        var order: [String] = []
        var visited: Set<String> = []
        var visiting: Set<String> = []

        func visit(_ name: String) {
            guard project.files[name] != nil else { return }
            guard !visited.contains(name) else { return }
            // 循環しているときは、そこで打ち切る。
            guard !visiting.contains(name) else { return }
            visiting.insert(name)
            for dependency in dependencies(of: name, in: project) { visit(dependency) }
            visiting.remove(name)
            visited.insert(name)
            order.append(name)
        }

        visit(project.entryFile)
        // 読み込まれなかったファイルは後ろに回す。
        for name in project.files.keys.sorted() where !visited.contains(name) {
            visit(name)
        }
        return order
    }

    /// そのファイルが読み込んでいる、プロジェクト内のファイル。
    public static func dependencies(of name: String, in project: RunProject) -> [String] {
        guard let text = project.files[name] else { return [] }
        let known = Set(project.files.keys)
        var found: [String] = []
        for line in text.components(separatedBy: "\n") {
            for target in importTargets(in: line) {
                for candidate in candidates(for: target,
                                            languageID: project.languageID) {
                    if known.contains(candidate), candidate != name,
                       !found.contains(candidate) {
                        found.append(candidate)
                    }
                }
            }
        }
        return found
    }

    /// 1 行から読み込み先の名前を取り出す。
    static func importTargets(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let keywords = ["import ", "#include ", "require ", "require_relative ",
                        "use ", "from ", "load ", "include ", "source ", ". "]
        guard keywords.contains(where: { trimmed.hasPrefix($0) }) else { return [] }

        var targets: [String] = []
        // 引用符や山括弧の中。
        var current = ""
        var inside: Character?
        for character in trimmed {
            if let open = inside {
                let closes = (open == "<" && character == ">") || character == open
                if closes {
                    if !current.isEmpty { targets.append(current) }
                    current = ""
                    inside = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" || character == "<" {
                inside = character
                current = ""
            }
        }
        if targets.isEmpty {
            // 引用符なしの `import foo` / `use foo::bar;`。
            let parts = trimmed.components(separatedBy: " ")
            if parts.count >= 2 {
                var name = parts[1]
                for suffix in [";", ","] where name.hasSuffix(suffix) {
                    name.removeLast()
                }
                if let head = name.components(separatedBy: "::").first,
                   !head.isEmpty {
                    targets.append(head)
                }
            }
        }
        return targets
    }

    /// 読み込み先の名前から、ありえるファイル名を並べる。
    static func candidates(for target: String, languageID: String) -> [String] {
        var names = [target]
        if !target.contains(".") {
            for suffix in extensions(for: languageID) { names.append(target + suffix) }
        }
        // `foo/bar` のような書き方。
        if let last = target.components(separatedBy: "/").last, last != target {
            names.append(last)
            if !last.contains(".") {
                for suffix in extensions(for: languageID) { names.append(last + suffix) }
            }
        }
        return names
    }

    static func extensions(for languageID: String) -> [String] {
        if let template = FileTemplateCatalog.template(for: languageID),
           let suffix = template.fileName.components(separatedBy: ".").last {
            return [".\(suffix)"]
        }
        return [".txt"]
    }

    /// まとめたあとに残ると困る読み込み行を消す。
    static func strippingImports(_ text: String, languageID: String,
                                 known: Set<String>) -> String {
        text.components(separatedBy: "\n").filter { line in
            let targets = importTargets(in: line)
            guard !targets.isEmpty else { return true }
            // プロジェクト内のファイルを指しているものだけ落とす。
            return !targets.contains { target in
                candidates(for: target, languageID: languageID)
                    .contains { known.contains($0) }
            }
        }.joined(separator: "\n")
    }
}
