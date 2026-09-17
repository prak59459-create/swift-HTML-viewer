// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

// iPad の Swift Playgrounds で開ける App Project。
// (Swift Playgrounds / Xcode でこのフォルダごと開くこと。
//  AppleProductTypes は Swift Playgrounds と Xcode でのみ利用できる)
let package = Package(
    name: "GitHubViewer",
    platforms: [
        .iOS("16.0")
    ],
    products: [
        .iOSApplication(
            name: "GitHubViewer",
            targets: ["AppModule"],
            bundleIdentifier: "com.example.githubviewer",
            displayVersion: "1.0",
            bundleVersion: "1",
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
