import Foundation

/// 差し込むコード片。
public struct Snippet: Equatable, Identifiable, Codable, Sendable {
    public var id: String
    /// 打ち込むと展開される短い名前 (`forr` など)。
    public var trigger: String
    public var title: String
    /// 対象の言語 ID (空なら全言語)。
    public var languageIDs: [String]
    /// 本文。`${1:name}` のような差し込み口を書ける。
    public var body: String
    /// 利用者が作ったものか。
    public var isUserDefined: Bool

    public init(id: String = UUID().uuidString, trigger: String, title: String,
                languageIDs: [String] = [], body: String, isUserDefined: Bool = false) {
        self.id = id
        self.trigger = trigger
        self.title = title
        self.languageIDs = languageIDs
        self.body = body
        self.isUserDefined = isUserDefined
    }

    /// この言語で使えるか。
    public func matches(languageID: String?) -> Bool {
        guard !languageIDs.isEmpty else { return true }
        guard let languageID else { return false }
        return languageIDs.contains(languageID)
    }
}

/// 差し込み口 (`${1:name}`) を解いた結果。
public struct ExpandedSnippet: Equatable, Sendable {
    public var text: String
    /// 最初の差し込み口の位置 (UTF-16)。カーソルをここに置く。
    public var caretLocation: Int
    public var caretLength: Int

    public init(text: String, caretLocation: Int, caretLength: Int) {
        self.text = text
        self.caretLocation = caretLocation
        self.caretLength = caretLength
    }
}

/// コード片の置き場。
public enum SnippetLibrary {

    /// 差し込み口を解く。`${1:name}` → `name` を選んだ状態にする。
    public static func expand(_ body: String, indent: String = "") -> ExpandedSnippet {
        var result = ""
        var caretLocation: Int?
        var caretLength = 0
        var characters = Array(body)
        var index = 0

        while index < characters.count {
            // `${1:name}` / `$1` / `$0`
            if characters[index] == "$", index + 1 < characters.count {
                if characters[index + 1] == "{" {
                    var cursor = index + 2
                    var inner = ""
                    while cursor < characters.count, characters[cursor] != "}" {
                        inner.append(characters[cursor])
                        cursor += 1
                    }
                    index = Swift.min(cursor + 1, characters.count)
                    let parts = inner.split(separator: ":", maxSplits: 1).map(String.init)
                    let placeholder = parts.count > 1 ? parts[1] : ""
                    if caretLocation == nil {
                        caretLocation = (result as NSString).length
                        caretLength = (placeholder as NSString).length
                    }
                    result += placeholder
                    continue
                }
                if characters[index + 1].isNumber {
                    var cursor = index + 1
                    while cursor < characters.count, characters[cursor].isNumber {
                        cursor += 1
                    }
                    if caretLocation == nil {
                        caretLocation = (result as NSString).length
                        caretLength = 0
                    }
                    index = cursor
                    continue
                }
            }
            if characters[index] == "\n" {
                result.append("\n")
                result += indent
                index += 1
                continue
            }
            result.append(characters[index])
            index += 1
        }
        characters = []
        return ExpandedSnippet(text: result,
                               caretLocation: caretLocation ?? (result as NSString).length,
                               caretLength: caretLength)
    }

    /// 言語で絞り込む。
    public static func snippets(for languageID: String?,
                                including extra: [Snippet] = []) -> [Snippet] {
        (builtIn + extra).filter { $0.matches(languageID: languageID) }
    }

    /// 打ち込んだ短い名前から探す。
    public static func snippet(trigger: String, languageID: String?,
                               including extra: [Snippet] = []) -> Snippet? {
        snippets(for: languageID, including: extra).first { $0.trigger == trigger }
    }

    /// 最初から用意してあるコード片。
    public static let builtIn: [Snippet] = [
        // どの言語でも使うもの。
        Snippet(id: "todo", trigger: "todo", title: "TODO コメント",
                body: "TODO: ${1:やること}"),
        Snippet(id: "date", trigger: "date", title: "今日の日付",
                body: "${1:YYYY-MM-DD}"),

        // C 系。
        Snippet(id: "c-main", trigger: "main", title: "main 関数", languageIDs: ["c"],
                body: "int main(void) {\n    ${1:/* ここに書く */}\n    return 0;\n}"),
        Snippet(id: "c-for", trigger: "for", title: "for ループ",
                languageIDs: ["c", "cpp", "objectivec", "java", "csharp", "javascript",
                              "typescript", "go", "rust", "swift", "kotlin", "dart",
                              "groovy", "d", "zig", "php", "scala"],
                body: "for (int ${1:i} = 0; ${1:i} < ${2:n}; ${1:i}++) {\n    ${3:}\n}"),
        Snippet(id: "c-printf", trigger: "pf", title: "printf",
                languageIDs: ["c", "cpp", "objectivec"],
                body: "printf(\"${1:%d}\\n\", ${2:value});"),
        Snippet(id: "c-struct", trigger: "struct", title: "構造体",
                languageIDs: ["c", "cpp"],
                body: "typedef struct {\n    ${1:int value;}\n} ${2:Name};"),

        // Swift。
        Snippet(id: "swift-func", trigger: "func", title: "関数", languageIDs: ["swift"],
                body: "func ${1:name}(${2:}) -> ${3:Void} {\n    ${4:}\n}"),
        Snippet(id: "swift-struct", trigger: "struct", title: "構造体",
                languageIDs: ["swift"],
                body: "struct ${1:Name} {\n    ${2:var value: Int}\n}"),
        Snippet(id: "swift-guard", trigger: "guard", title: "guard let",
                languageIDs: ["swift"],
                body: "guard let ${1:value} = ${2:optional} else {\n    ${3:return}\n}"),
        Snippet(id: "swift-print", trigger: "pr", title: "print", languageIDs: ["swift"],
                body: "print(\"${1:}\")"),

        // Java / Kotlin。
        Snippet(id: "java-main", trigger: "main", title: "main メソッド",
                languageIDs: ["java"],
                body: "public static void main(String[] args) {\n    ${1:}\n}"),
        Snippet(id: "java-class", trigger: "class", title: "クラス",
                languageIDs: ["java", "csharp", "kotlin", "scala", "groovy"],
                body: "class ${1:Name} {\n    ${2:}\n}"),
        Snippet(id: "java-sout", trigger: "sout", title: "標準出力",
                languageIDs: ["java"], body: "System.out.println(${1:});"),

        // Python / Ruby。
        Snippet(id: "python-def", trigger: "def", title: "関数",
                languageIDs: ["python"],
                body: "def ${1:name}(${2:}):\n    ${3:pass}"),
        Snippet(id: "python-main", trigger: "main", title: "main ガード",
                languageIDs: ["python"],
                body: "if __name__ == \"__main__\":\n    ${1:main()}"),
        Snippet(id: "ruby-def", trigger: "def", title: "メソッド",
                languageIDs: ["ruby", "crystal"],
                body: "def ${1:name}(${2:})\n  ${3:}\nend"),

        // JavaScript。
        Snippet(id: "js-func", trigger: "fn", title: "関数",
                languageIDs: ["javascript", "typescript"],
                body: "function ${1:name}(${2:}) {\n    ${3:}\n}"),
        Snippet(id: "js-arrow", trigger: "af", title: "アロー関数",
                languageIDs: ["javascript", "typescript"],
                body: "const ${1:name} = (${2:}) => {\n    ${3:}\n};"),
        Snippet(id: "js-log", trigger: "log", title: "console.log",
                languageIDs: ["javascript", "typescript"],
                body: "console.log(${1:});"),

        // Go / Rust。
        Snippet(id: "go-main", trigger: "main", title: "main 関数", languageIDs: ["go"],
                body: "package main\n\nimport \"fmt\"\n\nfunc main() {\n    fmt.Println(${1:})\n}"),
        Snippet(id: "go-func", trigger: "func", title: "関数", languageIDs: ["go"],
                body: "func ${1:name}(${2:}) ${3:} {\n    ${4:}\n}"),
        Snippet(id: "rust-main", trigger: "main", title: "main 関数",
                languageIDs: ["rust"],
                body: "fn main() {\n    println!(\"${1:}\");\n}"),
        Snippet(id: "rust-fn", trigger: "fn", title: "関数", languageIDs: ["rust"],
                body: "fn ${1:name}(${2:}) -> ${3:()} {\n    ${4:}\n}"),

        // シェル。
        Snippet(id: "sh-shebang", trigger: "sh", title: "shebang",
                languageIDs: ["shell", "bash"], body: "#!/bin/bash\nset -euo pipefail\n\n${1:}"),
        Snippet(id: "sh-if", trigger: "if", title: "if 文",
                languageIDs: ["shell", "bash"],
                body: "if [ ${1:condition} ]; then\n    ${2:}\nfi"),

        // HTML / CSS。
        Snippet(id: "html5", trigger: "html", title: "HTML の骨組み",
                languageIDs: ["html"],
                body: """
                <!DOCTYPE html>
                <html lang="ja">
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1">
                  <title>${1:タイトル}</title>
                </head>
                <body>
                  ${2:}
                </body>
                </html>
                """),
        Snippet(id: "css-flex", trigger: "flex", title: "Flexbox",
                languageIDs: ["css"],
                body: "display: flex;\nalign-items: ${1:center};\njustify-content: ${2:center};")
    ]
}

/// 新しいファイルのひな形。
public struct FileTemplate: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var languageID: String
    public var fileName: String
    public var body: String

    public init(id: String, name: String, languageID: String, fileName: String,
                body: String) {
        self.id = id
        self.name = name
        self.languageID = languageID
        self.fileName = fileName
        self.body = body
    }
}

/// ひな形の置き場。
public enum FileTemplateCatalog {

    /// 言語 ID からひな形を引く。
    public static func template(for languageID: String) -> FileTemplate? {
        all.first { $0.languageID == languageID }
    }

    public static let all: [FileTemplate] = [
        FileTemplate(id: "c", name: "C", languageID: "c", fileName: "main.c", body: """
        #include <stdio.h>

        int main(void) {
            printf("Hello, World!\\n");
            return 0;
        }
        """),
        FileTemplate(id: "cpp", name: "C++", languageID: "cpp", fileName: "main.cpp", body: """
        #include <iostream>

        int main() {
            std::cout << "Hello, World!" << std::endl;
            return 0;
        }
        """),
        FileTemplate(id: "swift", name: "Swift", languageID: "swift",
                     fileName: "main.swift", body: """
        print("Hello, World!")
        """),
        FileTemplate(id: "java", name: "Java", languageID: "java",
                     fileName: "Main.java", body: """
        public class Main {
            public static void main(String[] args) {
                System.out.println("Hello, World!");
            }
        }
        """),
        FileTemplate(id: "python", name: "Python", languageID: "python",
                     fileName: "main.py", body: """
        def main():
            print("Hello, World!")


        if __name__ == "__main__":
            main()
        """),
        FileTemplate(id: "javascript", name: "JavaScript", languageID: "javascript",
                     fileName: "main.js", body: """
        console.log("Hello, World!");
        """),
        FileTemplate(id: "typescript", name: "TypeScript", languageID: "typescript",
                     fileName: "main.ts", body: """
        const message: string = "Hello, World!";
        console.log(message);
        """),
        FileTemplate(id: "go", name: "Go", languageID: "go", fileName: "main.go", body: """
        package main

        import "fmt"

        func main() {
            fmt.Println("Hello, World!")
        }
        """),
        FileTemplate(id: "rust", name: "Rust", languageID: "rust",
                     fileName: "main.rs", body: """
        fn main() {
            println!("Hello, World!");
        }
        """),
        FileTemplate(id: "ruby", name: "Ruby", languageID: "ruby",
                     fileName: "main.rb", body: """
        puts "Hello, World!"
        """),
        FileTemplate(id: "php", name: "PHP", languageID: "php",
                     fileName: "main.php", body: """
        <?php
        echo "Hello, World!\\n";
        """),
        FileTemplate(id: "shell", name: "シェル", languageID: "bash",
                     fileName: "main.sh", body: """
        #!/bin/bash
        set -euo pipefail

        echo "Hello, World!"
        """),
        FileTemplate(id: "haskell", name: "Haskell", languageID: "haskell",
                     fileName: "main.hs", body: """
        main :: IO ()
        main = putStrLn "Hello, World!"
        """),
        FileTemplate(id: "html", name: "HTML", languageID: "html",
                     fileName: "index.html", body: """
        <!DOCTYPE html>
        <html lang="ja">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>ページ</title>
        </head>
        <body>
          <h1>Hello, World!</h1>
        </body>
        </html>
        """),
        FileTemplate(id: "markdown", name: "Markdown", languageID: "markdown",
                     fileName: "README.md", body: """
        # タイトル

        説明をここに書きます。

        ## 使い方

        ```bash
        echo hello
        ```
        """)
    ]

    /// `.gitignore` のひな形。
    public static let gitignoreTemplates: [(name: String, body: String)] = [
        ("Swift", """
        .DS_Store
        /.build
        /Packages
        xcuserdata/
        DerivedData/
        .swiftpm/configuration/registries.json
        .swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata
        """),
        ("Node", """
        node_modules/
        dist/
        .env
        npm-debug.log*
        """),
        ("Python", """
        __pycache__/
        *.py[cod]
        .venv/
        .env
        *.egg-info/
        """),
        ("C / C++", """
        *.o
        *.a
        *.so
        *.out
        build/
        """),
        ("汎用", """
        .DS_Store
        *.log
        *.tmp
        build/
        dist/
        """)
    ]

    /// ライセンスのひな形。`{year}` と `{owner}` を置き換えて使う。
    public static let licenseTemplates: [(name: String, body: String)] = [
        ("MIT", """
        MIT License

        Copyright (c) {year} {owner}

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.
        """),
        ("Apache 2.0 (要約)", """
        Copyright {year} {owner}

        Licensed under the Apache License, Version 2.0 (the "License");
        you may not use this file except in compliance with the License.
        You may obtain a copy of the License at

            http://www.apache.org/licenses/LICENSE-2.0

        Unless required by applicable law or agreed to in writing, software
        distributed under the License is distributed on an "AS IS" BASIS,
        WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
        See the License for the specific language governing permissions and
        limitations under the License.
        """),
        ("BSD 2-Clause", """
        BSD 2-Clause License

        Copyright (c) {year}, {owner}

        Redistribution and use in source and binary forms, with or without
        modification, are permitted provided that the following conditions are met:

        1. Redistributions of source code must retain the above copyright notice,
           this list of conditions and the following disclaimer.
        2. Redistributions in binary form must reproduce the above copyright notice,
           this list of conditions and the following disclaimer in the documentation
           and/or other materials provided with the distribution.
        """),
        ("CC0 (パブリックドメイン)", """
        このリポジトリの内容は CC0 1.0 により、権利を放棄しています。
        自由に使ってかまいません。
        """)
    ]

    /// ライセンスの `{year}` と `{owner}` を埋める。
    public static func fill(_ template: String, owner: String,
                            year: Int = Calendar(identifier: .gregorian)
                                .component(.year, from: Date())) -> String {
        template
            .replacingOccurrences(of: "{year}", with: String(year))
            .replacingOccurrences(of: "{owner}", with: owner)
    }
}
