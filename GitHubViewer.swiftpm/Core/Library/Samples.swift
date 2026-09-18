import Foundation

// MARK: - 231 / 232 / 233. 学習用サンプル

/// サンプル 1 つ。
public struct CodeSample: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var title: String
    /// 何を学べるか。
    public var summary: String
    public var languageID: String
    public var source: String
    /// 標準入力の例。
    public var input: String
    /// 期待する出力 (あれば、動くか確かめられる)。
    public var expectedOutput: String?
    /// 分類 (「基本」「アルゴリズム」など)。
    public var category: String
    /// 探すときの言葉。
    public var tags: [String]
    /// やさしさ (1〜3)。
    public var level: Int
    /// 自分で足したものか。
    public var isUserDefined: Bool

    public init(id: String, title: String, summary: String, languageID: String,
                source: String, input: String = "", expectedOutput: String? = nil,
                category: String = "基本", tags: [String] = [], level: Int = 1,
                isUserDefined: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.languageID = languageID
        self.source = source
        self.input = input
        self.expectedOutput = expectedOutput
        self.category = category
        self.tags = tags
        self.level = level
        self.isUserDefined = isUserDefined
    }

    /// やさしさの印。
    public var levelText: String {
        String(repeating: "★", count: Swift.max(1, Swift.min(3, level)))
    }

    /// 動かせるか。
    public var isRunnable: Bool { RunSession.hasEngine(for: languageID) }

    /// 探すときに見る文字列。
    public var searchText: String {
        ([title, summary, category, languageID] + tags).joined(separator: " ")
    }
}

/// 最初から入っているサンプルと、自分で足したもの。
public struct SampleLibrary: Equatable, Sendable {
    public var userSamples: [CodeSample]

    public init(userSamples: [CodeSample] = []) {
        self.userSamples = userSamples
    }

    /// 全部 (自分のものが先)。
    public var all: [CodeSample] {
        userSamples + SampleLibrary.builtIn
    }

    /// 言語で絞る。
    public func samples(languageID: String) -> [CodeSample] {
        all.filter { $0.languageID == languageID }
    }

    /// 分類で絞る。
    public func samples(category: String) -> [CodeSample] {
        all.filter { $0.category == category }
    }

    /// 出てくる分類。
    public var categories: [String] {
        var seen: [String] = []
        for sample in all where !seen.contains(sample.category) {
            seen.append(sample.category)
        }
        return seen
    }

    /// 232. あいまい検索。
    public func search(_ query: String, languageID: String? = nil,
                       category: String? = nil, limit: Int = 30) -> [CodeSample] {
        var candidates = all
        if let languageID { candidates = candidates.filter { $0.languageID == languageID } }
        if let category { candidates = candidates.filter { $0.category == category } }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(candidates.prefix(limit)) }
        return FuzzySearch.search(trimmed, in: candidates, limit: limit) {
            $0.searchText
        }.map(\.element)
    }

    public func sample(id: String) -> CodeSample? {
        all.first { $0.id == id }
    }

    // MARK: - 233. 自分で足す

    public mutating func add(_ sample: CodeSample) {
        var copy = sample
        copy.isUserDefined = true
        if let index = userSamples.firstIndex(where: { $0.id == copy.id }) {
            userSamples[index] = copy
        } else {
            userSamples.append(copy)
        }
    }

    public mutating func remove(id: String) {
        userSamples.removeAll { $0.id == id }
    }

    /// いま開いているコードからサンプルを作る。
    public static func makeSample(title: String, languageID: String, source: String,
                                  summary: String = "", input: String = "",
                                  category: String = "自分のもの",
                                  tags: [String] = []) -> CodeSample {
        CodeSample(id: "user-\(UUID().uuidString.prefix(8))", title: title,
                   summary: summary.isEmpty ? title : summary, languageID: languageID,
                   source: source, input: input, category: category, tags: tags,
                   isUserDefined: true)
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(userSamples) }

    public static func decoded(_ data: Data?) -> SampleLibrary {
        guard let data,
              let samples = try? JSONDecoder().decode([CodeSample].self, from: data)
        else { return SampleLibrary() }
        return SampleLibrary(userSamples: samples)
    }

    // MARK: - 最初から入っているもの

    public static let builtIn: [CodeSample] = [
        CodeSample(id: "hello-go", title: "はじめの一歩 (Go)",
                   summary: "画面に文字を出すだけの、いちばん短いプログラム。",
                   languageID: "go", source: """
                   package main

                   import "fmt"

                   func main() {
                       fmt.Println("こんにちは、世界")
                   }
                   """,
                   expectedOutput: "こんにちは、世界", category: "基本",
                   tags: ["出力", "入門"], level: 1),

        CodeSample(id: "fizzbuzz-js", title: "FizzBuzz",
                   summary: "条件分岐と繰り返しの練習。3 と 5 の倍数で言葉を変える。",
                   languageID: "javascript", source: """
                   for (let i = 1; i <= 15; i++) {
                       if (i % 15 === 0) { console.log("FizzBuzz"); }
                       else if (i % 3 === 0) { console.log("Fizz"); }
                       else if (i % 5 === 0) { console.log("Buzz"); }
                       else { console.log(i); }
                   }
                   """,
                   category: "基本", tags: ["条件", "繰り返し"], level: 1),

        CodeSample(id: "sum-input-js", title: "入力を足す",
                   summary: "標準入力から数を読んで、合計を出す。",
                   languageID: "javascript", source: """
                   let total = 0;
                   let line = readLine();
                   while (line !== undefined && line !== "") {
                       total += Number(line);
                       line = readLine();
                   }
                   console.log(total);
                   """,
                   input: "1\n2\n3\n4\n", expectedOutput: "10", category: "基本",
                   tags: ["入力", "合計"], level: 1),

        CodeSample(id: "fib-rust", title: "フィボナッチ数列",
                   summary: "再帰と繰り返しの違いを見くらべる。",
                   languageID: "rust", source: """
                   fn fib(n: i64) -> i64 {
                       if n < 2 { return n; }
                       let mut a = 0;
                       let mut b = 1;
                       let mut i = 1;
                       while i < n {
                           let next = a + b;
                           a = b;
                           b = next;
                           i += 1;
                       }
                       b
                   }

                   fn main() {
                       for i in 0..10 {
                           println!("{}", fib(i));
                       }
                   }
                   """,
                   category: "アルゴリズム", tags: ["再帰", "数列"], level: 2),

        CodeSample(id: "bubble-sort-java", title: "バブルソート",
                   summary: "となり同士を比べて並べ替える、いちばん素朴な方法。",
                   languageID: "java", source: """
                   public class Main {
                       public static void main(String[] args) {
                           int[] a = {5, 3, 8, 1, 9, 2};
                           for (int i = 0; i < a.length - 1; i++) {
                               for (int j = 0; j < a.length - 1 - i; j++) {
                                   if (a[j] > a[j + 1]) {
                                       int t = a[j];
                                       a[j] = a[j + 1];
                                       a[j + 1] = t;
                                   }
                               }
                           }
                           for (int value : a) {
                               System.out.print(value + " ");
                           }
                           System.out.println();
                       }
                   }
                   """,
                   category: "アルゴリズム", tags: ["並べ替え", "配列"], level: 2),

        CodeSample(id: "binary-search-cpp", title: "二分探索",
                   summary: "並んでいる配列から、半分ずつ絞って探す。",
                   languageID: "cpp", source: """
                   #include <iostream>
                   using namespace std;

                   int search(int a[], int n, int target) {
                       int low = 0, high = n - 1;
                       while (low <= high) {
                           int mid = (low + high) / 2;
                           if (a[mid] == target) return mid;
                           if (a[mid] < target) low = mid + 1;
                           else high = mid - 1;
                       }
                       return -1;
                   }

                   int main() {
                       int a[] = {1, 3, 5, 7, 9, 11};
                       cout << search(a, 6, 7) << endl;
                       return 0;
                   }
                   """,
                   expectedOutput: "3", category: "アルゴリズム",
                   tags: ["探索", "配列"], level: 2),

        CodeSample(id: "struct-go", title: "構造体とメソッド",
                   summary: "データと、それにまつわる処理をまとめる。",
                   languageID: "go", source: """
                   package main

                   import "fmt"

                   type Point struct {
                       X int
                       Y int
                   }

                   func (p Point) Sum() int {
                       return p.X + p.Y
                   }

                   func main() {
                       p := Point{X: 3, Y: 4}
                       fmt.Println(p.Sum())
                   }
                   """,
                   expectedOutput: "7", category: "型とデータ",
                   tags: ["構造体", "メソッド"], level: 2),

        CodeSample(id: "map-kotlin", title: "辞書を数える",
                   summary: "words の出てくる回数を数える。",
                   languageID: "kotlin", source: """
                   fun main() {
                       val words = listOf("あ", "い", "あ", "う", "あ")
                       val counts = HashMap<String, Int>()
                       for (word in words) {
                           counts[word] = (counts[word] ?: 0) + 1
                       }
                       println(counts["あ"])
                   }
                   """,
                   expectedOutput: "3", category: "型とデータ",
                   tags: ["辞書", "集計"], level: 2),

        CodeSample(id: "closure-js", title: "クロージャ",
                   summary: "関数が、まわりの変数を覚えたまま持ち歩く。",
                   languageID: "javascript", source: """
                   function counter() {
                       let count = 0;
                       return function () {
                           count += 1;
                           return count;
                       };
                   }

                   const next = counter();
                   console.log(next());
                   console.log(next());
                   console.log(next());
                   """,
                   expectedOutput: "1\n2\n3", category: "関数",
                   tags: ["関数", "スコープ"], level: 3),

        CodeSample(id: "pattern-elixir", title: "パターンマッチ",
                   summary: "形で分けて書く。Elixir らしい書き方。",
                   languageID: "elixir", source: """
                   defmodule Shape do
                     def area({:circle, r}), do: 3.14159 * r * r
                     def area({:rect, w, h}), do: w * h
                   end

                   IO.puts(Shape.area({:rect, 3, 4}))
                   """,
                   expectedOutput: "12", category: "関数",
                   tags: ["パターン", "分岐"], level: 3),

        CodeSample(id: "recursion-haskell", title: "再帰で階乗",
                   summary: "同じ形の小さな問題にして解く。",
                   languageID: "haskell", source: """
                   factorial :: Integer -> Integer
                   factorial 0 = 1
                   factorial n = n * factorial (n - 1)

                   main :: IO ()
                   main = print (factorial 10)
                   """,
                   expectedOutput: "3628800", category: "関数",
                   tags: ["再帰", "数学"], level: 3),

        CodeSample(id: "file-js", title: "ファイルを読み書きする",
                   summary: "仮想のファイルに書いて、読み返す。",
                   languageID: "javascript", source: """
                   writeFile("メモ.txt", "いち\\nに\\nさん");
                   const lines = readLines("メモ.txt");
                   console.log(lines.length);
                   console.log(lines[2]);
                   """,
                   expectedOutput: "3\nさん", category: "入出力",
                   tags: ["ファイル", "入出力"], level: 2),

        CodeSample(id: "shell-pipeline", title: "パイプでつなぐ",
                   summary: "小さな道具をつないで仕事をする、シェルの考え方。",
                   languageID: "shell", source: """
                   printf 'banana\\napple\\ncherry\\napple\\n' | sort | uniq -c | sort -rn
                   """,
                   category: "入出力", tags: ["シェル", "パイプ"], level: 2),

        CodeSample(id: "error-go", title: "エラーを返す",
                   summary: "失敗を値として返し、呼ぶ側が確かめる。",
                   languageID: "go", source: """
                   package main

                   import (
                       "errors"
                       "fmt"
                   )

                   func divide(a int, b int) (int, error) {
                       if b == 0 {
                           return 0, errors.New("0 で割れません")
                       }
                       return a / b, nil
                   }

                   func main() {
                       if value, err := divide(6, 3); err == nil {
                           fmt.Println(value)
                       }
                       if _, err := divide(1, 0); err != nil {
                           fmt.Println(err)
                       }
                   }
                   """,
                   category: "エラー処理", tags: ["エラー", "戻り値"], level: 2),

        CodeSample(id: "exception-python-like", title: "例外を捕まえる",
                   summary: "失敗したときの道を、別に書いておく。",
                   languageID: "javascript", source: """
                   function parse(text) {
                       const value = Number(text);
                       if (isNaN(value)) { throw "数ではありません: " + text; }
                       return value;
                   }

                   try {
                       console.log(parse("42"));
                       console.log(parse("あいう"));
                   } catch (e) {
                       console.log("捕まえた: " + e);
                   }
                   """,
                   category: "エラー処理", tags: ["例外", "分岐"], level: 2)
    ]
}

// MARK: - 234. Gist にして共有

/// 共有するときの中身。
public struct ShareBundle: Equatable, Sendable {
    public var description: String
    /// ファイル名 → 中身。
    public var files: [String: String]
    public var isPublic: Bool

    public init(description: String, files: [String: String], isPublic: Bool = false) {
        self.description = description
        self.files = files
        self.isPublic = isPublic
    }

    /// コードと、実行の結果をまとめる。
    public static func make(title: String, languageID: String, source: String,
                            result: RunResult? = nil, input: String = "",
                            isPublic: Bool = false) -> ShareBundle {
        let fileName = FileTemplateCatalog.template(for: languageID)?.fileName
            ?? "code.txt"
        var files = [fileName: source]
        if !input.isEmpty { files["input.txt"] = input }
        if let result {
            files["README.md"] = RunSharing.markdown(source: source, result: result,
                                                     languageID: languageID,
                                                     input: input)
        }
        return ShareBundle(description: title, files: files, isPublic: isPublic)
    }
}

extension GitHubClient {
    /// 234. Gist にして、共有できるリンクを作る。
    public func share(_ bundle: ShareBundle) async throws -> (gist: GitGist, url: URL?) {
        let gist = try await createGist(files: bundle.files,
                                        description: bundle.description,
                                        isPublic: bundle.isPublic)
        return (gist, gist.htmlURL)
    }
}

// MARK: - 235. エクスポート

/// 書き出す形。
public enum ExportFormat: String, CaseIterable, Identifiable, Equatable, Sendable {
    /// そのままの文字。
    case plainText
    /// Markdown (コードと出力)。
    case markdown
    /// 印刷や PDF のための HTML。
    case html
    /// Swift Playgrounds で開ける形。
    case playground
    /// zip にまとめる。
    case zip

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .plainText: return "テキスト"
        case .markdown: return "Markdown"
        case .html: return "HTML (PDF 用)"
        case .playground: return "Swift Playground"
        case .zip: return "zip"
        }
    }

    public var fileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .markdown: return "md"
        case .html: return "html"
        case .playground: return "swiftpm"
        case .zip: return "zip"
        }
    }
}

/// 書き出す中身を作る。
public enum Exporter {

    /// 1 つのファイルとして書き出す。
    public static func export(format: ExportFormat, title: String, languageID: String,
                              source: String, result: RunResult? = nil,
                              input: String = "") -> Data {
        switch format {
        case .plainText:
            guard let result else { return Data(source.utf8) }
            return Data(RunSharing.plainText(source: source, result: result,
                                             input: input).utf8)

        case .markdown:
            guard let result else {
                return Data("# \(title)\n\n```\(languageID)\n\(source)\n```\n".utf8)
            }
            return Data(("# \(title)\n\n"
                + RunSharing.markdown(source: source, result: result,
                                      languageID: languageID, input: input)
                + "\n").utf8)

        case .html:
            return Data(html(title: title, languageID: languageID, source: source,
                             result: result, input: input).utf8)

        case .playground:
            return playgroundArchive(title: title, languageID: languageID,
                                     source: source)

        case .zip:
            var files = [fileName(for: languageID): source]
            if !input.isEmpty { files["input.txt"] = input }
            if let result {
                files["output.txt"] = ANSIParser.strip(result.output)
                files["README.md"] = RunSharing.markdown(source: source, result: result,
                                                          languageID: languageID,
                                                          input: input)
            }
            return Zip.archive(files: files)
        }
    }

    static func fileName(for languageID: String) -> String {
        FileTemplateCatalog.template(for: languageID)?.fileName ?? "code.txt"
    }

    /// 印刷や PDF に向く HTML を作る。
    ///
    /// 色分けはこちらで付けるので、外のライブラリは要らない。
    public static func html(title: String, languageID: String, source: String,
                            result: RunResult? = nil, input: String = "",
                            theme: EditorTheme = EditorThemeCatalog.light) -> String {
        var body = ""
        body += "<h1>\(escape(title))</h1>\n"
        body += "<pre class=\"code\">\(highlighted(source, languageID: languageID, theme: theme))</pre>\n"
        if !input.isEmpty {
            body += "<h2>入力</h2>\n<pre>\(escape(input))</pre>\n"
        }
        if let result {
            let output = ANSIParser.strip(result.output)
            body += "<h2>出力</h2>\n<pre>\(escape(output.isEmpty ? "(出力なし)" : output))</pre>\n"
            if let failure = result.failureText, !failure.isEmpty {
                body += "<h2>エラー</h2>\n<pre class=\"error\">\(escape(failure))</pre>\n"
            }
            body += "<p class=\"status\">\(escape(result.engineName)) — "
                + "\(escape(result.statusLine))</p>\n"
        }

        return """
        <!DOCTYPE html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        body { font-family: -apple-system, "Hiragino Sans", sans-serif;
               line-height: 1.7; margin: 2em auto; max-width: 48em; padding: 0 1em;
               color: \(theme.foreground.hexString); }
        h1 { font-size: 1.6em; border-bottom: 1px solid #ccc; padding-bottom: .3em; }
        h2 { font-size: 1.2em; margin-top: 1.6em; }
        pre { background: \(theme.background.hexString); padding: 1em;
              border-radius: .5em; overflow-x: auto; font-size: .9em;
              font-family: ui-monospace, "SF Mono", Menlo, monospace; }
        pre.error { background: #fff0f0; }
        p.status { color: #666; font-size: .85em; }
        @media print { body { margin: 0; max-width: none; } pre { white-space: pre-wrap; } }
        </style>
        </head>
        <body>
        \(body)</body>
        </html>
        """
    }

    /// 色を付けた HTML の断片。
    static func highlighted(_ source: String, languageID: String,
                            theme: EditorTheme) -> String {
        let spans = SyntaxHighlighter.spans(for: source, languageID: languageID)
        let units = Array(source.utf16)
        var result = ""
        var cursor = 0

        func append(_ range: Range<Int>, color: String?) {
            guard range.lowerBound < range.upperBound,
                  range.upperBound <= units.count else { return }
            let text = escape(String(decoding: units[range], as: UTF16.self))
            if let color {
                result += "<span style=\"color:\(color)\">\(text)</span>"
            } else {
                result += text
            }
        }

        for span in spans.sorted(by: { $0.location < $1.location })
        where span.location >= cursor {
            append(cursor..<span.location, color: nil)
            append(span.location..<(span.location + span.length),
                   color: theme.color(for: span.kind).hexString)
            cursor = span.location + span.length
        }
        append(cursor..<units.count, color: nil)
        return result
    }

    /// Swift Playgrounds で開ける形にまとめる。
    ///
    /// Swift 以外の言語も、そのまま読めるように入れておく。
    public static func playgroundArchive(title: String, languageID: String,
                                         source: String) -> Data {
        let name = title.isEmpty ? "MyPlayground" : title
        var files: [String: String] = [:]

        files["Package.swift"] = """
        // swift-tools-version: 5.9

        import PackageDescription
        import AppleProductTypes

        let package = Package(
            name: "\(name)",
            platforms: [.iOS("16.0")],
            products: [
                .iOSApplication(
                    name: "\(name)",
                    targets: ["AppModule"],
                    displayVersion: "1.0",
                    bundleVersion: "1",
                    accentColor: .presetColor(.blue),
                    supportedDeviceFamilies: [.pad, .phone],
                    supportedInterfaceOrientations: [.portrait, .landscapeLeft,
                                                     .landscapeRight]
                )
            ],
            targets: [
                .executableTarget(name: "AppModule", path: ".")
            ]
        )
        """

        if languageID == "swift" {
            files["ContentView.swift"] = source
        } else {
            // ほかの言語は、そのまま持ち込んで読めるようにしておく。
            files[fileName(for: languageID)] = source
            files["ContentView.swift"] = """
            import SwiftUI

            /// \(name) — \(languageID) のコードを持ち込んだもの。
            struct ContentView: View {
                private let source = \"\"\"
            \(source.components(separatedBy: "\n").map { "    " + $0 }
                .joined(separator: "\n"))
                \"\"\"

                var body: some View {
                    ScrollView {
                        Text(source)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            """
        }

        files["MyApp.swift"] = """
        import SwiftUI

        @main
        struct MyApp: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
        """

        return Zip.archive(files: files)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
