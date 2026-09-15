import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ViewerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub アクセストークン") {
                    SecureField("ghp_…", text: $model.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("未入力でも公開リポジトリは表示できます。入力すると API のレート制限が緩和され、プライベートリポジトリも開けます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("サーバー実行 (コンパイラ)") {
                    Toggle("サーバーでのコンパイル・実行を許可", isOn: $model.allowsRemoteExecution)
                    Picker("実行サービス", selection: $model.executionBackend) {
                        ForEach(ExecutionBackend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    if model.executionBackend == .piston {
                        TextField("https://…/api/v2/piston", text: $model.pistonEndpointText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.system(.footnote, design: .monospaced))
                        Text("公開 Piston API は 2026 年からホワイトリスト制です。Docker で自分のインスタンスを立て、その URL を指定してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("""
                    C / C++ / Java / Go / Rust / Swift などブラウザ内で動かせない言語は、\
                    ソースコードを実行サービスに送ってコンパイル・実行します。\
                    コードが外部に送信される点に注意してください (端末内で動く言語は送信しません)。
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("標準入力 (stdin)") {
                    TextEditor(text: $model.stdin)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(height: 100)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("サーバー実行のときにプログラムへ渡します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("端末内で実行できる言語") {
                    ForEach(LanguageCatalog.all.filter { $0.local != nil }) { language in
                        LabeledContent(language.name, value: language.local?.displayName ?? "")
                            .font(.caption)
                    }
                }

                Section("サーバー実行に対応している言語") {
                    Text(LanguageCatalog.all.filter { $0.local == nil }.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
