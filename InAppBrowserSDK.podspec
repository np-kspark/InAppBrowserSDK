Pod::Spec.new do |spec|
  spec.name         = "InAppBrowserSDK"
  spec.version      = "1.3.5"
  spec.summary      = "InApp Browser SDK"
  spec.description  = "InApp Browser SDK for iOS"
  spec.homepage     = "https://github.com/np-kspark/InAppBrowserSDK"
  spec.license      = { :type => "MIT", :file => "LICENSE" }
  spec.author       = { "kspark" => "kspark@thenextpaper.com" }
  spec.source       = { :git => "https://github.com/np-kspark/InAppBrowserSDK.git", :tag => "#{spec.version}" }

  # Package.swift 의 .iOS(.v13) 과 동일하게 유지
  spec.ios.deployment_target = "13.0"
  spec.swift_versions = ["5.5"]

  spec.source_files = "Sources/InAppBrowserSDK/**/*.swift"

  # 리소스 번들 이름은 소스의 Bundle.resourceBundle (#if SWIFT_PACKAGE 외 분기) 이 찾는
  # "InAppBrowserSDK_InAppBrowserSDK" 와 반드시 일치해야 한다.
  spec.resource_bundles = {
    "InAppBrowserSDK_InAppBrowserSDK" => ["Sources/InAppBrowserSDK/Resources/Assets.xcassets"]
  }

  spec.frameworks = "UIKit", "WebKit", "AVFoundation", "AdSupport", "AppTrackingTransparency"

  # Google-Mobile-Ads-SDK 는 정적 xcframework 이므로 use_frameworks! 환경에서
  # "transitive dependencies that include statically linked binaries" 오류를 피하려면 static 으로 빌드한다.
  spec.static_framework = true

  # GMA 버전은 앱 Podfile 에 지정된 Google-Mobile-Ads-SDK (12.0 이상) 를 그대로 따른다.
  spec.dependency "Google-Mobile-Ads-SDK", ">= 12.0"
end
