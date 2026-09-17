import Foundation

// MARK: - 181. ステータスバー

/// 画面の下に出す情報。
public struct StatusBarInfo: Equatable, Sendable {
    /// 「12:34」(行:桁)。
    public var position: String
    /// 選んでいる範囲の説明。
    public var selection: String?
    public var languageName: String?
    public var encodingName: String
    public var lineEndingName: String
    public var indentName: String
    /// 実行の結果 (あれば)。
    public var runStatus: String?
    /// 診断の数。
    public var diagnostics: String?
    /// レート制限の残り。
    public var rateLimit: String?

    public init(position: String, selection: String? = nil, languageName: String? = nil,
                encodingName: String = "UTF-8", lineEndingName: String = "LF",
                indentName: String = "空白 4", runStatus: String? = nil,
                diagnostics: String? = nil, rateLimit: String? = nil) {
        self.position = position
        self.selection = selection
        self.languageName = languageName
        self.encodingName = encodingName
        self.lineEndingName = lineEndingName
        self.indentName = indentName
        self.runStatus = runStatus
        self.diagnostics = diagnostics
        self.rateLimit = rateLimit
    }

    /// 出す順に並べた項目。
    public var items: [String] {
        [position, selection, languageName, encodingName, lineEndingName,
         indentName, diagnostics, runStatus, rateLimit].compactMap { $0 }
    }

    public var text: String { items.joined(separator: "  ") }

    /// 編集の状態から組み立てる。
    public static func make(text: String, caretLocation: Int, selectionLength: Int,
                            languageID: String?, settings: EditorSettings,
                            diagnostics: DiagnosticSet? = nil,
                            run: RunResult? = nil,
                            rateLimit: RateLimitStatus? = nil) -> StatusBarInfo {
        let document = TextDocument(text)
        let position = document.position(at: caretLocation)
        var selection: String?
        if selectionLength > 0 {
            let summary = document.summary(location: caretLocation,
                                           length: selectionLength)
            selection = "選択 \(summary.characters) 文字"
                + (summary.lines > 1 ? " / \(summary.lines) 行" : "")
        }
        let encoding = TextEncodingInfo.decode(Data(text.utf8))?.name ?? "UTF-8"
        let ending = LineEnding.detect(in: text)
        return StatusBarInfo(
            position: "\(position.line):\(position.column)",
            selection: selection,
            languageName: languageID.flatMap { id in
                LanguageCatalog.all.first { $0.id == id }?.name
            },
            encodingName: encoding,
            lineEndingName: ending.displayName,
            indentName: settings.indent.usesSpaces
                ? "空白 \(settings.indent.width)" : "タブ",
            runStatus: run?.statusLine,
            diagnostics: diagnostics.flatMap { $0.isEmpty ? nil : $0.summary },
            rateLimit: rateLimit.map(\.description))
    }
}

// MARK: - 182. トースト通知

/// ちょっとした知らせ。
public struct Toast: Identifiable, Equatable, Sendable {
    public enum Style: String, Equatable, Sendable {
        case info
        case success
        case warning
        case error

        public var symbol: String {
            switch self {
            case .info: return "•"
            case .success: return "✓"
            case .warning: return "⚠"
            case .error: return "✗"
            }
        }

        /// 消えるまでの秒数。
        public var duration: TimeInterval {
            switch self {
            case .error: return 6
            case .warning: return 4.5
            default: return 3
            }
        }
    }

    public var id: UUID
    public var style: Style
    public var message: String
    /// 押せる操作 (「元に戻す」など)。
    public var actionTitle: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), style: Style = .info, message: String,
                actionTitle: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.style = style
        self.message = message
        self.actionTitle = actionTitle
        self.createdAt = createdAt
    }

    /// その時点で、まだ出しておくか。
    public func isVisible(at date: Date) -> Bool {
        date.timeIntervalSince(createdAt) < style.duration
    }
}

/// 出ている知らせをまとめる。
public struct ToastQueue: Equatable, Sendable {
    public private(set) var toasts: [Toast]
    /// 同時に出す数。
    public var limit: Int

    public init(toasts: [Toast] = [], limit: Int = 3) {
        self.toasts = toasts
        self.limit = limit
    }

    public var isEmpty: Bool { toasts.isEmpty }

    public mutating func show(_ toast: Toast) {
        // 同じ文言が続けて出るのは 1 つにまとめる。
        toasts.removeAll { $0.message == toast.message }
        toasts.append(toast)
        if toasts.count > limit { toasts.removeFirst(toasts.count - limit) }
    }

    public mutating func show(_ message: String, style: Toast.Style = .info,
                              actionTitle: String? = nil) {
        show(Toast(style: style, message: message, actionTitle: actionTitle))
    }

    public mutating func dismiss(id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    /// 時間がたって消えるものを片付ける。
    public mutating func prune(at date: Date = Date()) {
        toasts.removeAll { !$0.isVisible(at: date) }
    }

    public mutating func clear() { toasts.removeAll() }
}

// MARK: - 183. 読み込み中の表示

/// 時間のかかる仕事の進み具合。
public struct ProgressState: Equatable, Sendable {
    public var title: String
    /// 済んだ数。
    public var completed: Int
    /// 全部の数。0 なら「どれくらいか分からない」。
    public var total: Int
    /// いま何をしているか。
    public var detail: String?
    public var startedAt: Date
    public var isCancellable: Bool

    public init(title: String, completed: Int = 0, total: Int = 0,
                detail: String? = nil, startedAt: Date = Date(),
                isCancellable: Bool = true) {
        self.title = title
        self.completed = completed
        self.total = total
        self.detail = detail
        self.startedAt = startedAt
        self.isCancellable = isCancellable
    }

    /// 割合が分かるか。
    public var isDeterminate: Bool { total > 0 }

    /// 0〜1。
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Swift.min(1, Double(completed) / Double(total))
    }

    public var isFinished: Bool { total > 0 && completed >= total }

    /// 「12 / 40 (30%)」。
    public var progressText: String {
        guard isDeterminate else { return detail ?? "" }
        return "\(completed) / \(total) (\(Int(fraction * 100))%)"
    }

    /// 残り時間の見積もり。
    public func estimatedRemaining(at date: Date = Date()) -> TimeInterval? {
        guard isDeterminate, completed > 0, !isFinished else { return nil }
        let elapsed = date.timeIntervalSince(startedAt)
        guard elapsed > 0 else { return nil }
        let perItem = elapsed / Double(completed)
        return perItem * Double(total - completed)
    }

    /// 「あと 12 秒くらい」。
    public func remainingText(at date: Date = Date()) -> String? {
        guard let remaining = estimatedRemaining(at: date) else { return nil }
        return "あと \(RunFormatting.duration(remaining)) くらい"
    }
}

// MARK: - 184. エラーと再試行

/// 失敗したときに画面に出すもの。
public struct FailureState: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var message: String
    /// 手助けになる説明。
    public var hint: String?
    /// もう一度やれるか。
    public var canRetry: Bool
    /// 何回試したか。
    public var attempts: Int

    public init(id: UUID = UUID(), title: String, message: String, hint: String? = nil,
                canRetry: Bool = true, attempts: Int = 1) {
        self.id = id
        self.title = title
        self.message = message
        self.hint = hint
        self.canRetry = canRetry
        self.attempts = attempts
    }

    /// エラーから組み立てる。
    public static func make(from error: Error, attempts: Int = 1) -> FailureState {
        if let clientError = error as? GitHubClientError {
            switch clientError {
            case .rateLimited:
                return FailureState(
                    title: "しばらく待ってください",
                    message: clientError.errorDescription ?? "",
                    hint: "設定でアクセストークンを入れると、回数の上限が上がります。",
                    canRetry: true, attempts: attempts)
            case .notFound(let path):
                return FailureState(
                    title: "見つかりませんでした", message: path,
                    hint: "URL のつづりと、ブランチ名を確かめてください。",
                    canRetry: false, attempts: attempts)
            case .http(let status, let message):
                return FailureState(
                    title: "通信に失敗しました (\(status))", message: message,
                    hint: status >= 500 ? "サーバー側の不調かもしれません。"
                        + "少し待ってからもう一度試してください。" : nil,
                    canRetry: status >= 500 || status == 429, attempts: attempts)
            case .badResponse:
                return FailureState(title: "応答を読めませんでした",
                                    message: clientError.errorDescription ?? "",
                                    canRetry: true, attempts: attempts)
            }
        }
        if let urlError = error as? URLError {
            return FailureState(
                title: "つながりませんでした",
                message: urlError.localizedDescription,
                hint: "電波や Wi-Fi の状態を確かめてください。",
                canRetry: true, attempts: attempts)
        }
        return FailureState(title: "うまくいきませんでした",
                            message: error.localizedDescription,
                            canRetry: true, attempts: attempts)
    }

    /// もう一度試したときの状態。
    public func retried() -> FailureState {
        var copy = self
        copy.attempts += 1
        return copy
    }

    /// 何度も失敗しているか。
    public var isPersistent: Bool { attempts >= 3 }

    /// 次に試すまで待つ秒数 (だんだん延ばす)。
    public var retryDelay: TimeInterval {
        Swift.min(30, pow(2, Double(attempts - 1)))
    }
}

// MARK: - 185. 空状態の案内

/// 何も無いときに出す案内。
public struct EmptyState: Equatable, Sendable {
    public var title: String
    public var message: String
    /// 押せる操作の名前。
    public var actionTitle: String?
    /// 例として出す文字列。
    public var examples: [String]

    public init(title: String, message: String, actionTitle: String? = nil,
                examples: [String] = []) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.examples = examples
    }

    /// 最初の画面。
    public static let welcome = EmptyState(
        title: "リポジトリを開きましょう",
        message: "GitHub の URL を貼り付けるか、`owner/repo` の形で入力してください。",
        actionTitle: "URL を入力",
        examples: ["https://github.com/apple/swift",
                   "apple/swift-algorithms",
                   "https://github.com/o/r/blob/main/README.md"])

    /// 中身の無いフォルダ。
    public static let emptyDirectory = EmptyState(
        title: "このフォルダは空です",
        message: "ファイルがありません。1 つ上の階層に戻ってみてください。")

    /// 検索で見つからなかったとき。
    public static func noSearchResults(query: String) -> EmptyState {
        EmptyState(title: "「\(query)」は見つかりませんでした",
                   message: "大文字と小文字の区別や、絞り込みの設定を見直してみてください。",
                   actionTitle: "絞り込みを外す")
    }

    /// 出力がまだ無いとき。
    public static let noOutput = EmptyState(
        title: "まだ実行していません",
        message: "実行ボタンを押すと、ここに結果が出ます。",
        actionTitle: "実行")

    /// タブが 1 つも無いとき。
    public static let noTabs = EmptyState(
        title: "開いているファイルがありません",
        message: "左の一覧からファイルを選ぶと、ここに出ます。")

    /// ブックマークが無いとき。
    public static let noBookmarks = EmptyState(
        title: "ブックマークはまだありません",
        message: "行番号を長く押すと、その行にブックマークを付けられます。")

    /// オフラインに落としたものが無いとき。
    public static let noOfflineRepositories = EmptyState(
        title: "端末に保存したリポジトリはありません",
        message: "リポジトリを開いて「オフライン用に保存」を選ぶと、"
            + "通信できないときも読めます。",
        actionTitle: "保存する")
}

// MARK: - 169. HTML の要素インスペクタ

/// HTML の要素 1 つ。
public struct HTMLNode: Identifiable, Equatable, Sendable {
    public var id: Int
    public var tagName: String
    public var attributes: [(name: String, value: String)]
    /// 中の文字 (子要素は含まない)。
    public var text: String
    public var children: [HTMLNode]
    /// もとの行番号。
    public var line: Int

    public init(id: Int, tagName: String, attributes: [(name: String, value: String)] = [],
                text: String = "", children: [HTMLNode] = [], line: Int = 0) {
        self.id = id
        self.tagName = tagName
        self.attributes = attributes
        self.text = text
        self.children = children
        self.line = line
    }

    public static func == (lhs: HTMLNode, rhs: HTMLNode) -> Bool {
        lhs.id == rhs.id && lhs.tagName == rhs.tagName && lhs.text == rhs.text
            && lhs.line == rhs.line && lhs.children == rhs.children
            && lhs.attributes.count == rhs.attributes.count
            && zip(lhs.attributes, rhs.attributes).allSatisfy {
                $0.name == $1.name && $0.value == $1.value
            }
    }

    public func attribute(_ name: String) -> String? {
        attributes.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    public var idAttribute: String? { attribute("id") }
    public var classNames: [String] {
        (attribute("class") ?? "").split(separator: " ").map(String.init)
    }

    /// CSS で指すときの書き方 (`div#main.card`)。
    public var selector: String {
        var text = tagName
        if let idAttribute { text += "#\(idAttribute)" }
        for name in classNames { text += ".\(name)" }
        return text
    }

    /// 子も含めた数。
    public var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }
}

/// HTML をざっと木にほどく。
///
/// ブラウザほど厳密ではないが、構造を見るには足りる。
/// 閉じ忘れがあっても、同じ名前の閉じタグまでを子として扱う。
public enum HTMLInspector {
    /// 閉じタグを書かない要素。
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr"
    ]

    public static func parse(_ html: String) -> HTMLNode {
        var counter = 0
        var index = html.startIndex
        var line = 1
        let parsed = parseChildren(html, index: &index, line: &line, until: nil,
                                   counter: &counter)
        return HTMLNode(id: 0, tagName: "#document", text: parsed.text,
                        children: parsed.children)
    }

    /// 閉じタグ (または終わり) まで読み進める。
    ///
    /// その場に書かれていた文字も一緒に返す。中の文字は、
    /// 子要素ではなくその要素のものとして扱う。
    private static func parseChildren(_ html: String, index: inout String.Index,
                                      line: inout Int, until closing: String?,
                                      counter: inout Int)
        -> (children: [HTMLNode], text: String) {
        var result: [HTMLNode] = []
        var collected = ""
        var text = ""

        func flushText() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            guard !trimmed.isEmpty else { return }
            collected += collected.isEmpty ? trimmed : " " + trimmed
        }

        while index < html.endIndex {
            let character = html[index]
            if character == "\n" { line += 1 }
            guard character == "<" else {
                text.append(character)
                index = html.index(after: index)
                continue
            }

            // コメントは読み飛ばす。
            if html[index...].hasPrefix("<!--") {
                if let end = html.range(of: "-->", range: index..<html.endIndex) {
                    line += html[index..<end.upperBound].filter { $0 == "\n" }.count
                    index = end.upperBound
                } else {
                    index = html.endIndex
                }
                continue
            }

            guard let close = html[index...].firstIndex(of: ">") else {
                index = html.endIndex
                continue
            }
            let raw = String(html[html.index(after: index)..<close])
            let afterTag = html.index(after: close)

            // 閉じタグ。
            if raw.hasPrefix("/") {
                let name = String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)
                    .lowercased()
                index = afterTag
                if let closing, closing == name {
                    flushText()
                    return (result, collected)
                }
                continue
            }

            // 宣言 (`<!DOCTYPE ...>`) は飛ばす。
            if raw.hasPrefix("!") || raw.hasPrefix("?") {
                index = afterTag
                continue
            }

            flushText()
            let isSelfClosing = raw.hasSuffix("/")
            let body = isSelfClosing ? String(raw.dropLast()) : raw
            let (name, attributes) = parseTag(body)
            counter += 1
            let identifier = counter
            let startLine = line
            index = afterTag

            var children: [HTMLNode] = []
            var inner = ""
            if !isSelfClosing, !voidElements.contains(name) {
                let parsed = parseChildren(html, index: &index, line: &line,
                                           until: name, counter: &counter)
                children = parsed.children
                inner = parsed.text
            }
            result.append(HTMLNode(id: identifier, tagName: name,
                                   attributes: attributes, text: inner,
                                   children: children, line: startLine))
        }
        flushText()
        return (result, collected)
    }

    /// タグの中身を名前と属性に分ける。
    static func parseTag(_ body: String) -> (String, [(name: String, value: String)]) {
        var name = ""
        var attributes: [(String, String)] = []
        var index = body.startIndex

        while index < body.endIndex, !body[index].isWhitespace {
            name.append(body[index])
            index = body.index(after: index)
        }

        var current = ""
        var value: String?
        var quote: Character?

        func flush() {
            let key = current.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { attributes.append((key, value ?? "")) }
            current = ""
            value = nil
        }

        while index < body.endIndex {
            let character = body[index]
            index = body.index(after: index)
            if let open = quote {
                if character == open {
                    quote = nil
                    flush()
                } else {
                    value = (value ?? "") + String(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                value = ""
                continue
            }
            if character == "=" {
                value = ""
                continue
            }
            if character.isWhitespace {
                if value != nil || !current.isEmpty { flush() }
                continue
            }
            if value != nil { value?.append(character) } else { current.append(character) }
        }
        flush()
        return (name.lowercased(), attributes)
    }

    /// 木の中から、条件に合うものを探す。
    public static func find(in node: HTMLNode,
                            where predicate: (HTMLNode) -> Bool) -> [HTMLNode] {
        var result: [HTMLNode] = []
        if predicate(node) { result.append(node) }
        for child in node.children { result += find(in: child, where: predicate) }
        return result
    }

    /// タグ名で探す。
    public static func elements(named name: String, in node: HTMLNode) -> [HTMLNode] {
        find(in: node) { $0.tagName == name.lowercased() }
    }
}

// MARK: - 170. JavaScript コンソール

/// コンソールに出る 1 行。
public struct ConsoleEntry: Identifiable, Equatable, Sendable {
    public enum Level: String, Equatable, Sendable {
        case log
        case info
        case warn
        case error
        case input
        case result

        public var symbol: String {
            switch self {
            case .log, .info: return "•"
            case .warn: return "⚠"
            case .error: return "✗"
            case .input: return ">"
            case .result: return "←"
            }
        }
    }

    public var id: UUID
    public var level: Level
    public var text: String
    public var at: Date

    public init(id: UUID = UUID(), level: Level, text: String, at: Date = Date()) {
        self.id = id
        self.level = level
        self.text = text
        self.at = at
    }
}

/// ページの中で動かした JavaScript のやりとりを覚えておく。
public struct JavaScriptConsole: Equatable, Sendable {
    public private(set) var entries: [ConsoleEntry]
    /// 打ち込んだものの履歴 (↑ キーで戻る)。
    public private(set) var inputHistory: [String]
    public var limit: Int

    public init(entries: [ConsoleEntry] = [], inputHistory: [String] = [],
                limit: Int = 500) {
        self.entries = entries
        self.inputHistory = inputHistory
        self.limit = limit
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var errorCount: Int { entries.filter { $0.level == .error }.count }

    public mutating func add(_ entry: ConsoleEntry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    public mutating func add(_ text: String, level: ConsoleEntry.Level = .log) {
        add(ConsoleEntry(level: level, text: text))
    }

    /// 打ち込んだものを記録する。
    public mutating func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        add(ConsoleEntry(level: .input, text: trimmed))
        inputHistory.removeAll { $0 == trimmed }
        inputHistory.append(trimmed)
        if inputHistory.count > 100 { inputHistory.removeFirst() }
    }

    /// 履歴をさかのぼる。`offset` は 1 が「1 つ前」。
    public func historyEntry(offset: Int) -> String? {
        guard offset >= 1, offset <= inputHistory.count else { return nil }
        return inputHistory[inputHistory.count - offset]
    }

    public mutating func clear() { entries.removeAll() }

    /// ページに埋め込む、console を横取りする JavaScript。
    ///
    /// WebView 側で受け取って `add` に渡す。
    public static let bridgeScript = """
    (function () {
        if (window.__viewerConsoleInstalled) { return; }
        window.__viewerConsoleInstalled = true;
        var send = function (level, args) {
            try {
                var text = Array.prototype.map.call(args, function (value) {
                    if (typeof value === 'object') {
                        try { return JSON.stringify(value); } catch (e) { return String(value); }
                    }
                    return String(value);
                }).join(' ');
                window.webkit.messageHandlers.viewerConsole.postMessage({
                    level: level, text: text
                });
            } catch (e) {}
        };
        ['log', 'info', 'warn', 'error'].forEach(function (name) {
            var original = console[name];
            console[name] = function () {
                send(name === 'info' ? 'log' : name, arguments);
                if (original) { original.apply(console, arguments); }
            };
        });
        window.addEventListener('error', function (event) {
            send('error', [event.message + ' (' + event.filename + ':' + event.lineno + ')']);
        });
        window.addEventListener('unhandledrejection', function (event) {
            send('error', ['未処理の拒否: ' + event.reason]);
        });
    })();
    """
}
