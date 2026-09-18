import Foundation

// MARK: - 249. 英語 UI

/// 画面に出す言葉。
public enum AppLanguage: String, CaseIterable, Identifiable, Equatable, Sendable {
    /// 端末の設定に合わせる。
    case system
    case japanese
    case english

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "端末に合わせる"
        case .japanese: return "日本語"
        case .english: return "English"
        }
    }

    /// 端末の設定から、実際に使う言葉を決める。
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages)
        -> AppLanguage {
        guard self == .system else { return self }
        let first = preferredLanguages.first?.lowercased() ?? "en"
        return first.hasPrefix("ja") ? .japanese : .english
    }
}

/// 画面の文言。
///
/// 表を 1 つ持つだけの小さな仕組み。見つからない鍵は、鍵そのものを返す
/// (画面が空になるより、手がかりが出るほうがよい)。
public enum L10n {

    /// いま使う言葉。アプリの設定から入れ替える。
    public nonisolated(unsafe) static var current: AppLanguage = .system

    public static func string(_ key: String, language: AppLanguage? = nil) -> String {
        let resolved = (language ?? current).resolved()
        if resolved == .japanese, let text = japanese[key] { return text }
        if resolved == .english, let text = english[key] { return text }
        // 片方にしかない言葉は、あるほうを出す。
        return japanese[key] ?? english[key] ?? key
    }

    /// 差し込みのある文言。`{0}` から順に置き換える。
    public static func string(_ key: String, _ arguments: [String],
                              language: AppLanguage? = nil) -> String {
        var text = string(key, language: language)
        for (index, argument) in arguments.enumerated() {
            text = text.replacingOccurrences(of: "{\(index)}", with: argument)
        }
        return text
    }

    /// 訳のない鍵 (テストで見張る)。
    public static var missingTranslations: [String] {
        Set(japanese.keys).symmetricDifference(english.keys).sorted()
    }

    public static let japanese: [String: String] = [
        "app.name": "GitHubViewer",
        "action.open": "開く",
        "action.run": "実行",
        "action.stop": "停止",
        "action.save": "保存",
        "action.cancel": "キャンセル",
        "action.done": "完了",
        "action.share": "共有",
        "action.export": "書き出す",
        "action.retry": "やり直す",
        "action.delete": "削除",
        "action.next": "次へ",
        "action.back": "戻る",
        "action.skip": "スキップ",
        "tab.files": "ファイル",
        "tab.editor": "エディタ",
        "tab.output": "出力",
        "tab.settings": "設定",
        "tab.help": "使い方",
        "settings.appearance": "見た目",
        "settings.editor": "エディタ",
        "settings.storage": "保存",
        "settings.language": "表示言語",
        "settings.presets": "プリセット",
        "run.running": "実行中…",
        "run.succeeded": "実行できました",
        "run.failed": "エラーが出ました",
        "run.noOutput": "(出力なし)",
        "run.input": "入力",
        "error.offline": "通信できません",
        "error.notFound": "見つかりません",
        "error.rateLimited": "GitHub の回数制限に達しました",
        "empty.noFiles": "ファイルがありません",
        "empty.noResults": "見つかりませんでした",
        "storage.total": "合計 {0}",
        "badge.earned": "{0} を獲得しました",
        "tip.title": "今日のヒント"
    ]

    public static let english: [String: String] = [
        "app.name": "GitHubViewer",
        "action.open": "Open",
        "action.run": "Run",
        "action.stop": "Stop",
        "action.save": "Save",
        "action.cancel": "Cancel",
        "action.done": "Done",
        "action.share": "Share",
        "action.export": "Export",
        "action.retry": "Try Again",
        "action.delete": "Delete",
        "action.next": "Next",
        "action.back": "Back",
        "action.skip": "Skip",
        "tab.files": "Files",
        "tab.editor": "Editor",
        "tab.output": "Output",
        "tab.settings": "Settings",
        "tab.help": "Help",
        "settings.appearance": "Appearance",
        "settings.editor": "Editor",
        "settings.storage": "Storage",
        "settings.language": "Display Language",
        "settings.presets": "Presets",
        "run.running": "Running…",
        "run.succeeded": "Finished successfully",
        "run.failed": "Something went wrong",
        "run.noOutput": "(no output)",
        "run.input": "Input",
        "error.offline": "You are offline",
        "error.notFound": "Not found",
        "error.rateLimited": "GitHub rate limit reached",
        "empty.noFiles": "No files here",
        "empty.noResults": "Nothing found",
        "storage.total": "{0} in total",
        "badge.earned": "You earned {0}",
        "tip.title": "Tip of the day"
    ]
}
