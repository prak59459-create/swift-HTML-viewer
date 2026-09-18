import Foundation

// MARK: - 236. 対応言語一覧と対応範囲

/// その言語をどこまで扱えるか。
public struct LanguageSupport: Identifiable, Equatable, Sendable {
    /// どこで動かすか。
    public enum Place: String, Equatable, Sendable {
        /// アプリに入っている処理系。持ち出さないので、いつでも動く。
        case builtIn
        /// 端末の中の WebAssembly や JavaScript。読み込みに通信がいる。
        case onDevice
        /// よそのサーバーに送って動かす。
        case server
        /// 動かせない (読むだけ)。
        case none

        public var displayName: String {
            switch self {
            case .builtIn: return "アプリ内蔵"
            case .onDevice: return "端末内 (WebAssembly など)"
            case .server: return "サーバー実行"
            case .none: return "実行できない"
            }
        }

        /// 通信がいるか。
        public var needsNetwork: Bool { self != .builtIn }
    }

    public var id: String { languageID }
    public var languageID: String
    public var name: String
    public var place: Place
    /// 動かすもの ("内蔵 Go 処理系" など)。
    public var engineName: String
    public var fileExtensions: [String]
    /// 書けること。
    public var covered: [String]
    /// まだ書けないこと。
    public var notCovered: [String]

    public init(languageID: String, name: String, place: Place, engineName: String,
                fileExtensions: [String] = [], covered: [String] = [],
                notCovered: [String] = []) {
        self.languageID = languageID
        self.name = name
        self.place = place
        self.engineName = engineName
        self.fileExtensions = fileExtensions
        self.covered = covered
        self.notCovered = notCovered
    }

    public var isRunnable: Bool { place != .none }
    /// 通信なしで動くか。
    public var worksOffline: Bool { place == .builtIn }

    /// 一覧に出す短い説明。
    public var summary: String {
        "\(name) — \(place.displayName)"
    }

    var searchText: String {
        ([name, languageID, engineName] + fileExtensions).joined(separator: " ")
    }
}

/// どの言語をどこまで扱えるかの案内。
public enum LanguageGuide {

    /// 対応言語の一覧 (カタログの並びそのまま)。
    public static let all: [LanguageSupport] = LanguageCatalog.all.map(support(for:))

    public static func support(for language: ProgrammingLanguage) -> LanguageSupport {
        let place: LanguageSupport.Place
        let engineName: String
        if let builtin = language.builtin {
            place = .builtIn
            engineName = builtin.displayName
        } else if let local = language.local {
            place = .onDevice
            engineName = local.displayName
        } else if let remote = language.remote {
            place = .server
            engineName = "\(remote.pistonLanguage) (サーバー)"
        } else {
            place = .none
            engineName = "なし"
        }
        let coverage = self.coverage(for: language.id, place: place)
        return LanguageSupport(languageID: language.id, name: language.name,
                               place: place, engineName: engineName,
                               fileExtensions: language.fileExtensions,
                               covered: coverage.covered,
                               notCovered: coverage.notCovered)
    }

    public static func support(languageID: String) -> LanguageSupport? {
        all.first { $0.languageID == languageID }
    }

    /// 通信なしで動く言語だけ。
    public static var offlineReady: [LanguageSupport] {
        all.filter(\.worksOffline)
    }

    public static func search(_ query: String, limit: Int = 30) -> [LanguageSupport] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(all.prefix(limit)) }
        return FuzzySearch.search(trimmed, in: all, limit: limit) { $0.searchText }
            .map(\.element)
    }

    /// 内蔵処理系に共通して言えること。
    static let builtInCovered = [
        "変数・演算・条件分岐・繰り返し",
        "関数 (再帰も)",
        "配列・辞書・文字列の基本的な操作",
        "標準出力への表示と、標準入力の読み取り"
    ]

    static let builtInNotCovered = [
        "スレッドや非同期の細かい動き",
        "外部ライブラリの取り込み",
        "ファイルやネットワークへの本物のアクセス"
    ]

    /// 言語ごとの違いを足す。
    static func coverage(for languageID: String, place: LanguageSupport.Place)
        -> (covered: [String], notCovered: [String]) {
        guard place == .builtIn else {
            switch place {
            case .onDevice:
                return (["本物の処理系がそのまま動く"],
                        ["最初の読み込みに通信がいる"])
            case .server:
                return (["本物の処理系でコンパイル・実行できる"],
                        ["コードをサーバーに送る", "通信できないときは使えない"])
            default:
                return ([], ["この言語は実行できない (色分けと閲覧はできる)"])
            }
        }
        var covered = builtInCovered
        var notCovered = builtInNotCovered
        switch languageID {
        case "go":
            covered += ["構造体とメソッド", "複数の戻り値", "error を返す書き方"]
            notCovered += ["goroutine と channel", "defer の細かい順番"]
        case "rust":
            covered += ["struct・enum・match", "Option と Result"]
            notCovered += ["所有権と借用の検査", "trait の高度な使い方"]
        case "java", "csharp", "kotlin", "scala":
            covered += ["クラスと継承", "インターフェース", "例外"]
            notCovered += ["ジェネリクスの型検査", "リフレクション"]
        case "cpp":
            covered += ["クラス", "参照渡し", "vector や map の基本"]
            notCovered += ["テンプレートの特殊化", "ポインタ演算の細かい規則"]
        case "haskell", "ocaml", "elixir", "erlang", "lisp":
            covered += ["パターンマッチ", "高階関数", "再帰による組み立て"]
            notCovered += ["遅延評価の細かい振る舞い", "型クラスの解決"]
        case "shell":
            covered += ["パイプとリダイレクト", "変数展開", "if・for・while"]
            notCovered += ["本物のコマンドの呼び出し", "ジョブ制御"]
        default:
            break
        }
        return (covered, notCovered)
    }
}

// MARK: - 237. 言語ごとのチュートリアル

/// チュートリアルの 1 歩。
public struct TutorialStep: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// なにをする回か。
    public var explanation: String
    public var code: String
    /// 動かすと出るはずのもの。
    public var expectedOutput: String?
    /// やってみること。
    public var challenge: String?

    public init(id: String, title: String, explanation: String, code: String,
                expectedOutput: String? = nil, challenge: String? = nil) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.code = code
        self.expectedOutput = expectedOutput
        self.challenge = challenge
    }
}

/// ひとつづきの学習。
public struct Tutorial: Identifiable, Equatable, Sendable {
    public var id: String
    public var languageID: String
    public var title: String
    public var summary: String
    public var steps: [TutorialStep]

    public init(id: String, languageID: String, title: String, summary: String,
                steps: [TutorialStep]) {
        self.id = id
        self.languageID = languageID
        self.title = title
        self.summary = summary
        self.steps = steps
    }

    public var stepCount: Int { steps.count }

    public func step(id: String) -> TutorialStep? {
        steps.first { $0.id == id }
    }

    /// 何歩目まで進んだか (0.0 〜 1.0)。
    public func progress(completed: Set<String>) -> Double {
        guard !steps.isEmpty else { return 0 }
        let done = steps.filter { completed.contains($0.id) }.count
        return Double(done) / Double(steps.count)
    }
}

public enum TutorialLibrary {

    public static func tutorials(languageID: String) -> [Tutorial] {
        all.filter { $0.languageID == languageID }
    }

    public static func tutorial(id: String) -> Tutorial? {
        all.first { $0.id == id }
    }

    /// チュートリアルのある言語。
    public static var languageIDs: [String] {
        var seen: Set<String> = []
        return all.compactMap { seen.insert($0.languageID).inserted ? $0.languageID : nil }
    }

    public static let all: [Tutorial] = [
        Tutorial(id: "go-basics", languageID: "go", title: "Go をはじめる",
                 summary: "表示・変数・繰り返し・関数まで。",
                 steps: [
                    TutorialStep(id: "go-1", title: "表示する",
                                 explanation: "fmt.Println で 1 行出せます。",
                                 code: """
                                 package main

                                 import "fmt"

                                 func main() {
                                     fmt.Println("こんにちは")
                                 }
                                 """,
                                 expectedOutput: "こんにちは",
                                 challenge: "自分の名前を出してみましょう。"),
                    TutorialStep(id: "go-2", title: "変数をつくる",
                                 explanation: ":= で、型を書かずに変数をつくれます。",
                                 code: """
                                 package main

                                 import "fmt"

                                 func main() {
                                     count := 3
                                     name := "りんご"
                                     fmt.Println(name, count)
                                 }
                                 """,
                                 expectedOutput: "りんご 3"),
                    TutorialStep(id: "go-3", title: "繰り返す",
                                 explanation: "Go の繰り返しは for だけです。",
                                 code: """
                                 package main

                                 import "fmt"

                                 func main() {
                                     for i := 1; i <= 3; i++ {
                                         fmt.Println(i)
                                     }
                                 }
                                 """,
                                 expectedOutput: "1\n2\n3"),
                    TutorialStep(id: "go-4", title: "関数にまとめる",
                                 explanation: "同じ手順は関数にすると読みやすくなります。",
                                 code: """
                                 package main

                                 import "fmt"

                                 func double(value int) int {
                                     return value * 2
                                 }

                                 func main() {
                                     fmt.Println(double(21))
                                 }
                                 """,
                                 expectedOutput: "42",
                                 challenge: "3 倍にする関数も足してみましょう。")
                 ]),

        Tutorial(id: "kotlin-basics", languageID: "kotlin", title: "Kotlin をはじめる",
                 summary: "val と var、リスト、関数。",
                 steps: [
                    TutorialStep(id: "kotlin-1", title: "表示する",
                                 explanation: "println で出します。",
                                 code: """
                                 fun main() {
                                     println("こんにちは")
                                 }
                                 """,
                                 expectedOutput: "こんにちは"),
                    TutorialStep(id: "kotlin-2", title: "val と var",
                                 explanation: "val は変えないもの、var は変えられるもの。",
                                 code: """
                                 fun main() {
                                     val name = "りんご"
                                     var count = 1
                                     count = count + 2
                                     println("$name $count")
                                 }
                                 """,
                                 expectedOutput: "りんご 3"),
                    TutorialStep(id: "kotlin-3", title: "リストを回す",
                                 explanation: "listOf で作って、for で回します。",
                                 code: """
                                 fun main() {
                                     val values = listOf(1, 2, 3)
                                     var total = 0
                                     for (value in values) {
                                         total += value
                                     }
                                     println(total)
                                 }
                                 """,
                                 expectedOutput: "6",
                                 challenge: "sum() を使っても同じ答えになります。")
                 ]),

        Tutorial(id: "rust-basics", languageID: "rust", title: "Rust をはじめる",
                 summary: "let、可変、match。",
                 steps: [
                    TutorialStep(id: "rust-1", title: "表示する",
                                 explanation: "println! は最後に ! が付きます。",
                                 code: """
                                 fn main() {
                                     println!("こんにちは");
                                 }
                                 """,
                                 expectedOutput: "こんにちは"),
                    TutorialStep(id: "rust-2", title: "変えられる変数",
                                 explanation: "変えたい変数には mut を付けます。",
                                 code: """
                                 fn main() {
                                     let mut count = 1;
                                     count += 2;
                                     println!("{}", count);
                                 }
                                 """,
                                 expectedOutput: "3"),
                    TutorialStep(id: "rust-3", title: "match で分ける",
                                 explanation: "値ごとに処理を分けられます。",
                                 code: """
                                 fn main() {
                                     let value = 2;
                                     match value {
                                         1 => println!("いち"),
                                         2 => println!("に"),
                                         _ => println!("そのほか"),
                                     }
                                 }
                                 """,
                                 expectedOutput: "に")
                 ]),

        Tutorial(id: "javascript-basics", languageID: "javascript",
                 title: "JavaScript をはじめる",
                 summary: "console.log、配列、関数。",
                 steps: [
                    TutorialStep(id: "js-1", title: "表示する",
                                 explanation: "console.log で出します。",
                                 code: "console.log(\"こんにちは\");",
                                 expectedOutput: "こんにちは"),
                    TutorialStep(id: "js-2", title: "配列を回す",
                                 explanation: "for...of で 1 つずつ取り出せます。",
                                 code: """
                                 const values = [1, 2, 3];
                                 let total = 0;
                                 for (const value of values) {
                                     total += value;
                                 }
                                 console.log(total);
                                 """,
                                 expectedOutput: "6"),
                    TutorialStep(id: "js-3", title: "関数にする",
                                 explanation: "同じ手順は関数にまとめます。",
                                 code: """
                                 function double(value) {
                                     return value * 2;
                                 }
                                 console.log(double(21));
                                 """,
                                 expectedOutput: "42")
                 ]),

        Tutorial(id: "java-basics", languageID: "java", title: "Java をはじめる",
                 summary: "クラス、main、繰り返し。",
                 steps: [
                    TutorialStep(id: "java-1", title: "表示する",
                                 explanation: "main から始まります。",
                                 code: """
                                 public class Main {
                                     public static void main(String[] args) {
                                         System.out.println("こんにちは");
                                     }
                                 }
                                 """,
                                 expectedOutput: "こんにちは"),
                    TutorialStep(id: "java-2", title: "繰り返す",
                                 explanation: "for で 3 回まわします。",
                                 code: """
                                 public class Main {
                                     public static void main(String[] args) {
                                         for (int i = 1; i <= 3; i++) {
                                             System.out.println(i);
                                         }
                                     }
                                 }
                                 """,
                                 expectedOutput: "1\n2\n3")
                 ])
    ]
}

// MARK: - 238. 未対応の構文を教える

/// 「ここは内蔵処理系では動かない」という知らせ。
public enum UnsupportedSyntax {

    struct Rule {
        var languageIDs: [String]
        var pattern: String
        var message: String
        var advice: String
    }

    static let rules: [Rule] = [
        Rule(languageIDs: ["go"], pattern: #"(^|[^\w])go\s+func\s*\("#,
             message: "goroutine は内蔵処理系では動きません",
             advice: "同じ処理を順番に呼ぶ形に書き換えると動きます。"),
        Rule(languageIDs: ["go"], pattern: #"make\s*\(\s*chan\b"#,
             message: "channel は内蔵処理系では作れません",
             advice: "配列やスライスに値をためる形にしてみてください。"),
        Rule(languageIDs: ["go"], pattern: #"\bselect\s*\{"#,
             message: "select は内蔵処理系では動きません",
             advice: "channel を使わない書き方に直してください。"),
        Rule(languageIDs: ["java", "kotlin", "scala", "csharp"],
             pattern: #"\bimport\s+(java\.net|java\.nio|okhttp3|retrofit)"#,
             message: "ネットワークのライブラリは使えません",
             advice: "通信の代わりに、決め打ちの値を使って動かしてみてください。"),
        Rule(languageIDs: ["java", "kotlin", "scala"],
             pattern: #"\b(Thread|ExecutorService|CompletableFuture)\b"#,
             message: "スレッドや非同期の細かい動きは再現できません",
             advice: "順番に実行する形なら、そのまま動きます。"),
        Rule(languageIDs: ["rust"], pattern: #"\buse\s+std::thread\b"#,
             message: "スレッドは内蔵処理系では動きません",
             advice: "1 本の流れに書き直すと動きます。"),
        Rule(languageIDs: ["rust"], pattern: #"\bunsafe\s*\{"#,
             message: "unsafe ブロックは扱えません",
             advice: "安全な書き方に直してください。"),
        Rule(languageIDs: ["cpp"], pattern: #"#include\s*<thread>"#,
             message: "<thread> は内蔵処理系にありません",
             advice: "順番に実行する形に直してください。"),
        Rule(languageIDs: ["cpp"], pattern: #"\btemplate\s*<"#,
             message: "テンプレートは簡単なものしか扱えません",
             advice: "使う型を決め打ちにすると動くことがあります。"),
        Rule(languageIDs: ["javascript", "typescript"],
             pattern: #"\b(fetch|XMLHttpRequest)\s*\("#,
             message: "通信は内蔵処理系ではできません",
             advice: "受け取るはずの値を、そのまま書いて試してください。"),
        Rule(languageIDs: [], pattern: #"\b(socket|Socket)\s*\("#,
             message: "ソケット通信はできません",
             advice: "入力を標準入力から読む形に変えてみてください。")
    ]

    /// 使えない書き方を探す。
    public static func hints(in source: String, languageID: String) -> [SourceHint] {
        var hints: [SourceHint] = []
        let lines = source.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            // 文字列やコメントの中は見ない (簡単な判定)。
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") { continue }
            for rule in rules {
                guard rule.languageIDs.isEmpty
                        || rule.languageIDs.contains(languageID) else { continue }
                guard line.range(of: rule.pattern, options: .regularExpression) != nil
                else { continue }
                hints.append(SourceHint(level: .caution, line: index + 1,
                                        message: rule.message,
                                        suggestion: rule.advice,
                                        ruleID: "unsupported"))
            }
        }
        return hints
    }

    /// 動かす前に見せる、ひとことのまとめ。
    public static func summary(in source: String, languageID: String) -> String? {
        let found = hints(in: source, languageID: languageID)
        guard !found.isEmpty else { return nil }
        if found.count == 1 { return found[0].message }
        return "\(found[0].message) (ほかに \(found.count - 1) 件)"
    }
}

// MARK: - 242. 実行できない理由の説明

/// なぜ動かせないのか。
public struct RunAvailability: Equatable, Sendable {
    public var canRun: Bool
    /// どう動かすか、または動かせない理由。
    public var reason: String
    /// どうすれば動くか。
    public var remedy: String?

    public init(canRun: Bool, reason: String, remedy: String? = nil) {
        self.canRun = canRun
        self.reason = reason
        self.remedy = remedy
    }

    public var text: String {
        guard let remedy else { return reason }
        return "\(reason)\n\(remedy)"
    }

    /// ファイル名と設定から調べる。
    public static func check(fileName: String, kind: ContentKind? = nil,
                             allowsRemoteExecution: Bool,
                             isOnline: Bool = true) -> RunAvailability {
        let language = LanguageCatalog.language(forFileName: fileName)
        let plan = LanguageCatalog.plan(kind: kind ?? .code(language: language?.id ?? ""),
                                        fileName: fileName,
                                        allowsRemoteExecution: allowsRemoteExecution)
        return check(plan: plan, fileName: fileName, isOnline: isOnline)
    }

    public static func check(plan: ExecutionPlan, fileName: String,
                             isOnline: Bool = true) -> RunAvailability {
        switch plan {
        case .browser:
            return RunAvailability(canRun: true, reason: "WebView で表示・実行します")

        case .builtin(let compiler, _):
            return RunAvailability(canRun: true,
                                   reason: "\(compiler.displayName) で動かします",
                                   remedy: "通信は要りません。")

        case .local(let engine, _):
            guard isOnline else {
                return RunAvailability(
                    canRun: false,
                    reason: "\(engine.displayName) の読み込みに通信が必要です",
                    remedy: "通信できるところで一度開くと、次からは速くなります。")
            }
            return RunAvailability(canRun: true,
                                   reason: "\(engine.displayName) で動かします")

        case .remote(_, let language):
            guard isOnline else {
                return RunAvailability(canRun: false,
                                       reason: "\(language.name) はサーバーで動かすので、通信が必要です",
                                       remedy: "通信できるところで試してください。")
            }
            return RunAvailability(canRun: true,
                                   reason: "\(language.name) をサーバーで動かします",
                                   remedy: "コードはサーバーに送られます。")

        case .unavailable(let reason):
            let name = (fileName as NSString).pathExtension
            if name.isEmpty {
                return RunAvailability(canRun: false, reason: reason,
                                       remedy: "拡張子を付けると、言語を見分けられます。")
            }
            if LanguageCatalog.language(forFileName: fileName) == nil {
                return RunAvailability(
                    canRun: false,
                    reason: ".\(name) は対応していない種類です",
                    remedy: "対応している言語は「対応言語一覧」で見られます。")
            }
            return RunAvailability(canRun: false, reason: reason,
                                   remedy: "設定でサーバー実行を許可すると動くことがあります。")
        }
    }
}
