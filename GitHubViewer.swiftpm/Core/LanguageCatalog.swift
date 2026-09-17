import Foundation

/// 端末の中 (WebView) で実行できる言語ランタイム。
/// いずれも WebAssembly / JavaScript 実装を CDN から読み込むので、サーバーにコードを送らない。
public enum LocalEngine: String, Equatable, CaseIterable {
    case javascript
    case typescript
    case python
    case ruby
    case lua
    case sql

    public var displayName: String {
        switch self {
        case .javascript: return "JavaScript (WebView)"
        case .typescript: return "TypeScript (tsc + WebView)"
        case .python: return "Python (Pyodide / WebAssembly)"
        case .ruby: return "Ruby (ruby.wasm)"
        case .lua: return "Lua (Fengari)"
        case .sql: return "SQL (sql.js / SQLite)"
        }
    }
}

/// アプリに内蔵しているコンパイラ。端末内で完結し、ネットワークも使わない。
public enum BuiltinCompiler: Equatable {
    case miniC
    case miniPHP
    case miniSwift
    /// 共通基盤の上に作った処理系 (言語 ID で選ぶ)。
    case miniLang(String)

    public var displayName: String {
        switch self {
        case .miniC: return "内蔵 C コンパイラ (端末内)"
        case .miniPHP: return "内蔵 PHP インタプリタ (端末内)"
        case .miniSwift: return "内蔵 Swift インタプリタ (端末内)"
        case .miniLang(let id):
            let name = MiniLangRegistry.engine(for: id)?.displayName ?? "内蔵処理系"
            return name + " (端末内)"
        }
    }
}

/// サーバー実行の指定。サービスごとに言語名が違うので両方持つ。
public struct RemoteSpec: Equatable {
    /// Piston 側の言語名。
    public var pistonLanguage: String
    /// Wandbox 側の language 名 (対応していない言語は nil)。
    public var wandboxLanguage: String?
    /// 送信するファイル名 (Java のようにファイル名が意味を持つ言語がある)。
    public var fileName: String

    public init(pistonLanguage: String, wandboxLanguage: String?, fileName: String) {
        self.pistonLanguage = pistonLanguage
        self.wandboxLanguage = wandboxLanguage
        self.fileName = fileName
    }
}

/// 実行できる言語 1 つ分の定義。
public struct ProgrammingLanguage: Equatable, Identifiable {
    public var id: String
    public var name: String
    public var fileExtensions: [String]
    /// アプリに内蔵しているコンパイラ (あればこれを最優先で使う)。
    public var builtin: BuiltinCompiler?
    /// WebView のランタイムで実行できる場合のエンジン。
    public var local: LocalEngine?
    /// サーバーでコンパイル・実行する場合の指定。
    public var remote: RemoteSpec?

    public init(id: String, name: String, fileExtensions: [String],
                builtin: BuiltinCompiler? = nil,
                local: LocalEngine? = nil, remote: RemoteSpec? = nil) {
        self.id = id
        self.name = name
        self.fileExtensions = fileExtensions
        self.builtin = builtin
        self.local = local
        self.remote = remote
    }

    public var isRunnable: Bool { builtin != nil || local != nil || remote != nil }
}

/// 実行方法の決定結果。
public enum ExecutionPlan: Equatable {
    /// HTML / SVG をそのまま WebView で表示・実行する。
    case browser
    /// アプリ内蔵のコンパイラでコンパイルして実行する。
    case builtin(BuiltinCompiler, ProgrammingLanguage)
    /// 端末内のランタイムで実行する。
    case local(LocalEngine, ProgrammingLanguage)
    /// 実行サービスに送ってコンパイル・実行する。
    case remote(RemoteSpec, ProgrammingLanguage)
    /// 実行できない (対応言語ではない、またはサーバー実行が無効)。
    case unavailable(reason: String)

    public var summary: String {
        switch self {
        case .browser:
            return "WebView で実行"
        case .builtin(let compiler, _):
            return compiler.displayName
        case .local(let engine, _):
            return engine.displayName
        case .remote(_, let language):
            return "\(language.name) をサーバーで実行"
        case .unavailable(let reason):
            return reason
        }
    }
}

/// 拡張子と言語の対応表。
public enum LanguageCatalog {
    /// 内蔵処理系を割り当てたあとの一覧。
    public static let all: [ProgrammingLanguage] = definitions.map { language in
        var updated = language
        if updated.builtin == nil, updated.local == nil,
           let engineID = builtinLanguageID(for: language.id),
           MiniLangRegistry.engine(for: engineID) != nil {
            updated.builtin = .miniLang(engineID)
        }
        return updated
    }

    /// カタログの言語 ID を内蔵処理系の言語 ID に直す。
    static func builtinLanguageID(for id: String) -> String? {
        switch id {
        case "bash": return "shell"
        default: return id
        }
    }

    private static let definitions: [ProgrammingLanguage] = [
        // --- 端末内 (WebAssembly / JavaScript) で実行できるもの ---
        ProgrammingLanguage(id: "javascript", name: "JavaScript", fileExtensions: ["js", "mjs", "cjs"],
                            local: .javascript,
                            remote: RemoteSpec(pistonLanguage: "javascript", wandboxLanguage: "JavaScript",
                                               fileName: "main.js")),
        ProgrammingLanguage(id: "typescript", name: "TypeScript", fileExtensions: ["ts"],
                            local: .typescript,
                            remote: RemoteSpec(pistonLanguage: "typescript", wandboxLanguage: "TypeScript",
                                               fileName: "main.ts")),
        ProgrammingLanguage(id: "python", name: "Python", fileExtensions: ["py"],
                            local: .python,
                            remote: RemoteSpec(pistonLanguage: "python", wandboxLanguage: "Python",
                                               fileName: "main.py")),
        ProgrammingLanguage(id: "ruby", name: "Ruby", fileExtensions: ["rb"],
                            local: .ruby,
                            remote: RemoteSpec(pistonLanguage: "ruby", wandboxLanguage: "Ruby",
                                               fileName: "main.rb")),
        ProgrammingLanguage(id: "lua", name: "Lua", fileExtensions: ["lua"],
                            local: .lua,
                            remote: RemoteSpec(pistonLanguage: "lua", wandboxLanguage: "Lua",
                                               fileName: "main.lua")),
        ProgrammingLanguage(id: "sql", name: "SQL (SQLite)", fileExtensions: ["sql"],
                            local: .sql,
                            remote: RemoteSpec(pistonLanguage: "sqlite3", wandboxLanguage: "SQL",
                                               fileName: "main.sql")),

        // --- コンパイラ / ランタイムが要るのでサーバー実行 ---
        ProgrammingLanguage(id: "c", name: "C", fileExtensions: ["c", "h"],
                            builtin: .miniC,
                            remote: RemoteSpec(pistonLanguage: "c", wandboxLanguage: "C", fileName: "main.c")),
        ProgrammingLanguage(id: "cpp", name: "C++", fileExtensions: ["cpp", "cc", "cxx", "hpp"],
                            remote: RemoteSpec(pistonLanguage: "c++", wandboxLanguage: "C++", fileName: "main.cpp")),
        ProgrammingLanguage(id: "objectivec", name: "Objective-C", fileExtensions: ["m"],
                            remote: RemoteSpec(pistonLanguage: "objective-c", wandboxLanguage: nil, fileName: "main.m")),
        ProgrammingLanguage(id: "swift", name: "Swift", fileExtensions: ["swift"],
                            builtin: .miniSwift,
                            remote: RemoteSpec(pistonLanguage: "swift", wandboxLanguage: "Swift", fileName: "main.swift")),
        ProgrammingLanguage(id: "java", name: "Java", fileExtensions: ["java"],
                            remote: RemoteSpec(pistonLanguage: "java", wandboxLanguage: "Java", fileName: "Main.java")),
        ProgrammingLanguage(id: "kotlin", name: "Kotlin", fileExtensions: ["kt", "kts"],
                            remote: RemoteSpec(pistonLanguage: "kotlin", wandboxLanguage: nil, fileName: "Main.kt")),
        ProgrammingLanguage(id: "csharp", name: "C#", fileExtensions: ["cs"],
                            remote: RemoteSpec(pistonLanguage: "csharp", wandboxLanguage: "C#", fileName: "Main.cs")),
        ProgrammingLanguage(id: "go", name: "Go", fileExtensions: ["go"],
                            remote: RemoteSpec(pistonLanguage: "go", wandboxLanguage: "Go", fileName: "main.go")),
        ProgrammingLanguage(id: "rust", name: "Rust", fileExtensions: ["rs"],
                            remote: RemoteSpec(pistonLanguage: "rust", wandboxLanguage: "Rust", fileName: "main.rs")),
        ProgrammingLanguage(id: "php", name: "PHP", fileExtensions: ["php"],
                            builtin: .miniPHP,
                            remote: RemoteSpec(pistonLanguage: "php", wandboxLanguage: "PHP", fileName: "main.php")),
        ProgrammingLanguage(id: "perl", name: "Perl", fileExtensions: ["pl"],
                            remote: RemoteSpec(pistonLanguage: "perl", wandboxLanguage: "Perl", fileName: "main.pl")),
        ProgrammingLanguage(id: "bash", name: "Shell", fileExtensions: ["sh", "bash"],
                            remote: RemoteSpec(pistonLanguage: "bash", wandboxLanguage: "Bash script", fileName: "main.sh")),
        ProgrammingLanguage(id: "haskell", name: "Haskell", fileExtensions: ["hs"],
                            remote: RemoteSpec(pistonLanguage: "haskell", wandboxLanguage: "Haskell", fileName: "main.hs")),
        ProgrammingLanguage(id: "scala", name: "Scala", fileExtensions: ["scala"],
                            remote: RemoteSpec(pistonLanguage: "scala", wandboxLanguage: "Scala", fileName: "Main.scala")),
        ProgrammingLanguage(id: "dart", name: "Dart", fileExtensions: ["dart"],
                            remote: RemoteSpec(pistonLanguage: "dart", wandboxLanguage: nil, fileName: "main.dart")),
        ProgrammingLanguage(id: "elixir", name: "Elixir", fileExtensions: ["ex", "exs"],
                            remote: RemoteSpec(pistonLanguage: "elixir", wandboxLanguage: "Elixir", fileName: "main.exs")),
        ProgrammingLanguage(id: "erlang", name: "Erlang", fileExtensions: ["erl"],
                            remote: RemoteSpec(pistonLanguage: "erlang", wandboxLanguage: "Erlang", fileName: "main.erl")),
        ProgrammingLanguage(id: "nim", name: "Nim", fileExtensions: ["nim"],
                            remote: RemoteSpec(pistonLanguage: "nim", wandboxLanguage: "Nim", fileName: "main.nim")),
        ProgrammingLanguage(id: "zig", name: "Zig", fileExtensions: ["zig"],
                            remote: RemoteSpec(pistonLanguage: "zig", wandboxLanguage: "Zig", fileName: "main.zig")),
        ProgrammingLanguage(id: "pascal", name: "Pascal", fileExtensions: ["pas"],
                            remote: RemoteSpec(pistonLanguage: "pascal", wandboxLanguage: "Pascal", fileName: "main.pas")),
        ProgrammingLanguage(id: "d", name: "D", fileExtensions: ["d"],
                            remote: RemoteSpec(pistonLanguage: "d", wandboxLanguage: "D", fileName: "main.d")),
        ProgrammingLanguage(id: "r", name: "R", fileExtensions: ["r"],
                            remote: RemoteSpec(pistonLanguage: "rscript", wandboxLanguage: "R", fileName: "main.r")),
        ProgrammingLanguage(id: "julia", name: "Julia", fileExtensions: ["jl"],
                            remote: RemoteSpec(pistonLanguage: "julia", wandboxLanguage: "Julia", fileName: "main.jl")),
        ProgrammingLanguage(id: "ocaml", name: "OCaml", fileExtensions: ["ml"],
                            remote: RemoteSpec(pistonLanguage: "ocaml", wandboxLanguage: "OCaml", fileName: "main.ml")),
        ProgrammingLanguage(id: "crystal", name: "Crystal", fileExtensions: ["cr"],
                            remote: RemoteSpec(pistonLanguage: "crystal", wandboxLanguage: "Crystal", fileName: "main.cr")),
        ProgrammingLanguage(id: "groovy", name: "Groovy", fileExtensions: ["groovy"],
                            remote: RemoteSpec(pistonLanguage: "groovy", wandboxLanguage: "Groovy", fileName: "main.groovy")),
        ProgrammingLanguage(id: "lisp", name: "Lisp", fileExtensions: ["lisp", "lsp"],
                            remote: RemoteSpec(pistonLanguage: "lisp", wandboxLanguage: "Lisp", fileName: "main.lisp")),
    ]

    public static func language(forFileName fileName: String) -> ProgrammingLanguage? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return all.first { $0.fileExtensions.contains(ext) }
    }

    public static func language(id: String) -> ProgrammingLanguage? {
        all.first { $0.id == id }
    }

    /// ファイルの種類と設定から、どう実行するかを決める。
    ///
    /// - Parameters:
    ///   - kind: 表示種別 (HTML なら WebView で実行)。
    ///   - fileName: 拡張子から言語を判定するために使う。
    ///   - allowsRemoteExecution: サーバー実行を許可しているか。
    ///   - prefersLocal: 端末内で動くならそちらを優先するか (既定 true)。
    public static func plan(kind: ContentKind,
                            fileName: String,
                            allowsRemoteExecution: Bool,
                            prefersLocal: Bool = true) -> ExecutionPlan {
        if kind == .web { return .browser }

        guard let language = language(forFileName: fileName) else {
            return .unavailable(reason: "この種類のファイルは実行できません")
        }
        return plan(for: language, allowsRemoteExecution: allowsRemoteExecution, prefersLocal: prefersLocal)
    }

    /// 言語を指定して実行方法を決める (拡張子の判定を上書きしたいとき)。
    public static func plan(for language: ProgrammingLanguage,
                            allowsRemoteExecution: Bool,
                            prefersLocal: Bool = true) -> ExecutionPlan {
        if prefersLocal, let compiler = language.builtin {
            return .builtin(compiler, language)
        }
        if prefersLocal, let engine = language.local {
            return .local(engine, language)
        }
        if let remote = language.remote {
            guard allowsRemoteExecution else {
                return .unavailable(reason: "\(language.name) の実行にはサーバー実行の許可が必要です")
            }
            return .remote(remote, language)
        }
        if let engine = language.local {
            return .local(engine, language)
        }
        if let compiler = language.builtin {
            return .builtin(compiler, language)
        }
        return .unavailable(reason: "\(language.name) は実行できません")
    }
}
