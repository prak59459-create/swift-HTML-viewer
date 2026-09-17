import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ディレクトリ一覧の 1 行。
public struct RepositoryEntry: Identifiable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int
    /// リポジトリ内の項目ならその場所。Gist のファイルなど場所を持たないものは nil。
    public var location: GitHubLocation?
    /// 直接ダウンロードできる URL (raw リンク)。
    public var downloadURL: URL?

    public var id: String {
        location.map { "\($0.owner)/\($0.repo)@\($0.ref ?? "-")/\($0.path)" } ?? (downloadURL?.absoluteString ?? name)
    }

    public init(name: String, isDirectory: Bool, size: Int = 0,
                location: GitHubLocation? = nil, downloadURL: URL? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.location = location
        self.downloadURL = downloadURL
    }
}

/// 取得したファイル本体。
public struct RemoteFile: Equatable {
    public var name: String
    public var path: String
    public var data: Data
    public var kind: ContentKind
    /// 相対パス (画像や CSS) を解決するためのベース URL。
    public var baseURL: URL?
    /// GitHub 上のページ URL。
    public var htmlURL: URL?

    public var text: String? { ContentClassifier.text(from: data) }

    public init(name: String, path: String, data: Data, kind: ContentKind,
                baseURL: URL? = nil, htmlURL: URL? = nil) {
        self.name = name
        self.path = path
        self.data = data
        self.kind = kind
        self.baseURL = baseURL
        self.htmlURL = htmlURL
    }
}

/// ディレクトリ (または Gist) の一覧。
public struct DirectoryListing: Equatable {
    public var title: String
    public var location: GitHubLocation?
    public var entries: [RepositoryEntry]

    public init(title: String, location: GitHubLocation?, entries: [RepositoryEntry]) {
        self.title = title
        self.location = location
        self.entries = entries
    }
}

public enum RemoteContent: Equatable {
    case file(RemoteFile)
    case directory(DirectoryListing)
}

public enum GitHubClientError: LocalizedError {
    case badResponse
    case http(status: Int, message: String)
    case rateLimited
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse:
            return "サーバーからの応答を解釈できませんでした。"
        case .http(let status, let message):
            return "HTTP \(status): \(message)"
        case .rateLimited:
            return "GitHub API のレート制限に達しました。設定でアクセストークンを入力すると上限が上がります。"
        case .notFound(let path):
            return "見つかりませんでした: \(path)"
        }
    }
}

/// GitHub REST API (と raw.githubusercontent.com) からコンテンツを取得する。
public struct GitHubClient {
    public var token: String?
    /// API のホスト。GitHub Enterprise では自分のホストに差し替える。
    public var apiHost: String
    /// 生ファイルのホスト。
    public var rawHost: String
    /// 応答ヘッダからレート制限を記録する先 (任意)。
    public var rateLimitMonitor: RateLimitMonitor?
    let session: URLSession

    public init(token: String? = nil, session: URLSession = .shared,
                apiHost: String = "api.github.com",
                rawHost: String = "raw.githubusercontent.com",
                rateLimitMonitor: RateLimitMonitor? = nil) {
        self.token = (token?.isEmpty == false) ? token : nil
        self.session = session
        self.apiHost = apiHost.isEmpty ? "api.github.com" : apiHost
        self.rawHost = rawHost.isEmpty ? "raw.githubusercontent.com" : rawHost
        self.rateLimitMonitor = rateLimitMonitor
    }

    /// API の URL を組み立てる。
    func apiURL(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url ?? URL(string: "https://\(apiHost)\(path)")!
    }

    // MARK: - 公開 API

    public func fetch(_ target: GitHubTarget) async throws -> RemoteContent {
        switch target {
        case .repository(let location):
            return try await fetchRepository(location)
        case .gist(let id):
            return try await fetchGist(id: id)
        case .rawURL(let url):
            return .file(try await fetchRawFile(url))
        }
    }

    /// リポジトリのデフォルトブランチ名を取得する。
    public func defaultBranch(owner: String, repo: String) async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!
        let data = try await get(url, accept: "application/vnd.github+json")
        struct Repo: Decodable { let default_branch: String }
        guard let repo = try? JSONDecoder().decode(Repo.self, from: data) else {
            throw GitHubClientError.badResponse
        }
        return repo.default_branch
    }

    // MARK: - リポジトリ

    private func fetchRepository(_ location: GitHubLocation) async throws -> RemoteContent {
        var location = location
        if location.ref == nil {
            location.ref = try await defaultBranch(owner: location.owner, repo: location.repo)
        }
        let ref = location.ref ?? "HEAD"

        // ルートでは末尾のスラッシュを付けない (一部のプロキシが弾くため)。
        let encodedPath = encodePath(location.path)
        let contentsPath = encodedPath.isEmpty ? "contents" : "contents/\(encodedPath)"
        var components = URLComponents(string: "https://api.github.com/repos/\(location.owner)/\(location.repo)/\(contentsPath)")!
        components.queryItems = [URLQueryItem(name: "ref", value: ref)]
        guard let url = components.url else { throw GitHubClientError.notFound(location.path) }

        let data = try await get(url, accept: "application/vnd.github+json")
        let decoder = JSONDecoder()

        if let items = try? decoder.decode([ContentsItem].self, from: data) {
            let entries = items
                .sorted { lhs, rhs in
                    if (lhs.type == "dir") != (rhs.type == "dir") { return lhs.type == "dir" }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                .map { item -> RepositoryEntry in
                    let isDirectory = item.type == "dir"
                    let child = GitHubLocation(owner: location.owner, repo: location.repo, ref: ref,
                                               path: item.path, isDirectory: isDirectory)
                    return RepositoryEntry(name: item.name, isDirectory: isDirectory, size: item.size ?? 0,
                                           location: child,
                                           downloadURL: item.download_url.flatMap(URL.init(string:)))
                }
            let title = location.path.isEmpty
                ? "\(location.owner)/\(location.repo)"
                : "\(location.owner)/\(location.repo)/\(location.path)"
            var directory = location
            directory.isDirectory = true
            return .directory(DirectoryListing(title: title, location: directory, entries: entries))
        }

        guard let item = try? decoder.decode(ContentsItem.self, from: data) else {
            throw GitHubClientError.badResponse
        }

        let bytes: Data
        if let encoded = item.content, item.encoding == "base64",
           let decoded = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")) {
            bytes = decoded
        } else if let downloadURL = item.download_url.flatMap(URL.init(string:)) {
            // 1MB を超えるファイルは content が空になるため raw から取り直す。
            bytes = try await get(downloadURL, accept: nil)
        } else {
            throw GitHubClientError.notFound(location.path)
        }

        return .file(RemoteFile(
            name: item.name,
            path: item.path,
            data: bytes,
            kind: ContentClassifier.classify(fileName: item.name, data: bytes),
            baseURL: rawBaseURL(owner: location.owner, repo: location.repo, ref: ref, filePath: item.path),
            htmlURL: item.html_url.flatMap(URL.init(string:))
        ))
    }

    // MARK: - Gist

    private func fetchGist(id: String) async throws -> RemoteContent {
        let url = URL(string: "https://api.github.com/gists/\(id)")!
        let data = try await get(url, accept: "application/vnd.github+json")
        guard let gist = try? JSONDecoder().decode(GistResponse.self, from: data) else {
            throw GitHubClientError.badResponse
        }

        let files = gist.files.values.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }

        // ファイルが 1 つだけならそのまま開く。
        if files.count == 1, let file = files.first {
            let bytes: Data
            if let content = file.content, file.truncated != true {
                bytes = Data(content.utf8)
            } else if let rawURL = file.raw_url.flatMap(URL.init(string:)) {
                bytes = try await get(rawURL, accept: nil)
            } else {
                throw GitHubClientError.notFound(file.filename)
            }
            return .file(RemoteFile(
                name: file.filename,
                path: file.filename,
                data: bytes,
                kind: ContentClassifier.classify(fileName: file.filename, data: bytes),
                baseURL: file.raw_url.flatMap(URL.init(string:))?.deletingLastPathComponent(),
                htmlURL: gist.html_url.flatMap(URL.init(string:))
            ))
        }

        let entries = files.map { file in
            RepositoryEntry(name: file.filename, isDirectory: false, size: file.size ?? 0,
                            location: nil, downloadURL: file.raw_url.flatMap(URL.init(string:)))
        }
        return .directory(DirectoryListing(title: "Gist \(id)", location: nil, entries: entries))
    }

    // MARK: - 任意の URL

    public func fetchRawFile(_ url: URL) async throws -> RemoteFile {
        let bytes = try await get(url, accept: nil)
        let name = url.lastPathComponent.isEmpty ? (url.host ?? "index.html") : url.lastPathComponent
        return RemoteFile(
            name: name,
            path: url.path,
            data: bytes,
            kind: ContentClassifier.classify(fileName: name, data: bytes),
            baseURL: url.deletingLastPathComponent(),
            htmlURL: url
        )
    }

    // MARK: - 下請け

    private func rawBaseURL(owner: String, repo: String, ref: String, filePath: String) -> URL? {
        var directory = filePath.split(separator: "/").map(String.init)
        if !directory.isEmpty { directory.removeLast() }
        var string = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/"
        if !directory.isEmpty { string += directory.joined(separator: "/") + "/" }
        return URL(string: string)
    }

    private func encodePath(_ path: String) -> String {
        path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    func get(_ url: URL, accept: String?) async throws -> Data {
        try await send(url, method: "GET", accept: accept, body: nil).0
    }

    /// 任意のメソッドで送る。応答ヘッダも返す。
    @discardableResult
    func send(_ url: URL, method: String, accept: String?,
              body: Data?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("GitHubViewer", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, http) = try await HTTP.send(request, session: session)
        rateLimitMonitor?.update(from: http)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403 || http.statusCode == 429,
               http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                throw GitHubClientError.rateLimited
            }
            if http.statusCode == 404 { throw GitHubClientError.notFound(url.absoluteString) }
            let message = apiMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GitHubClientError.http(status: http.statusCode, message: message)
        }
        return (data, http)
    }

    func apiMessage(from data: Data) -> String? {
        struct APIError: Decodable { let message: String }
        return (try? JSONDecoder().decode(APIError.self, from: data))?.message
    }
}

// MARK: - JSON モデル

private struct ContentsItem: Decodable {
    let name: String
    let path: String
    let type: String
    let size: Int?
    let content: String?
    let encoding: String?
    let download_url: String?
    let html_url: String?
}

private struct GistResponse: Decodable {
    let html_url: String?
    let files: [String: GistFile]
}

private struct GistFile: Decodable {
    let filename: String
    let raw_url: String?
    let size: Int?
    let truncated: Bool?
    let content: String?
}
