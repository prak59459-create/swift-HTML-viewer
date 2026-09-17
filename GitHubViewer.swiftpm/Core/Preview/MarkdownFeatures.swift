import Foundation

// MARK: - 163. プレビューとソースの並列表示

/// Markdown の見せ方。
public enum MarkdownViewMode: String, CaseIterable, Identifiable, Codable, Equatable,
                              Sendable {
    case preview
    case source
    case both

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .preview: return "プレビュー"
        case .source: return "ソース"
        case .both: return "両方"
        }
    }

    public var showsPreview: Bool { self != .source }
    public var showsSource: Bool { self != .preview }
}

/// ソースの行と、プレビューの見出しを結びつける。
///
/// 片方をスクロールしたとき、もう片方を同じところに合わせるのに使う。
public enum MarkdownScrollSync {

    /// 見出しごとの (ソースの行, 何番目の見出しか)。
    public static func anchors(in markdown: String) -> [(line: Int, index: Int)] {
        var result: [(Int, Int)] = []
        var inFence = false
        var count = 0
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, trimmed.hasPrefix("#") else { continue }
            result.append((index + 1, count))
            count += 1
        }
        return result
    }

    /// ソースの行に対応する、いちばん近い見出しの番号。
    public static func headingIndex(forSourceLine line: Int,
                                    in markdown: String) -> Int? {
        let found = anchors(in: markdown)
        guard !found.isEmpty else { return nil }
        var result: Int?
        for anchor in found where anchor.line <= line { result = anchor.index }
        return result
    }

    /// 見出しの番号に対応するソースの行。
    public static func sourceLine(forHeadingIndex index: Int,
                                  in markdown: String) -> Int? {
        anchors(in: markdown).first { $0.index == index }?.line
    }
}

// MARK: - 165. Markdown 内のコードブロック実行

/// Markdown の中のコード塊。
public struct MarkdownCodeBlock: Identifiable, Equatable, Sendable {
    public var id: Int
    /// ``` のうしろに書かれた言語名。
    public var language: String?
    public var code: String
    /// 始まりの行 (``` の行)。
    public var startLine: Int
    public var endLine: Int

    public init(id: Int, language: String?, code: String, startLine: Int,
                endLine: Int) {
        self.id = id
        self.language = language
        self.code = code
        self.startLine = startLine
        self.endLine = endLine
    }

    /// 内蔵処理系の言語 ID (動かせないときは nil)。
    public var runnableLanguageID: String? {
        guard let language else { return nil }
        let id = MarkdownCodeBlock.normalize(language)
        return RunSession.hasEngine(for: id) ? id : nil
    }

    public var isRunnable: Bool { runnableLanguageID != nil }

    /// `js` や `c++` のような書き方をそろえる。
    static func normalize(_ language: String) -> String {
        let lower = language.lowercased().trimmingCharacters(in: .whitespaces)
        switch lower {
        case "js", "node": return "javascript"
        case "ts": return "typescript"
        case "c++", "cxx", "cc": return "cpp"
        case "c#", "cs": return "csharp"
        case "objective-c", "objc", "obj-c": return "objectivec"
        case "sh", "bash", "zsh", "shell-session", "console": return "shell"
        case "py": return "python"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "kt": return "kotlin"
        case "ml": return "ocaml"
        case "hs": return "haskell"
        case "ex", "exs": return "elixir"
        case "erl": return "erlang"
        case "pl": return "perl"
        case "cr": return "crystal"
        case "jl": return "julia"
        case "pas": return "pascal"
        case "lisp", "elisp", "commonlisp": return "lisp"
        default: return lower
        }
    }
}

/// Markdown からコード塊を取り出す。
public enum MarkdownCode {

    public static func blocks(in markdown: String) -> [MarkdownCodeBlock] {
        var result: [MarkdownCodeBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        var counter = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let fence: String?
            if trimmed.hasPrefix("```") { fence = "```" }
            else if trimmed.hasPrefix("~~~") { fence = "~~~" }
            else { fence = nil }

            guard let marker = fence else {
                index += 1
                continue
            }
            let language = String(trimmed.dropFirst(marker.count))
                .components(separatedBy: " ").first?
                .trimmingCharacters(in: .whitespaces)
            let startLine = index + 1
            var body: [String] = []
            index += 1
            while index < lines.count {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix(marker) { break }
                body.append(lines[index])
                index += 1
            }
            result.append(MarkdownCodeBlock(
                id: counter, language: (language?.isEmpty ?? true) ? nil : language,
                code: body.joined(separator: "\n"), startLine: startLine,
                endLine: index + 1))
            counter += 1
            index += 1
        }
        return result
    }

    /// 動かせる塊だけ。
    public static func runnableBlocks(in markdown: String) -> [MarkdownCodeBlock] {
        blocks(in: markdown).filter(\.isRunnable)
    }

    /// 塊を動かす。
    public static func run(_ block: MarkdownCodeBlock,
                           options: RunOptions = .default) throws -> RunResult {
        guard let languageID = block.runnableLanguageID else {
            throw RunSessionError.noEngine(block.language ?? "?")
        }
        return try RunSession.run(languageID: languageID, source: block.code,
                                  options: options)
    }

    /// 動かした結果を、塊のうしろに書き足した Markdown を作る。
    public static func inserting(_ result: RunResult, after block: MarkdownCodeBlock,
                                 in markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let output = ANSIParser.strip(result.output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let insertion = ["", "出力:", "", "```", output.isEmpty ? "(出力なし)" : output,
                         "```"]
        let index = Swift.min(block.endLine, lines.count)
        lines.insert(contentsOf: insertion, at: index)
        return lines.joined(separator: "\n")
    }
}

// MARK: - 166. 数式 / 167. Mermaid 図

/// Markdown の中で、ふつうの文ではない部分。
public struct EmbeddedBlock: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// `$$ ... $$` や `\[ ... \]`。
        case displayMath
        /// `$ ... $`。
        case inlineMath
        /// ```mermaid の塊。
        case mermaid

        public var displayName: String {
            switch self {
            case .displayMath: return "数式 (別行)"
            case .inlineMath: return "数式 (行内)"
            case .mermaid: return "Mermaid 図"
            }
        }
    }

    public var id: Int
    public var kind: Kind
    /// 中身 (囲みの記号は含まない)。
    public var content: String
    public var startLine: Int
    public var endLine: Int

    public init(id: Int, kind: Kind, content: String, startLine: Int, endLine: Int) {
        self.id = id
        self.kind = kind
        self.content = content
        self.startLine = startLine
        self.endLine = endLine
    }
}

/// 数式と Mermaid の塊を見つける。
///
/// 描くのは WebView に任せる。ここでは「どこに何があるか」を見つけて、
/// 描くための HTML を組み立てるところまでを受け持つ。
public enum EmbeddedContent {

    public static func blocks(in markdown: String) -> [EmbeddedBlock] {
        var result: [EmbeddedBlock] = []
        var counter = 0

        // Mermaid はコード塊として書かれる。
        for block in MarkdownCode.blocks(in: markdown)
        where block.language?.lowercased() == "mermaid" {
            result.append(EmbeddedBlock(id: counter, kind: .mermaid,
                                        content: block.code,
                                        startLine: block.startLine,
                                        endLine: block.endLine))
            counter += 1
        }

        // 数式はコード塊の外にあるものだけ見る。
        let codeLines = Set(MarkdownCode.blocks(in: markdown).flatMap {
            Array($0.startLine...$0.endLine)
        })
        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let number = index + 1
            guard !codeLines.contains(number) else {
                index += 1
                continue
            }
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            // `$$` で囲まれた別行の数式。
            if trimmed == "$$" {
                var body: [String] = []
                var cursor = index + 1
                while cursor < lines.count,
                      lines[cursor].trimmingCharacters(in: .whitespaces) != "$$" {
                    body.append(lines[cursor])
                    cursor += 1
                }
                if cursor < lines.count {
                    result.append(EmbeddedBlock(id: counter, kind: .displayMath,
                                                content: body.joined(separator: "\n"),
                                                startLine: number,
                                                endLine: cursor + 1))
                    counter += 1
                    index = cursor + 1
                    continue
                }
            }

            // 同じ行に `$$ ... $$`。
            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
                let content = String(trimmed.dropFirst(2).dropLast(2))
                result.append(EmbeddedBlock(id: counter, kind: .displayMath,
                                            content: content, startLine: number,
                                            endLine: number))
                counter += 1
                index += 1
                continue
            }

            // 行の中の `$ ... $`。
            for content in inlineMath(in: trimmed) {
                result.append(EmbeddedBlock(id: counter, kind: .inlineMath,
                                            content: content, startLine: number,
                                            endLine: number))
                counter += 1
            }
            index += 1
        }
        return result.sorted { $0.startLine < $1.startLine }
    }

    /// 行の中の `$ ... $` を拾う。
    static func inlineMath(in line: String) -> [String] {
        var result: [String] = []
        var current: String?
        var previous: Character?
        for character in line {
            if character == "$", previous != "\\" {
                if let open = current {
                    if !open.isEmpty { result.append(open) }
                    current = nil
                } else {
                    current = ""
                }
                previous = character
                continue
            }
            if current != nil { current?.append(character) }
            previous = character
        }
        return result
    }

    /// 数式があるか。
    public static func hasMath(_ markdown: String) -> Bool {
        blocks(in: markdown).contains { $0.kind != .mermaid }
    }

    /// Mermaid 図があるか。
    public static func hasMermaid(_ markdown: String) -> Bool {
        blocks(in: markdown).contains { $0.kind == .mermaid }
    }

    /// 描くために読み込む外部ライブラリ。
    ///
    /// 必要なときだけ読み込むよう、どれが要るかを返す。
    public static func requiredLibraries(for markdown: String) -> [String] {
        var result: [String] = []
        if hasMath(markdown) { result.append("KaTeX") }
        if hasMermaid(markdown) { result.append("Mermaid") }
        return result
    }
}
