# GitHub Viewer (iPad / iPhone)

GitHub のリンクを貼り付けると、その中身を **HTML として実行** したり、**C や Python のプログラムとして実行** したり、Markdown・ソース・画像として表示できる iPadOS / iOS アプリです。

**C コンパイラと PHP インタプリタは自作のものをアプリに内蔵しています。** サーバーにも外部サービスにも頼らず、iPad の中だけで動きます。

- C: 字句解析 → 構文解析 → 型検査 → バイトコード生成 → 仮想マシン → [docs/MiniC.md](docs/MiniC.md)
- PHP: 字句解析 → 構文解析 → AST インタプリタ → [docs/MiniPHP.md](docs/MiniPHP.md)

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
| `Examples/demo.c` | **内蔵 C コンパイラ** (端末内、設定不要) |
| `Examples/c/*.c` | 内蔵 C コンパイラ (GCC と出力を突き合わせた 40 本) |
| `Examples/php/*.php` | 内蔵 PHP インタプリタ (PHP 8.4 と出力を突き合わせた 16 本) |

## できること

- **URL を貼るだけ** — `https://github.com/owner/repo/blob/main/index.html` のようなページ URL をそのまま入力できます。
- **HTML / SVG をその場で実行** — WKWebView で描画するので CSS も JavaScript も動きます。
- **他の言語も実行** — 拡張子から言語を判定し、内蔵の C コンパイラ・WebView のランタイム・実行サービスのいずれかで動かします (下表)。
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

iPadOS ではネイティブのコンパイラを同梱できない (実行時のコード生成が許可されていない) ため、次の 3 通りで実行します。

### 1. 内蔵コンパイラで実行 — ネットワークすら使いません

| 言語 | 実装 |
| --- | --- |
| C | 自作のコンパイラ + バイトコード仮想マシン ([docs/MiniC.md](docs/MiniC.md)) |
| PHP | 自作のインタプリタ ([docs/MiniPHP.md](docs/MiniPHP.md)) |

**C** は C99 の実用的な部分をほぼ網羅しています (構造体・共用体・ポインタ・多次元配列・関数ポインタ・
`goto`・可変長引数・`static` ローカル・構造体の値返し・`malloc`・`printf`・`qsort` など)。
ツールバーの「逆アセンブル」で、生成されたバイトコードも読めます。

**PHP** は変数・配列 (順序つき連想配列)・関数・クロージャ・クラスと継承・`foreach`・文字列の変数展開・
インライン HTML (`<?php ... ?>` と `<?= ?>`) に対応し、標準関数を 150 以上用意しています。
HTML を出力する PHP は、その結果をそのままページとして表示します。

どちらもコンパイル・構文エラーは行と桁つきで、実行時エラー (NULL 参照、0 除算、無限ループ、深すぎる再帰) も
安全に止めて報告します。

### 2. WebView のランタイムで実行 — コードは外に出ません

WebView に WebAssembly / JavaScript 実装のランタイムを読み込んで実行します (読み込みのためのネットワークは必要)。

| 言語 | ランタイム |
| --- | --- |
| JavaScript | WebView そのまま |
| TypeScript | TypeScript コンパイラでトランスパイルしてから実行 |
| Python | Pyodide (CPython の WebAssembly ビルド) |
| Ruby | ruby.wasm |
| Lua | Fengari |
| SQL | sql.js (SQLite の WebAssembly ビルド) |

### 3. 実行サービスでコンパイル・実行 — 設定で許可したときだけ

C++ / Objective-C / Swift / Java / Kotlin / C# / Go / Rust / Perl / Shell / Haskell / Scala / Dart / Elixir / Erlang / Nim / Zig / Pascal / D / R / Julia / OCaml / Crystal / Groovy / Lisp (C もここから選べます)

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
    MiniPHP/                   自作の PHP インタプリタ
      PHPLexer.swift             字句解析 (インライン HTML も)
      PHPParser.swift            構文解析
      PHPAST.swift               構文木
      PHPValue.swift             値と順序つき配列・型変換
      PHPOperations.swift        演算子の意味 (型ジャグリング)
      PHPInterpreter.swift       実行 (スコープ・クラス・クロージャ)
      PHPBuiltins.swift          標準関数
      PHPFormatter.swift         sprintf / var_dump / print_r / json_encode
      MiniPHP.swift              窓口
    MiniC/                     自作の C コンパイラと仮想マシン
      Lexer.swift                字句解析
      Preprocessor.swift         #define / #ifdef
      Parser.swift               構文解析 (再帰下降)
      AST.swift / CType.swift    構文木と型
      Compiler.swift             型検査 + バイトコード生成
      Bytecode.swift             命令セットと逆アセンブラ
      VM.swift                   スタックマシン (メモリ・malloc・実行制限)
      Builtins.swift             printf などの標準ライブラリ
      Diagnostics.swift          エラー表示 (行・桁・キャレット)
      MiniC.swift                窓口 (compile / execute / disassemble)
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
Tests/GitHubViewerCoreTests/ Core のテスト (129 件)
Examples/                    動作確認用のサンプル
  c/                         C のサンプル 40 本 + GCC で作った期待出力
  php/                       PHP のサンプル 16 本 + PHP 8.4 で作った期待出力
docs/MiniC.md                内蔵 C コンパイラの説明
docs/MiniPHP.md              内蔵 PHP インタプリタの説明
```

`Core` は Foundation だけに依存しているので、Mac や Linux でテストできます。

```bash
swift test    # 129 tests
```

テストには **本物の処理系との差分テスト**が含まれます。`Examples/c/` の 40 本を内蔵コンパイラで、
`Examples/php/` の 16 本を内蔵インタプリタで実行し、同じソースを `gcc -std=c99` および `php` (8.4) で
実行した出力と 1 バイトも違わないことを確認しています。

## 注意

- 開いた HTML / JavaScript はアプリ内の WebView で **実行されます**。信頼できないコードを実行しないでください。
- 内蔵 C コンパイラはネットワークを使いませんが、Pyodide などの WebView ランタイムは CDN (jsdelivr) から読み込むため、初回はダウンロードに時間がかかります (Ruby は約 16MB、Python は数十 MB)。
- 内蔵 C コンパイラが対応していない機能 (ビットフィールド、VLA、ファイル入出力など) は [docs/MiniC.md](docs/MiniC.md) にまとめてあります。
- ブランチ名にスラッシュを含む URL (`blob/feature/foo/index.html` など) は、先頭の 1 要素をブランチ名として扱います。
- 1MB を超えるファイルは API が中身を返さないため、`raw.githubusercontent.com` から取得し直します。
