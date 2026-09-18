import Foundation

// MARK: - 243. 初回起動時のガイド

/// はじめて開いたときに見せる 1 枚。
public struct OnboardingPage: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    /// 押せるボタンの文言 (なければ「次へ」)。
    public var actionTitle: String?
    /// 飛ばしてよい回か。
    public var isSkippable: Bool

    public init(id: String, title: String, body: String, actionTitle: String? = nil,
                isSkippable: Bool = true) {
        self.id = id
        self.title = title
        self.body = body
        self.actionTitle = actionTitle
        self.isSkippable = isSkippable
    }
}

/// 初回ガイドの進み具合。
public struct OnboardingFlow: Equatable, Sendable {
    public var pages: [OnboardingPage]
    /// いま何枚目か (0 始まり)。
    public private(set) var index: Int
    /// 最後まで見た、または飛ばしたか。
    public private(set) var isFinished: Bool

    public init(pages: [OnboardingPage] = OnboardingFlow.defaultPages,
                index: Int = 0, isFinished: Bool = false) {
        self.pages = pages
        self.index = Swift.max(0, Swift.min(index, Swift.max(0, pages.count - 1)))
        self.isFinished = isFinished || pages.isEmpty
    }

    public var current: OnboardingPage? {
        guard !isFinished, pages.indices.contains(index) else { return nil }
        return pages[index]
    }

    public var isLast: Bool { index >= pages.count - 1 }

    /// 0.0 〜 1.0。
    public var progress: Double {
        guard !pages.isEmpty else { return 1 }
        if isFinished { return 1 }
        return Double(index) / Double(pages.count)
    }

    public mutating func advance() {
        guard !isFinished else { return }
        if isLast {
            isFinished = true
        } else {
            index += 1
        }
    }

    public mutating func back() {
        guard index > 0 else { return }
        isFinished = false
        index -= 1
    }

    public mutating func skip() {
        isFinished = true
    }

    /// 2 回目からは出さない。
    public static func shouldShow(hasSeen: Bool) -> Bool { !hasSeen }

    public static let defaultPages: [OnboardingPage] = [
        OnboardingPage(id: "welcome", title: "ようこそ",
                       body: "GitHub のコードを開いて、読んで、その場で動かせます。",
                       actionTitle: "はじめる", isSkippable: false),
        OnboardingPage(id: "open", title: "まず開いてみる",
                       body: "GitHub の URL を貼るか、リポジトリを検索して開きます。"),
        OnboardingPage(id: "run", title: "その場で動かす",
                       body: "26 の言語はアプリの中だけで動くので、通信が要りません。"),
        OnboardingPage(id: "edit", title: "書き換えて試す",
                       body: "編集した内容は下書きとして残ります。元に戻すこともできます。"),
        OnboardingPage(id: "account", title: "アカウント (任意)",
                       body: "GitHub にサインインすると、私用リポジトリや保存ができます。",
                       actionTitle: "あとで")
    ]
}

// MARK: - 244. Tips of the day

/// ひとことの豆知識。
public struct Tip: Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    /// どの画面の話か。
    public var category: String

    public init(id: String, text: String, category: String = "全般") {
        self.id = id
        self.text = text
        self.category = category
    }
}

public enum TipLibrary {

    /// その日の 1 つ。同じ日なら同じものが出る。
    public static func tip(on date: Date = Date(),
                           calendar: Calendar = Calendar(identifier: .gregorian))
        -> Tip {
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        return all[abs(day) % all.count]
    }

    /// まだ見ていないものを優先して出す。
    public static func nextUnseen(seen: Set<String>, on date: Date = Date()) -> Tip {
        let unseen = all.filter { !seen.contains($0.id) }
        guard !unseen.isEmpty else { return tip(on: date) }
        let day = Calendar(identifier: .gregorian)
            .ordinality(of: .day, in: .era, for: date) ?? 0
        return unseen[abs(day) % unseen.count]
    }

    public static func tips(category: String) -> [Tip] {
        all.filter { $0.category == category }
    }

    public static var categories: [String] {
        var seen: Set<String> = []
        return all.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    public static let all: [Tip] = [
        Tip(id: "tip-command-palette", text: "⌘P でファイルを名前から開けます。",
            category: "操作"),
        Tip(id: "tip-run", text: "⌘R でいま開いているコードを動かせます。",
            category: "実行"),
        Tip(id: "tip-offline", text: "内蔵処理系の言語は、通信がなくても動きます。",
            category: "実行"),
        Tip(id: "tip-snapshot", text: "編集の途中経過は自動で残るので、戻せます。",
            category: "編集"),
        Tip(id: "tip-snippet", text: "短い合言葉を打つと、決まった形に広がります。",
            category: "編集"),
        Tip(id: "tip-split", text: "2 つのファイルを並べて見比べられます。",
            category: "画面"),
        Tip(id: "tip-share", text: "動かした結果ごと Gist にして共有できます。",
            category: "共有"),
        Tip(id: "tip-export", text: "HTML で書き出すと、そのまま PDF にできます。",
            category: "共有"),
        Tip(id: "tip-search", text: "検索は、あいまいな打ち方でも当たります。",
            category: "操作"),
        Tip(id: "tip-debug", text: "行に印を付けると、そこで止めて中身を見られます。",
            category: "実行"),
        Tip(id: "tip-storage", text: "置いてあるものの量は、設定から見て消せます。",
            category: "設定"),
        Tip(id: "tip-theme", text: "配色は、明るいところと暗いところで切り替わります。",
            category: "設定")
    ]
}

// MARK: - 245. 使い方の案内

/// 使い方の 1 項目。
public struct HelpTopic: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var category: String
    /// 関わりのある操作 (ショートカットの ID など)。
    public var related: [String]

    public init(id: String, title: String, body: String, category: String,
                related: [String] = []) {
        self.id = id
        self.title = title
        self.body = body
        self.category = category
        self.related = related
    }

    var searchText: String { [title, body, category].joined(separator: " ") }
}

public enum HelpCenter {

    public static func topics(category: String) -> [HelpTopic] {
        all.filter { $0.category == category }
    }

    public static var categories: [String] {
        var seen: Set<String> = []
        return all.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    public static func topic(id: String) -> HelpTopic? {
        all.first { $0.id == id }
    }

    public static func search(_ query: String, limit: Int = 20) -> [HelpTopic] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(all.prefix(limit)) }
        return FuzzySearch.search(trimmed, in: all, limit: limit) { $0.searchText }
            .map(\.element)
    }

    public static let all: [HelpTopic] = [
        HelpTopic(id: "help-open", title: "リポジトリを開く",
                  body: "URL を貼るか、検索から選びます。ブランチやタグも選べます。",
                  category: "はじめかた"),
        HelpTopic(id: "help-browse", title: "ファイルを探す",
                  body: "左の一覧から辿るか、⌘P で名前から開きます。",
                  category: "はじめかた", related: ["openQuickly"]),
        HelpTopic(id: "help-run", title: "コードを動かす",
                  body: "⌘R で動かします。標準入力が要るときは、入力欄に書いてから動かします。",
                  category: "実行", related: ["run"]),
        HelpTopic(id: "help-languages", title: "動かせる言語",
                  body: "内蔵処理系の言語は通信なしで動きます。ほかはサーバー実行になります。",
                  category: "実行"),
        HelpTopic(id: "help-debug", title: "止めて中を見る",
                  body: "行に印を付けて動かすと、そこで止まります。変数の中身も見られます。",
                  category: "実行"),
        HelpTopic(id: "help-edit", title: "書き換える",
                  body: "編集は下書きとして自動で残ります。元に戻すこともできます。",
                  category: "編集"),
        HelpTopic(id: "help-commit", title: "GitHub に書き戻す",
                  body: "サインインすると、編集をコミットしたり PR にしたりできます。",
                  category: "編集"),
        HelpTopic(id: "help-share", title: "共有する",
                  body: "Gist にする、書き出す、リンクにする、の 3 通りがあります。",
                  category: "共有"),
        HelpTopic(id: "help-offline", title: "通信がないとき",
                  body: "一度見たものは残っているので読めます。内蔵処理系なら実行もできます。",
                  category: "設定"),
        HelpTopic(id: "help-storage", title: "置いてあるものを消す",
                  body: "設定の「保存」から、種類ごとに消せます。",
                  category: "設定"),
        HelpTopic(id: "help-shortcuts", title: "ショートカット",
                  body: "⌘ を長押しすると、使えるショートカットが出ます。",
                  category: "操作")
    ]
}

// MARK: - 250. 設定のプリセット

/// まとめて当てられる設定の組。
public struct SettingsPreset: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var settings: EditorSettings

    public init(id: String, name: String, summary: String,
                settings: EditorSettings) {
        self.id = id
        self.name = name
        self.summary = summary
        self.settings = settings
    }

    /// いまの設定に当てる。
    public func apply(to current: inout EditorSettings) {
        current = settings
    }

    /// いまの設定が、このプリセットのままか。
    public func matches(_ current: EditorSettings) -> Bool {
        current == settings
    }
}

public enum SettingsPresetCatalog {

    public static func preset(id: String) -> SettingsPreset? {
        all.first { $0.id == id }
    }

    /// いまの設定に当てはまるプリセット (なければ nil = 自分好み)。
    public static func current(for settings: EditorSettings) -> SettingsPreset? {
        all.first { $0.matches(settings) }
    }

    /// 自分好みの設定から、プリセットを作る。
    public static func make(name: String, from settings: EditorSettings)
        -> SettingsPreset {
        SettingsPreset(id: "user-\(UUID().uuidString.prefix(8))", name: name,
                       summary: "自分で作った組み合わせ", settings: settings)
    }

    public static let all: [SettingsPreset] = [
        SettingsPreset(id: "preset-default", name: "ふつう",
                       summary: "最初の設定。",
                       settings: EditorSettings()),
        SettingsPreset(id: "preset-beginner", name: "はじめての人向け",
                       summary: "文字を大きく、行番号と現在行をはっきり。",
                       settings: EditorSettings(wrapMode: .word,
                                                fontSize: FontSize(points: 18),
                                                showsLineNumbers: true,
                                                showsInvisibles: false,
                                                highlightsCurrentLine: true,
                                                showsMinimap: false,
                                                indent: IndentStyle(usesSpaces: true,
                                                                    width: 4),
                                                completesBrackets: true,
                                                autoSaves: true)),
        SettingsPreset(id: "preset-reading", name: "読むとき",
                       summary: "折り返して、余計なものを消す。",
                       settings: EditorSettings(wrapMode: .word,
                                                fontSize: FontSize(points: 16),
                                                showsLineNumbers: true,
                                                showsInvisibles: false,
                                                highlightsCurrentLine: false,
                                                showsMinimap: false,
                                                completesBrackets: false,
                                                autoSaves: false)),
        SettingsPreset(id: "preset-writing", name: "書くとき",
                       summary: "折り返さず、印と補完を全部出す。",
                       settings: EditorSettings(wrapMode: .none,
                                                fontSize: FontSize(points: 14),
                                                showsLineNumbers: true,
                                                showsInvisibles: true,
                                                highlightsCurrentLine: true,
                                                showsMinimap: true,
                                                rulerColumn: 100,
                                                completesBrackets: true,
                                                autoSaves: true)),
        SettingsPreset(id: "preset-presentation", name: "見せるとき",
                       summary: "とても大きな文字で、余計なものを消す。",
                       settings: EditorSettings(wrapMode: .word,
                                                fontSize: FontSize(points: 26),
                                                showsLineNumbers: false,
                                                showsInvisibles: false,
                                                highlightsCurrentLine: false,
                                                showsMinimap: false,
                                                completesBrackets: false,
                                                autoSaves: false))
    ]
}
