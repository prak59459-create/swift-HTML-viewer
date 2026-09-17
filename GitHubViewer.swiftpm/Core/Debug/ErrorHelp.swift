import Foundation

// MARK: - 145. エラーの日本語説明

/// エラーにそえる手助け。
public struct ErrorExplanation: Equatable, Sendable {
    /// ひとことでの言い換え。
    public var summary: String
    /// なぜ起きるのか。
    public var cause: String
    /// どう直すか。
    public var remedy: String
    /// 直し方の例 (あれば)。
    public var example: String?

    public init(summary: String, cause: String, remedy: String,
                example: String? = nil) {
        self.summary = summary
        self.cause = cause
        self.remedy = remedy
        self.example = example
    }

    public var text: String {
        var parts = [summary, "原因: \(cause)", "直し方: \(remedy)"]
        if let example { parts.append("例:\n\(example)") }
        return parts.joined(separator: "\n")
    }
}

/// 処理系が出したメッセージに、かみくだいた説明を添える。
public enum ErrorHelp {

    /// メッセージから説明を探す。見つからなければ nil。
    public static func explanation(for message: String) -> ErrorExplanation? {
        for rule in rules where rule.matches(message) {
            return rule.explanation
        }
        return nil
    }

    /// 説明があれば足した文字列。
    public static func annotated(_ message: String) -> String {
        guard let explanation = explanation(for: message) else { return message }
        return message + "\n\n" + explanation.text
    }

    struct Rule {
        var keywords: [String]
        var explanation: ErrorExplanation

        func matches(_ message: String) -> Bool {
            keywords.allSatisfy { message.contains($0) }
        }
    }

    static let rules: [Rule] = [
        Rule(keywords: ["0 で割る"], explanation: ErrorExplanation(
            summary: "0 で割ろうとしました。",
            cause: "割る数が 0 になっています。変数の初期値や、入力が空のときによく起きます。",
            remedy: "割る前に 0 かどうかを確かめてください。",
            example: "if (n != 0) { x = a / n; }")),

        Rule(keywords: ["0 で割った余り"], explanation: ErrorExplanation(
            summary: "0 で余りを求めようとしました。",
            cause: "`%` の右側が 0 になっています。",
            remedy: "余りを求める前に 0 でないことを確かめてください。")),

        Rule(keywords: ["が見つかりません"], explanation: ErrorExplanation(
            summary: "その名前の変数や関数が見当たりません。",
            cause: "打ち間違い、宣言する前に使っている、別のスコープで宣言している、"
                + "のいずれかです。",
            remedy: "つづりを確かめ、使う前に宣言されているか見てください。")),

        Rule(keywords: ["範囲外"], explanation: ErrorExplanation(
            summary: "配列の外側を読もう (書こう) としました。",
            cause: "添字が 0 未満か、要素の数以上になっています。"
                + "多くの言語で添字は 0 から始まり、最後は「個数 - 1」です。",
            remedy: "添字が 0 以上、個数未満に収まっているか確かめてください。",
            example: "for (int i = 0; i < n; i++) { ... }   // i <= n ではない")),

        Rule(keywords: ["深くなりすぎ"], explanation: ErrorExplanation(
            summary: "関数の呼び出しが深くなりすぎました。",
            cause: "再帰が終わっていません。終わりの条件に届いていない可能性があります。",
            remedy: "再帰の「もう呼ばない」条件を確かめ、"
                + "呼ぶたびに条件へ近づいているか見てください。")),

        Rule(keywords: ["実行ステップが上限"], explanation: ErrorExplanation(
            summary: "命令の数が多すぎて打ち切りました。",
            cause: "終わらないループになっているか、計算量が大きすぎます。",
            remedy: "ループの終わり方を確かめてください。"
                + "正しく重い処理なら、実行の上限を上げてください。")),

        Rule(keywords: ["実行時間が上限"], explanation: ErrorExplanation(
            summary: "時間がかかりすぎたので打ち切りました。",
            cause: "終わらないループか、時間のかかる計算です。",
            remedy: "アルゴリズムを見直すか、時間の上限を上げてください。")),

        Rule(keywords: ["定数", "代入"], explanation: ErrorExplanation(
            summary: "変えられない値を変えようとしました。",
            cause: "`const` / `val` / `let` などで宣言したものは、あとから変えられません。",
            remedy: "変えたいなら、変えられる宣言 (`var` など) にしてください。")),

        Rule(keywords: ["数値が必要"], explanation: ErrorExplanation(
            summary: "数を待っているところに、数でないものが来ました。",
            cause: "文字列や空の値をそのまま計算に使っています。",
            remedy: "数に直してから使ってください (`Number(...)` / `int(...)` など)。")),

        Rule(keywords: ["捕まえられていない例外"], explanation: ErrorExplanation(
            summary: "投げられた例外を誰も受け取りませんでした。",
            cause: "`throw` した例外に、対応する `catch` がありません。",
            remedy: "呼び出しを `try` で囲んで `catch` してください。")),

        Rule(keywords: ["キーがありません"], explanation: ErrorExplanation(
            summary: "辞書にそのキーがありません。",
            cause: "入れる前に読んでいるか、キーのつづりが違います。",
            remedy: "読む前に入っているか確かめるか、無いときの既定値を決めてください。")),

        Rule(keywords: ["ファイルがありません"], explanation: ErrorExplanation(
            summary: "そのファイルは用意されていません。",
            cause: "このアプリではファイルは実際のディスクではなく、"
                + "実行のたびに用意する仮想のものです。",
            remedy: "実行の設定でファイルを用意するか、"
                + "`writeFile` で先に作ってください。")),

        Rule(keywords: ["構文"], explanation: ErrorExplanation(
            summary: "書き方が文法に合っていません。",
            cause: "括弧やクォートの閉じ忘れ、区切り記号の抜けがよくある原因です。",
            remedy: "エラーの行と、その少し上を見てください。"
                + "対応する括弧が閉じているか確かめます。"))
    ]
}

// MARK: - 146. よくある間違いの指摘

/// ソースを見て気づいたこと。
public struct SourceHint: Identifiable, Equatable, Sendable {
    public enum Level: String, Equatable, Sendable {
        /// おそらく間違い。
        case mistake
        /// 気をつけたほうがよい。
        case caution
        /// 書き方の提案。
        case style

        public var displayName: String {
            switch self {
            case .mistake: return "間違いかも"
            case .caution: return "注意"
            case .style: return "書き方"
            }
        }
    }

    public var id: UUID
    public var level: Level
    public var line: Int
    public var message: String
    /// どう直すか。
    public var suggestion: String?
    /// 規則の名前 (切り替え用)。
    public var ruleID: String

    public init(id: UUID = UUID(), level: Level, line: Int, message: String,
                suggestion: String? = nil, ruleID: String) {
        self.id = id
        self.level = level
        self.line = line
        self.message = message
        self.suggestion = suggestion
        self.ruleID = ruleID
    }
}

/// よくある間違いを、ソースを読んで見つける。
///
/// 文法まで踏み込まず、行ごとの見た目で判断する軽いもの。
/// 誤検出を減らすため、文字列とコメントは先に取り除く。
public enum CommonMistakes {

    public static func hints(in source: String, languageID: String?) -> [SourceHint] {
        var hints: [SourceHint] = []
        let lines = strippedLines(of: source, languageID: languageID)
        // 文字列そのものを見たい規則のために、元の行も取っておく。
        let rawLines = source.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let number = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let raw = index < rawLines.count
                ? rawLines[index].trimmingCharacters(in: .whitespaces) : trimmed
            guard !trimmed.isEmpty else { continue }

            // if (a = b) のような、比較のつもりの代入。
            if let range = trimmed.range(of: #"(if|while)\s*\([^=!<>]*[^=!<>]=[^=]"#,
                                         options: .regularExpression) {
                _ = range
                hints.append(SourceHint(
                    level: .mistake, line: number,
                    message: "条件の中で代入しています。比べたいなら `==` です。",
                    suggestion: "`=` を `==` に変えてください。",
                    ruleID: "assign-in-condition"))
            }

            // == で文字列を比べる言語 (Java など)。
            // 文字列そのものを見るので、ここだけ元の行を使う。
            if let id = languageID, ["java", "csharp", "kotlin", "scala"].contains(id),
               raw.range(of: #"==\s*"[^"]*""#, options: .regularExpression) != nil {
                hints.append(SourceHint(
                    level: .caution, line: number,
                    message: "文字列を `==` で比べています。中身を比べるなら `equals` です。",
                    suggestion: "`a.equals(\"...\")` を使ってください。",
                    ruleID: "string-identity"))
            }

            // <= で配列の最後まで回す。
            if trimmed.range(of: #"for\s*\(.*<=\s*\w+\.(length|size|count)"#,
                             options: .regularExpression) != nil {
                hints.append(SourceHint(
                    level: .mistake, line: number,
                    message: "`<=` で長さまで回すと、最後の 1 つ分はみ出します。",
                    suggestion: "`<` に変えてください。",
                    ruleID: "off-by-one"))
            }

            // 空の本体。
            if trimmed.range(of: #"^(if|while|for)\s*\(.*\)\s*;$"#,
                             options: .regularExpression) != nil {
                hints.append(SourceHint(
                    level: .mistake, line: number,
                    message: "条件のうしろにセミコロンがあるので、本体が空になっています。",
                    suggestion: "行末の `;` を消してください。",
                    ruleID: "empty-body"))
            }

            // 浮動小数の等値比較。
            if trimmed.range(of: #"==\s*[0-9]+\.[0-9]+"#,
                             options: .regularExpression) != nil {
                hints.append(SourceHint(
                    level: .caution, line: number,
                    message: "小数を `==` で比べると、誤差でうまくいかないことがあります。",
                    suggestion: "差の絶対値が十分小さいかで比べてください。",
                    ruleID: "float-equality"))
            }

            // 整数どうしの割り算。
            if trimmed.range(of: #"\b[0-9]+\s*/\s*[0-9]+\b"#,
                             options: .regularExpression) != nil,
               let id = languageID,
               ["c", "cpp", "java", "csharp", "go", "rust"].contains(id) {
                hints.append(SourceHint(
                    level: .caution, line: number,
                    message: "整数どうしの割り算は、小数点以下が切り捨てられます。",
                    suggestion: "小数がほしいときは、どちらかを小数にしてください。",
                    ruleID: "integer-division"))
            }
        }

        hints += bracketHints(in: source, languageID: languageID)
        return hints.sorted { $0.line < $1.line }
    }

    /// 括弧の数が合っているか。
    static func bracketHints(in source: String, languageID: String?) -> [SourceHint] {
        let text = SyntaxHighlighter.strippingCommentsAndStrings(source,
                                                                 languageID: languageID)
        var counts: [Character: Int] = [:]
        for character in text {
            switch character {
            case "(", ")", "{", "}", "[", "]": counts[character, default: 0] += 1
            default: break
            }
        }
        var hints: [SourceHint] = []
        let pairs: [(Character, Character, String)] = [("(", ")", "丸括弧"),
                                                       ("{", "}", "波括弧"),
                                                       ("[", "]", "角括弧")]
        for (open, close, name) in pairs {
            let opened = counts[open] ?? 0
            let closed = counts[close] ?? 0
            guard opened != closed else { continue }
            hints.append(SourceHint(
                level: .mistake, line: 0,
                message: "\(name)の数が合っていません (開き \(opened) 個、閉じ \(closed) 個)。",
                suggestion: opened > closed ? "閉じ括弧を足してください。"
                                            : "余分な閉じ括弧を消してください。",
                ruleID: "unbalanced-brackets"))
        }
        return hints
    }

    /// 文字列とコメントを空白に置き換えた行。
    static func strippedLines(of source: String, languageID: String?) -> [String] {
        SyntaxHighlighter.strippingCommentsAndStrings(source, languageID: languageID)
            .components(separatedBy: "\n")
    }
}
