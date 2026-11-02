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
        // GoogleMobileAds 12.x / 13.x 모두 허용.
        // from: "12.0.0" 은 SPM 규칙상 13.0.0 미만으로 제한되어 GMA 13.x 사용 앱에서 해석 실패 → 명시적 범위로 변경 (1.3.5)
        .package(name: "GoogleMobileAds", url: "https://github.com/googleads/swift-package-manager-google-mobile-ads.git", "12.0.0"..<"14.0.0"),
    ],
    targets: [
        .target(
            name: "InAppBrowserSDK",
            dependencies: [
                .product(name: "GoogleMobileAds", package: "GoogleMobileAds"),
            ],
            resources: [
                .process("Resources")
            ]),
        .testTarget(
            name: "InAppBrowserSDKTests",
            dependencies: ["InAppBrowserSDK"]),
    ]
)
