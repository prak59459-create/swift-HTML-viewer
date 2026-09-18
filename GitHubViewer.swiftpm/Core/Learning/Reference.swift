import Foundation

// MARK: - 239. エラーからの修正候補

/// 「こう直すと動くかもしれません」という候補。
public struct FixSuggestion: Identifiable, Equatable, Sendable {
    public var id: UUID
    /// 何をする案か。
    public var title: String
    /// なぜそう思うか。
    public var detail: String
    /// 直す行 (1 始まり)。分からなければ nil。
    public var line: Int?
    /// 置き換えるもとの文字。
    public var replacing: String?
    /// 置き換えたあとの文字。
    public var replacement: String?

    public init(id: UUID = UUID(), title: String, detail: String, line: Int? = nil,
                replacing: String? = nil, replacement: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.line = line
        self.replacing = replacing
        self.replacement = replacement
    }

    /// そのまま直せる案か。
    public var isApplicable: Bool {
        line != nil && replacing != nil && replacement != nil
    }

    /// 案のとおりに直したコードを返す。直せない案なら nil。
    public func apply(to source: String) -> String? {
        guard let line, let replacing, let replacement else { return nil }
        var lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return nil }
        guard let range = lines[line - 1].range(of: replacing) else { return nil }
        lines[line - 1].replaceSubrange(range, with: replacement)
        return lines.joined(separator: "\n")
    }
}

/// エラーの文から、直し方を考える。
public enum FixAdvisor {

    /// 実行の結果から候補を作る。
    public static func suggestions(for result: RunResult, source: String)
        -> [FixSuggestion] {
        guard let failure = result.failureText else { return [] }
        return suggestions(forMessage: failure, source: source,
                           languageID: result.languageID)
    }

    /// エラーの文と、書いていたコードから候補を作る。
    public static func suggestions(forMessage message: String, source: String,
                                   languageID: String) -> [FixSuggestion] {
        var found: [FixSuggestion] = []
        let line = lineNumber(in: message)

        // 名前の打ち間違いは、似ている名前を探す。
        if let name = quotedName(in: message, keywords: ["未定義", "見つかりません",
                                                         "はありません", "undefined",
                                                         "not found"]) {
            for candidate in similarNames(to: name, in: source, languageID: languageID) {
                found.append(FixSuggestion(
                    title: "\(name) を \(candidate) に直す",
                    detail: "コードの中に、よく似た名前 \(candidate) があります。",
                    line: line ?? lineContaining(name, in: source),
                    replacing: name, replacement: candidate))
            }
            if found.isEmpty {
                found.append(FixSuggestion(
                    title: "\(name) を先に用意する",
                    detail: "使う前に、\(name) を作るか取り込む必要があります。",
                    line: line))
            }
        }

        // 記号の不足。
        for (token, label) in [(";", "セミコロン"), (")", "閉じ括弧"),
                               ("}", "閉じ中括弧"), ("]", "閉じ角括弧")] {
            guard message.contains("\(token) が必要") || message.contains("expected '\(token)'")
            else { continue }
            found.append(FixSuggestion(
                title: "\(label) を足す",
                detail: "この行の終わりに \(token) が足りていないようです。",
                line: line))
        }

        // 括弧の数が合わない。
        if let unbalanced = unbalancedBracket(in: source) {
            found.append(FixSuggestion(
                title: "\(unbalanced.character) の数を合わせる",
                detail: "\(unbalanced.character) が \(unbalanced.difference) 個 多い (または足りない) ようです。",
                line: unbalanced.line))
        }

        // 0 での割り算。
        if message.contains("0 で割") || message.lowercased().contains("division by zero") {
            found.append(FixSuggestion(
                title: "割る前に 0 かどうか調べる",
                detail: "割る数が 0 のときは、別の処理に分けてください。",
                line: line))
        }

        // 範囲外。
        if message.contains("範囲外") || message.lowercased().contains("out of range")
            || message.lowercased().contains("index out of bounds") {
            found.append(FixSuggestion(
                title: "添字の範囲を見直す",
                detail: "配列の添字は 0 から (要素数 - 1) までです。"
                    + "繰り返しの終わりの条件を確かめてください。",
                line: line))
        }

        // 時間切れ。
        if message.contains("時間") && message.contains("超") {
            found.append(FixSuggestion(
                title: "繰り返しが終わるか確かめる",
                detail: "条件がいつまでも真のままだと、終わりません。",
                line: line))
        }

        // 型が合わない。
        if message.contains("型") && (message.contains("合いません")
                                       || message.contains("できません")) {
            found.append(FixSuggestion(
                title: "型をそろえる",
                detail: "文字列と数を混ぜていないか、変換が要らないか見てください。",
                line: line))
        }

        // 最後に、もとからある説明も足す。
        if let explanation = ErrorHelp.explanation(for: message) {
            found.append(FixSuggestion(title: explanation.summary,
                                       detail: explanation.remedy, line: line))
        }
        return found
    }

    /// 「3:12 …」のような行番号を取り出す。
    static func lineNumber(in message: String) -> Int? {
        let pattern = #"(?:^|\s)(\d+):(\d+)"#
        guard let range = message.range(of: pattern, options: .regularExpression)
        else { return nil }
        let text = message[range].trimmingCharacters(in: .whitespaces)
        return Int(text.split(separator: ":")[0])
    }

    /// エラー文の中の名前を拾う。
    static func quotedName(in message: String, keywords: [String]) -> String? {
        guard keywords.contains(where: { message.contains($0) }) else { return nil }
        // 「未定義の変数 foo」「foo はありません」のような並びから拾う。
        let pattern = #"[A-Za-z_][A-Za-z0-9_]*"#
        let words = matches(of: pattern, in: message)
        // 英語のキーワードそのものは外す。
        let noise: Set<String> = ["undefined", "not", "found", "variable", "function",
                                  "name", "error"]
        return words.last { !noise.contains($0.lowercased()) }
    }

    /// コードの中から、似ている名前を探す。
    static func similarNames(to name: String, in source: String,
                             languageID: String, limit: Int = 3) -> [String] {
        var names = Set(matches(of: #"[A-Za-z_][A-Za-z0-9_]*"#, in: source))
        names.remove(name)
        let scored = names.compactMap { candidate -> (String, Int)? in
            let distance = editDistance(name.lowercased(), candidate.lowercased())
            // 遠すぎるものは候補にしない。
            let allowed = Swift.max(1, name.count / 3)
            guard distance <= allowed else { return nil }
            return (candidate, distance)
        }
        return scored.sorted {
            $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0
        }.prefix(limit).map(\.0)
    }

    static func lineContaining(_ text: String, in source: String) -> Int? {
        let lines = source.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.contains(text) }) else {
            return nil
        }
        return index + 1
    }

    /// 括弧の数が合わない場所を探す。
    static func unbalancedBracket(in source: String)
        -> (character: String, difference: Int, line: Int?)? {
        for (open, close) in [("(", ")"), ("{", "}"), ("[", "]")] {
            let opens = source.filter { String($0) == open }.count
            let closes = source.filter { String($0) == close }.count
            guard opens != closes else { continue }
            let difference = abs(opens - closes)
            let character = opens > closes ? open : close
            return (character, difference, nil)
        }
        return nil
    }

    static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let all = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return all.compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// レーベンシュタイン距離 (打ち間違いの近さ)。
    static func editDistance(_ left: String, _ right: String) -> Int {
        let a = Array(left), b = Array(right)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1,
                                       previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - 241. 内蔵の言語リファレンス

/// リファレンスの 1 項目。
public struct ReferenceEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, CaseIterable, Sendable {
        case syntax
        case builtin
        case concept

        public var displayName: String {
            switch self {
            case .syntax: return "構文"
            case .builtin: return "組み込み"
            case .concept: return "考え方"
            }
        }
    }

    public var id: String
    /// nil なら、どの言語でも通じる話。
    public var languageID: String?
    public var kind: Kind
    public var title: String
    public var summary: String
    public var example: String
    public var seeAlso: [String]

    public init(id: String, languageID: String?, kind: Kind, title: String,
                summary: String, example: String, seeAlso: [String] = []) {
        self.id = id
        self.languageID = languageID
        self.kind = kind
        self.title = title
        self.summary = summary
        self.example = example
        self.seeAlso = seeAlso
    }

    var searchText: String {
        [title, summary, languageID ?? "", kind.displayName].joined(separator: " ")
    }
}

/// 通信なしで引ける、短いリファレンス。
public enum ReferenceLibrary {

    public static func entries(languageID: String?) -> [ReferenceEntry] {
        all.filter { $0.languageID == languageID || $0.languageID == nil }
    }

    public static func entry(id: String) -> ReferenceEntry? {
        all.first { $0.id == id }
    }

    public static func search(_ query: String, languageID: String? = nil,
                              kind: ReferenceEntry.Kind? = nil,
                              limit: Int = 30) -> [ReferenceEntry] {
        var candidates = all
        if let languageID {
            candidates = candidates.filter {
                $0.languageID == languageID || $0.languageID == nil
            }
        }
        if let kind { candidates = candidates.filter { $0.kind == kind } }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(candidates.prefix(limit)) }
        return FuzzySearch.search(trimmed, in: candidates, limit: limit) {
            $0.searchText
        }.map(\.element)
    }

    public static let all: [ReferenceEntry] = [
        ReferenceEntry(id: "concept-variable", languageID: nil, kind: .concept,
                       title: "変数",
                       summary: "値に名前を付けて、あとから呼び出せるようにするもの。",
                       example: "count = 3", seeAlso: ["concept-type"]),
        ReferenceEntry(id: "concept-type", languageID: nil, kind: .concept,
                       title: "型",
                       summary: "値の種類。数と文字列を混ぜると、たいてい怒られる。",
                       example: "1 + 2      // 数\n\"1\" + \"2\"  // 文字列"),
        ReferenceEntry(id: "concept-function", languageID: nil, kind: .concept,
                       title: "関数",
                       summary: "手順にまとめて名前を付けたもの。何度でも呼べる。",
                       example: "double(21)  // → 42"),
        ReferenceEntry(id: "concept-loop", languageID: nil, kind: .concept,
                       title: "繰り返し",
                       summary: "同じ処理を、条件が満たされるあいだ続けるもの。",
                       example: "for i in 0..<3 { print(i) }"),
        ReferenceEntry(id: "concept-recursion", languageID: nil, kind: .concept,
                       title: "再帰",
                       summary: "関数が自分を呼ぶこと。終わる条件を必ず書く。",
                       example: "fact(n) = n <= 1 ? 1 : n * fact(n - 1)"),

        ReferenceEntry(id: "go-print", languageID: "go", kind: .builtin,
                       title: "fmt.Println",
                       summary: "値を並べて 1 行出す。空白で区切られる。",
                       example: "fmt.Println(\"a\", 1)  // a 1"),
        ReferenceEntry(id: "go-slice", languageID: "go", kind: .syntax,
                       title: "スライス",
                       summary: "伸び縮みする並び。append で足す。",
                       example: "values := []int{1, 2}\nvalues = append(values, 3)"),
        ReferenceEntry(id: "go-error", languageID: "go", kind: .syntax,
                       title: "error を返す",
                       summary: "失敗するかもしれない関数は、error も返す。",
                       example: """
                       func div(a, b int) (int, error) {
                           if b == 0 {
                               return 0, errors.New("0 で割れません")
                           }
                           return a / b, nil
                       }
                       """),
        ReferenceEntry(id: "kotlin-val", languageID: "kotlin", kind: .syntax,
                       title: "val と var",
                       summary: "val は変えないもの、var は変えられるもの。",
                       example: "val name = \"あ\"\nvar count = 1"),
        ReferenceEntry(id: "kotlin-map", languageID: "kotlin", kind: .builtin,
                       title: "Map",
                       summary: "鍵と値の組。ない鍵を引くと null が返る。",
                       example: "val counts = HashMap<String, Int>()\ncounts[\"あ\"] = 1"),
        ReferenceEntry(id: "rust-match", languageID: "rust", kind: .syntax,
                       title: "match",
                       summary: "値の形で分ける。すべての場合を書く必要がある。",
                       example: """
                       match value {
                           1 => println!("いち"),
                           _ => println!("そのほか"),
                       }
                       """),
        ReferenceEntry(id: "rust-mut", languageID: "rust", kind: .syntax,
                       title: "mut",
                       summary: "変えたい変数に付ける印。付けないと変えられない。",
                       example: "let mut count = 0;\ncount += 1;"),
        ReferenceEntry(id: "java-main", languageID: "java", kind: .syntax,
                       title: "main",
                       summary: "プログラムの入口。この形でないと始まらない。",
                       example: "public static void main(String[] args) { }"),
        ReferenceEntry(id: "javascript-const", languageID: "javascript", kind: .syntax,
                       title: "const と let",
                       summary: "const は入れ直せない、let は入れ直せる。",
                       example: "const name = \"あ\";\nlet count = 1;"),
        ReferenceEntry(id: "javascript-array", languageID: "javascript", kind: .builtin,
                       title: "配列のメソッド",
                       summary: "map・filter・reduce で、並びを作り変える。",
                       example: "[1, 2, 3].map(x => x * 2)  // [2, 4, 6]"),
        ReferenceEntry(id: "cpp-vector", languageID: "cpp", kind: .builtin,
                       title: "std::vector",
                       summary: "伸び縮みする配列。push_back で足す。",
                       example: "std::vector<int> values;\nvalues.push_back(1);"),
        ReferenceEntry(id: "shell-pipe", languageID: "shell", kind: .syntax,
                       title: "パイプ",
                       summary: "左の出力を、右の入力につなぐ。",
                       example: "echo あ | cat")
    ]
}

// MARK: - 240. コード例の検索

/// サンプル・スニペット・リファレンスを、まとめて探した結果。
public struct ExampleHit: Identifiable, Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case sample
        case snippet
        case reference
        case tutorial

        public var displayName: String {
            switch self {
            case .sample: return "サンプル"
            case .snippet: return "スニペット"
            case .reference: return "リファレンス"
            case .tutorial: return "チュートリアル"
            }
        }
    }

    public var id: String
    public var source: Source
    public var title: String
    public var summary: String
    public var code: String
    public var languageID: String?

    public init(id: String, source: Source, title: String, summary: String,
                code: String, languageID: String?) {
        self.id = id
        self.source = source
        self.title = title
        self.summary = summary
        self.code = code
        self.languageID = languageID
    }

    var searchText: String {
        [title, summary, languageID ?? "", source.displayName].joined(separator: " ")
    }
}

/// 例をまとめて探す。
public enum ExampleSearch {

    /// 探せるもの全部。
    public static func candidates(library: SampleLibrary = SampleLibrary())
        -> [ExampleHit] {
        var hits: [ExampleHit] = []
        for sample in library.all {
            hits.append(ExampleHit(id: "sample:\(sample.id)", source: .sample,
                                   title: sample.title, summary: sample.summary,
                                   code: sample.source,
                                   languageID: sample.languageID))
        }
        for snippet in SnippetLibrary.builtIn {
            hits.append(ExampleHit(id: "snippet:\(snippet.id)", source: .snippet,
                                   title: snippet.title,
                                   summary: "\(snippet.trigger) で展開",
                                   code: snippet.body,
                                   languageID: snippet.languageIDs.first))
        }
        for entry in ReferenceLibrary.all {
            hits.append(ExampleHit(id: "reference:\(entry.id)", source: .reference,
                                   title: entry.title, summary: entry.summary,
                                   code: entry.example,
                                   languageID: entry.languageID))
        }
        for tutorial in TutorialLibrary.all {
            for step in tutorial.steps {
                hits.append(ExampleHit(id: "tutorial:\(step.id)", source: .tutorial,
                                       title: "\(tutorial.title) — \(step.title)",
                                       summary: step.explanation, code: step.code,
                                       languageID: tutorial.languageID))
            }
        }
        return hits
    }

    public static func search(_ query: String, languageID: String? = nil,
                              sources: Set<ExampleHit.Source>? = nil,
                              library: SampleLibrary = SampleLibrary(),
                              limit: Int = 30) -> [ExampleHit] {
        var candidates = self.candidates(library: library)
        if let languageID {
            candidates = candidates.filter { $0.languageID == languageID }
        }
        if let sources { candidates = candidates.filter { sources.contains($0.source) } }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(candidates.prefix(limit)) }
        return FuzzySearch.search(trimmed, in: candidates, limit: limit) {
            $0.searchText
        }.map(\.element)
    }
}
