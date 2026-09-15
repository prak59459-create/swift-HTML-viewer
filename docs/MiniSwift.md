# MiniSwift — アプリに内蔵した Swift インタプリタ

Swift のサブセットを、**構文木をそのままたどって実行する**インタプリタです。
外部のサービスもネットワークも使わず、端末の中だけで完結します。

実装は `GitHubViewer.swiftpm/Core/MiniSwift/` にあります。

## パイプライン

```
ソース
  ↓ SwiftLexer.swift        字句解析 (文字列補間 \(...) もここで切り出す)
  ↓ SwiftParser.swift       再帰下降構文解析 → AST (SwiftAST.swift)
  ↓ SwiftInterpreter.swift  構文木をたどって実行 (スコープ・型・クロージャ)
出力
```

値は `SwiftValue.swift`、演算子は `SwiftOperations.swift`、標準ライブラリは
`SwiftBuiltins.swift` にあります。

```swift
let execution = MiniSwift.execute(source: source, input: stdin)
execution.output          // print の出力
execution.runtimeError    // 実行時エラー
execution.diagnosticsText // 構文エラー (行・桁・キャレット付き)
```

## 対応している Swift

**値と型**
`Int` / `Double` / `String` / `Character` / `Bool` / 配列 / 辞書 / タプル / 範囲 / オプショナル /
構造体 / クラス / 列挙型 / クロージャ。
**構造体は値型、クラスは参照型**という Swift の意味論を再現しています。
`print` の表示も Swift と同じ書き方 (`1.0`、`[1, 2]`、`["a"]`、`nil`、`Point(x: 1, y: 2)`) です。

**構文**
`let` / `var` (型注釈と型変換つき)、文字列補間、複数行文字列、
`if` / `else if` / `else`、`if let`、`guard let ... else`、`while`、`while let`、`repeat-while`、
`for ... in` (範囲・配列・辞書・`enumerated()`・タプル分解・`where`)、
`switch` (値・範囲・`.case`・`let` 束縛・`where`・`default`)、`break` / `continue` / `return`、
`func` (引数ラベル・既定値・可変長引数 `...`・`inout`・戻り値の型)、
クロージャ (`{ $0 * 2 }`、`{ (x: Int) -> Int in ... }`、末尾クロージャ、**参照でのキャプチャ**)、
`struct` (メンバーワイズ初期化・`mutating`・計算プロパティ)、
`class` (継承・`override`・`super.init`・`self`)、
`enum` (raw 値・`rawValue`・`init(rawValue:)`・メソッド)、
`??`、`?.`、`!`、三項演算子、`is` / `as?` / `as!`、`&` (inout 引数)、演算子の関数渡し (`reduce(0, +)`)。

**標準ライブラリ**
`print` (`separator:` / `terminator:`)、`abs` `min` `max` `sqrt` `pow` `floor` `ceil` `round`
`Int()` `Double()` `String()` `Bool()` `Character()` `Array(repeating:count:)` `zip` `stride` `readLine`。

String: `count` `isEmpty` `uppercased` `lowercased` `hasPrefix` `hasSuffix` `contains` `split`
`replacingOccurrences` `trimmingCharacters` `prefix` `suffix` `dropFirst` `dropLast` `reversed`
`first` `last` `joined` `components` など。

Array: `count` `isEmpty` `append` `insert` `remove` `removeLast` `removeFirst` `contains`
`firstIndex` `sorted` `sort` `reversed` `map` `compactMap` `flatMap` `filter` `forEach` `reduce`
`allSatisfy` `first(where:)` `enumerated` `joined` `prefix` `suffix` `min` `max` `indices` など。

Dictionary: `keys` `values` `count` `isEmpty` `removeValue(forKey:)` `updateValue` `filter` `map` など。

## 安全装置

実行の手数・出力サイズ・再帰の深さに上限があり、無限ループや暴走する再帰でもアプリが固まりません。
`nil` の強制アンラップ、配列の範囲外、`let` への再代入、0 除算は、行番号つきのエラーとして報告します。

## テスト

- `Tests/GitHubViewerCoreTests/MiniSwiftTests.swift` — 言語機能・エラー処理の単体テスト 17 件。
- `Tests/GitHubViewerCoreTests/SwiftComparisonTests.swift` — **本物の Swift との差分テスト**。
  `Examples/swift/` の 14 本を内蔵インタプリタで実行し、`swiftc` 6.0.3 でコンパイル・実行した
  出力と 1 バイトも違わないことを確認します。

14 本には、構造体とクラスの値・参照の違い、継承とオーバーライド、列挙型と `switch`、
オプショナルと `guard`、辞書、クロージャのキャプチャ、高階関数、クイックソートと二分探索、
タプルと `inout`、文字列処理、数値の表示などが入っています。

## まだできないこと

- プロトコル、`extension`、ジェネリクス (型引数は読み飛ばします)
- `throw` / `try` / `catch` (`try` は読み飛ばします)、`defer`、`async` / `await`
- 関連値つきの列挙 (`case point(Int, Int)`)、`indirect enum`
- 演算子の定義、`subscript` の定義、`willSet` / `didSet`、`lazy`
- 静的メソッドの一部、`Set`、`Foundation` のほとんどの API
- 型検査 (実行時に値の型で動く、動的なインタプリタです)
