import Foundation

// MARK: - 191 / 192 / 196. ドラッグ & ドロップとファイル

/// 受け取ったもの。
public enum DroppedItem: Equatable, Sendable {
    /// ファイル (名前と中身)。
    case file(name: String, data: Data)
    /// 文字。
    case text(String)
    /// URL。
    case url(URL)

    public var displayName: String {
        switch self {
        case .file(let name, _): return name
        case .text(let text): return String(text.prefix(30))
        case .url(let url): return url.lastPathComponent
        }
    }
}

/// 落とされたものをどう扱うか決めた結果。
public enum DropOutcome: Equatable, Sendable {
    /// 新しいタブで開く。
    case openFile(name: String, text: String, languageID: String?)
    /// いまのところに貼り付ける。
    case insertText(String)
    /// その URL を開く。
    case openTarget(GitHubTarget)
    /// 画像などを、そのまま見せる。
    case showBinary(name: String, data: Data)
    /// 扱えない。
    case unsupported(String)
}

/// ドラッグ & ドロップの取り決め。
public enum DropHandling {

    /// 受け取れる種類。
    public static let acceptedExtensions: Set<String> = {
        var result: Set<String> = ["txt", "md", "json", "yml", "yaml", "csv", "tsv",
                                    "html", "css", "xml", "toml", "ini", "log"]
        for language in LanguageCatalog.all {
            for suffix in language.fileExtensions {
                result.insert(suffix.lowercased())
            }
        }
        return result
    }()

    public static func canAccept(fileName: String) -> Bool {
        let suffix = (fileName.split(separator: ".").last.map(String.init) ?? "")
            .lowercased()
        if acceptedExtensions.contains(suffix) { return true }
        // 拡張子が無いものも、文字として読めれば受け取る。
        return !fileName.contains(".")
    }

    /// 落とされたものを、どう開くか決める。
    public static func handle(_ item: DroppedItem) -> DropOutcome {
        switch item {
        case .file(let name, let data):
            let kind = MediaClassifier.kind(fileName: name, data: data)
            if kind != .other, kind != .archive {
                return .showBinary(name: name, data: data)
            }
            guard let text = ContentClassifier.text(from: data) else {
                return .showBinary(name: name, data: data)
            }
            return .openFile(name: name, text: text,
                             languageID: LanguageCatalog.language(forFileName: name)?.id)

        case .text(let text):
            // URL に見えるならそちらを優先する。
            if let target = SharedInput.target(from: text) {
                return .openTarget(target)
            }
            return .insertText(text)

        case .url(let url):
            if let target = try? GitHubURLParser.parse(url.absoluteString) {
                return .openTarget(target)
            }
            return .unsupported(url.absoluteString)
        }
    }

    /// 192. 外に渡すときの中身。
    public static func exportPayload(text: String, fileName: String)
        -> (fileName: String, text: String) {
        (fileName, text)
    }
}

// MARK: - 193 / 194 / 195 / 208. 画面の広さとウィンドウ

/// 画面の使える広さの区分。
public enum SizeClass: String, Equatable, Sendable {
    case compact
    case regular

    public static func from(width: Double) -> SizeClass {
        width < 500 ? .compact : .regular
    }
}

/// いまの見え方。
public struct WindowContext: Equatable, Sendable {
    public var width: Double
    public var height: Double
    /// ほかのアプリと並んでいるか (Split View)。
    public var isSplitView: Bool
    /// 手前にかぶさっているか (Slide Over)。
    public var isSlideOver: Bool
    /// 外部ディスプレイにつないでいるか。
    public var hasExternalDisplay: Bool

    public init(width: Double, height: Double, isSplitView: Bool = false,
                isSlideOver: Bool = false, hasExternalDisplay: Bool = false) {
        self.width = width
        self.height = height
        self.isSplitView = isSplitView
        self.isSlideOver = isSlideOver
        self.hasExternalDisplay = hasExternalDisplay
    }

    public var sizeClass: SizeClass { SizeClass.from(width: width) }
    public var isLandscape: Bool { width > height }
    public var isNarrow: Bool { sizeClass == .compact || isSlideOver }

    /// 狭いときは、サイドバーを重ねて出す。
    public var sidebarOverlays: Bool { isNarrow }

    /// 193. その広さに合う並べ方。
    public var suggestedLayout: LayoutMode {
        if isNarrow { return .editorOnly }
        return LayoutMode.suggested(width: width, height: height)
    }

    /// 195 / 208. 外部ディスプレイに何を出すか。
    public var externalDisplayContent: ExternalDisplayContent {
        hasExternalDisplay ? .output : .none
    }
}

/// 外部ディスプレイに出すもの。
public enum ExternalDisplayContent: String, Equatable, Sendable {
    case none
    /// 実行の出力。
    case output
    /// HTML のプレビュー。
    case preview
    /// いまの画面をそのまま。
    case mirror

    public var displayName: String {
        switch self {
        case .none: return "出さない"
        case .output: return "実行の出力"
        case .preview: return "プレビュー"
        case .mirror: return "画面をそのまま"
        }
    }
}

// MARK: - 198. ショートカット App から実行

/// ほかのアプリから呼べる操作。
public struct AppIntent: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// 受け取るもの。
    public var parameters: [String]
    /// 返すもの。
    public var result: String

    public init(id: String, title: String, parameters: [String], result: String) {
        self.id = id
        self.title = title
        self.parameters = parameters
        self.result = result
    }
}

public enum AppIntents {
    public static let all: [AppIntent] = [
        AppIntent(id: "run-code", title: "コードを実行",
                  parameters: ["言語", "コード", "標準入力"], result: "出力"),
        AppIntent(id: "open-repository", title: "リポジトリを開く",
                  parameters: ["URL"], result: "なし"),
        AppIntent(id: "fetch-file", title: "ファイルの中身を取得",
                  parameters: ["URL"], result: "本文"),
        AppIntent(id: "format-code", title: "コードを整形",
                  parameters: ["言語", "コード"], result: "整形したコード"),
        AppIntent(id: "check-syntax", title: "構文を調べる",
                  parameters: ["言語", "コード"], result: "問題の一覧")
    ]

    public static func intent(id: String) -> AppIntent? {
        all.first { $0.id == id }
    }

    /// 「コードを実行」を実際に動かす。
    public static func runCode(languageID: String, source: String,
                               input: String = "") -> String {
        guard RunSession.hasEngine(for: languageID) else {
            return "\(languageID) は実行できません。"
        }
        var options = RunOptions()
        options.input = input
        options.timeLimit = 10
        guard let result = try? RunSession.run(languageID: languageID, source: source,
                                               options: options) else {
            return "実行できませんでした。"
        }
        if let failure = result.failureText, !failure.isEmpty { return failure }
        return ANSIParser.strip(result.output)
    }

    /// 「コードを整形」。
    public static func formatCode(languageID: String, source: String) -> String {
        CodeFormatter.format(source, languageID: languageID)
    }

    /// 「構文を調べる」。
    public static func checkSyntax(languageID: String, source: String) -> String {
        guard let check = try? RunSession.checkSyntax(languageID: languageID,
                                                      source: source) else {
            return "\(languageID) は調べられません。"
        }
        return check.isValid ? "問題は見つかりませんでした" : check.diagnosticsText
    }
}

// MARK: - 199 / 201. Handoff と Spotlight

/// ほかの端末に引き継ぐ / 検索に出すための情報。
public struct ActivityInfo: Equatable, Codable, Sendable {
    /// 何をしているか (`viewing` / `editing`)。
    public var kind: String
    public var title: String
    /// 引き継ぐ場所。
    public var location: GitHubLocation?
    /// 見ていた行。
    public var line: Int
    /// 検索に引っかける言葉。
    public var keywords: [String]

    public init(kind: String, title: String, location: GitHubLocation? = nil,
                line: Int = 1, keywords: [String] = []) {
        self.kind = kind
        self.title = title
        self.location = location
        self.line = line
        self.keywords = keywords
    }

    /// 開いているファイルから作る。
    public static func forFile(_ location: GitHubLocation, line: Int = 1,
                               languageID: String? = nil) -> ActivityInfo {
        var keywords = [location.owner, location.repo]
        keywords += location.path.split(separator: "/").map(String.init)
        if let languageID { keywords.append(languageID) }
        return ActivityInfo(kind: "viewing", title: location.displayName,
                            location: location, line: line,
                            keywords: keywords.filter { !$0.isEmpty })
    }

    /// 引き継ぎに載せる URL。
    public var handoffURL: URL? {
        guard let location else { return nil }
        return GitHubLinks.blobURL(location,
                                   lines: line > 1 ? LineRange(start: line) : nil)
    }

    /// 検索に出す説明。
    public var searchDescription: String {
        guard let location else { return title }
        let place = location.path.isEmpty ? "" : " — \(location.path)"
        return "\(location.owner)/\(location.repo)\(place)"
    }
}

// MARK: - 200. ウィジェット

/// ホーム画面に出す小さな表示。
public struct WidgetSnapshot: Equatable, Codable, Sendable {
    /// 最近開いたもの。
    public var recent: [String]
    /// レート制限の残り。
    public var rateLimitText: String?
    /// 直近の実行の結果。
    public var lastRunSummary: String?
    public var updatedAt: Date

    public init(recent: [String] = [], rateLimitText: String? = nil,
                lastRunSummary: String? = nil, updatedAt: Date = Date()) {
        self.recent = recent
        self.rateLimitText = rateLimitText
        self.lastRunSummary = lastRunSummary
        self.updatedAt = updatedAt
    }

    /// アプリの状態から作る。
    public static func make(history: NavigationHistory, runs: RunHistory,
                            rateLimit: RateLimitStatus?,
                            limit: Int = 4) -> WidgetSnapshot {
        WidgetSnapshot(recent: history.recent.prefix(limit).map(\.title),
                       rateLimitText: rateLimit?.description,
                       lastRunSummary: runs.all.first.map {
                           "\($0.languageID): \($0.summary)"
                       })
    }

    public var isEmpty: Bool {
        recent.isEmpty && rateLimitText == nil && lastRunSummary == nil
    }
}

// MARK: - 207. トラックパッドのホバー

/// 指を触れずに重ねたときに出すもの。
public struct HoverInfo: Equatable, Sendable {
    public var title: String
    public var detail: String?
    /// 型や値など、細かい説明。
    public var extra: [String]

    public init(title: String, detail: String? = nil, extra: [String] = []) {
        self.title = title
        self.detail = detail
        self.extra = extra
    }

    public var text: String {
        ([title, detail].compactMap { $0 } + extra).joined(separator: "\n")
    }
}

public enum Hovering {

    /// 行に重ねたときの説明。
    public static func forLine(_ line: Int, diagnostics: DiagnosticSet,
                               heat: Double? = nil) -> HoverInfo? {
        var extra: [String] = []
        if let heat, heat > 0 {
            extra.append("実行の多さ \(Int(heat * 100))%")
        }
        let items = diagnostics.diagnostics(atLine: line)
        guard !items.isEmpty || !extra.isEmpty else { return nil }
        guard let first = items.first else {
            return HoverInfo(title: "\(line) 行目", extra: extra)
        }
        return HoverInfo(title: first.message,
                         detail: first.suggestion,
                         extra: extra + items.dropFirst().map(\.message))
    }

    /// 変数に重ねたときの説明。
    public static func forVariable(_ variable: WatchedVariable) -> HoverInfo {
        HoverInfo(title: variable.name, detail: variable.displayValue,
                  extra: ["型: \(variable.typeName)"])
    }

    /// ファイルに重ねたときの説明。
    public static func forFile(_ item: FileListItem) -> HoverInfo {
        HoverInfo(title: item.name,
                  detail: item.isDirectory ? "フォルダ" : item.detailText,
                  extra: item.entry.location.map { ["パス: \($0.path)"] } ?? [])
    }
}

// MARK: - 213 / 214. 状態の保持と復元

/// アプリを閉じても覚えておくもの。
public struct SessionState: Equatable, Codable, Sendable {
    public var tabs: TabBar
    public var history: NavigationHistory
    public var bookmarks: BookmarkStore
    public var workspace: Workspace
    public var settings: EditorSettings
    public var display: DisplayState
    public var sidebar: SidebarState
    public var treeExpansion: TreeExpansion
    public var urlHistory: URLHistory
    public var splitEditor: SplitEditor
    public var savedAt: Date
    /// 形が変わったときのための版。
    public var version: Int

    public static let currentVersion = 1

    public init(tabs: TabBar = TabBar(), history: NavigationHistory = NavigationHistory(),
                bookmarks: BookmarkStore = BookmarkStore(),
                workspace: Workspace = Workspace(),
                settings: EditorSettings = .default,
                display: DisplayState = DisplayState(),
                sidebar: SidebarState = SidebarState(),
                treeExpansion: TreeExpansion = TreeExpansion(),
                urlHistory: URLHistory = URLHistory(),
                splitEditor: SplitEditor = SplitEditor(),
                savedAt: Date = Date(),
                version: Int = SessionState.currentVersion) {
        self.tabs = tabs
        self.history = history
        self.bookmarks = bookmarks
        self.workspace = workspace
        self.settings = settings
        self.display = display
        self.sidebar = sidebar
        self.treeExpansion = treeExpansion
        self.urlHistory = urlHistory
        self.splitEditor = splitEditor
        self.savedAt = savedAt
        self.version = version
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    /// 保存しておいたものから戻す。読めなければ初期状態。
    public static func decoded(_ data: Data?) -> SessionState {
        guard let data else { return SessionState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(SessionState.self, from: data),
              state.version <= SessionState.currentVersion else {
            return SessionState()
        }
        return state
    }

    /// 213. 画面が回っても保つもの (並べ方だけ画面に合わせ直す)。
    public func adaptedToRotation(_ context: WindowContext) -> SessionState {
        var copy = self
        // 左右分割のまま縦にすると窮屈なので、そのときだけ上下に切り替える。
        if copy.display.layout.isSplit {
            copy.display.layout = context.suggestedLayout.isSplit
                ? context.suggestedLayout : copy.display.layout
        }
        if context.isNarrow { copy.sidebar.isVisible = false }
        return copy
    }

    /// 古すぎる状態か (復元するか決める目安)。
    public func isStale(at date: Date = Date(),
                        maximumAge: TimeInterval = 60 * 60 * 24 * 14) -> Bool {
        date.timeIntervalSince(savedAt) > maximumAge
    }
}
