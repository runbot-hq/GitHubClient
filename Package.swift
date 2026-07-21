// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "GitHubClient",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "EnvTokenKit",
            targets: ["EnvTokenKit"]
        ),
        .library(
            name: "OAuthTokenKit",
            targets: ["OAuthTokenKit"]
        ),
        .library(
            name: "GitHubClient",
            targets: ["GitHubClient"]
        )
    ],
    targets: [
        .target(
            name: "EnvTokenKit",
            path: "Sources/EnvTokenKit",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .target(
            name: "OAuthTokenKit",
            path: "Sources/OAuthTokenKit",
            // No dependency on EnvTokenKit — completely independent peer target
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .target(
            name: "GitHubClient",
            dependencies: ["EnvTokenKit", "OAuthTokenKit"],
            path: "Sources/GitHubClient",
            exclude: ["README.md"],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "GitHubClientTests",
            dependencies: ["GitHubClient", "EnvTokenKit"],
            path: "Tests/GitHubClientTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
