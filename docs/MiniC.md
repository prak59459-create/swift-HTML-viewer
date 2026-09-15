# MiniC — アプリに内蔵した C コンパイラ

iPadOS ではネイティブコードをその場で生成して実行することが許可されていません。
そこで **C のソースをバイトコードにコンパイルし、Swift で書いた仮想マシンで実行する** 方式にしました。
外部サービスもネットワークも使わず、端末の中だけで完結します。

実装は `GitHubViewer.swiftpm/Core/MiniC/` にあります (Swift 5,170 行)。

## パイプライン

```
ソース
  ↓ Lexer.swift          字句解析 (トークン + 行・桁)
  ↓ Preprocessor.swift   #define / #ifdef / #include の処理
  ↓ Parser.swift         再帰下降構文解析 → AST (AST.swift)
  ↓ Compiler.swift       スコープ解決・型検査・バイトコード生成 (1 パス)
  ↓ Bytecode.swift       命令列 + 行番号表 + 関数表 + 静的データ
  ↓ VM.swift             スタックマシンで実行 (Builtins.swift が標準ライブラリ)
出力・終了コード
```

窓口は `MiniC.swift`:

```swift
let execution = MiniC.execute(source: source, input: stdin)
execution.output          // 標準出力
execution.exitCode        // main の戻り値
execution.diagnosticsText // エラー・警告 (行とキャレット付き)
execution.runtimeError    // 実行時エラー (0 除算など)

let text = try MiniC.disassemble(source: source)  // バイトコードを読む
```

## 対応している C

**型**
`void` / `char` / `unsigned char` / `int` / `unsigned int` / `long` / `unsigned long` /
`float`・`double` (どちらも倍精度) / ポインタ / 配列 (多次元) / `struct` / `enum` / `typedef`。
`signed`・`const`・`volatile`・`static`・`extern` は解析して受け流します。

**宣言**
グローバル変数 (定数式で初期化、`{...}` と文字列リテラルに対応)、ブロック内のどこでも書けるローカル変数、
関数のプロトタイプと定義、相互再帰、`struct` の前方参照 (`struct Node { struct Node *next; }`)。

**文**
`if` / `else` / `while` / `do-while` / `for` (初期化に宣言を書ける) / `switch`・`case`・`default`
(フォールスルーあり) / `break` / `continue` / `return` / ブロック。

**式**
C の優先順位をそのまま実装しています。代入と複合代入 (`+= -= *= /= %= &= |= ^= <<= >>=`)、
三項演算子、論理演算の短絡評価、ビット演算、インクリメント・デクリメント (前置・後置)、
`sizeof` (型・式)、キャスト、カンマ演算子、配列添字、`.` と `->`、関数呼び出し、
ポインタ演算 (`p + n` の要素サイズ倍、`p - q` の要素数)、文字列リテラルの連結。

**プリプロセッサ**
`#include` (標準ヘッダ前提で読み飛ばし)、`#define` (オブジェクト形式・関数形式)、`#undef`、
`#ifdef` / `#ifndef` / `#if` / `#elif` / `#else` / `#endif`、`#error`、`#pragma`。

**標準ライブラリ** (`Builtins.swift`)
`printf` `puts` `putchar` `getchar` `scanf`
`strlen` `strcmp` `strncmp` `strcpy` `strncpy` `strcat` `strchr`
`memset` `memcpy` `memmove`
`malloc` `calloc` `realloc` `free`
`abs` `labs` `atoi` `atof` `exit` `rand` `srand` `time`
`sqrt` `pow` `fabs` `floor` `ceil` `round` `fmod` `sin` `cos` `tan` `atan` `atan2` `log` `log10` `exp`

`printf` はフラグ (`- 0 + 空白 #`)、幅、精度、`*`、長さ修飾子、
`d i u x X o c s f e g p %` に対応しています。

## 実行モデル

- **メモリ**は 1 本のバイト配列で、先頭 8 バイトを NULL 用に予約し、
  静的領域 (グローバル変数と文字列リテラル) → ヒープ → スタックの順に並びます。
  ポインタはこの配列の添字なので、`&x`、ポインタ演算、`memcpy` がそのまま自然に動きます。
- **フレーム**は呼び出しごとにスタック領域へ確保します。ローカル変数はメモリ上にあるので
  `&local` が取れます。構造体の引数は呼び出し側がアドレスを積み、VM が値をコピーします。
- **`malloc`** はヘッダ 16 バイト + 空きリストの first-fit で、解放時に隣接ブロックを併合します。
  二重 `free` と不正なポインタは実行時エラーにします。
- **安全装置**: NULL 参照、範囲外アクセス、0 除算、スタックあふれ、再帰の深さ、
  命令数の上限 (既定 2,000 万)、出力サイズの上限。
  いずれも「何行目の何が悪いか」を日本語で返します (無限ループでアプリが固まりません)。

命令は 40 種類ほどのスタックマシン命令です。`square(int n) { return n * n; }` はこうなります。

```
square:  ; フレーム 4 バイト, 引数 1 個
    0 |   2| local     fp+0
    1 |   2| load.4
    2 |   2| local     fp+0
    3 |   2| load.4
    4 |   2| mul.i
    5 |   2| trunc.4     ← int の 32 ビット幅に合わせる
    6 |   2| ret
```

`trunc.4` があるので、`int` のオーバーフローも C と同じように折り返します。

## テスト

- `Tests/GitHubViewerCoreTests/MiniCTests.swift` — 言語機能・エラー処理の単体テスト 61 件。
- `Tests/GitHubViewerCoreTests/GCCComparisonTests.swift` — **GCC との差分テスト**。
  `Examples/c/` の 30 本のプログラムを内蔵コンパイラで実行し、
  `Examples/c/expected/` に置いた期待出力と 1 バイトも違わないことを確認します。
  期待出力は同じソースを `gcc -std=c99` (GCC 13.3) でコンパイル・実行して作りました。

30 本には、カエサル暗号、構造体の整列、二分探索、ビット演算、ニュートン法、キュー、
素因数分解、行列式、連結リストの反転、ハッシュ関数 (`unsigned long`)、アッカーマン関数、
`printf` の書式尽くし、再帰下降の電卓などが入っています。

```bash
swift test    # 102 tests
```

## まだできないこと

- `goto` とラベル
- 関数ポインタ、可変長引数を持つユーザー定義関数
- 構造体を戻り値にする関数 (引数として渡すのは可)
- `union`、ビットフィールド、`long double`、複素数
- 複数ファイルのコンパイルとリンク (1 ファイル単位)
- `#include` した実際のヘッダの読み込み (標準関数は組み込みで代用)

`goto`、関数ポインタ、構造体を返す関数、`union` は、黙って誤動作させずコンパイルエラーとして報告します。
`float` と `long double` は `double` として扱います。
