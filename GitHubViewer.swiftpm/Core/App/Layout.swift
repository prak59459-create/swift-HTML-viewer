import Foundation

// MARK: - 159. レイアウト切り替え

/// 画面の分け方。
public enum LayoutMode: String, CaseIterable, Identifiable, Codable, Equatable,
                        Sendable {
    /// コードだけ。
    case editorOnly
    /// 出力だけ。
    case outputOnly
    /// 左右に分ける。
    case sideBySide
    /// 上下に分ける。
    case stacked

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .editorOnly: return "コードだけ"
        case .outputOnly: return "出力だけ"
        case .sideBySide: return "左右に分ける"
        case .stacked: return "上下に分ける"
        }
    }

    public var showsEditor: Bool { self != .outputOnly }
    public var showsOutput: Bool { self != .editorOnly }
    public var isSplit: Bool { self == .sideBySide || self == .stacked }
    public var isHorizontal: Bool { self == .sideBySide }

    /// 画面の細長さから、分け方の向きを選ぶ。
    ///
    /// 横長 (iPad の横置きなど) なら左右、縦長なら上下。
    public static func suggested(width: Double, height: Double) -> LayoutMode {
        width >= height * 1.2 ? .sideBySide : .stacked
    }
}

// MARK: - 160. ペインの大きさ

/// 分けた画面の割合。
public struct SplitRatio: Equatable, Codable, Sendable {
    /// 手前側 (コード) の割合 (0〜1)。
    public var value: Double
    public static let minimum: Double = 0.15
    public static let maximum: Double = 0.85

    public init(_ value: Double = 0.6) {
        self.value = Swift.min(SplitRatio.maximum,
                               Swift.max(SplitRatio.minimum, value))
    }

    /// 全体の長さから、手前側の大きさを求める。
    public func leading(of total: Double) -> Double { total * value }
    public func trailing(of total: Double) -> Double { total * (1 - value) }

    /// つまみを動かす。
    public mutating func drag(by delta: Double, total: Double) {
        guard total > 0 else { return }
        self = SplitRatio(value + delta / total)
    }

    /// 半分に戻す。
    public mutating func reset() { self = SplitRatio(0.5) }
}

// MARK: - 158. 表示倍率 / 162. 集中モード

/// 画面全体の見せ方。
public struct DisplayState: Equatable, Codable, Sendable {
    /// 158. 表示倍率 (1.0 が等倍)。
    public var zoom: Double
    /// 162. 集中モード (まわりを隠す)。
    public var isFocused: Bool
    /// 161. 出力を別のウィンドウに出しているか。
    public var outputIsDetached: Bool
    public var layout: LayoutMode
    public var splitRatio: SplitRatio

    public static let minimumZoom: Double = 0.5
    public static let maximumZoom: Double = 3.0

    public init(zoom: Double = 1, isFocused: Bool = false,
                outputIsDetached: Bool = false, layout: LayoutMode = .sideBySide,
                splitRatio: SplitRatio = SplitRatio()) {
        self.zoom = Swift.min(DisplayState.maximumZoom,
                              Swift.max(DisplayState.minimumZoom, zoom))
        self.isFocused = isFocused
        self.outputIsDetached = outputIsDetached
        self.layout = layout
        self.splitRatio = splitRatio
    }

    public mutating func setZoom(_ value: Double) {
        zoom = Swift.min(DisplayState.maximumZoom,
                         Swift.max(DisplayState.minimumZoom, value))
    }

    /// ピンチで拡大・縮小する。
    public mutating func pinch(by factor: Double) { setZoom(zoom * factor) }

    /// 1 段ずつ。
    public mutating func zoomIn() { setZoom(zoom + 0.1) }
    public mutating func zoomOut() { setZoom(zoom - 0.1) }
    public mutating func resetZoom() { zoom = 1 }

    public var isDefaultZoom: Bool { abs(zoom - 1) < 0.001 }

    /// 「120%」。
    public var zoomText: String { "\(Int((zoom * 100).rounded()))%" }

    /// 集中モードのときに隠すもの。
    public var showsSidebar: Bool { !isFocused }
    public var showsStatusBar: Bool { !isFocused }
    public var showsTabBar: Bool { !isFocused }

    /// 集中モードを切り替える。
    public mutating func toggleFocus() { isFocused.toggle() }
}

// MARK: - 35. 縦分割で 2 ファイル

/// 左右 (または上下) にファイルを並べる。
public struct SplitEditor: Equatable, Codable, Sendable {
    /// 2 つ目を出しているか。
    public var isSplit: Bool
    /// 手前側のタブ。
    public var primaryTabID: UUID?
    /// 奥側のタブ。
    public var secondaryTabID: UUID?
    /// どちらを触っているか。
    public var focusIsSecondary: Bool
    public var ratio: SplitRatio
    /// 縦に並べるか。
    public var isVertical: Bool

    public init(isSplit: Bool = false, primaryTabID: UUID? = nil,
                secondaryTabID: UUID? = nil, focusIsSecondary: Bool = false,
                ratio: SplitRatio = SplitRatio(0.5), isVertical: Bool = false) {
        self.isSplit = isSplit
        self.primaryTabID = primaryTabID
        self.secondaryTabID = secondaryTabID
        self.focusIsSecondary = focusIsSecondary
        self.ratio = ratio
        self.isVertical = isVertical
    }

    /// いま触っている側のタブ。
    public var activeTabID: UUID? {
        isSplit && focusIsSecondary ? secondaryTabID : primaryTabID
    }

    /// 分けて、2 つ目にタブを置く。
    public mutating func split(with tabID: UUID?) {
        isSplit = true
        secondaryTabID = tabID ?? primaryTabID
        focusIsSecondary = true
    }

    /// 1 つに戻す。触っていた側を残す。
    public mutating func close() {
        if focusIsSecondary, let secondaryTabID { primaryTabID = secondaryTabID }
        isSplit = false
        secondaryTabID = nil
        focusIsSecondary = false
    }

    /// 触る側を入れ替える。
    public mutating func toggleFocus() {
        guard isSplit else { return }
        focusIsSecondary.toggle()
    }

    /// 左右の中身を入れ替える。
    public mutating func swap() {
        guard isSplit else { return }
        let first = primaryTabID
        primaryTabID = secondaryTabID
        secondaryTabID = first
    }

    /// タブを開いたときに、どちら側に入れるか決める。
    public mutating func place(_ tabID: UUID) {
        if isSplit, focusIsSecondary { secondaryTabID = tabID }
        else { primaryTabID = tabID }
    }

    /// そのタブが閉じられたとき。
    public mutating func forget(_ tabID: UUID) {
        if primaryTabID == tabID { primaryTabID = nil }
        if secondaryTabID == tabID {
            secondaryTabID = nil
            if isSplit { close() }
        }
    }
}

// MARK: - 53. 画像のピンチズーム

/// 画像を見るときの拡大と位置。
public struct ImageViewerState: Equatable, Sendable {
    public var scale: Double
    /// 動かした量 (点)。
    public var offsetX: Double
    public var offsetY: Double
    public static let minimumScale: Double = 0.1
    public static let maximumScale: Double = 20

    public init(scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0) {
        self.scale = Swift.min(ImageViewerState.maximumScale,
                               Swift.max(ImageViewerState.minimumScale, scale))
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    public mutating func pinch(by factor: Double) {
        scale = Swift.min(ImageViewerState.maximumScale,
                          Swift.max(ImageViewerState.minimumScale, scale * factor))
        if isFit { offsetX = 0; offsetY = 0 }
    }

    public mutating func pan(dx: Double, dy: Double) {
        offsetX += dx
        offsetY += dy
    }

    /// もとの大きさに戻す。
    public mutating func reset() { self = ImageViewerState() }

    /// 等倍に近いか。
    public var isFit: Bool { abs(scale - 1) < 0.01 }

    /// ダブルタップしたときの倍率 (等倍 ↔ 2 倍)。
    public mutating func toggleZoom(at factor: Double = 2) {
        if isFit { pinch(by: factor) } else { reset() }
    }

    /// 画面に収まる倍率。
    public static func fitScale(imageWidth: Double, imageHeight: Double,
                                viewWidth: Double, viewHeight: Double) -> Double {
        guard imageWidth > 0, imageHeight > 0, viewWidth > 0, viewHeight > 0 else {
            return 1
        }
        return Swift.min(viewWidth / imageWidth, viewHeight / imageHeight)
    }

    /// 「120%」。
    public var scaleText: String { "\(Int((scale * 100).rounded()))%" }
}

// MARK: - 168. HTML のレスポンシブ確認

/// 表示を確かめる画面の大きさ。
public struct DevicePreset: Identifiable, Equatable, Sendable {
    public var name: String
    public var width: Double
    public var height: Double

    public var id: String { name }

    public init(name: String, width: Double, height: Double) {
        self.name = name
        self.width = width
        self.height = height
    }

    /// 縦横を入れ替える。
    public var rotated: DevicePreset {
        DevicePreset(name: name, width: height, height: width)
    }

    public var isLandscape: Bool { width > height }

    /// 「390 × 844」。
    public var sizeText: String { "\(Int(width)) × \(Int(height))" }
}

/// よく使う画面の大きさ。
public enum DevicePresets {
    public static let all: [DevicePreset] = [
        DevicePreset(name: "iPhone SE", width: 375, height: 667),
        DevicePreset(name: "iPhone 15", width: 393, height: 852),
        DevicePreset(name: "iPhone 15 Pro Max", width: 430, height: 932),
        DevicePreset(name: "iPad mini", width: 744, height: 1133),
        DevicePreset(name: "iPad Pro 11", width: 834, height: 1194),
        DevicePreset(name: "iPad Pro 13", width: 1024, height: 1366),
        DevicePreset(name: "ノート PC", width: 1280, height: 800),
        DevicePreset(name: "デスクトップ", width: 1920, height: 1080)
    ]

    public static let `default` = all[4]

    public static func preset(named name: String) -> DevicePreset? {
        all.first { $0.name == name }
    }

    /// その幅で効く、よくある区切り (CSS のメディアクエリ)。
    public static func breakpointName(forWidth width: Double) -> String {
        switch width {
        case ..<576: return "とても狭い (< 576)"
        case ..<768: return "狭い (576〜767)"
        case ..<992: return "ふつう (768〜991)"
        case ..<1200: return "広い (992〜1199)"
        default: return "とても広い (≥ 1200)"
        }
    }
}
