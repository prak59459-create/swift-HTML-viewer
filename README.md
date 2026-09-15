# GitHub Viewer

GitHub のリンクを貼り付けると、その中身を **HTML として実行** したり、Markdown・ソースコード・画像として表示できる macOS アプリ (SwiftUI + WebKit) です。

![mode](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey) ![swift](https://img.shields.io/badge/Swift-5.9%2B-orange)

## できること

- **URL を貼るだけ** — `https://github.com/owner/repo/blob/main/index.html` のようなページ URL をそのまま入力できます。
- **HTML / SVG をその場で実行** — WKWebView で描画するので、CSS も JavaScript も動きます。
- **Markdown を整形表示** — 外部ライブラリなしの変換器で README を GitHub 風に表示します。
- **ソース / 画像表示** — その他のファイルはコードとして、画像ファイルはそのまま表示します。
- **表示方法の切り替え** — 「自動 / HTML として実行 / Markdown / ソース / 画像」を手動で選べます。Markdown を HTML として実行する、といった使い方も可能です。
- **その場で編集して再実行** — 「編集」でソースを書き換え、⌘R (実行) で反映されます。
- **JavaScript コンソール** — ページ内の `console.log` と実行時エラーをアプリ下部に表示します。
- **リポジトリを辿れる** — ディレクトリを開くとサイドバーにファイル一覧が出て、README は自動で開きます。
- **ブラウザで開く / GitHub で開く** — 表示中の内容を一時ファイルに書き出して既定のブラウザで開けます。

### 対応している入力形式

| 入力 | 動作 |
| --- | --- |
| `https://github.com/owner/repo` | デフォルトブランチのルートを一覧表示 |
| `https://github.com/owner/repo/blob/main/docs/index.html` | そのファイルを表示・実行 |
| `https://github.com/owner/repo/tree/main/docs` | そのフォルダを一覧表示 |
| `https://raw.githubusercontent.com/owner/repo/main/index.html` | そのファイルを表示・実行 |
| `https://gist.github.com/user/<gist id>` | Gist を表示 (複数ファイルなら一覧) |
| `owner/repo` / `owner/repo/path/to/file` | 省略形 |
| その他の `http(s)` URL | そのまま取得して表示 |

## 使い方

必要なもの: macOS 13 以降と Xcode 15 以降 (または Swift 5.9 以降のツールチェイン)。

```bash
git clone https://github.com/prak59459-create/swift-html-viewer.git
cd swift-html-viewer
swift run GitHubViewer
```

Xcode で開く場合は `Package.swift` をそのまま開き、`GitHubViewer` スキームを実行してください。

起動したらアドレス欄に GitHub の URL を入れて **開く** (または ⌘Return)。動作確認にはこのリポジトリのデモページが使えます。

```
https://github.com/prak59459-create/swift-html-viewer/blob/main/Examples/demo.html
```

### アクセストークン (任意)

未設定でも公開リポジトリは読めますが、GitHub API の未認証レート制限は 1 時間あたり 60 回です。鍵アイコンからトークンを入力するか、環境変数 `GITHUB_TOKEN` を設定しておくと制限が緩和され、プライベートリポジトリも開けます。

```bash
GITHUB_TOKEN=ghp_xxx swift run GitHubViewer
```

## 構成

```
Sources/
  GitHubViewerCore/     ロジック (macOS / Linux 共通・UI 非依存)
    GitHubTarget.swift        URL 解析 (github.com / raw / gist / 省略形)
    GitHubClient.swift        GitHub REST API からの取得
    ContentKind.swift         拡張子と中身からの表示種別判定
    MarkdownRenderer.swift    Markdown → HTML 変換
    HTMLDocumentBuilder.swift WebView に渡す HTML の組み立て
    DisplayMode.swift         表示モード
  GitHubViewer/         アプリ本体 (macOS 専用)
    GitHubViewerApp.swift     エントリポイント
    ContentView.swift         画面
    ViewerModel.swift         状態管理
    WebView.swift             WKWebView ラッパー (console ブリッジ付き)
Tests/GitHubViewerCoreTests/  ロジックのテスト
Examples/demo.html            動作確認用のデモページ
```

`GitHubViewerCore` は Foundation だけに依存しているので、Linux でもビルドとテストができます。

```bash
swift test
```

## 注意

- 開いた HTML の JavaScript はアプリ内の WebView で **実行されます**。信頼できないコードを実行しないでください。
- ブランチ名にスラッシュを含む URL (`blob/feature/foo/index.html` など) は、先頭の 1 要素をブランチ名として扱います。
- 1MB を超えるファイルは API が中身を返さないため、`raw.githubusercontent.com` から取得し直します。
