import AppKit
import GitHubViewerCore
import SwiftUI

struct ContentView: View {
    @StateObject private var model = ViewerModel()
    @State private var showsSettings = false
    @State private var showsConsole = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    // MARK: - サイドバー (ディレクトリ一覧)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let listing = model.listing {
                List {
                    if model.parentEntryTitle != nil {
                        Button {
                            model.goUp()
                        } label: {
                            Label("上のフォルダへ", systemImage: "arrow.turn.left.up")
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(listing.entries) { entry in
                        Button {
                            model.openEntry(entry)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: entry.isDirectory ? "folder" : icon(for: entry.name))
                                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                                Text(entry.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                Text(listing.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ファイル一覧")
                        .font(.headline)
                    Text("リポジトリやフォルダの URL を開くと、ここに中身が並びます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            }
        }
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm", "svg": return "chevron.left.forwardslash.chevron.right"
        case "md", "markdown": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        default: return "doc.text"
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
            if showsConsole {
                Divider()
                console
            }
            Divider()
            statusBar
        }
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("前の場所に戻る")

            Button { model.goUp() } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(model.parentEntryTitle == nil)
            .help("上のフォルダへ")

            TextField("https://github.com/owner/repo/blob/main/index.html", text: $model.urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.openFromInput() }

            Button("開く") { model.openFromInput() }
                .keyboardShortcut(.return, modifiers: [.command])

            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("再読み込み")

            Button {
                showsSettings.toggle()
            } label: {
                Image(systemName: "key")
            }
            .help("アクセストークンの設定")
            .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                settings
            }
        }
        .padding(8)
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Picker("表示", selection: $model.mode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 210)

            Toggle(isOn: $model.isEditing) {
                Label("編集", systemImage: "square.and.pencil")
            }
            .toggleStyle(.button)
            .disabled(model.file?.kind.isTextual != true)

            Button {
                model.run()
                if model.resolvedMode == .web { showsConsole = true }
            } label: {
                Label("実行", systemImage: "play.fill")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(model.file == nil)

            Toggle(isOn: $showsConsole) {
                Label("コンソール", systemImage: "terminal")
            }
            .toggleStyle(.button)

            Spacer()

            Button {
                if let url = model.exportHTMLToTemporaryFile() { NSWorkspace.shared.open(url) }
            } label: {
                Label("ブラウザで開く", systemImage: "safari")
            }
            .disabled(model.renderedHTML.isEmpty)

            Button {
                if let url = model.githubPageURL { NSWorkspace.shared.open(url) }
            } label: {
                Label("GitHub", systemImage: "link")
            }
            .disabled(model.githubPageURL == nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var contentArea: some View {
        ZStack {
            if model.isEditing, model.file?.kind.isTextual == true {
                HSplitView {
                    editor
                        .frame(minWidth: 260)
                    preview
                        .frame(minWidth: 320)
                }
            } else {
                preview
            }

            if model.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ソース (編集して「実行」で反映)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(6)
            Divider()
            TextEditor(text: $model.source)
                .font(.system(.body, design: .monospaced))
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let file = model.file, model.resolvedMode == .image {
            if let image = NSImage(data: file.data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                }
            } else {
                placeholder("この画像は表示できませんでした。")
            }
        } else if model.renderedHTML.isEmpty {
            placeholder("GitHub の URL を入力すると、HTML はそのまま実行、Markdown は整形、\nそれ以外はソースとして表示します。")
        } else {
            WebView(html: model.renderedHTML,
                    baseURL: model.currentBaseURL,
                    reloadToken: model.reloadToken,
                    onLog: model.appendLog)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("コンソール")
                    .font(.caption.bold())
                Spacer()
                Button("消去") { model.clearLog() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.consoleLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("error") ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
        }
        .frame(height: 140)
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
            Text(model.resolvedMode.title)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub アクセストークン")
                .font(.headline)
            Text("未入力でも公開リポジトリは表示できます。入力するとレート制限が緩和され、\nプライベートリポジトリも開けます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("ghp_…", text: $model.token)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            Text("環境変数 GITHUB_TOKEN があれば起動時に読み込みます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
