import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GitHubViewerCore

/// 通信の代わりに、決めておいた応答を返す。
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String]

        init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }

        static func json(_ text: String, status: Int = 200,
                         headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: Data(text.utf8), headers: headers)
        }
    }

    /// パスの一部 (と、指定があればメソッド) → 返すもの。
    nonisolated(unsafe) static var replies: [(match: String, method: String?,
                                              reply: Reply)] = []
    /// 受け取った要求の記録。
    nonisolated(unsafe) static var requests: [(method: String, url: String, body: String)] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        replies = []
        requests = []
        lock.unlock()
    }

    static func stub(_ match: String, method: String? = nil, _ reply: Reply) {
        lock.lock()
        replies.append((match, method, reply))
        lock.unlock()
    }

    static func stubJSON(_ match: String, method: String? = nil, _ text: String,
                         status: Int = 200, headers: [String: String] = [:]) {
        stub(match, method: method, .json(text, status: status, headers: headers))
    }

    /// テスト用のセッション。
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func makeClient(token: String? = "test-token",
                           monitor: RateLimitMonitor? = nil) -> GitHubClient {
        GitHubClient(token: token, session: makeSession(), rateLimitMonitor: monitor)
    }

    /// 最後に送った本文を JSON として読む。
    static func lastBody() -> [String: Any]? {
        lock.lock()
        let text = requests.last?.body
        lock.unlock()
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func bodies() -> [[String: Any]] {
        lock.lock()
        let all = requests.map(\.body)
        lock.unlock()
        return all.compactMap {
            guard let data = $0.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        var body = ""
        if let data = request.httpBody {
            body = String(decoding: data, as: UTF8.self)
        } else if let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            body = String(decoding: collected, as: UTF8.self)
        }

        let method = request.httpMethod ?? "GET"
        Self.lock.lock()
        Self.requests.append((method, url, body))
        // メソッドまで指定してあるものを先に見る。
        let match = (Self.replies.first { url.contains($0.match) && $0.method == method }
            ?? Self.replies.first { url.contains($0.match) && $0.method == nil })?.reply
        Self.lock.unlock()

        let reply = match ?? Reply(status: 404, body: Data(#"{"message":"Not Found"}"#.utf8))
        var headers = reply.headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://x")!,
                                       statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response,
                            cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
