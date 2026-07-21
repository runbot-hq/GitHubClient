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
        // OAuthTokenKit product added in Step 7
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
            name: "GitHubClient",
            // OAuthTokenKit dependency added in Step 7
            dependencies: ["EnvTokenKit"],
            path: "Sources/GitHubClient",
            exclude: ["README.md"],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "GitHubClientTests",
            dependencies: ["GitHubClient"],
            path: "Tests/GitHubClientTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
