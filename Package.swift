// swift-tools-version: 5.9
import PackageDescription

// アプリ本体 (SwiftUI + WebKit) は macOS 専用。
// ロジック部分の GitHubViewerCore は Linux でもビルド・テストできるようにしておく。
var products: [Product] = [
    .library(name: "GitHubViewerCore", targets: ["GitHubViewerCore"]),
]

var targets: [Target] = [
    .target(name: "GitHubViewerCore", path: "Sources/GitHubViewerCore"),
    .testTarget(name: "GitHubViewerCoreTests",
                dependencies: ["GitHubViewerCore"],
                path: "Tests/GitHubViewerCoreTests"),
]

#if os(macOS)
products.append(.executable(name: "GitHubViewer", targets: ["GitHubViewer"]))
targets.append(.executableTarget(name: "GitHubViewer",
                                 dependencies: ["GitHubViewerCore"],
                                 path: "Sources/GitHubViewer"))
#endif

let package = Package(
    name: "GitHubViewer",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
