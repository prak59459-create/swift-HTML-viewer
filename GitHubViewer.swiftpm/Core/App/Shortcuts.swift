import Foundation

// MARK: - 186 / 187 / 188. キーボードショートカット

/// 押す組み合わせ。
public struct KeyChord: Equatable, Hashable, Codable, Sendable {
    /// 押す文字 (`"s"`) か、特別なキーの名前 (`"return"` など)。
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(_ key: String, command: Bool = false, shift: Bool = false,
                option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// 「⇧⌘S」。
    public var displayText: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        text += KeyChord.keyName(key)
        return text
    }

    static func keyName(_ key: String) -> String {
        switch key.lowercased() {
        case "return", "enter": return "↩"
        case "tab": return "⇥"
        case "space": return "␣"
        case "delete", "backspace": return "⌫"
        case "escape", "esc": return "⎋"
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        case "/": return "/"
        default: return key.count == 1 ? key.uppercased() : key
        }
    }

    /// 修飾キーを押していないか。
    public var hasNoModifiers: Bool {
        !command && !shift && !option && !control
    }
}

/// ショートカットで起こせること。
public enum ShortcutAction: String, CaseIterable, Identifiable, Codable, Equatable,
                            Sendable {
    case run
    case stop
    case save
    case discard
    case find
    case findNext
    case replace
    case goToLine
    case commentToggle
    case indent
    case outdent
    case format
    case newFile
    case closeTab
    case nextTab
    case previousTab
    case toggleSidebar
    case toggleFocus
    case toggleLayout
    case zoomIn
    case zoomOut
    case resetZoom
    case openQuickly
    case goBack
    case goForward
    case toggleBookmark
    case nextDiagnostic
    case previousDiagnostic
    case toggleBreakpoint
    case stepOver
    case stepInto
    case reload
    case copyPermalink
    case showShortcuts

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .run: return "実行"
        case .stop: return "実行を止める"
        case .save: return "保存"
        case .discard: return "編集を破棄"
        case .find: return "検索"
        case .findNext: return "次を検索"
        case .replace: return "置換"
        case .goToLine: return "指定行へ移動"
        case .commentToggle: return "コメントの切り替え"
        case .indent: return "字下げを深く"
        case .outdent: return "字下げを浅く"
        case .format: return "整形"
        case .newFile: return "新規ファイル"
        case .closeTab: return "タブを閉じる"
        case .nextTab: return "次のタブ"
        case .previousTab: return "前のタブ"
        case .toggleSidebar: return "サイドバーの開閉"
        case .toggleFocus: return "集中モード"
        case .toggleLayout: return "レイアウトの切り替え"
        case .zoomIn: return "拡大"
        case .zoomOut: return "縮小"
        case .resetZoom: return "等倍に戻す"
        case .openQuickly: return "ファイルをすばやく開く"
        case .goBack: return "戻る"
        case .goForward: return "進む"
        case .toggleBookmark: return "ブックマーク"
        case .nextDiagnostic: return "次の問題へ"
        case .previousDiagnostic: return "前の問題へ"
        case .toggleBreakpoint: return "ブレークポイント"
        case .stepOver: return "ステップ実行 (またぐ)"
        case .stepInto: return "ステップ実行 (中へ)"
        case .reload: return "読み込み直す"
        case .copyPermalink: return "リンクをコピー"
        case .showShortcuts: return "ショートカット一覧"
        }
    }

    /// 一覧で分けるときの見出し。
    public var category: String {
        switch self {
        case .run, .stop, .toggleBreakpoint, .stepOver, .stepInto: return "実行"
        case .save, .discard, .newFile, .reload: return "ファイル"
        case .find, .findNext, .replace, .goToLine, .openQuickly: return "検索と移動"
        case .commentToggle, .indent, .outdent, .format: return "編集"
        case .closeTab, .nextTab, .previousTab, .goBack, .goForward,
             .toggleBookmark: return "タブと履歴"
        case .nextDiagnostic, .previousDiagnostic: return "問題"
        default: return "表示"
        }
    }
}

/// どのキーで何が起きるか。
public struct ShortcutMap: Equatable, Codable, Sendable {
    private var bindings: [ShortcutAction: KeyChord]

    public init(bindings: [ShortcutAction: KeyChord] = ShortcutMap.defaultBindings) {
        self.bindings = bindings
    }

    /// 最初から決まっている組み合わせ。
    public static let defaultBindings: [ShortcutAction: KeyChord] = [
        .run: KeyChord("r", command: true),
        .stop: KeyChord(".", command: true),
        .save: KeyChord("s", command: true),
        .discard: KeyChord("z", command: true, shift: true, option: true),
        .find: KeyChord("f", command: true),
        .findNext: KeyChord("g", command: true),
        .replace: KeyChord("f", command: true, option: true),
        .goToLine: KeyChord("l", command: true),
        .commentToggle: KeyChord("/", command: true),
        .indent: KeyChord("]", command: true),
        .outdent: KeyChord("[", command: true),
        .format: KeyChord("i", command: true, control: true),
        .newFile: KeyChord("n", command: true),
        .closeTab: KeyChord("w", command: true),
        .nextTab: KeyChord("]", command: true, shift: true),
        .previousTab: KeyChord("[", command: true, shift: true),
        .toggleSidebar: KeyChord("0", command: true, control: true),
        .toggleFocus: KeyChord("return", command: true, control: true),
        .toggleLayout: KeyChord("y", command: true, option: true),
        .zoomIn: KeyChord("+", command: true),
        .zoomOut: KeyChord("-", command: true),
        .resetZoom: KeyChord("0", command: true),
        .openQuickly: KeyChord("p", command: true),
        .goBack: KeyChord("[", command: true, control: true),
        .goForward: KeyChord("]", command: true, control: true),
        .toggleBookmark: KeyChord("d", command: true, shift: true),
        .nextDiagnostic: KeyChord("'", command: true),
        .previousDiagnostic: KeyChord("'", command: true, shift: true),
        .toggleBreakpoint: KeyChord("b", command: true, shift: true),
        .stepOver: KeyChord("'", command: true, control: true),
        .stepInto: KeyChord(";", command: true, control: true),
        .reload: KeyChord("r", command: true, shift: true),
        .copyPermalink: KeyChord("c", command: true, shift: true, option: true),
        .showShortcuts: KeyChord("/", command: true, shift: true)
    ]

    public static let `default` = ShortcutMap()

    public func chord(for action: ShortcutAction) -> KeyChord? {
        bindings[action]
    }

    /// その組み合わせで起きること。
    public func action(for chord: KeyChord) -> ShortcutAction? {
        bindings.first { $0.value == chord }?.key
    }

    /// 187. 割り当てを変える。すでに使われていれば、そちらを外す。
    @discardableResult
    public mutating func assign(_ chord: KeyChord,
                                to action: ShortcutAction) -> ShortcutAction? {
        let conflicting = bindings.first { $0.value == chord && $0.key != action }?.key
        if let conflicting { bindings[conflicting] = nil }
        bindings[action] = chord
        return conflicting
    }

    public mutating func remove(_ action: ShortcutAction) {
        bindings[action] = nil
    }

    public mutating func resetToDefaults() {
        bindings = ShortcutMap.defaultBindings
    }

    public mutating func reset(_ action: ShortcutAction) {
        bindings[action] = ShortcutMap.defaultBindings[action]
    }

    /// 変えてあるものだけ。
    public var customized: [ShortcutAction] {
        ShortcutAction.allCases.filter {
            bindings[$0] != ShortcutMap.defaultBindings[$0]
        }
    }

    /// 186. 一覧に出すための並び (見出しごと)。
    public func listing() -> [(category: String,
                               items: [(action: ShortcutAction, chord: KeyChord)])] {
        var groups: [String: [(ShortcutAction, KeyChord)]] = [:]
        var order: [String] = []
        for action in ShortcutAction.allCases {
            guard let chord = bindings[action] else { continue }
            if groups[action.category] == nil { order.append(action.category) }
            groups[action.category, default: []].append((action, chord))
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// 188. すべての操作にキーが割り当たっているか。
    public var coversEveryAction: Bool {
        ShortcutAction.allCases.allSatisfy { bindings[$0] != nil }
    }
}

// MARK: - 202. 長押しメニュー

/// 長押しで出す項目。
public struct ContextMenuItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// 危ない操作 (赤く出す)。
    public var isDestructive: Bool
    /// 対応するショートカット。
    public var shortcut: KeyChord?

    public init(id: String, title: String, isDestructive: Bool = false,
                shortcut: KeyChord? = nil) {
        self.id = id
        self.title = title
        self.isDestructive = isDestructive
        self.shortcut = shortcut
    }
}

/// 押したものに合わせて、出す項目を決める。
public enum ContextMenus {

    /// ファイル一覧の項目。
    public static func fileItems(isDirectory: Bool, isBookmarked: Bool,
                                 shortcuts: ShortcutMap = .default) -> [ContextMenuItem] {
        var items = [ContextMenuItem(id: "open", title: "開く")]
        if !isDirectory {
            items.append(ContextMenuItem(id: "open-split", title: "並べて開く"))
        }
        items += [
            ContextMenuItem(id: "copy-path", title: "パスをコピー"),
            ContextMenuItem(id: "copy-link", title: "リンクをコピー",
                            shortcut: shortcuts.chord(for: .copyPermalink)),
            ContextMenuItem(id: "bookmark",
                            title: isBookmarked ? "ブックマークを外す" : "ブックマーク",
                            shortcut: shortcuts.chord(for: .toggleBookmark)),
            ContextMenuItem(id: "share", title: "共有")
        ]
        if !isDirectory {
            items.append(ContextMenuItem(id: "download", title: "端末に保存"))
        }
        return items
    }

    /// 編集中の文字を選んだときの項目。
    public static func selectionItems(hasSelection: Bool, languageID: String?,
                                      shortcuts: ShortcutMap = .default)
        -> [ContextMenuItem] {
        var items: [ContextMenuItem] = []
        if hasSelection {
            items += [
                ContextMenuItem(id: "cut", title: "カット"),
                ContextMenuItem(id: "copy", title: "コピー"),
                ContextMenuItem(id: "comment", title: "コメントの切り替え",
                                shortcut: shortcuts.chord(for: .commentToggle)),
                ContextMenuItem(id: "select-occurrences", title: "同じ語をすべて選ぶ"),
                ContextMenuItem(id: "copy-link", title: "この行へのリンクをコピー")
            ]
            if languageID != nil {
                items.append(ContextMenuItem(id: "run-selection", title: "選択部分を実行",
                                             shortcut: shortcuts.chord(for: .run)))
            }
        }
        items += [
            ContextMenuItem(id: "paste", title: "ペースト"),
            ContextMenuItem(id: "format", title: "整形",
                            shortcut: shortcuts.chord(for: .format))
        ]
        return items
    }

    /// タブの項目。
    public static func tabItems(isPinned: Bool, isDirty: Bool,
                                shortcuts: ShortcutMap = .default) -> [ContextMenuItem] {
        var items = [
            ContextMenuItem(id: "close", title: "閉じる",
                            shortcut: shortcuts.chord(for: .closeTab)),
            ContextMenuItem(id: "close-others", title: "ほかを閉じる"),
            ContextMenuItem(id: "pin", title: isPinned ? "ピンを外す" : "ピン留め"),
            ContextMenuItem(id: "split", title: "並べて開く")
        ]
        if isDirty {
            items.append(ContextMenuItem(id: "discard", title: "編集を破棄",
                                         isDestructive: true,
                                         shortcut: shortcuts.chord(for: .discard)))
        }
        return items
    }
}

// MARK: - 205 / 203. ジェスチャー

/// 指で行う操作。
public enum Gesture: String, CaseIterable, Identifiable, Equatable, Sendable {
    /// 3 本指で左へ = 元に戻す。
    case threeFingerSwipeLeft
    /// 3 本指で右へ = やり直す。
    case threeFingerSwipeRight
    /// 3 本指で下へ = キーボードを隠す。
    case threeFingerSwipeDown
    /// 3 本指でつまむ = コピー。
    case threeFingerPinchIn
    /// 3 本指で広げる = ペースト。
    case threeFingerPinchOut
    /// 端から右へ = サイドバーを出す。
    case edgeSwipeRight
    /// 端から左へ = サイドバーを隠す。
    case edgeSwipeLeft
    /// 2 本指でつまむ = 文字の大きさ。
    case pinch

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .threeFingerSwipeLeft: return "3 本指で左へ"
        case .threeFingerSwipeRight: return "3 本指で右へ"
        case .threeFingerSwipeDown: return "3 本指で下へ"
        case .threeFingerPinchIn: return "3 本指でつまむ"
        case .threeFingerPinchOut: return "3 本指で広げる"
        case .edgeSwipeRight: return "左端から右へ"
        case .edgeSwipeLeft: return "左端へ向けて"
        case .pinch: return "2 本指でつまむ / 広げる"
        }
    }

    /// 何が起きるか。
    public var effect: String {
        switch self {
        case .threeFingerSwipeLeft: return "元に戻す"
        case .threeFingerSwipeRight: return "やり直す"
        case .threeFingerSwipeDown: return "キーボードを隠す"
        case .threeFingerPinchIn: return "コピー"
        case .threeFingerPinchOut: return "ペースト"
        case .edgeSwipeRight: return "サイドバーを出す"
        case .edgeSwipeLeft: return "サイドバーを隠す"
        case .pinch: return "文字の大きさを変える"
        }
    }
}

// MARK: - 206. ハプティック

/// 手ごたえの強さ。
public enum HapticFeedback: String, Equatable, Sendable {
    case light
    case medium
    case heavy
    case success
    case warning
    case failure
    case selection

    /// できごとに合う手ごたえ。
    public static func forEvent(_ event: HapticEvent) -> HapticFeedback? {
        switch event {
        case .runSucceeded: return .success
        case .runFailed: return .failure
        case .saved: return .light
        case .breakpointToggled: return .selection
        case .tabSwitched: return .selection
        case .limitReached: return .warning
        case .dragStarted: return .medium
        case .none: return nil
        }
    }
}

/// 手ごたえを返すできごと。
public enum HapticEvent: String, Equatable, Sendable {
    case runSucceeded
    case runFailed
    case saved
    case breakpointToggled
    case tabSwitched
    case limitReached
    case dragStarted
    case none
}

// MARK: - 209 / 210 / 211. 読みやすさ

/// 文字の大きさの好み (ダイナミックタイプ)。
public enum ContentSizeCategory: String, CaseIterable, Identifiable, Codable, Equatable,
                                 Sendable {
    case extraSmall
    case small
    case medium
    case large
    case extraLarge
    case extraExtraLarge
    case extraExtraExtraLarge
    case accessibilityMedium
    case accessibilityLarge
    case accessibilityExtraLarge

    public var id: String { rawValue }

    /// 標準を 1 とした倍率。
    public var scale: Double {
        switch self {
        case .extraSmall: return 0.82
        case .small: return 0.88
        case .medium: return 0.94
        case .large: return 1.0
        case .extraLarge: return 1.12
        case .extraExtraLarge: return 1.24
        case .extraExtraExtraLarge: return 1.36
        case .accessibilityMedium: return 1.6
        case .accessibilityLarge: return 1.9
        case .accessibilityExtraLarge: return 2.3
        }
    }

    /// 文字がとても大きい設定か (並べ方を変える目安)。
    public var isAccessibilitySize: Bool { scale >= 1.6 }

    /// その設定でのエディタの文字の大きさ。
    public func fontSize(base: FontSize) -> FontSize {
        FontSize(points: base.points * scale)
    }
}

/// 読み上げのための説明。
public enum AccessibilityText {

    /// 行の説明。
    public static func line(number: Int, text: String,
                            diagnostic: InlineDiagnostic? = nil,
                            hasBreakpoint: Bool = false) -> String {
        var parts = ["\(number) 行目"]
        let body = text.trimmingCharacters(in: .whitespaces)
        parts.append(body.isEmpty ? "空の行" : body)
        if hasBreakpoint { parts.append("ブレークポイントあり") }
        if let diagnostic {
            parts.append("\(diagnostic.severity.displayName): \(diagnostic.message)")
        }
        return parts.joined(separator: "、")
    }

    /// 記号を読み上げやすい言葉にする (211. コードの読み上げ)。
    public static func spoken(_ code: String) -> String {
        var result = ""
        for character in code {
            if let word = symbolNames[character] {
                result += " \(word) "
            } else {
                result.append(character)
            }
        }
        // 空白が続いたら 1 つにまとめる。
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static let symbolNames: [Character: String] = [
        "{": "波括弧ひらく", "}": "波括弧とじる",
        "(": "丸括弧ひらく", ")": "丸括弧とじる",
        "[": "角括弧ひらく", "]": "角括弧とじる",
        "<": "小なり", ">": "大なり",
        "=": "イコール", "+": "プラス", "-": "マイナス",
        "*": "アスタリスク", "/": "スラッシュ", "%": "パーセント",
        "!": "びっくり", "?": "はてな", "&": "アンド", "|": "たて棒",
        "^": "ハット", "~": "チルダ", "@": "アットマーク", "#": "シャープ",
        "$": "ドル", "_": "アンダースコア", ";": "セミコロン", ":": "コロン",
        ",": "カンマ", ".": "ドット", "\"": "ダブルクォート", "'": "シングルクォート",
        "`": "バッククォート", "\\": "バックスラッシュ"
    ]

    /// ボタンなどの説明。
    public static func button(_ name: String, shortcut: KeyChord?) -> String {
        guard let shortcut else { return name }
        return "\(name)、ショートカット \(shortcut.displayText)"
    }
}

// MARK: - 212. 片手モード

/// 片手で持ったときの、操作の寄せ方。
public enum ReachabilitySide: String, CaseIterable, Identifiable, Codable, Equatable,
                              Sendable {
    case off
    case left
    case right

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "使わない"
        case .left: return "左手"
        case .right: return "右手"
        }
    }

    /// よく使うボタンを寄せる側。
    public var alignsTrailing: Bool { self == .right }
    public var isEnabled: Bool { self != .off }
}

// MARK: - 215. 低電力モード

/// 電池を節約するときに、どこを軽くするか。
public struct PowerSavingPolicy: Equatable, Codable, Sendable {
    public var isLowPower: Bool

    public init(isLowPower: Bool = false) {
        self.isLowPower = isLowPower
    }

    /// 打っている途中の自動実行を止めるか。
    public var disablesAutoRun: Bool { isLowPower }
    /// 色分けを軽くするか。
    public var simplifiesHighlighting: Bool { isLowPower }
    /// ミニマップを隠すか。
    public var hidesMinimap: Bool { isLowPower }
    /// 動きを減らすか。
    public var reducesAnimation: Bool { isLowPower }
    /// 先に読み込んでおくのをやめるか。
    public var disablesPrefetch: Bool { isLowPower }

    /// 実行の上限を控えめにする。
    public func adjusted(_ options: RunOptions) -> RunOptions {
        guard isLowPower else { return options }
        var updated = options
        updated.maximumSteps = Swift.min(options.maximumSteps, 1_000_000)
        updated.timeLimit = Swift.min(options.timeLimit ?? 5, 5)
        return updated
    }

    /// 設定に反映する。
    public func adjusted(_ settings: EditorSettings) -> EditorSettings {
        guard isLowPower else { return settings }
        var updated = settings
        updated.showsMinimap = false
        if updated.autoRun == .onPause { updated.autoRun = .onSave }
        return updated
    }
}
