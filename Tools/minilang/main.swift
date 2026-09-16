import Foundation
import GitHubViewerCore

// 内蔵処理系を macOS / Linux のコマンドラインから動かすための開発用ツール。
// 本物の処理系 (gcc, php, perl, node ...) と出力を突き合わせるのに使う。
//
//   swift run minilang <言語ID> <ソースファイル> [< 標準入力]
//   swift run minilang --list

let languages: [String: MiniLangEngine.Type] = MiniLangRegistry.engines

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    使い方: minilang <言語ID> <ファイル>
            minilang --list
    """.utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--list" {
    for id in languages.keys.sorted() {
        print("\(id)\t\(languages[id]!.displayName)")
    }
    exit(0)
}

guard arguments.count >= 2 else { usage() }
let languageID = arguments[0]
let path = arguments[1]

guard let engine = languages[languageID] else {
    FileHandle.standardError.write(Data("知らない言語 ID です: \(languageID)\n".utf8))
    exit(2)
}
guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
    FileHandle.standardError.write(Data("ファイルを読めません: \(path)\n".utf8))
    exit(2)
}

var standardInput = ""
if isatty(0) == 0 {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    standardInput = String(decoding: data, as: UTF8.self)
}

let result = engine.execute(source: source, input: standardInput, limits: .default)
if !result.parsed {
    FileHandle.standardError.write(Data((result.diagnosticsText + "\n").utf8))
    exit(1)
}
FileHandle.standardOutput.write(Data(result.output.utf8))
if let error = result.runtimeError {
    FileHandle.standardError.write(Data(("実行時エラー: " + error + "\n").utf8))
    exit(1)
}
exit(result.exitCode)
