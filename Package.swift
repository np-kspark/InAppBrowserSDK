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
    // GoogleMobileAds 는 SDK 가 직접 의존하지 않는다 (1.3.5).
    // 앱이 자체적으로 추가한 GoogleMobileAds (12.0 이상) 를 그대로 사용하므로,
    // 앱 쪽 GMA 버전(13.x, 14.x ...)과 충돌하지 않는다.
    dependencies: [],
    targets: [
        .target(
            name: "InAppBrowserSDK",
            dependencies: [],
            resources: [
                .process("Resources")
            ]),
        .testTarget(
            name: "InAppBrowserSDKTests",
            dependencies: ["InAppBrowserSDK"]),
    ]
)
