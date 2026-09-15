import Foundation

/// 取得した内容を「どう表示するか」のユーザー選択。
public enum DisplayMode: String, CaseIterable, Identifiable, Equatable {
    /// 拡張子から自動で決める。
    case auto
    /// HTML / SVG として WebView で実行する。
    case web
    /// Markdown として整形する。
    case markdown
    /// ソースコードとして表示する。
    case code
    /// 画像として表示する。
    case image

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自動"
        case .web: return "HTML として実行"
        case .markdown: return "Markdown"
        case .code: return "ソース"
        case .image: return "画像"
        }
    }

    /// `.auto` を実際の表示方法に解決する。
    public func resolved(for kind: ContentKind) -> DisplayMode {
        guard self == .auto else { return self }
        switch kind {
        case .web: return .web
        case .markdown: return .markdown
        case .image: return .image
        case .code: return .code
        case .binary: return .code
        }
    }
}
