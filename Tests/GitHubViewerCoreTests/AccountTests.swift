import XCTest
@testable import GitHubViewerCore

final class GitHubHostTests: XCTestCase {
    func testDotCom() {
        XCTAssertTrue(GitHubHost.dotCom.isDotCom)
        XCTAssertEqual(GitHubHost.dotCom.rawHost, "raw.githubusercontent.com")
    }

    func testEnterpriseStripsScheme() {
        let host = GitHubHost.enterprise("https://ghe.example.com/")
        XCTAssertEqual(host.apiHost, "ghe.example.com")
        XCTAssertEqual(host.webHost, "ghe.example.com")
        XCTAssertFalse(host.isDotCom)
    }

    func testEnterpriseStripsAPIPath() {
        XCTAssertEqual(GitHubHost.enterprise("ghe.example.com/api/v3").apiHost,
                       "ghe.example.com")
    }

    func testEnterpriseName() {
        XCTAssertEqual(GitHubHost.enterprise("ghe.example.com", name: "社内").name, "社内")
    }

    func testCodable() throws {
        let data = try JSONEncoder().encode(GitHubHost.enterprise("a.b"))
        let back = try JSONDecoder().decode(GitHubHost.self, from: data)
        XCTAssertEqual(back.apiHost, "a.b")
    }
}

final class MemoryTokenStoreTests: XCTestCase {
    func testSetAndGet() {
        let store = MemoryTokenStore()
        store.setToken("abc", for: "k")
        XCTAssertEqual(store.token(for: "k"), "abc")
    }

    func testEmptyTokenRemoves() {
        let store = MemoryTokenStore(values: ["k": "abc"])
        store.setToken("", for: "k")
        XCTAssertNil(store.token(for: "k"))
    }

    func testNilRemoves() {
        let store = MemoryTokenStore(values: ["k": "abc"])
        store.setToken(nil, for: "k")
        XCTAssertNil(store.token(for: "k"))
    }

    func testRemoveAll() {
        let store = MemoryTokenStore(values: ["a": "1", "b": "2"])
        store.removeAll()
        XCTAssertNil(store.token(for: "a"))
        XCTAssertNil(store.token(for: "b"))
    }
}

final class AccountManagerTests: XCTestCase {
    func testAddAndSelect() {
        let store = MemoryTokenStore()
        let manager = AccountManager(tokenStore: store)
        let account = GitHubAccount(login: "me")
        manager.add(account, token: "t1")

        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.selected?.login, "me")
        XCTAssertEqual(manager.token(for: account), "t1")
    }

    func testSameLoginIsReplacedNotDuplicated() {
        let manager = AccountManager(tokenStore: MemoryTokenStore())
        manager.add(GitHubAccount(login: "me", displayName: "古い"), token: "t1")
        manager.add(GitHubAccount(login: "me", displayName: "新しい"), token: "t2")
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.selected?.displayName, "新しい")
    }

    func testSameLoginOnDifferentHostsCoexist() {
        let manager = AccountManager(tokenStore: MemoryTokenStore())
        manager.add(GitHubAccount(login: "me"), token: "t1")
        manager.add(GitHubAccount(login: "me",
                                  host: .enterprise("ghe.example.com")), token: "t2")
        XCTAssertEqual(manager.accounts.count, 2)
    }

    func testSwitching() {
        let manager = AccountManager(tokenStore: MemoryTokenStore())
        let first = GitHubAccount(login: "a")
        let second = GitHubAccount(login: "b")
        manager.add(first, token: "1")
        manager.add(second, token: "2")
        manager.select(id: first.id)
        XCTAssertEqual(manager.selected?.login, "a")
    }

    func testSelectingUnknownIDChangesNothing() {
        let manager = AccountManager(tokenStore: MemoryTokenStore())
        manager.add(GitHubAccount(login: "a"), token: "1")
        manager.select(id: "どこにもない")
        XCTAssertEqual(manager.selected?.login, "a")
    }

    func testRemoveAlsoDropsTheToken() {
        let store = MemoryTokenStore()
        let manager = AccountManager(tokenStore: store)
        let account = GitHubAccount(login: "me")
        manager.add(account, token: "t")
        manager.remove(id: account.id)

        XCTAssertTrue(manager.accounts.isEmpty)
        XCTAssertNil(manager.selected)
        XCTAssertNil(store.token(for: account.tokenKey))
    }

    func testRemovingTheSelectedOnePicksAnother() {
        let manager = AccountManager(tokenStore: MemoryTokenStore())
        let first = GitHubAccount(login: "a")
        let second = GitHubAccount(login: "b")
        manager.add(first, token: "1")
        manager.add(second, token: "2")
        manager.select(id: second.id)
        manager.remove(id: second.id)
        XCTAssertEqual(manager.selected?.login, "a")
    }

    func testClientUsesSelectedAccount() {
        let store = MemoryTokenStore()
        let manager = AccountManager(tokenStore: store)
        manager.add(GitHubAccount(login: "me", host: .enterprise("ghe.example.com")),
                    token: "secret")
        let client = manager.makeClient(session: StubURLProtocol.makeSession())
        XCTAssertEqual(client.token, "secret")
        XCTAssertEqual(client.apiHost, "ghe.example.com")
    }

    func testClientWithoutAccountHasNoToken() {
        let manager = AccountManager(tokenStore: MemoryTokenStore())
        let client = manager.makeClient(session: StubURLProtocol.makeSession())
        XCTAssertNil(client.token)
        XCTAssertEqual(client.apiHost, "api.github.com")
    }

    func testSaveAndRestore() {
        let store = MemoryTokenStore()
        let manager = AccountManager(tokenStore: store)
        manager.add(GitHubAccount(login: "a"), token: "1")
        manager.add(GitHubAccount(login: "b"), token: "2")
        let saved = manager.encoded()
        XCTAssertNotNil(saved)

        let restored = AccountManager(json: saved, tokenStore: store)
        XCTAssertEqual(restored.accounts.map(\.login), ["a", "b"])
        XCTAssertEqual(restored.selected?.login, "b")
        XCTAssertEqual(restored.token(for: restored.accounts[0]), "1")
    }

    func testRestoreFromNothing() {
        let manager = AccountManager(json: nil)
        XCTAssertTrue(manager.accounts.isEmpty)
        XCTAssertNil(manager.selected)
    }

    func testSaveCallbackFires() {
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let manager = AccountManager(tokenStore: MemoryTokenStore()) { _ in
            box.count += 1
        }
        manager.add(GitHubAccount(login: "a"), token: "1")
        manager.select(id: manager.accounts[0].id)
        XCTAssertEqual(box.count, 2)
    }

    func testSubtitle() {
        XCTAssertEqual(GitHubAccount(login: "me").subtitle, "me")
        XCTAssertEqual(GitHubAccount(login: "me",
                                     host: .enterprise("ghe.example.com")).subtitle,
                       "me @ ghe.example.com")
    }
}

final class OAuthDeviceFlowTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func makeFlow() -> OAuthDeviceFlow {
        OAuthDeviceFlow(clientID: "id", session: StubURLProtocol.makeSession())
    }

    func testRequestCode() async throws {
        StubURLProtocol.stubJSON("/login/device/code", """
        {"device_code":"dc","user_code":"ABCD-1234",
         "verification_uri":"https://github.com/login/device","interval":5,
         "expires_in":900}
        """)
        let grant = try await makeFlow().requestCode()
        XCTAssertEqual(grant.userCode, "ABCD-1234")
        XCTAssertEqual(grant.interval, 5)
        XCTAssertNotNil(grant.verificationURL)

        let body = StubURLProtocol.lastBody()
        XCTAssertEqual(body?["client_id"] as? String, "id")
        XCTAssertEqual(body?["scope"] as? String, "repo gist read:user")
    }

    func testRequestTokenSucceeds() async throws {
        StubURLProtocol.stubJSON("/login/oauth/access_token",
                                 #"{"access_token":"gho_xxx"}"#)
        let token = try await makeFlow().requestToken(deviceCode: "dc")
        XCTAssertEqual(token, "gho_xxx")
    }

    func testPendingIsReported() async {
        StubURLProtocol.stubJSON("/login/oauth/access_token",
                                 #"{"error":"authorization_pending"}"#)
        do {
            _ = try await makeFlow().requestToken(deviceCode: "dc")
            XCTFail("エラーになるはずです")
        } catch OAuthError.pending {
            // 期待どおり。
        } catch {
            XCTFail("違うエラーです: \(error)")
        }
    }

    func testDeniedIsReported() async {
        StubURLProtocol.stubJSON("/login/oauth/access_token",
                                 #"{"error":"access_denied"}"#)
        do {
            _ = try await makeFlow().requestToken(deviceCode: "dc")
            XCTFail("エラーになるはずです")
        } catch OAuthError.denied {
            // 期待どおり。
        } catch {
            XCTFail("違うエラーです: \(error)")
        }
    }

    func testSlowDownCarriesTheInterval() async {
        StubURLProtocol.stubJSON("/login/oauth/access_token",
                                 #"{"error":"slow_down","interval":10}"#)
        do {
            _ = try await makeFlow().requestToken(deviceCode: "dc")
            XCTFail("エラーになるはずです")
        } catch OAuthError.slowDown(let interval) {
            XCTAssertEqual(interval, 10)
        } catch {
            XCTFail("違うエラーです: \(error)")
        }
    }

    func testWaitKeepsAskingUntilApproved() async throws {
        final class Box: @unchecked Sendable {
            var calls = 0
            var waits: [Int] = []
        }
        let box = Box()
        StubURLProtocol.reset()
        // 1 回目は保留、2 回目で成功。
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        _ = counter

        StubURLProtocol.stubJSON("/login/oauth/access_token",
                                 #"{"error":"authorization_pending"}"#)
        let grant = DeviceCodeGrant(deviceCode: "dc", userCode: "A", verificationURL: nil,
                                    interval: 1, expiresIn: 3)
        let flow = makeFlow()
        do {
            _ = try await flow.waitForToken(grant, sleep: { _ in
                box.calls += 1
                if box.calls == 2 {
                    // 2 回目の問い合わせの直前に、成功を返すようにする。
                    StubURLProtocol.reset()
                    StubURLProtocol.stubJSON("/login/oauth/access_token",
                                             #"{"access_token":"ok"}"#)
                }
            }, onWait: { box.waits.append($0) })
            // ここに来れば成功。
        } catch {
            XCTFail("承認されるはずです: \(error)")
        }
        XCTAssertEqual(box.calls, 2)
        XCTAssertEqual(box.waits, [1, 1])
    }

    func testWaitGivesUpWhenExpired() async {
        StubURLProtocol.stubJSON("/login/oauth/access_token",
                                 #"{"error":"authorization_pending"}"#)
        let grant = DeviceCodeGrant(deviceCode: "dc", userCode: "A", verificationURL: nil,
                                    interval: 1, expiresIn: 0)
        do {
            _ = try await makeFlow().waitForToken(grant, sleep: { _ in })
            XCTFail("期限切れになるはずです")
        } catch OAuthError.expired {
            // 期待どおり。
        } catch {
            XCTFail("違うエラーです: \(error)")
        }
    }

    func testEnterpriseLoginURL() async throws {
        StubURLProtocol.stubJSON("/login/device/code",
                                 #"{"device_code":"d","user_code":"u"}"#)
        let flow = OAuthDeviceFlow(clientID: "id",
                                   host: .enterprise("ghe.example.com"),
                                   session: StubURLProtocol.makeSession())
        _ = try await flow.requestCode()
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://ghe.example.com/login/device/code")
    }
}
