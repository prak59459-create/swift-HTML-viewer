# GitHub Viewer (iPad / iPhone)

GitHub のリンクを貼り付けると、その中身を **HTML として実行** したり、**Python や C などのプログラムとして実行** したり、Markdown・ソース・画像として表示できる iPadOS / iOS アプリです。

**iPad の Swift Playgrounds でそのまま開いて実行できる App Project (`.swiftpm`)** として作ってあります。Mac や Xcode は必要ありません。

![platform](https://img.shields.io/badge/platform-iPadOS%20%2F%20iOS%2016%2B-lightgrey) ![swift](https://img.shields.io/badge/Swift%20Playgrounds-4.4%2B-orange)

## 使い方 (iPad)

1. iPad に **Swift Playgrounds** (App Store) を入れる。
2. このリポジトリを iPad にダウンロードする。
   - Working Copy や a-Shell などの Git アプリでクローンするか、
   - GitHub の「Code → Download ZIP」から保存して「ファイル」App で展開する。
3. `GitHubViewer.swiftpm` を **Swift Playgrounds で開く** (タップするだけで開きます)。
4. 右上の ▶︎ で実行。
5. アドレス欄に GitHub の URL を入れて「開く」。

Mac の Xcode で開く場合も `GitHubViewer.swiftpm` をそのまま開けます (iOS シミュレータ / iPad 実機向け)。

動作確認にはこのリポジトリの例が使えます。

```
https://github.com/prak59459-create/swift-html-viewer/tree/main/Examples
```

| 例 | 実行方法 |
| --- | --- |
| `Examples/demo.html` | WebView でそのまま実行 (JavaScript も動く) |
| `Examples/demo.py` | Pyodide (端末内) |
| `Examples/demo.sql` | sql.js / SQLite (端末内) |
| `Examples/demo.c` | 実行サービスでコンパイル (設定で許可が必要) |

## できること

- **URL を貼るだけ** — `https://github.com/owner/repo/blob/main/index.html` のようなページ URL をそのまま入力できます。
- **HTML / SVG をその場で実行** — WKWebView で描画するので CSS も JavaScript も動きます。
- **他の言語も実行** — 拡張子から言語を判定し、端末内のランタイムか実行サービスで動かします (下表)。
- **Markdown を整形表示 / ソース・画像表示** — README は GitHub 風に、画像はそのまま表示します。
- **表示方法の切り替え** — 「自動 / HTML として実行 / Markdown / ソース / 画像」を手動で選べます。
- **その場で編集して再実行** — 「編集」でソースを書き換え、「実行」(⌘R) で反映されます。
- **出力ペイン** — 標準出力・標準エラー・コンパイルエラー・`console.log` をまとめて表示します。
- **リポジトリを辿れる** — ディレクトリを開くとサイドバーにファイル一覧が出て、README は自動で開きます。

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

## 対応言語と実行方法

iPadOS ではネイティブのコンパイラをアプリに同梱できない (実行時のコード生成が許可されていない) ため、次の 2 通りで実行します。

### 1. 端末内で実行 — コードは外に出ません

WebView に WebAssembly / JavaScript 実装のランタイムを読み込んで実行します (読み込みのためのネットワークは必要)。

| 言語 | ランタイム |
| --- | --- |
| JavaScript | WebView そのまま |
| TypeScript | TypeScript コンパイラでトランスパイルしてから実行 |
| Python | Pyodide (CPython の WebAssembly ビルド) |
| Ruby | ruby.wasm |
| Lua | Fengari |
| SQL | sql.js (SQLite の WebAssembly ビルド) |

### 2. 実行サービスでコンパイル・実行 — 設定で許可したときだけ

C / C++ / Objective-C / Swift / Java / Kotlin / C# / Go / Rust / PHP / Perl / Shell / Haskell / Scala / Dart / Elixir / Erlang / Nim / Zig / Pascal / D / R / Julia / OCaml / Crystal / Groovy / Lisp

- 既定は **Wandbox** (`https://wandbox.org/api`) で、登録不要で使えます。
- **Piston** も選べます。公開インスタンス (`emkc.org`) は 2026 年 2 月からホワイトリスト制なので、[自分で立てた Piston](https://github.com/engineer-man/piston) の URL を設定で指定してください。
- どちらも **ソースコードを外部サービスに送信します**。設定の「サーバーでのコンパイル・実行を許可」を ON にしたときだけ動きます (既定は OFF)。
- 実行サービス側の障害やメンテナンスで失敗することがあります。そのときは出力ペインにサービスからのエラーがそのまま出ます。

言語は拡張子から自動判定しますが、ツールバーのメニューで手動指定もできます (例: 拡張子なしのファイルを Python として実行)。

### アクセストークン (任意)

未設定でも公開リポジトリは読めますが、GitHub API の未認証レート制限は 1 時間あたり 60 回です。設定画面でトークンを入れると制限が緩和され、プライベートリポジトリも開けます。

## 構成

```
GitHubViewer.swiftpm/        ← Swift Playgrounds で開く App Project
  Package.swift              iOS アプリとしての定義 (.iOSApplication)
  App/                       画面まわり (SwiftUI + WebKit, iPadOS / iOS 専用)
    GitHubViewerApp.swift      エントリポイント
    ContentView.swift          メイン画面と出力ペイン
    SettingsView.swift         トークン / 実行サービスの設定
    ViewerModel.swift          状態管理
    WebView.swift              WKWebView ラッパー (console ブリッジ付き)
  Core/                      ロジック (UI 非依存)
    GitHubTarget.swift         URL 解析 (github.com / raw / gist / 省略形)
    GitHubClient.swift         GitHub REST API からの取得
    ContentKind.swift          拡張子と中身からの表示種別判定
    LanguageCatalog.swift      言語カタログと実行方法の決定
    SandboxPageBuilder.swift   端末内実行用の HTML ページ生成
    CodeRunner.swift           実行サービス (Wandbox / Piston) クライアント
    MarkdownRenderer.swift     Markdown → HTML 変換
    HTMLDocumentBuilder.swift  WebView に渡す HTML の組み立て
    DisplayMode.swift          表示モード
    HTTP.swift                 URLSession の薄いラッパー
Package.swift                ← Core を macOS / Linux でテストするためのマニフェスト
Tests/GitHubViewerCoreTests/ Core のテスト
Examples/                    動作確認用のサンプル
```

`Core` は Foundation だけに依存しているので、Mac や Linux でテストできます。

```bash
swift test    # 38 tests
```

## 注意

- 開いた HTML / JavaScript はアプリ内の WebView で **実行されます**。信頼できないコードを実行しないでください。
- 端末内ランタイム (Pyodide など) は CDN (jsdelivr) から読み込むため、初回はダウンロードに時間がかかります (Ruby は約 16MB、Python は数十 MB)。
- ブランチ名にスラッシュを含む URL (`blob/feature/foo/index.html` など) は、先頭の 1 要素をブランチ名として扱います。
- 1MB を超えるファイルは API が中身を返さないため、`raw.githubusercontent.com` から取得し直します。
