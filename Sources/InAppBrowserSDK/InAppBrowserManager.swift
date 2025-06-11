import UIKit
import GoogleMobileAds

public class InAppBrowserManager {
    public static let shared = InAppBrowserManager()
    private var config: InAppBrowserConfig?
    private var isInitialized: Bool = false
    private var onBrowserClosed: (() -> Void)?
    
    private init() {}
    
    public func setOnBrowserClosed(_ callback: @escaping () -> Void) {
        self.onBrowserClosed = callback
    }
    
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
            if let presentedVC = viewController.presentedViewController as? InAppBrowserViewController {
                presentedVC.dismiss(animated: false) {
                    self.launchNewBrowser(from: viewController, url: url, config: currentConfig)
                }
                return
            }
            
            launchNewBrowser(from: viewController, url: url, config: currentConfig)
        }
    }

    private func launchNewBrowser(from viewController: UIViewController, url: String, config: InAppBrowserConfig) {
        // 새 설정 객체 생성
        let newConfig = InAppBrowserConfig.Builder()
            .setToolbarMode(config.toolbarMode)
            .setToolbarTitle(config.toolbarTitle)
            .setTitleAlignment(config.titleAlignment)
            .setUrl(url)
            .setFullscreen(config.isFullscreen)
            .setDebugEnabled(config.isDebugEnabled)
            .setUserAgent(config.userAgent)
            .setLeftButtonRole(config.leftButtonRole)
            .setRightButtonRole(config.rightButtonRole)
            .setLeftButtonVisible(config.leftButtonVisible)
            .setRightButtonVisible(config.rightButtonVisible)
            .setLeftButtonIcon(config.leftButtonIcon)
            .setRightButtonIcon(config.rightButtonIcon)
            .setBackAction(config.backAction)
            .setBackConfirmMessage(config.backConfirmMessage)
            .setBackConfirmTimeout(config.backConfirmTimeout)
            .setPreventCache(config.preventCache)
            .build()
        
        copyConfigProperties(from: config, to: newConfig)
        
        let browserVC = InAppBrowserViewController(config: newConfig)
        browserVC.modalPresentationStyle = .fullScreen
        viewController.present(browserVC, animated: true)
    }
    
    private func copyConfigProperties(from source: InAppBrowserConfig, to target: InAppBrowserConfig) {
        target.fontFamily = source.fontFamily
        target.fontSize = source.fontSize
        target.toolbarBackgroundColor = source.toolbarBackgroundColor
        target.titleTextColor = source.titleTextColor
        target.backButtonImageName = source.backButtonImageName
        target.closeButtonImageName = source.closeButtonImageName
        
        target.backButtonLeftMargin = source.backButtonLeftMargin
        target.backButtonTopMargin = source.backButtonTopMargin
        target.backButtonBottomMargin = source.backButtonBottomMargin
        target.backButtonRightMargin = source.backButtonRightMargin
        target.closeButtonRightMargin = source.closeButtonRightMargin
        target.closeButtonLeftMargin = source.closeButtonLeftMargin
        target.closeButtonTopMargin = source.closeButtonTopMargin
        target.closeButtonBottomMargin = source.closeButtonBottomMargin
        target.toolbarHeight = source.toolbarHeight
        target.backButtonIconSize = source.backButtonIconSize
        target.closeButtonIconSize = source.closeButtonIconSize
        
        target.titleLeftMargin = source.titleLeftMargin
        target.titleRightMargin = source.titleRightMargin
        target.titleCenterOffset = source.titleCenterOffset
        
        target.loadingBackgroundColor = source.loadingBackgroundColor
        target.progressBarColor = source.progressBarColor
        target.progressBarStyle = source.progressBarStyle
        target.progressBarImageName = source.progressBarImageName
        target.progressBarAnimationDuration = source.progressBarAnimationDuration
    }
    
    internal func notifyBrowserClosed() {
        if let callback = onBrowserClosed {
            callback()
        }
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
        
        DispatchQueue.main.async {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first,
               let rootVC = window.rootViewController {
                
                if let presentedVC = self.findPresentedBrowser(from: rootVC) {
                    presentedVC.updateConfiguration(newConfig)
                } else {
                }
            }
        }
    }
    private func findPresentedBrowser(from viewController: UIViewController) -> InAppBrowserViewController? {
        if let browserVC = viewController as? InAppBrowserViewController {
            return browserVC
        }
        
        if let presentedVC = viewController.presentedViewController {
            return findPresentedBrowser(from: presentedVC)
        }
        
        return nil
    }
}
