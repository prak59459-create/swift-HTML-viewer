import Foundation

/// 最小限のプリプロセッサ。
///
/// - `#include` は標準ヘッダを前提にしているので読み飛ばす (標準関数は組み込みで用意する)
/// - `#define` はオブジェクト形式と関数形式の両方に対応
/// - `#ifdef` / `#ifndef` / `#if` (定数と `defined`) / `#else` / `#elif` / `#endif`
/// - `#undef`, `#pragma`, `#line`, `#error`
struct Preprocessor {
    struct Macro {
        var parameters: [String]?
        var body: [Token]
    }

    private var macros: [String: Macro] = [:]
    private let diagnostics: DiagnosticBag
    private static let maxExpansionDepth = 32

    init(diagnostics: DiagnosticBag, predefined: [String: [Token]] = [:]) {
        self.diagnostics = diagnostics
        for (name, body) in predefined {
            macros[name] = Macro(parameters: nil, body: body)
        }
    }

    mutating func process(_ tokens: [Token]) -> [Token] {
        var output: [Token] = []
        var index = 0
        /// 条件付きコンパイルの状態 (有効な分岐にいるか、この #if で既に採用済みか)
        var conditionStack: [(active: Bool, taken: Bool)] = []

        func isActive() -> Bool { conditionStack.allSatisfy(\.active) }

        while index < tokens.count {
            let token = tokens[index]
            if case .endOfFile = token.kind {
                output.append(token)
                break
            }

            guard token.isAtLineStart, token.isPunctuator(.hash) else {
                if isActive() {
                    output.append(contentsOf: expand(tokens, at: &index))
                } else {
                    index += 1
                }
                continue
            }

            // 指令 1 行を切り出す。
            index += 1
            var directiveTokens: [Token] = []
            while index < tokens.count, !tokens[index].isAtLineStart {
                if case .endOfFile = tokens[index].kind { break }
                directiveTokens.append(tokens[index])
                index += 1
            }
            guard let first = directiveTokens.first else { continue }
            let directive = directiveName(first)
            let arguments = Array(directiveTokens.dropFirst())

            switch directive {
            case "include", "pragma", "line", "warning":
                break // 何もしない

            case "error":
                if isActive() {
                    let message = arguments.map(\.text).joined(separator: " ")
                    diagnostics.error("#error \(message)", at: first.location)
                }

            case "define":
                if isActive() { defineMacro(arguments, at: first.location) }

            case "undef":
                if isActive(), let name = arguments.first?.identifier { macros.removeValue(forKey: name) }

            case "ifdef", "ifndef":
                let name = arguments.first?.identifier ?? ""
                var condition = macros[name] != nil
                if directive == "ifndef" { condition.toggle() }
                let parentActive = isActive()
                conditionStack.append((active: parentActive && condition, taken: condition))

            case "if":
                let parentActive = isActive()
                let condition = evaluateCondition(arguments, at: first.location)
                conditionStack.append((active: parentActive && condition, taken: condition))

            case "elif":
                guard var current = conditionStack.popLast() else {
                    diagnostics.error("対応する #if がない #elif です。", at: first.location)
                    break
                }
                let parentActive = isActive()
                let condition = !current.taken && evaluateCondition(arguments, at: first.location)
                current.active = parentActive && condition
                current.taken = current.taken || condition
                conditionStack.append(current)

            case "else":
                guard var current = conditionStack.popLast() else {
                    diagnostics.error("対応する #if がない #else です。", at: first.location)
                    break
                }
                let parentActive = isActive()
                current.active = parentActive && !current.taken
                current.taken = true
                conditionStack.append(current)

            case "endif":
                if conditionStack.popLast() == nil {
                    diagnostics.error("対応する #if がない #endif です。", at: first.location)
                }

            default:
                if isActive() {
                    diagnostics.warning("知らないプリプロセッサ指令です: #\(directive)", at: first.location)
                }
            }
        }

        if !conditionStack.isEmpty {
            diagnostics.error("#endif が足りません。", at: tokens.last?.location ?? .unknown)
        }
        return output
    }

    private func directiveName(_ token: Token) -> String {
        switch token.kind {
        case .identifier(let name): return name
        case .keyword(let keyword): return keyword.rawValue
        default: return token.text
        }
    }

    // MARK: - #define

    private mutating func defineMacro(_ tokens: [Token], at location: SourceLocation) {
        guard let nameToken = tokens.first, let name = nameToken.identifier else {
            diagnostics.error("#define の名前がありません。", at: location)
            return
        }
        var rest = Array(tokens.dropFirst())

        // 関数形式かどうか (名前の直後に括弧があり、間に空白がない場合。
        // ここでは簡単のため、括弧が続いていれば関数形式として扱う)
        var parameters: [String]?
        if let first = rest.first, first.isPunctuator(.leftParen),
           first.location.line == nameToken.location.line,
           first.location.column == nameToken.location.column + name.count {
            var names: [String] = []
            var index = 1
            while index < rest.count, !rest[index].isPunctuator(.rightParen) {
                if let parameter = rest[index].identifier { names.append(parameter) }
                index += 1
            }
            parameters = names
            rest = Array(rest.dropFirst(min(index + 1, rest.count)))
        }

        macros[name] = Macro(parameters: parameters, body: rest)
    }

    // MARK: - マクロ展開

    /// `tokens[index]` を展開して結果を返す。index は消費した分だけ進む。
    private func expand(_ tokens: [Token], at index: inout Int, depth: Int = 0) -> [Token] {
        let token = tokens[index]
        guard depth < Preprocessor.maxExpansionDepth,
              let name = token.identifier,
              let macro = macros[name] else {
            index += 1
            return [token]
        }

        guard let parameters = macro.parameters else {
            index += 1
            return reexpand(macro.body, origin: token, depth: depth)
        }

        // 関数形式: 引数リストが続いていなければ展開しない。
        guard index + 1 < tokens.count, tokens[index + 1].isPunctuator(.leftParen) else {
            index += 1
            return [token]
        }

        var cursor = index + 2
        var arguments: [[Token]] = []
        var current: [Token] = []
        var depthCount = 0
        while cursor < tokens.count {
            let argumentToken = tokens[cursor]
            if case .endOfFile = argumentToken.kind { break }
            if argumentToken.isPunctuator(.leftParen) { depthCount += 1 }
            if argumentToken.isPunctuator(.rightParen) {
                if depthCount == 0 { break }
                depthCount -= 1
            }
            if argumentToken.isPunctuator(.comma), depthCount == 0 {
                arguments.append(current)
                current = []
                cursor += 1
                continue
            }
            current.append(argumentToken)
            cursor += 1
        }
        if !current.isEmpty || !arguments.isEmpty { arguments.append(current) }
        index = min(cursor + 1, tokens.count) // 閉じ括弧の次へ

        var substituted: [Token] = []
        for bodyToken in macro.body {
            if let identifier = bodyToken.identifier,
               let position = parameters.firstIndex(of: identifier),
               position < arguments.count {
                substituted.append(contentsOf: arguments[position])
            } else {
                substituted.append(bodyToken)
            }
        }
        return reexpand(substituted, origin: token, depth: depth)
    }

    /// 展開結果の中に現れるマクロをもう一段だけ展開し、位置情報を呼び出し側に揃える。
    private func reexpand(_ body: [Token], origin: Token, depth: Int) -> [Token] {
        var result: [Token] = []
        var index = 0
        var relocated = body.map { token -> Token in
            var copy = token
            copy.location = origin.location
            copy.isAtLineStart = false
            return copy
        }
        relocated.append(Token(kind: .endOfFile, location: origin.location, isAtLineStart: false))

        while index < relocated.count - 1 {
            result.append(contentsOf: expand(relocated, at: &index, depth: depth + 1))
        }
        return result
    }

    // MARK: - #if の条件式

    private func evaluateCondition(_ tokens: [Token], at location: SourceLocation) -> Bool {
        var values: [Int64] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token.kind {
            case .integer(let value, _):
                values.append(value)
            case .identifier(let name):
                if name == "defined" {
                    var cursor = index + 1
                    if cursor < tokens.count, tokens[cursor].isPunctuator(.leftParen) { cursor += 1 }
                    let target = cursor < tokens.count ? (tokens[cursor].identifier ?? "") : ""
                    values.append(macros[target] != nil ? 1 : 0)
                    index = cursor
                } else if let macro = macros[name], macro.parameters == nil,
                          case .integer(let value, _)? = macro.body.first?.kind {
                    values.append(value)
                } else {
                    values.append(0)
                }
            default:
                break
            }
            index += 1
        }
        // 演算子は扱わない。最初の値の真偽だけを見る。
        return (values.first ?? 0) != 0
    }
}
