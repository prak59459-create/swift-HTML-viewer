import Foundation

// MARK: - 247. 利用統計 (端末の中だけ)

/// どれだけ使ったかの記録。
///
/// どこにも送らない。設定の画面と、バッジの判定にだけ使う。
public struct UsageStatistics: Equatable, Codable, Sendable {
    /// 言語 ID → 実行した回数。
    public var runsByLanguage: [String: Int]
    /// 成功した回数。
    public var successfulRuns: Int
    /// 失敗した回数。
    public var failedRuns: Int
    /// 開いたファイルの数。
    public var filesOpened: Int
    /// 開いたリポジトリ (重複なし)。
    public var repositories: Set<String>
    /// 編集して保存した回数。
    public var edits: Int
    /// 実行に使った時間の合計 (秒)。
    public var totalRunSeconds: Double
    /// 使った日 (yyyy-MM-dd)。
    public var activeDays: Set<String>
    public var firstUsedAt: Date?
    public var lastUsedAt: Date?

    public init(runsByLanguage: [String: Int] = [:], successfulRuns: Int = 0,
                failedRuns: Int = 0, filesOpened: Int = 0,
                repositories: Set<String> = [], edits: Int = 0,
                totalRunSeconds: Double = 0, activeDays: Set<String> = [],
                firstUsedAt: Date? = nil, lastUsedAt: Date? = nil) {
        self.runsByLanguage = runsByLanguage
        self.successfulRuns = successfulRuns
        self.failedRuns = failedRuns
        self.filesOpened = filesOpened
        self.repositories = repositories
        self.edits = edits
        self.totalRunSeconds = totalRunSeconds
        self.activeDays = activeDays
        self.firstUsedAt = firstUsedAt
        self.lastUsedAt = lastUsedAt
    }

    public var totalRuns: Int { successfulRuns + failedRuns }

    /// 使った言語の数。
    public var languageCount: Int { runsByLanguage.count }

    /// よく使う順。
    public var languagesByUse: [(languageID: String, count: Int)] {
        runsByLanguage.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.map { (languageID: $0.key, count: $0.value) }
    }

    /// うまくいった割合 (一度も動かしていなければ nil)。
    public var successRate: Double? {
        guard totalRuns > 0 else { return nil }
        return Double(successfulRuns) / Double(totalRuns)
    }

    static func dayKey(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0,
                      parts.day ?? 0)
    }

    mutating func touch(_ date: Date) {
        if firstUsedAt == nil { firstUsedAt = date }
        lastUsedAt = date
        activeDays.insert(UsageStatistics.dayKey(date))
    }

    public mutating func recordRun(languageID: String, succeeded: Bool,
                                   duration: TimeInterval = 0,
                                   at date: Date = Date()) {
        runsByLanguage[languageID, default: 0] += 1
        if succeeded { successfulRuns += 1 } else { failedRuns += 1 }
        totalRunSeconds += duration
        touch(date)
    }

    public mutating func record(_ result: RunResult, at date: Date = Date()) {
        recordRun(languageID: result.languageID, succeeded: result.succeeded,
                  duration: result.duration, at: date)
    }

    public mutating func recordFileOpened(repository: String? = nil,
                                          at date: Date = Date()) {
        filesOpened += 1
        if let repository { repositories.insert(repository) }
        touch(date)
    }

    public mutating func recordEdit(at date: Date = Date()) {
        edits += 1
        touch(date)
    }

    /// 人に見せる文。
    public var summaryLines: [String] {
        var lines: [String] = []
        lines.append("動かした回数: \(totalRuns) 回")
        if let rate = successRate {
            lines.append("うまくいった割合: \(Int((rate * 100).rounded())) %")
        }
        lines.append("使った言語: \(languageCount) 種類")
        lines.append("開いたファイル: \(filesOpened) 個")
        lines.append("開いたリポジトリ: \(repositories.count) 個")
        lines.append("使った日: \(activeDays.count) 日")
        return lines
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    public static func decoded(_ data: Data?) -> UsageStatistics {
        guard let data else { return UsageStatistics() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(UsageStatistics.self, from: data))
            ?? UsageStatistics()
    }

    /// 全部忘れる。
    public mutating func reset() {
        self = UsageStatistics()
    }
}

// MARK: - 248. 達成バッジ

/// もらえる印。
public struct Badge: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// どうすればもらえるか。
    public var requirement: String
    /// 記号 (SF Symbols の名前)。
    public var symbol: String
    /// あと何回で届くかを出すための、目標の数。
    public var goal: Int
    /// いまいくつか。
    var progressValue: @Sendable (UsageStatistics) -> Int

    public init(id: String, name: String, requirement: String, symbol: String,
                goal: Int,
                progressValue: @escaping @Sendable (UsageStatistics) -> Int) {
        self.id = id
        self.name = name
        self.requirement = requirement
        self.symbol = symbol
        self.goal = goal
        self.progressValue = progressValue
    }

    public static func == (lhs: Badge, rhs: Badge) -> Bool { lhs.id == rhs.id }

    /// いまの達成度 (0.0 〜 1.0)。
    public func progress(_ statistics: UsageStatistics) -> Double {
        guard goal > 0 else { return 1 }
        return Swift.min(1, Double(progressValue(statistics)) / Double(goal))
    }

    public func isEarned(_ statistics: UsageStatistics) -> Bool {
        progressValue(statistics) >= goal
    }

    /// あといくつか。
    public func remaining(_ statistics: UsageStatistics) -> Int {
        Swift.max(0, goal - progressValue(statistics))
    }
}

public enum BadgeCatalog {

    public static func badge(id: String) -> Badge? {
        all.first { $0.id == id }
    }

    public static func earned(_ statistics: UsageStatistics) -> [Badge] {
        all.filter { $0.isEarned(statistics) }
    }

    /// あと少しでもらえるもの (近い順)。
    public static func upcoming(_ statistics: UsageStatistics, limit: Int = 3)
        -> [Badge] {
        all.filter { !$0.isEarned(statistics) }
            .sorted { $0.progress(statistics) > $1.progress(statistics) }
            .prefix(limit).map { $0 }
    }

    /// 今回の記録で、新しくもらえた分。
    public static func newlyEarned(before: UsageStatistics,
                                   after: UsageStatistics) -> [Badge] {
        let had = Set(earned(before).map(\.id))
        return earned(after).filter { !had.contains($0.id) }
    }

    public static let all: [Badge] = [
        Badge(id: "badge-first-run", name: "はじめの一歩",
              requirement: "コードを 1 回動かす", symbol: "play.circle", goal: 1,
              progressValue: { $0.totalRuns }),
        Badge(id: "badge-ten-runs", name: "常連",
              requirement: "コードを 10 回動かす", symbol: "flame", goal: 10,
              progressValue: { $0.totalRuns }),
        Badge(id: "badge-hundred-runs", name: "走り込み",
              requirement: "コードを 100 回動かす", symbol: "bolt", goal: 100,
              progressValue: { $0.totalRuns }),
        Badge(id: "badge-polyglot", name: "多言語",
              requirement: "5 つの言語を動かす", symbol: "globe", goal: 5,
              progressValue: { $0.languageCount }),
        Badge(id: "badge-explorer", name: "探検家",
              requirement: "10 個のリポジトリを開く", symbol: "map", goal: 10,
              progressValue: { $0.repositories.count }),
        Badge(id: "badge-reader", name: "読書家",
              requirement: "100 個のファイルを開く", symbol: "book", goal: 100,
              progressValue: { $0.filesOpened }),
        Badge(id: "badge-editor", name: "書き手",
              requirement: "20 回編集する", symbol: "pencil", goal: 20,
              progressValue: { $0.edits }),
        Badge(id: "badge-regular", name: "毎日",
              requirement: "7 日使う", symbol: "calendar", goal: 7,
              progressValue: { $0.activeDays.count }),
        Badge(id: "badge-debugger", name: "粘り強い",
              requirement: "失敗を 20 回のりこえる", symbol: "ladybug", goal: 20,
              progressValue: { $0.failedRuns })
    ]
}

// MARK: - 246. フィードバック送信

/// 送る内容。
public struct FeedbackReport: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Equatable, Sendable {
        case bug
        case idea
        case question

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .bug: return "うまく動かない"
            case .idea: return "こうしてほしい"
            case .question: return "聞きたいこと"
            }
        }

        var label: String {
            switch self {
            case .bug: return "bug"
            case .idea: return "enhancement"
            case .question: return "question"
            }
        }
    }

    public var kind: Kind
    public var title: String
    public var body: String
    /// 何をしていたか (言語やファイルの種類)。中身そのものは入れない。
    public var context: [String: String]
    /// 端末と版の情報を足すか。
    public var includesEnvironment: Bool

    public init(kind: Kind, title: String, body: String,
                context: [String: String] = [:],
                includesEnvironment: Bool = true) {
        self.kind = kind
        self.title = title
        self.body = body
        self.context = context
        self.includesEnvironment = includesEnvironment
    }

    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 送る先と、送る文の組み立て。
public enum FeedbackComposer {

    /// 版などの情報。アプリ側から渡す。
    public struct Environment: Equatable, Sendable {
        public var appVersion: String
        public var systemVersion: String
        public var deviceModel: String

        public init(appVersion: String, systemVersion: String,
                    deviceModel: String) {
            self.appVersion = appVersion
            self.systemVersion = systemVersion
            self.deviceModel = deviceModel
        }
    }

    /// Issue の本文を組み立てる。
    ///
    /// コードそのものは入れない。入れるかどうかは、書く人が決める。
    public static func body(for report: FeedbackReport,
                            environment: Environment? = nil) -> String {
        var text = report.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !report.context.isEmpty {
            text += "\n\n## 状況\n"
            for key in report.context.keys.sorted() {
                text += "- \(key): \(report.context[key] ?? "")\n"
            }
        }
        if report.includesEnvironment, let environment {
            text += "\n## 環境\n"
            text += "- アプリ: \(environment.appVersion)\n"
            text += "- OS: \(environment.systemVersion)\n"
            text += "- 端末: \(environment.deviceModel)\n"
        }
        return text
    }

    /// GitHub の Issue 作成ページへのリンク。
    public static func issueURL(for report: FeedbackReport,
                                repository: GitHubLocation,
                                environment: Environment? = nil) -> URL? {
        guard report.isValid else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repository.owner)/\(repository.repo)/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: report.title),
            URLQueryItem(name: "body", value: body(for: report,
                                                   environment: environment)),
            URLQueryItem(name: "labels", value: report.kind.label)
        ]
        return components.url
    }

    /// メールで送るときのリンク。
    public static func mailURL(for report: FeedbackReport, to address: String,
                               environment: Environment? = nil) -> URL? {
        guard report.isValid else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: "[\(report.kind.label)] \(report.title)"),
            URLQueryItem(name: "body", value: body(for: report,
                                                   environment: environment))
        ]
        return components.url
    }
}
