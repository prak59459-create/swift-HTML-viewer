import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// サーバー実行 (コンパイル + 実行) の結果。
public struct ExecutionOutput: Equatable, Sendable {
    public var languageVersion: String
    public var compileOutput: String
    public var stdout: String
    public var stderr: String
    public var exitCode: Int?

    public var isEmpty: Bool {
        compileOutput.isEmpty && stdout.isEmpty && stderr.isEmpty
    }

    public init(languageVersion: String = "", compileOutput: String = "",
                stdout: String = "", stderr: String = "", exitCode: Int? = nil) {
        self.languageVersion = languageVersion
        self.compileOutput = compileOutput
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// どの実行サービスを使うか。
public enum ExecutionBackend: String, CaseIterable, Identifiable, Equatable {
    /// <https://wandbox.org> の公開 API。登録不要で使える。
    case wandbox
    /// <https://github.com/engineer-man/piston> の API。
    /// 公開インスタンスは 2026 年からホワイトリスト制なので、基本は自分で立てたものを指定する。
    case piston

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wandbox: return "Wandbox (登録不要)"
        case .piston: return "Piston (自前ホスト推奨)"
        }
    }
}

public enum CodeRunnerError: LocalizedError, Equatable {
    case unsupportedLanguage(String)
    case http(status: Int, message: String)
    case service(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let name):
            return "この実行サービスは \(name) に対応していません。"
        case .http(let status, let message):
            return "実行サービスのエラー (HTTP \(status)): \(message)"
        case .service(let message):
            return "実行サービスがエラーを返しました: \(message)"
        case .badResponse:
            return "実行サービスからの応答を解釈できませんでした。"
        }
    }
}

/// コンパイラ / インタプリタを持つ実行サービスのクライアント。
///
/// C, C++, Java, Go, Rust, Swift などブラウザ内で動かせない言語は、
/// ソースをこのサービスに送ってコンパイル・実行する。
public actor CodeRunner {
    public static let defaultPistonEndpoint = URL(string: "https://emkc.org/api/v2/piston")!
    public static let wandboxEndpoint = URL(string: "https://wandbox.org/api")!

    private let session: URLSession
    /// Wandbox の言語名 → コンパイラ名。
    private var wandboxCompilers: [String: String] = [:]
    /// Piston の言語名 → バージョン。
    private var pistonVersions: [String: String] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func run(spec: RemoteSpec,
                    source: String,
                    stdin: String = "",
                    backend: ExecutionBackend,
                    pistonEndpoint: URL = CodeRunner.defaultPistonEndpoint) async throws -> ExecutionOutput {
        switch backend {
        case .wandbox:
            return try await runOnWandbox(spec: spec, source: source, stdin: stdin)
        case .piston:
            return try await runOnPiston(spec: spec, source: source, stdin: stdin, endpoint: pistonEndpoint)
        }
    }

    // MARK: - Wandbox

    private func runOnWandbox(spec: RemoteSpec, source: String, stdin: String) async throws -> ExecutionOutput {
        guard let language = spec.wandboxLanguage else {
            throw CodeRunnerError.unsupportedLanguage(spec.pistonLanguage)
        }
        let compiler = try await wandboxCompiler(for: language)

        var request = URLRequest(url: CodeRunner.wandboxEndpoint.appendingPathComponent("compile.json"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GitHubViewer", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "compiler": compiler,
            "code": source,
            "stdin": stdin,
            "save": false,
        ])

        let (data, http) = try await HTTP.send(request, session: session)
        guard (200..<300).contains(http.statusCode) else {
            throw CodeRunnerError.http(status: http.statusCode, message: message(from: data))
        }
        guard let response = try? JSONDecoder().decode(WandboxResponse.self, from: data) else {
            // Wandbox は障害時に JSON ではないエラー文字列を返すことがある。
            throw CodeRunnerError.service(message(from: data))
        }

        return ExecutionOutput(
            languageVersion: compiler,
            compileOutput: [response.compiler_output, response.compiler_error]
                .compactMap { $0 }.joined().trimmingCharacters(in: .whitespacesAndNewlines),
            stdout: response.program_output ?? "",
            stderr: response.program_error ?? "",
            exitCode: response.status.flatMap(Int.init)
        )
    }

    private func wandboxCompiler(for language: String) async throws -> String {
        if let cached = wandboxCompilers[language] { return cached }

        var request = URLRequest(url: CodeRunner.wandboxEndpoint.appendingPathComponent("list.json"))
        request.setValue("GitHubViewer", forHTTPHeaderField: "User-Agent")
        let (data, http) = try await HTTP.send(request, session: session)
        guard (200..<300).contains(http.statusCode),
              let compilers = try? JSONDecoder().decode([WandboxCompiler].self, from: data) else {
            throw CodeRunnerError.badResponse
        }
        for compiler in compilers where wandboxCompilers[compiler.language] == nil {
            wandboxCompilers[compiler.language] = compiler.name
        }
        guard let compiler = wandboxCompilers[language] else {
            throw CodeRunnerError.unsupportedLanguage(language)
        }
        return compiler
    }

    // MARK: - Piston

    private func runOnPiston(spec: RemoteSpec, source: String, stdin: String, endpoint: URL) async throws -> ExecutionOutput {
        let version = try await pistonVersion(for: spec.pistonLanguage, endpoint: endpoint)

        var request = URLRequest(url: endpoint.appendingPathComponent("execute"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GitHubViewer", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "language": spec.pistonLanguage,
            "version": version,
            "stdin": stdin,
            "files": [["name": spec.fileName, "content": source]],
        ])

        let (data, http) = try await HTTP.send(request, session: session)
        guard (200..<300).contains(http.statusCode) else {
            throw CodeRunnerError.http(status: http.statusCode, message: message(from: data))
        }
        guard let response = try? JSONDecoder().decode(PistonExecuteResponse.self, from: data) else {
            throw CodeRunnerError.service(message(from: data))
        }

        return ExecutionOutput(
            languageVersion: "\(response.language) \(response.version)",
            compileOutput: [response.compile?.stdout, response.compile?.stderr]
                .compactMap { $0 }.joined().trimmingCharacters(in: .whitespacesAndNewlines),
            stdout: response.run.stdout ?? "",
            stderr: response.run.stderr ?? "",
            exitCode: response.run.code
        )
    }

    private func pistonVersion(for language: String, endpoint: URL) async throws -> String {
        if let cached = pistonVersions[language] { return cached }

        var request = URLRequest(url: endpoint.appendingPathComponent("runtimes"))
        request.setValue("GitHubViewer", forHTTPHeaderField: "User-Agent")
        let (data, http) = try await HTTP.send(request, session: session)
        guard (200..<300).contains(http.statusCode),
              let runtimes = try? JSONDecoder().decode([PistonRuntime].self, from: data) else {
            // 一覧が取れないときは最新指定で試す。
            return "*"
        }
        for runtime in runtimes {
            pistonVersions[runtime.language] = runtime.version
            for alias in runtime.aliases ?? [] where pistonVersions[alias] == nil {
                pistonVersions[alias] = runtime.version
            }
        }
        guard let version = pistonVersions[language] else {
            throw CodeRunnerError.unsupportedLanguage(language)
        }
        return version
    }

    // MARK: - 補助

    private func message(from data: Data) -> String {
        if let error = try? JSONDecoder().decode(ServiceMessage.self, from: data) {
            return error.message
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return String(text.prefix(300))
    }
}

// MARK: - JSON モデル

private struct WandboxCompiler: Decodable {
    let name: String
    let language: String
}

private struct WandboxResponse: Decodable {
    let status: String?
    let compiler_output: String?
    let compiler_error: String?
    let program_output: String?
    let program_error: String?
}

private struct PistonRuntime: Decodable {
    let language: String
    let version: String
    let aliases: [String]?
}

private struct PistonExecuteResponse: Decodable {
    struct Stage: Decodable {
        let stdout: String?
        let stderr: String?
        let code: Int?
    }
    let language: String
    let version: String
    let run: Stage
    let compile: Stage?
}

private struct ServiceMessage: Decodable {
    let message: String
}
