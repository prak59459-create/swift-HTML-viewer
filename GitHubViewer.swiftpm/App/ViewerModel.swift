import Foundation
import SwiftUI

@MainActor
final class ViewerModel: ObservableObject {
    // 入力
    @Published var urlText: String = ""
    @Published var token: String = ""
    @Published var mode: DisplayMode = .auto { didSet { refreshRendering() } }

    /// 拡張子による判定を上書きして、別の言語として実行したいときに使う。
    @Published var languageOverrideID: String?
    /// 実行サービスにソースを送って実行してよいか。
    @Published var allowsRemoteExecution: Bool = false
    /// どの実行サービスを使うか。
    @Published var executionBackend: ExecutionBackend = .wandbox
    /// Piston を使う場合のエンドポイント (自前ホストしたものを指定できる)。
    @Published var pistonEndpointText: String = CodeRunner.defaultPistonEndpoint.absoluteString
    /// サーバー実行に渡す標準入力。
    @Published var stdin: String = ""

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

    // 実行
    @Published private(set) var isRunning = false
    /// 内蔵コンパイラの逆アセンブル結果。
    @Published private(set) var disassembly: String = ""
    @Published private(set) var executionOutput: ExecutionOutput?
    /// 実行結果 (サンドボックスページ) を表示中かどうか。
    @Published private(set) var isShowingRunResult = false

    private let codeRunner = CodeRunner()
    private var history: [GitHubTarget] = []
    private var currentTarget: GitHubTarget?

    init() {
        token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? ""
    }

    var canGoBack: Bool { history.count > 1 }

    var resolvedMode: DisplayMode {
        guard let file else { return mode == .auto ? .code : mode }
        return mode.resolved(for: file.kind)
    }

    var currentBaseURL: URL? { isShowingRunResult ? nil : file?.baseURL }

    var canGoUp: Bool { (listing?.location ?? fileLocation)?.parent != nil }

    /// 拡張子 (または手動指定) から決まる言語。
    var language: ProgrammingLanguage? {
        if let languageOverrideID { return LanguageCatalog.language(id: languageOverrideID) }
        guard let file else { return nil }
        return LanguageCatalog.language(forFileName: file.name)
    }

    /// 現在のファイルをどう実行するか。
    var executionPlan: ExecutionPlan {
        guard let file else { return .unavailable(reason: "ファイルが開かれていません") }
        if let languageOverrideID, let language = LanguageCatalog.language(id: languageOverrideID) {
            return LanguageCatalog.plan(for: language, allowsRemoteExecution: allowsRemoteExecution)
        }
        return LanguageCatalog.plan(kind: file.kind,
                                    fileName: file.name,
                                    allowsRemoteExecution: allowsRemoteExecution)
    }

    var canRun: Bool {
        if case .unavailable = executionPlan { return false }
        return file != nil && !isRunning
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
        guard let parent = (listing?.location ?? fileLocation)?.parent else { return }
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
        executionOutput = nil
        disassembly = ""
        isShowingRunResult = false
        languageOverrideID = nil
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
                        + "<p>一覧からファイルを選ぶと、その内容を表示・実行します。</p></article>")
                statusText = "\(listing.title) — \(listing.entries.count) 項目"
                if let readme = listing.entries.first(where: {
                    !$0.isDirectory && $0.name.lowercased().hasPrefix("readme")
                }) {
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
        isShowingRunResult = false
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

    // MARK: - 実行

    /// 現在のソースを、言語に応じた方法で実行する。
    func run() {
        guard let file else { return }
        consoleLines.removeAll()
        errorMessage = nil
        executionOutput = nil

        switch executionPlan {
        case .builtin(let compiler, let language):
            switch compiler {
            case .miniC:
                statusText = "\(language.name) を内蔵コンパイラでコンパイル中…"
                let execution = MiniC.execute(source: source, input: stdin, includeDisassembly: true)
                disassembly = execution.disassembly
                executionOutput = ExecutionOutput(
                    languageVersion: "内蔵 C コンパイラ",
                    compileOutput: execution.diagnosticsText,
                    stdout: execution.output,
                    stderr: execution.runtimeError ?? "",
                    exitCode: Int(execution.exitCode))
                if !execution.compiled {
                    statusText = "コンパイルエラー: \(execution.errorCount) 件"
                } else if let runtimeError = execution.runtimeError {
                    statusText = "実行時エラー: \(runtimeError)"
                } else {
                    statusText = "実行完了 (終了コード \(execution.exitCode)"
                        + ", \(execution.executedSteps) 命令"
                        + (execution.warningCount > 0 ? ", 警告 \(execution.warningCount) 件" : "") + ")"
                }
            }

        case .browser:
            if mode == .auto || mode == .web {
                renderedHTML = HTMLDocumentBuilder.executable(html: source, title: file.name)
                isShowingRunResult = false
            } else {
                refreshRendering()
            }
            reloadToken += 1
            statusText = "WebView で実行しました。"

        case .local(let engine, let language):
            renderedHTML = SandboxPageBuilder.page(engine: engine, source: source, fileName: file.name)
            isShowingRunResult = true
            reloadToken += 1
            statusText = "\(language.name) を端末内で実行中…"

        case .remote(let spec, let language):
            isRunning = true
            statusText = "\(language.name) を \(executionBackend.displayName) に送信中…"
            let source = self.source
            let stdin = self.stdin
            let backend = executionBackend
            let endpoint = URL(string: pistonEndpointText) ?? CodeRunner.defaultPistonEndpoint
            Task { [codeRunner] in
                do {
                    let output = try await codeRunner.run(spec: spec, source: source, stdin: stdin,
                                                          backend: backend, pistonEndpoint: endpoint)
                    self.executionOutput = output
                    self.statusText = "実行完了: \(output.languageVersion)"
                        + (output.exitCode.map { " (終了コード \($0))" } ?? "")
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.statusText = "実行に失敗しました。"
                }
                self.isRunning = false
            }

        case .unavailable(let reason):
            errorMessage = reason
        }
    }

    func appendLog(_ line: String) {
        consoleLines.append(line)
        if consoleLines.count > 500 { consoleLines.removeFirst(consoleLines.count - 500) }
    }

    func clearLog() {
        consoleLines.removeAll()
        executionOutput = nil
    }

    /// 内蔵コンパイラの逆アセンブルだけを作る。
    func showDisassembly() {
        guard case .builtin = executionPlan else { return }
        let execution = MiniC.execute(source: source, input: stdin, includeDisassembly: true)
        disassembly = execution.disassembly
        if !execution.compiled {
            errorMessage = "コンパイルできないので逆アセンブルできません。"
            executionOutput = ExecutionOutput(languageVersion: "内蔵 C コンパイラ",
                                              compileOutput: execution.diagnosticsText,
                                              stdout: "", stderr: "", exitCode: 1)
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
