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
            // No dependency on EnvTokenKit — OAuthTokenKit and EnvTokenKit are peer targets,
            // not a stack. Each owns one resolution mechanism (Keychain/OAuth vs.
            // env-var/login-shell) and neither needs the other's types. GitHubClient is the
            // only target that depends on both, wiring them together via TokenCache.
            // See TokenCache Boundary Rule in #74.
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
            name: "EnvTokenKitTests",
            dependencies: ["EnvTokenKit"],
            path: "Tests/EnvTokenKitTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "OAuthTokenKitTests",
            dependencies: ["OAuthTokenKit"],
            path: "Tests/OAuthTokenKitTests",
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
