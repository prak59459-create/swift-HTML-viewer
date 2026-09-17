import Foundation

/// 内蔵処理系の一覧。アプリ側の実行と、開発用 CLI・テストの両方から引く。
public enum MiniLangRegistry {
    /// 言語 ID → 処理系。
    public static let engines: [String: MiniLangEngine.Type] = {
        var table: [String: MiniLangEngine.Type] = [:]
        for engine in all { table[engine.languageID] = engine }
        return table
    }()

    /// 登録順 (README や設定画面の並びにも使う)。
    public static let all: [MiniLangEngine.Type] = [
        MiniJava.self,
        MiniCSharp.self,
        MiniKotlin.self,
        MiniScala.self,
        MiniGo.self,
        MiniRust.self,
        MiniCpp.self,
        MiniJavaScript.self,
        MiniTypeScript.self,
        MiniDart.self,
        MiniGroovy.self,
        MiniD.self,
        MiniObjectiveC.self,
        MiniZig.self,
        MiniJulia.self,
        MiniCrystal.self,
        MiniNim.self,
        MiniPascal.self,
        MiniPerl.self,
        MiniR.self,
        MiniLisp.self,
        MiniElixir.self,
        MiniShell.self,
        MiniErlang.self,
        MiniOCaml.self
    ]

    public static func engine(for languageID: String) -> MiniLangEngine.Type? {
        engines[languageID]
    }

    /// 内蔵処理系を持つ言語 ID の一覧。
    public static var supportedLanguageIDs: [String] { all.map { $0.languageID } }
}
