# MiniPHP — アプリに内蔵した PHP インタプリタ

PHP は動的型付けなので、C のようにバイトコードにせず **構文木をそのままたどって実行する** 方式にしました。
外部のサービスもネットワークも使わず、端末の中だけで完結します。

実装は `GitHubViewer.swiftpm/Core/MiniPHP/` にあります。

## パイプライン

```
ソース
  ↓ PHPLexer.swift        字句解析 (<?php の外はインライン HTML として扱う)
  ↓ PHPParser.swift       再帰下降構文解析 → AST (PHPAST.swift)
  ↓ PHPInterpreter.swift  構文木をたどって実行 (スコープ・クラス・クロージャ)
出力・終了コード
```

値は `PHPValue.swift`、演算子の意味 (型ジャグリング) は `PHPOperations.swift`、
標準関数は `PHPBuiltins.swift`、`sprintf` / `var_dump` / `print_r` / `json_encode` の書式は
`PHPFormatter.swift` にあります。

```swift
let execution = MiniPHP.execute(source: source, input: stdin)
execution.output          // 出力 (インライン HTML を含む)
execution.runtimeError    // 実行時エラー
execution.diagnosticsText // 構文エラー (行・桁・キャレット付き)
```

## 対応している PHP

**値と型**
`null` / `bool` / `int` / `float` / `string` / 配列 / オブジェクト / クロージャ。
配列は **順序を保つ連想配列** で、PHP と同じく代入するとコピーされます (オブジェクトは参照)。
型ジャグリング (`"10" + 5`、`"abc" == 0`、`1 <=> 2`、`===`) は PHP 8 の規則に合わせています。

**構文**
`<?php ... ?>` とインライン HTML、`<?= ?>`、`echo` / `print`、変数展開 (`"$name"`, `"{$a['k']}"`,
`"$obj->prop"`)、ヒアドキュメント以外の文字列、`if` / `elseif` / `else` (代替構文 `:` ... `endif;` も)、
`while` / `do-while` / `for` / `foreach` (キー付き・参照付き)、`switch`、`break n` / `continue n`、
`function` (既定引数・可変長引数 `...$args`・参照渡し `&$x`)、無名関数と `use`、アロー関数 `fn() =>`、
`class` / `extends` / `parent::` / `self::` / `static::` (遅延静的束縛) / `const` / `new` / `instanceof` /
`$this`、`global`、`unset`、`isset` / `empty`、`??` / `??=` / `?:`、`**` (右結合)、型宣言 (読み飛ばし)。

**標準関数** (150 以上)
文字列: `strlen` `substr` `strpos` `str_replace` `str_repeat` `str_pad` `str_split` `explode` `implode`
`trim` 系 `strtoupper` `strtolower` `ucfirst` `ucwords` `strrev` `sprintf` `printf` `number_format`
`str_contains` `str_starts_with` `wordwrap` `htmlspecialchars` `ord` `chr` `dechex` など。

配列: `count` `array_keys` `array_values` `array_merge` `array_slice` `array_map` `array_filter`
`array_reduce` `array_search` `in_array` `array_unique` `array_flip` `array_combine` `array_column`
`array_diff` `array_intersect` `array_chunk` `array_push/pop/shift/unshift` `range` `sort` `rsort`
`usort` `uasort` `uksort` `ksort` `krsort` `asort` `arsort` `end` `reset` など。

その他: `var_dump` `print_r` `var_export` `json_encode` `is_*` `gettype` `intval` `floatval`
`max` `min` `abs` `round` `floor` `ceil` `sqrt` `pow` `intdiv` `fmod` 三角関数 `call_user_func`
`function_exists` `class_exists` `method_exists` `fgets` (標準入力) など。

## 安全装置

実行の手数、出力サイズ、再帰の深さに上限があり、無限ループや暴走する再帰でもアプリが固まりません。
深い再帰でも落ちないよう、スタックを大きく取った専用スレッドで実行します。

## テスト

- `Tests/GitHubViewerCoreTests/MiniPHPTests.swift` — 言語機能・エラー処理の単体テスト 16 件。
- `Tests/GitHubViewerCoreTests/PHPComparisonTests.swift` — **本物の PHP との差分テスト**。
  `Examples/php/` の 16 本を内蔵インタプリタで実行し、`php` 8.4 で同じソースを実行した出力と
  1 バイトも違わないことを確認します。

16 本には、文字列処理、配列とソート、クラスと継承、クロージャとアロー関数、参照渡し、
インライン HTML のテンプレート、`var_dump` / `print_r` / `json_encode` の書式、
数値の意味 (整数除算・浮動小数点の表示・緩い比較) などが入っています。

## まだできないこと

- ヒアドキュメント (`<<<EOT`)、名前空間、トレイト、インターフェイスの実体、抽象クラスの強制
- 例外 (`try` / `catch` / `throw`)、ジェネレータ (`yield`)、`match` 式
- 静的プロパティ (`static $x`)、マジックメソッド (`__get` など。`__construct` のみ対応)
- 正規表現 (`preg_*`)、ファイル入出力、データベース、日付関数
- 参照 (`&`) の完全な意味論 (関数の引数と `foreach` では対応)
