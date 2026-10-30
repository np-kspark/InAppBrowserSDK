Pod::Spec.new do |spec|
  spec.name         = "InAppBrowserSDK"
  spec.version      = "1.3.3"
  spec.summary      = "InApp Browser SDK"
  spec.description  = "InApp Browser SDK for iOS"
  spec.homepage     = "https://github.com/np-kspark/InAppBrowserSDK"
  spec.license      = { :type => "MIT" }
  spec.author       = { "kspark" => "kspark@thenextpaper.com" }
  #spec.source       = { :path => "." } 
  spec.source       = { :git => "https://github.com/np-kspark/InAppBrowserSDK.git", :tag => "#{spec.version}" }
  
  spec.ios.deployment_target = "12.0"
  spec.swift_version = "5.0"
  
  # spec.source_files = "Sources/InAppBrowserSDK/**/*.swift"
  spec.source_files = "Sources/InAppBrowserSDK/**/*.swift", "Sources/InAppBrowserSDK/Resources/**/*.swift"
  
  
  # GoogleMobileAds 의존성 추가
  spec.dependency 'Google-Mobile-Ads-SDK'
end
