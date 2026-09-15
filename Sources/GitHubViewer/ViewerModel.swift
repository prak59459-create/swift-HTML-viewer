import Foundation
import GitHubViewerCore
import SwiftUI

@MainActor
final class ViewerModel: ObservableObject {
    // 入力
    @Published var urlText: String = ""
    @Published var token: String = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? ""
    @Published var mode: DisplayMode = .auto { didSet { refreshRendering() } }

    // 取得結果
    @Published private(set) var listing: DirectoryListing?
    @Published private(set) var file: RemoteFile?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusText: String = "GitHub の URL を入力して「開く」を押してください。"

    // 表示
    @Published var source: String = ""
    @Published var isEditing = false
    @Published private(set) var renderedHTML: String = ""
    @Published private(set) var reloadToken: Int = 0
    @Published private(set) var consoleLines: [String] = []

    private var history: [GitHubTarget] = []
    private var currentTarget: GitHubTarget?

    var canGoBack: Bool { history.count > 1 }

    var resolvedMode: DisplayMode {
        guard let file else { return mode == .auto ? .code : mode }
        return mode.resolved(for: file.kind)
    }

    var currentBaseURL: URL? { file?.baseURL }

    var parentEntryTitle: String? {
        guard let location = listing?.location ?? fileLocation, location.parent != nil else { return nil }
        return ".."
    }

    private var fileLocation: GitHubLocation? {
        guard case .repository(let location)? = currentTarget else { return nil }
        return location
    }

    // MARK: - 読み込み

    func openFromInput() {
        let text = urlText
        Task { await open(text) }
    }

    func open(_ text: String) async {
        do {
            let target = try GitHubURLParser.parse(text)
            await load(target)
        } catch {
            errorMessage = error.localizedDescription
            statusText = "URL を解釈できませんでした。"
        }
    }

    func openEntry(_ entry: RepositoryEntry) {
        if let location = entry.location {
            Task { await load(.repository(location)) }
        } else if let url = entry.downloadURL {
            Task { await load(.rawURL(url)) }
        }
    }

    func goUp() {
        let location = listing?.location ?? fileLocation
        guard let parent = location?.parent else { return }
        Task { await load(.repository(parent)) }
    }

    func goBack() {
        guard history.count > 1 else { return }
        history.removeLast() // 現在地を捨てる
        let previous = history.removeLast()
        Task { await load(previous) }
    }

    func reload() {
        guard let target = currentTarget else { return }
        Task { await load(target, pushHistory: false) }
    }

    private func load(_ target: GitHubTarget, pushHistory: Bool = true) async {
        isLoading = true
        errorMessage = nil
        consoleLines.removeAll()
        statusText = "読み込み中…"
        defer { isLoading = false }

        let client = GitHubClient(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let content = try await client.fetch(target)
            currentTarget = target
            if pushHistory { history.append(target) }
            urlText = displayURL(for: target) ?? urlText

            switch content {
            case .directory(let listing):
                self.listing = listing
                self.file = nil
                self.source = ""
                self.renderedHTML = HTMLDocumentBuilder.page(
                    title: listing.title,
                    body: "<article class=\"markdown-body\"><h1>\(MarkdownRenderer.escape(listing.title))</h1>"
                        + "<p>左の一覧からファイルを選ぶと、その内容を表示・実行します。</p></article>")
                statusText = "\(listing.title) — \(listing.entries.count) 項目"
                // README があれば自動で開く。
                if let readme = listing.entries.first(where: { !$0.isDirectory && $0.name.lowercased().hasPrefix("readme") }) {
                    openEntry(readme)
                }

            case .file(let file):
                self.file = file
                self.source = file.kind.isTextual ? (file.text ?? "") : ""
                statusText = "\(file.path.isEmpty ? file.name : file.path) — \(byteCount(file.data.count))"
                refreshRendering()
            }
        } catch {
            errorMessage = error.localizedDescription
            statusText = "読み込みに失敗しました。"
            renderedHTML = HTMLDocumentBuilder.errorPage(error.localizedDescription)
            reloadToken += 1
        }
    }

    // MARK: - 表示

    /// 現在のモードとソースから WebView に渡す HTML を作り直す。
    func refreshRendering() {
        guard let file else { return }
        let title = file.name
        switch resolvedMode {
        case .web:
            renderedHTML = HTMLDocumentBuilder.executable(html: source, title: title)
        case .markdown:
            renderedHTML = HTMLDocumentBuilder.markdown(source, title: title)
        case .code, .auto:
            renderedHTML = HTMLDocumentBuilder.code(source, title: title)
        case .image:
            renderedHTML = ""
        }
    }

    /// 編集したソースを再実行する。
    func run() {
        consoleLines.removeAll()
        refreshRendering()
        reloadToken += 1
    }

    func appendLog(_ line: String) {
        consoleLines.append(line)
        if consoleLines.count > 500 { consoleLines.removeFirst(consoleLines.count - 500) }
    }

    func clearLog() { consoleLines.removeAll() }

    /// 現在の内容をブラウザで開けるよう一時ファイルに書き出す。
    func exportHTMLToTemporaryFile() -> URL? {
        guard !renderedHTML.isEmpty else { return nil }
        let name = (file?.name as NSString?)?.deletingPathExtension ?? "preview"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubViewer-\(name)-\(UUID().uuidString.prefix(8)).html")
        do {
            try renderedHTML.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    var githubPageURL: URL? { file?.htmlURL }

    // MARK: - 補助

    private func displayURL(for target: GitHubTarget) -> String? {
        switch target {
        case .repository(let location):
            var text = "https://github.com/\(location.owner)/\(location.repo)"
            if let ref = location.ref {
                text += "/\(location.isDirectory ? "tree" : "blob")/\(ref)"
                if !location.path.isEmpty { text += "/\(location.path)" }
            }
            return text
        case .gist(let id):
            return "https://gist.github.com/\(id)"
        case .rawURL(let url):
            return url.absoluteString
        }
    }

    private func byteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
