// swift-tools-version: 5.9
import PackageDescription

// アプリ本体は iPad の Swift Playgrounds で開ける App Project
// (GitHubViewer.swiftpm) として用意してある。
//
// このルートの Package.swift は、その中の Core/ にあるロジックを
// macOS / Linux でもビルド・テストするためのもの。
// (Swift Playgrounds はサブディレクトリの .swiftpm を直接開くので、
//  この Package.swift はアプリのビルドには関与しない)
let package = Package(
    name: "GitHubViewerCore",
    platforms: [.macOS(.v12), .iOS(.v16)],
    products: [
        .library(name: "GitHubViewerCore", targets: ["GitHubViewerCore"]),
    ],
    targets: [
        .target(name: "GitHubViewerCore", path: "GitHubViewer.swiftpm/Core"),
        .testTarget(name: "GitHubViewerCoreTests",
                    dependencies: ["GitHubViewerCore"],
                    path: "Tests/GitHubViewerCoreTests"),
    ]
)
