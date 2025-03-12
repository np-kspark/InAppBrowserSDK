// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "InAppBrowserSDK",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "InAppBrowserSDK",
            targets: ["InAppBrowserSDK"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "InAppBrowserSDK",
            dependencies: [
            ],
            resources: [
                .process("Resources")
            ]),
        .testTarget(
            name: "InAppBrowserSDKTests",
            dependencies: ["InAppBrowserSDK"]),
    ]
)
