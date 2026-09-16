import Foundation

/// ソース上の位置 (1 始まり)。
public struct SourceLocation: Equatable, Hashable, CustomStringConvertible {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static let unknown = SourceLocation(line: 0, column: 0)

    public var description: String { "\(line):\(column)" }
}

/// コンパイルエラー / 警告 1 件。
public struct Diagnostic: Equatable {
    public enum Severity: String, Equatable {
        case error = "エラー"
        case warning = "警告"
    }

    public var severity: Severity
    public var message: String
    public var location: SourceLocation

    public init(severity: Severity = .error, message: String, location: SourceLocation) {
        self.severity = severity
        self.message = message
        self.location = location
    }
}

/// コンパイルに失敗したときに投げられるエラー。
/// ソースの該当行とキャレットを添えた読みやすい説明を作る。
public struct CompileFailure: Error, CustomStringConvertible {
    public var diagnostics: [Diagnostic]
    public var source: String

    public init(diagnostics: [Diagnostic], source: String) {
        self.diagnostics = diagnostics
        self.source = source
    }

    public var description: String { formatted }

    public var formatted: String {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return diagnostics.map { diagnostic -> String in
            var text = "\(diagnostic.location.line):\(diagnostic.location.column): "
                + "\(diagnostic.severity.rawValue): \(diagnostic.message)"
            let index = diagnostic.location.line - 1
            if index >= 0, index < lines.count {
                let sourceLine = lines[index].replacingOccurrences(of: "\t", with: "    ")
                text += "\n  " + sourceLine
                let column = max(1, diagnostic.location.column)
                text += "\n  " + String(repeating: " ", count: column - 1) + "^"
            }
            return text
        }.joined(separator: "\n\n")
    }

    /// エラーだけを集めた短い一覧 (1 行ずつ)。
    public var summary: String {
        diagnostics.map { "\($0.location.line):\($0.location.column): \($0.message)" }
            .joined(separator: "\n")
    }
}

/// 診断を貯めて、エラーがあれば投げるための入れ物。
public final class DiagnosticBag {
    public private(set) var diagnostics: [Diagnostic] = []
    public let source: String
    /// 型を調べるためだけに式を解析するときなど、記録を止めたい区間の深さ。
    private var suppressionDepth = 0

    public init(source: String) {
        self.source = source
    }

    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    public func beginSuppression() { suppressionDepth += 1 }

    public func endSuppression() { suppressionDepth = max(0, suppressionDepth - 1) }

    public func error(_ message: String, at location: SourceLocation) {
        guard suppressionDepth == 0 else { return }
        diagnostics.append(Diagnostic(severity: .error, message: message, location: location))
    }

    public func warning(_ message: String, at location: SourceLocation) {
        guard suppressionDepth == 0 else { return }
        diagnostics.append(Diagnostic(severity: .warning, message: message, location: location))
    }

    public func failureIfNeeded() -> CompileFailure? {
        hasErrors ? CompileFailure(diagnostics: diagnostics, source: source) : nil
    }
}

/// 解析を打ち切るための内部エラー (メッセージは DiagnosticBag に入っている)。
public struct AbortCompilation: Error {
    public init() {}
}
