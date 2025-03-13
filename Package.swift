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
        .package(name: "GoogleMobileAds", url: "https://github.com/googleads/swift-package-manager-google-mobile-ads.git", from: "10.0.0"),
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
