import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 応答ヘッダから API のレート制限を拾って覚えておく入れ物。
///
/// `GitHubClient` は値型なので、通信のたびに書き換わる情報はここに預ける。
public final class RateLimitMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RateLimitStatus?
    /// 残量が変わったときに呼ばれる (画面の更新用)。
    public var onChange: (@Sendable (RateLimitStatus) -> Void)?

    public init(initial: RateLimitStatus? = nil) {
        self.stored = initial
    }

    /// いまの残量。
    public var current: RateLimitStatus? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// 応答ヘッダから取り込む。
    public func update(from response: HTTPURLResponse) {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }
        update(RateLimitStatus.from(headers: headers))
    }

    /// 直接入れ替える。
    public func update(_ status: RateLimitStatus?) {
        guard let status else { return }
        lock.lock()
        let changed = stored != status
        stored = status
        lock.unlock()
        if changed { onChange?(status) }
    }

    /// 覚えている内容を消す。
    public func reset() {
        lock.lock()
        stored = nil
        lock.unlock()
    }
}
