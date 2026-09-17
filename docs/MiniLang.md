# MiniLang — 26 言語ぶんの処理系を支える共通基盤

`GitHubViewer.swiftpm/Core/MiniLang/` は、26 言語の内蔵処理系が共有している土台です。
言語ごとに一から処理系を書くのではなく、**値・中間表現・評価器・標準ライブラリを 1 本にまとめ、
違うところだけを差し替える**つくりにしてあります。

```
ソース
  ↓ 字句解析      MLProfileLexer (言語ごとの表 = MLLanguageProfile)
字句の並び
  ↓ 構文解析      MLProfileParser / MLEndBlockParser / MLIndentParser を継承した各言語の構文解析
中間表現 (MLIR)
  ↓ 評価          MLInterpreter + MLSemantics (言語ごとの味付け) + MLStdlib
出力
```

## 部品

| ファイル | 役割 |
| --- | --- |
| `MLValue.swift` | 値モデル。整数・小数・文字・文字列・配列・辞書・タプル・オブジェクト・関数・範囲・記号 |
| `MLIR.swift` | 共通の中間表現。式 (`MLExpr`)・文 (`MLStmt`)・パターン (`MLPattern`)・宣言 |
| `MLRuntime.swift` | 実行時の器。環境 (`MLEnvironment`)・関数 (`MLFunction`)・クラス (`MLClass`)・エラー |
| `MLInterpreter.swift` | 評価器。スコープ・呼び出し・パターン照合・例外・実行制限 |
| `MLSemantics.swift` | 言語ごとの味付けを差し込む口 (下記) |
| `MLStdlib.swift` | 共通の標準ライブラリ (文字列・配列・辞書・数学・`printf` 系) |
| `MLOperations.swift` | 算術・比較・反復の共通処理 |
| `MLLexing.swift` | 字句解析と構文解析の土台 (字句の型・読み進め・先読み) |
| `MLLanguageProfile.swift` | 「言語の見た目」を表にしたもの + それに従う汎用の字句解析 |
| `MLProfileParser.swift` | 中括弧の言語のための汎用構文解析 (継承して差分だけ書く) |
| `MLEndBlockParser.swift` | `end` でブロックを閉じる言語向け (Julia・Crystal・Elixir・Pascal) |
| `MLIndentParser.swift` | 字下げでブロックを表す言語向け (Nim・Haskell) |
| `MLNumberFormatting.swift` | 言語ごとに違う小数の書き方 (Java 風・JS 風・Go 風…) |
| `MiniLangRegistry.swift` | 言語 ID → 処理系の対応表 |

## 言語ごとに書くもの

1 つの言語につき、だいたい次の 4 つを書きます。

1. **プロファイル** — コメントの書き方、文字列の書き方、予約語、演算子、
   関数・変数・型の宣言キーワードなど。`MLLanguageProfile` に表として書きます。
2. **字句解析** — プロファイルで足りない部分だけ `MLProfileLexer` を継承して足します
   (Perl の `$変数`、Elixir の `:アトム`、Nim の `` `演算子` `` など)。
3. **構文解析** — 3 種類の土台のどれかを継承し、その言語だけの構文を書きます
   (Go の多値 return、Rust の `impl`、Haskell のガードなど)。
4. **意味論と標準ライブラリ** — `MLSemantics` を継承して、真偽の決まり方・表示の書式・
   演算子の意味・組み込み関数を与えます。

## `MLSemantics` で差し替えられること

評価器は 1 本ですが、次のような「言語ごとの常識」はここで切り替えます。

- 添字の起点 (0 か 1 か)、負の添字が末尾を指すか、範囲外がエラーか
- 整数の割り算の丸め方、`/` が常に小数を返すか
- 真偽の決まり方 (`0` が偽か、空文字が偽か、`nil` だけが偽か)
- `print` したときの書式、入れ子にしたときの書式、小数の書き方
- 言語独自の演算子 (`.` の連結、`++` のリスト結合、`<=>`、`div`/`mod` など)
- メンバーアクセスの決まり (Ruby 風の括弧なし呼び出し、Nim の UFCS など)
- 多重定義を引数の型で選ぶか、列挙のケースを型名なしで書けるか
- 部分適用 (カリー化) するか

## 実行時の安全装置

内蔵処理系は iPad の中で動くので、暴走してもアプリが固まらないようにしてあります。

- 実行ステップ数の上限 (既定 500 万)
- 出力の上限 (既定 1MB)
- 関数呼び出しの深さの上限 (既定 400)
- 深い再帰でも落ちないよう、32MB のスタックを持つ専用スレッドで実行

## 言語ごとの土台

| 土台 | 言語 |
| --- | --- |
| `MLProfileParser` (中括弧) | C++ / Objective-C / Java / C# / Kotlin / Scala / Go / Rust / D / Zig / Dart / Groovy / JavaScript / TypeScript / Perl / R |
| `MLEndBlockParser` (`end`) | Julia / Crystal / Elixir / Pascal |
| `MLIndentParser` (字下げ) | Nim / Haskell |
| 専用の構文解析 | Erlang (`;` で区切る節) / OCaml (並べ書きの適用) / Lisp (S 式) / シェル (単語) |

## 動かし方 (開発用)

```bash
swift run minilang --list            # 使える言語 ID
swift run minilang haskell main.hs   # 内蔵 Haskell 処理系で実行
swift test                           # 差分テストを含む全テスト
```

`Examples/<言語>/basics.*` と `Examples/<言語>/expected/basics.expected` が差分テストの題材です。
本物の処理系が手に入る言語はその出力を期待値にしていて、手に入らない言語は
内蔵処理系の出力を固定して後戻りを防いでいます。
