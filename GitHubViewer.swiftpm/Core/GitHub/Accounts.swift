import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

// MARK: - 90 / 91. ホストの指定と複数アカウント

/// 接続先のホスト。GitHub Enterprise では自分のホストを入れる。
public struct GitHubHost: Equatable, Codable, Sendable {
    /// 表示名。
    public var name: String
    /// API のホスト (`api.github.com` または `ghe.example.com`)。
    public var apiHost: String
    /// 生ファイルのホスト。
    public var rawHost: String
    /// Web ページのホスト。
    public var webHost: String

    public init(name: String, apiHost: String, rawHost: String, webHost: String) {
        self.name = name
        self.apiHost = apiHost
        self.rawHost = rawHost
        self.webHost = webHost
    }

    /// github.com。
    public static let dotCom = GitHubHost(name: "GitHub.com",
                                          apiHost: "api.github.com",
                                          rawHost: "raw.githubusercontent.com",
                                          webHost: "github.com")

    /// GitHub Enterprise Server のホスト名から組み立てる。
    ///
    /// `https://ghe.example.com` でも `ghe.example.com` でも受け付ける。
    public static func enterprise(_ host: String, name: String? = nil) -> GitHubHost {
        var clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where clean.hasPrefix(prefix) {
            clean.removeFirst(prefix.count)
        }
        while clean.hasSuffix("/") { clean.removeLast() }
        if clean.hasSuffix("/api/v3") { clean.removeLast(7) }
        return GitHubHost(name: name ?? clean, apiHost: clean,
                          rawHost: "\(clean)/raw", webHost: clean)
    }

    public var isDotCom: Bool { apiHost == "api.github.com" }
}

/// ログインしているアカウント 1 つ。
///
/// トークンそのものはここには入れず、`TokenStore` に預ける。
public struct GitHubAccount: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var login: String
    public var displayName: String
    public var avatarURL: URL?
    public var host: GitHubHost

    public init(id: String = UUID().uuidString, login: String,
                displayName: String? = nil, avatarURL: URL? = nil,
                host: GitHubHost = .dotCom) {
        self.id = id
        self.login = login
        self.displayName = displayName ?? login
        self.avatarURL = avatarURL
        self.host = host
    }

    /// Keychain に入れるときの鍵。
    public var tokenKey: String { "\(host.apiHost)/\(login)" }

    /// `owner/repo` のような表示。
    public var subtitle: String { host.isDotCom ? login : "\(login) @ \(host.name)" }
}

// MARK: - 87. トークンの保管

/// トークンの入れ物。Keychain でもメモリでも同じように使える。
public protocol TokenStore: AnyObject {
    func token(for key: String) -> String?
    func setToken(_ token: String?, for key: String)
    func removeAll()
}

/// テストや、Keychain が使えない環境のための入れ物。
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public func token(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func setToken(_ token: String?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let token, !token.isEmpty { values[key] = token } else { values[key] = nil }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
    }
}

#if canImport(Security)
/// Keychain に預ける入れ物 (iPadOS / macOS)。
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    /// Keychain の「サービス」名。
    public let service: String

    public init(service: String = "com.example.GitHubViewer.token") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func token(for key: String) -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String?, for key: String) {
        let request = query(key)
        guard let token, !token.isEmpty else {
            SecItemDelete(request as CFDictionary)
            return
        }
        let data = Data(token.utf8)
        let updates: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(request as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var insert = request
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    public func removeAll() {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service]
        SecItemDelete(request as CFDictionary)
    }
}
#endif

/// その環境でいちばん安全な入れ物を返す。
public enum TokenStoreFactory {
    public static func makeDefault(service: String = "com.example.GitHubViewer.token")
        -> TokenStore {
        #if canImport(Security)
        return KeychainTokenStore(service: service)
        #else
        return MemoryTokenStore()
        #endif
    }
}

// MARK: - 91. アカウントの切り替え

/// 複数アカウントをまとめて面倒を見る。
public final class AccountManager: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GitHubAccount] = []
    private var selectedID: String?
    private let store: TokenStore
    /// アカウントの一覧をしまう場所 (UserDefaults など)。
    private let save: (@Sendable (Data) -> Void)?

    public init(accounts: [GitHubAccount] = [], selectedID: String? = nil,
                tokenStore: TokenStore = MemoryTokenStore(),
                save: (@Sendable (Data) -> Void)? = nil) {
        self.stored = accounts
        self.selectedID = selectedID ?? accounts.first?.id
        self.store = tokenStore
        self.save = save
    }

    /// 保存しておいた JSON から復元する。
    public convenience init(json: Data?, tokenStore: TokenStore = MemoryTokenStore(),
                            save: (@Sendable (Data) -> Void)? = nil) {
        struct Saved: Codable {
            var accounts: [GitHubAccount]
            var selectedID: String?
        }
        let loaded = json.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        self.init(accounts: loaded?.accounts ?? [], selectedID: loaded?.selectedID,
                  tokenStore: tokenStore, save: save)
    }

    public var accounts: [GitHubAccount] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// いま選んでいるアカウント。
    public var selected: GitHubAccount? {
        lock.lock()
        defer { lock.unlock() }
        guard let selectedID else { return stored.first }
        return stored.first { $0.id == selectedID } ?? stored.first
    }

    /// 足す (同じ login + ホストなら入れ替える)。
    ///
    /// 足した直後はそのアカウントに切り替わる。ログインし終えた人が
    /// そのまま使い始められるようにするため。
    public func add(_ account: GitHubAccount, token: String?) {
        lock.lock()
        if let index = stored.firstIndex(where: { $0.tokenKey == account.tokenKey }) {
            var replacement = account
            replacement.id = stored[index].id
            stored[index] = replacement
            selectedID = replacement.id
        } else {
            stored.append(account)
            selectedID = account.id
        }
        lock.unlock()
        store.setToken(token, for: account.tokenKey)
        persist()
    }

    /// 消す。トークンも一緒に消す。
    public func remove(id: String) {
        lock.lock()
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let removed = stored.remove(at: index)
        if selectedID == id { selectedID = stored.first?.id }
        lock.unlock()
        store.setToken(nil, for: removed.tokenKey)
        persist()
    }

    /// 選び直す。
    public func select(id: String) {
        lock.lock()
        if stored.contains(where: { $0.id == id }) { selectedID = id }
        lock.unlock()
        persist()
    }

    /// あるアカウントのトークン。
    public func token(for account: GitHubAccount) -> String? {
        store.token(for: account.tokenKey)
    }

    /// いま選んでいるアカウントで使う通信係を作る。
    public func makeClient(session: URLSession = .shared,
                           rateLimitMonitor: RateLimitMonitor? = nil) -> GitHubClient {
        guard let account = selected else {
            return GitHubClient(token: nil, session: session,
                                rateLimitMonitor: rateLimitMonitor)
        }
        return GitHubClient(token: store.token(for: account.tokenKey), session: session,
                            apiHost: account.host.apiHost,
                            rawHost: account.host.rawHost,
                            rateLimitMonitor: rateLimitMonitor)
    }

    /// 保存用の JSON。
    public func encoded() -> Data? {
        struct Saved: Codable {
            var accounts: [GitHubAccount]
            var selectedID: String?
        }
        lock.lock()
        let snapshot = Saved(accounts: stored, selectedID: selectedID)
        lock.unlock()
        return try? JSONEncoder().encode(snapshot)
    }

    private func persist() {
        guard let save, let data = encoded() else { return }
        save(data)
    }
}

// MARK: - 88. OAuth (デバイスフロー)

/// デバイスフローの 1 段目の答え。
public struct DeviceCodeGrant: Equatable, Sendable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURL: URL?
    /// 何秒おきに聞きに行ってよいか。
    public var interval: Int
    /// 何秒で期限切れになるか。
    public var expiresIn: Int

    public init(deviceCode: String, userCode: String, verificationURL: URL?,
                interval: Int, expiresIn: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

public enum OAuthError: LocalizedError, Equatable {
    /// まだ利用者が承認していない。
    case pending
    /// 聞きに行くのが速すぎる。
    case slowDown(interval: Int)
    /// 期限切れ。
    case expired
    /// 利用者が断った。
    case denied
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .pending: return "まだ承認されていません。"
        case .slowDown: return "問い合わせが早すぎます。少し待ってください。"
        case .expired: return "コードの期限が切れました。やり直してください。"
        case .denied: return "承認が断られました。"
        case .other(let message): return message
        }
    }

    static func from(_ code: String, description: String?) -> OAuthError {
        switch code {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown(interval: 5)
        case "expired_token": return .expired
        case "access_denied": return .denied
        default: return .other(description ?? code)
        }
    }
}

/// GitHub のデバイスフローでログインする。
///
/// ブラウザを開けない場面でも「コードを打ち込む」だけで済むので、iPad と相性が良い。
public struct OAuthDeviceFlow: Sendable {
    public var clientID: String
    public var scopes: [String]
    public var host: GitHubHost
    let session: URLSession

    public init(clientID: String, scopes: [String] = ["repo", "gist", "read:user"],
                host: GitHubHost = .dotCom, session: URLSession = .shared) {
        self.clientID = clientID
        self.scopes = scopes
        self.host = host
        self.session = session
    }

    /// ログインの入口 (利用者がコードを打ち込むページ)。
    public var verificationURL: URL? {
        URL(string: host.isDotCom ? "https://github.com/login/device"
                                  : "https://\(host.webHost)/login/device")
    }

    private func loginURL(_ path: String) -> URL? {
        let webHost = host.isDotCom ? "github.com" : host.webHost
        return URL(string: "https://\(webHost)/login/\(path)")
    }

    /// 1 段目。利用者に見せるコードをもらう。
    public func requestCode() async throws -> DeviceCodeGrant {
        guard let url = loginURL("device/code") else { throw OAuthError.other("URL") }
        let body = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "scope": scopes.joined(separator: " ")
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GitHubViewer", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (data, _) = try await HTTP.send(request, session: session)
        struct Response: Decodable {
            let device_code: String
            let user_code: String
            let verification_uri: String?
            let interval: Int?
            let expires_in: Int?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OAuthError.other(String(decoding: data, as: UTF8.self))
        }
        return DeviceCodeGrant(
            deviceCode: response.device_code, userCode: response.user_code,
            verificationURL: response.verification_uri.flatMap(URL.init(string:))
                ?? verificationURL,
            interval: response.interval ?? 5, expiresIn: response.expires_in ?? 900)
    }

    /// 2 段目。承認されていればトークンが返る。まだなら `.pending` を投げる。
    public func requestToken(deviceCode: String) async throws -> String {
        guard let url = loginURL("oauth/access_token") else {
            throw OAuthError.other("URL")
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GitHubViewer", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (data, _) = try await HTTP.send(request, session: session)
        struct Response: Decodable {
            let access_token: String?
            let error: String?
            let error_description: String?
            let interval: Int?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OAuthError.other(String(decoding: data, as: UTF8.self))
        }
        if let token = response.access_token, !token.isEmpty { return token }
        if let code = response.error {
            if code == "slow_down" {
                throw OAuthError.slowDown(interval: response.interval ?? 5)
            }
            throw OAuthError.from(code, description: response.error_description)
        }
        throw OAuthError.other("トークンを受け取れませんでした。")
    }

    /// 承認されるまで待つ。`onWait` は次に問い合わせるまでの秒数を知らせる。
    public func waitForToken(_ grant: DeviceCodeGrant,
                             sleep: @Sendable (UInt64) async throws -> Void = {
                                 try await Task.sleep(nanoseconds: $0)
                             },
                             onWait: (@Sendable (Int) -> Void)? = nil) async throws -> String {
        var interval = Swift.max(1, grant.interval)
        let deadline = Date().addingTimeInterval(TimeInterval(grant.expiresIn))
        while Date() < deadline {
            onWait?(interval)
            try await sleep(UInt64(interval) * 1_000_000_000)
            do {
                return try await requestToken(deviceCode: grant.deviceCode)
            } catch OAuthError.pending {
                continue
            } catch OAuthError.slowDown(let next) {
                interval += Swift.max(1, next)
                continue
            }
        }
        throw OAuthError.expired
    }
}
