import UIKit
import GoogleMobileAds

public class InAppBrowserManager {
    public static let shared = InAppBrowserManager()
    private var config: InAppBrowserConfig?
    private var isInitialized: Bool = false
    
    private init() {}
    
    public func initialize(with config: InAppBrowserConfig) {
        if isInitialized {
            return
        }
        
        self.config = config
        MobileAds.shared.start(completionHandler: nil)
        isInitialized = true
    }
    
    public func launch(from viewController: UIViewController) {
        checkInitialization()
        
        let browserVC = InAppBrowserViewController(config: config!)
        browserVC.modalPresentationStyle = .fullScreen
        viewController.present(browserVC, animated: true)
    }
    
    public func launch(from viewController: UIViewController, url: String) {
        checkInitialization()
        
        if let currentConfig = config {
            // 현재 설정을 기반으로 새 설정 객체 생성
            let newConfig = InAppBrowserConfig.Builder()
                .setToolbarMode(currentConfig.toolbarMode)
                .setToolbarTitle(currentConfig.toolbarTitle)
                .setTitleAlignment(currentConfig.titleAlignment)
                .setUrl(url)
                .setFullscreen(currentConfig.isFullscreen)
                .setDebugEnabled(currentConfig.isDebugEnabled)
                .setUserAgent(currentConfig.userAgent)
                .build()
            
            // UI 커스터마이징 속성 복사
            if let fontFamily = currentConfig.fontFamily {
                newConfig.fontFamily = fontFamily
            }
            newConfig.fontSize = currentConfig.fontSize
            newConfig.backButtonLeftMargin = currentConfig.backButtonLeftMargin
            newConfig.closeButtonRightMargin = currentConfig.closeButtonRightMargin
            newConfig.toolbarHeight = currentConfig.toolbarHeight
            newConfig.backButtonIconSize = currentConfig.backButtonIconSize
            newConfig.closeButtonIconSize = currentConfig.closeButtonIconSize
            
            if let bgColor = currentConfig.toolbarBackgroundColor {
                newConfig.toolbarBackgroundColor = bgColor
            }
            
            if let titleColor = currentConfig.titleTextColor {
                newConfig.titleTextColor = titleColor
            }
            
            if let backIconName = currentConfig.backButtonImageName {
                newConfig.backButtonImageName = backIconName
            }
            
            if let closeIconName = currentConfig.closeButtonImageName {
                newConfig.closeButtonImageName = closeIconName
            }
            
            // 로딩 커스터마이징 속성 복사
            if let loadingBgColor = currentConfig.loadingBackgroundColor {
                newConfig.loadingBackgroundColor = loadingBgColor
            }
            
            if let progressColor = currentConfig.progressBarColor {
                newConfig.progressBarColor = progressColor
            }
            
            newConfig.progressBarStyle = currentConfig.progressBarStyle
            
            if let progressImage = currentConfig.progressBarImageName {
                newConfig.progressBarImageName = progressImage
            }
            
            self.config = newConfig
        }
        
        launch(from: viewController)
    }
    
    private func checkInitialization() {
        guard isInitialized else {
            fatalError("InAppBrowserManager is not initialized. Call initialize() first.")
        }
    }
    
    public func getConfig() -> InAppBrowserConfig? {
        return config
    }
    
    public func updateConfig(_ newConfig: InAppBrowserConfig) {
        self.config = newConfig
    }
}
