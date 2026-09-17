import SwiftUI

struct ContentView: View {
    @StateObject private var model = ViewerModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showsSettings = false
    @State private var showsOutput = true
    @State private var showsDisassembly = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showsSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showsDisassembly) {
            DisassemblyView(text: model.disassembly)
        }
    }

    private var isCompact: Bool { sizeClass == .compact }

    // MARK: - サイドバー (ファイル一覧)

    private var sidebar: some View {
        Group {
            if let listing = model.listing {
                List {
                    if model.canGoUp {
                        Button {
                            model.goUp()
                        } label: {
                            Label("上のフォルダへ", systemImage: "arrow.turn.left.up")
                        }
                    }
                    Section(listing.title) {
                        ForEach(listing.entries) { entry in
                            Button {
                                model.openEntry(entry)
                                if isCompact { columnVisibility = .detailOnly }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.isDirectory ? "folder" : icon(for: entry.name))
                                        .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                                    Text(entry.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if entry.isDirectory {
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ファイル一覧")
                        .font(.headline)
                    Text("リポジトリやフォルダの URL を開くと、ここに中身が並びます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            }
        }
        .navigationTitle("GitHub Viewer")
    }

    private func icon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm", "svg": return "chevron.left.forwardslash.chevron.right"
        case "md", "markdown": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        default:
            return LanguageCatalog.language(forFileName: name) != nil ? "play.rectangle" : "doc.text"
        }
    }

    // MARK: - 本体

    private var detail: some View {
        VStack(spacing: 0) {
            urlBar
            Divider()
            controlBar
            Divider()
            contentArea
            if showsOutput, model.executionOutput != nil || !model.consoleLines.isEmpty {
                Divider()
                OutputPane(model: model)
                    .frame(height: isCompact ? 180 : 220)
            }
            Divider()
            statusBar
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)

            TextField("https://github.com/owner/repo/blob/main/index.html", text: $model.urlText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { model.openFromInput() }

            Button("開く") { model.openFromInput() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])

            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }

            Button { showsSettings = true } label: {
                Image(systemName: "gearshape")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Picker("表示", selection: $model.mode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                languageMenu

                Button {
                    model.run()
                    showsOutput = true
                } label: {
                    if model.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("実行", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!model.canRun)

                Toggle(isOn: $model.isEditing) {
                    Label("編集", systemImage: "square.and.pencil")
                }
                .toggleStyle(.button)
                .disabled(model.file?.kind.isTextual != true)

                Toggle(isOn: $showsOutput) {
                    Label("出力", systemImage: "terminal")
                }
                .toggleStyle(.button)

                if case .builtin = model.executionPlan {
                    Button {
                        model.showDisassembly()
                        showsDisassembly = !model.disassembly.isEmpty
                    } label: {
                        Label("逆アセンブル", systemImage: "list.number")
                    }
                }

                if let url = model.githubPageURL {
                    Link(destination: url) {
                        Label("GitHub", systemImage: "link")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// 実行する言語の手動指定。
    private var languageMenu: some View {
        Menu {
            Button {
                model.languageOverrideID = nil
            } label: {
                if model.languageOverrideID == nil {
                    Label("自動判定", systemImage: "checkmark")
                } else {
                    Text("自動判定")
                }
            }
            Section("端末内で実行") {
                ForEach(LanguageCatalog.all.filter { $0.local != nil }) { language in
                    Button(language.name) { model.languageOverrideID = language.id }
                }
            }
            Section("サーバーで実行") {
                ForEach(LanguageCatalog.all.filter { $0.local == nil }) { language in
                    Button(language.name) { model.languageOverrideID = language.id }
                }
            }
        } label: {
            Label(model.language?.name ?? "言語", systemImage: "chevron.left.slash.chevron.right")
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        ZStack {
            if model.isEditing, model.file?.kind.isTextual == true {
                if isCompact {
                    VStack(spacing: 0) {
                        editor
                        Divider()
                        preview
                    }
                } else {
                    HStack(spacing: 0) {
                        editor
                        Divider()
                        preview
                    }
                }
            } else {
                preview
            }

            if model.isLoading {
                ProgressView()
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ソース (編集して「実行」で反映)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
            Divider()
            TextEditor(text: $model.source)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let file = model.file, model.resolvedMode == .image, !model.isShowingRunResult {
            if let image = UIImage(data: file.data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                }
            } else {
                placeholder("この画像は表示できませんでした。")
            }
        } else if model.renderedHTML.isEmpty {
            placeholder("GitHub の URL を入力すると、HTML はそのまま実行、Markdown は整形、\nソースコードは「実行」で動かせます。")
        } else {
            WebView(html: model.renderedHTML,
                    baseURL: model.currentBaseURL,
                    reloadToken: model.reloadToken,
                    onLog: model.appendLog)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let error = model.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(1).truncationMode(.middle)
            } else {
                Text(model.statusText).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(model.executionPlan.summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// 実行結果 (サーバー実行の標準出力と、WebView からのログ)。
struct OutputPane: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("出力")
                    .font(.caption.bold())
                Spacer()
                Button("消去") { model.clearLog() }
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let output = model.executionOutput {
                        if !output.compileOutput.isEmpty {
                            section("コンパイル", text: output.compileOutput, color: .orange)
                        }
                        if !output.stdout.isEmpty {
                            section("標準出力", text: output.stdout, color: .primary)
                        }
                        if !output.stderr.isEmpty {
                            section("標準エラー", text: output.stderr, color: .red)
                        }
                        if output.isEmpty {
                            Text("(出力はありません)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(model.consoleLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("error") ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
                .padding(12)
            }
        }
    }

    private func section(_ title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


/// 内蔵コンパイラが吐いたバイトコードを見るための画面。
struct DisassemblyView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Text(text.isEmpty ? "まだコンパイルしていません。" : text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("バイトコード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
