import UIKit
import WebKit
import GoogleMobileAds
import AppTrackingTransparency
import AdSupport
import Foundation

@MainActor
class InAppBrowserViewController: UIViewController, WKUIDelegate, BannerViewDelegate {
    static let SDK_VERSION = "1.3.0"
    static var GOOGLE_SDK_VERSION: String {
        let v = MobileAds.shared.versionNumber
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    
    private var webView: WKWebView!
    private var loadingCover: UIView!
    private var loadingIndicator: UIView!
    private var rewardedAd: RewardedAd?
    private var interstitialAd: AdManagerInterstitialAd?
    private var rewardedInterstitialAd: RewardedInterstitialAd?
    private var currentAdUnitId: String = ""
    private var isLoadingAd: Bool = false
    private var isRewardEarned: Bool = false
    private var pendingCallbackFunction: String?
    
    private var config: InAppBrowserConfig
    
    private var adLoadTimeoutInterval: TimeInterval = 5.0
    private var adLoadTimer: Timer?
    private var adLoadTimeoutWorkItem: DispatchWorkItem?
    private var isAdRequestTimeOut: Bool = false

    private var customAdTargeting: [String: String] = [:]
    
    private var adUnitIndexCall: Int = 0
    private var adUnitIndexDisplay: Int = 1
    private var lastCallAdUnit: String = ""
    private var callBackAdUnit: String = ""
    
    private var originalURL: String?
    private var optimizedURL: String?
    
    private var lastBackPressed: TimeInterval = 0
    private var currentBackAction: InAppBrowserConfig.BackAction = .historyBack
    private var backConfirmMessage: String = "한번 더 누르면 창이 닫힙니다"
    private var backConfirmTimeout: TimeInterval = 2.0
    
    private var isMovingToExternalApp: Bool = false
    private var lastExternalAppTime: TimeInterval = 0
    private var pendingExternalURL: String?
    private var navigationHistory: [String] = []
    private var isNavigatingBack: Bool = false
    private var lastNavigationTime: TimeInterval = 0
    private var backActionCount: Int = 0
    private var lastBackActionTime: TimeInterval = 0
    private var lastBackActionURL: String = ""
    
    private var preloadedRewardedAd: RewardedAd?
    private var preloadedInterstitialAd: AdManagerInterstitialAd?
    private var preloadedRewardedInterstitialAd: RewardedInterstitialAd?

    private var preloadedRewardedAdUnit: String?
    private var preloadedInterstitialAdUnit: String?
    private var preloadedRewardedInterstitialAdUnit: String?

    private var isPreloadingRewardedAd: Bool = false
    private var isPreloadingInterstitialAd: Bool = false
    private var isPreloadingRewardedInterstitialAd: Bool = false

    private var isPreloadedRewardEarned: Bool = false
    private var preloadedPendingCallbackFunction: String?

    private var pendingBannerAdValue: AdValue?
    private var bannerPaidEventFallbackWorkItem: DispatchWorkItem?
    private var pendingInterstitialAdValue: AdValue?
    private var pendingRewardedAdValue: AdValue?
    private var pendingPreloadedInterstitialAdValue: AdValue?
    private var pendingPreloadedRewardedAdValue: AdValue?

    private var preloadTimeoutMs: Int = 5000
    private var isLoadingCoverEnabled: Bool = false
    
    private var isUsingUnifiedCallback: Bool = false
    private var currentCallbackType: String = "legacy"
    
    private var mainContainerStackView: UIStackView!
    private var toolbarView: UIView!
    private var webViewContainer: UIView!
    private var bannerContainer: UIView!
    
    private var bannerAdView: AdManagerBannerView?
    private var isBannerEnabled: Bool = true
    private var bannerHeight: Int = 50
    private var currentBannerAdUnit: String?
    private var isBannerVisible: Bool = false
    private var bannerCallbackFunction: String?

    private var initialDomain: String?
    private var currentRootDomain: String?
    
    private let BANNER_LOAD_TIMEOUT_INTERVAL: TimeInterval = 5.0

    private var isBannerRequestTimedOut: Bool = false
    private var bannerTimeoutWorkItem: DispatchWorkItem?

    private var isLoadingBanner: Bool = false
    private var popupWebView: WKWebView?
    
    init(config: InAppBrowserConfig) {
        self.config = config
        self.currentBackAction = config.backAction
        self.backConfirmMessage = config.backConfirmMessage
        self.backConfirmTimeout = config.backConfirmTimeout
        
        
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    private func setupBannerTimeout(for callbackFunction: String, adUnit: String) {
        bannerTimeoutWorkItem?.cancel()
        
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            if self.isLoadingBanner {
                
                self.isBannerRequestTimedOut = true
                self.isLoadingBanner = false
                
                DispatchQueue.main.async {
                    if let bannerAdView = self.bannerAdView {
                        self.bannerContainer.subviews.forEach { $0.removeFromSuperview() }
                        self.bannerAdView = nil
                    }

                    self.collapseBannerArea(animated: false)
                }
                
                let timeoutErrorInfo = self.createBannerTimeoutErrorInfo(adUnit: adUnit)
                
                self.executeBannerCallback(
                    callbackFunction,
                    adType: "banner",
                    status: "timeout",
                    adUnit: adUnit,
                    errorCode: -1001,
                    detailInfo: timeoutErrorInfo
                )
            }
        }
        
        bannerTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + BANNER_LOAD_TIMEOUT_INTERVAL, execute: timeoutWork)
    }
    private func createBannerTimeoutErrorInfo(adUnit: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        return """
        {"timestamp":\(timestamp),"adType":"banner","adUnit":"\(adUnit)","sdkVersion":"\(Self.SDK_VERSION)","gmaSdkVersion":"\(Self.GOOGLE_SDK_VERSION)","errorType":"TIMEOUT","errorCode":-1001,"message":"Banner ad load timeout after \(BANNER_LOAD_TIMEOUT_INTERVAL) seconds","errorCategory":"TIMEOUT","isRetryable":true,"timeoutMs":\(Int(BANNER_LOAD_TIMEOUT_INTERVAL * 1000)),"targeting":\(targetingJSONString())}
        """
    }
    public func setBannerHeight(_ newHeight: Int) {
        let validatedHeight = max(32, min(250, newHeight))
        self.bannerHeight = validatedHeight
    }
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        if isBannerRequestTimedOut {
            return
        }
        cancelBannerTimeout()
        isLoadingBanner = false

        expandBannerArea()
        showBannerAd()

        bannerPaidEventFallbackWorkItem?.cancel()
        let fallbackWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.bannerPaidEventFallbackWorkItem = nil
            let successInfo = self.buildSuccessInfoJSON(adType: "banner", adUnit: self.currentBannerAdUnit ?? "", status: "success", responseInfo: self.bannerAdView?.responseInfo)
            if let callbackFunction = self.bannerCallbackFunction {
                self.executeBannerCallback(callbackFunction, adType: "banner", status: "success", adUnit: self.currentBannerAdUnit ?? "", errorCode: 0, detailInfo: successInfo)
            }
        }
        bannerPaidEventFallbackWorkItem = fallbackWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: fallbackWork)
    }
    
    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        if isBannerRequestTimedOut {
            return
        }
        
        cancelBannerTimeout()

        isLoadingBanner = false

        if self.bannerAdView != nil {
            self.bannerContainer.subviews.forEach { $0.removeFromSuperview() }
            self.bannerAdView = nil
        }
        self.collapseBannerArea(animated: false)

        let errorCode = (error as NSError).code
        let errorMessage = error.localizedDescription
        let detailedErrorInfo = createBannerLoadErrorInfo(error: error, adUnit: currentBannerAdUnit ?? "")
        
        if let callbackFunction = bannerCallbackFunction {
            executeBannerCallback(callbackFunction, adType: "banner", status: "load_failed", adUnit: currentBannerAdUnit ?? "", errorCode: errorCode, detailInfo: detailedErrorInfo)
        }
    }
    private func cancelBannerTimeout() {
        bannerTimeoutWorkItem?.cancel()
        bannerTimeoutWorkItem = nil
    }

    private func createBannerLoadErrorInfo(error: Error, adUnit: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let errorCode = (error as NSError).code
        let errorMessage = error.localizedDescription.replacingOccurrences(of: "\"", with: "\\\"")

        return """
        {"timestamp":\(timestamp),"adType":"banner","adUnit":"\(adUnit)","sdkVersion":"\(Self.SDK_VERSION)","gmaSdkVersion":"\(Self.GOOGLE_SDK_VERSION)","errorType":"LOAD_ERROR","errorCode":\(errorCode),"message":"\(errorMessage)","errorCategory":"LOAD_FAILED","isRetryable":true,"targeting":\(targetingJSONString())}
        """
    }
    private func cleanupBannerTimeout() {
        cancelBannerTimeout()
        isLoadingBanner = false
        isBannerRequestTimedOut = false
    }
    
    private func setupBannerArea() {
        self.bannerContainer.isHidden = false
        self.bannerContainer.alpha = 1.0
        
        self.bannerContainer.constraints.forEach { constraint in
            if constraint.firstAttribute == .height {
                constraint.constant = CGFloat(self.bannerHeight)
            }
        }
        
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
    }

    
    private func setupBannerConstraints(_ bannerAdView: AdManagerBannerView) {
        bannerAdView.translatesAutoresizingMaskIntoConstraints = false
        
        let constraints = [
            bannerAdView.centerXAnchor.constraint(equalTo: self.bannerContainer.centerXAnchor),
            bannerAdView.centerYAnchor.constraint(equalTo: self.bannerContainer.centerYAnchor),
            bannerAdView.widthAnchor.constraint(lessThanOrEqualTo: self.bannerContainer.widthAnchor),
            bannerAdView.heightAnchor.constraint(lessThanOrEqualTo: self.bannerContainer.heightAnchor)
        ]
        
        NSLayoutConstraint.activate(constraints)
    }
    func bannerViewDidRecordClick(_ bannerView: BannerView) {
        currentBackAction = .historyBack
    }
    public func getBannerHeight() -> Int {
        return bannerHeight
    }
    
    public func setBannerEnabled(_ enabled: Bool) {
        let wasEnabled = self.isBannerEnabled
        self.isBannerEnabled = enabled
        
        if !enabled && isBannerVisible && bannerAdView != nil {
            DispatchQueue.main.async { [weak self] in
                self?.destroyBannerAd()
            }
        }
    }
    
    public func updateBannerArea(_ height: Int, enabled: Bool) {
        let validatedHeight = max(32, min(250, height))
        
        self.bannerHeight = validatedHeight
        setBannerEnabled(enabled)
        
    }
    
    private func expandBannerArea() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if self.bannerContainer != nil {
                self.bannerContainer.isHidden = false
                
                self.bannerContainer.constraints.forEach { constraint in
                    if constraint.firstAttribute == .height {
                        constraint.constant = CGFloat(self.bannerHeight)
                    }
                }
                
                UIView.animate(withDuration: 0.3) {
                    self.view.layoutIfNeeded()
                }
            }
        }
    }
    
    private func collapseBannerArea(animated: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if self.bannerContainer != nil {
                self.bannerContainer.constraints.forEach { constraint in
                    if constraint.firstAttribute == .height {
                        constraint.constant = 0
                    }
                }

                let finish = {
                    self.bannerContainer.isHidden = true
                    self.isBannerVisible = false
                    self.updateBannerVisibilityInJS()
                }

                if animated {
                    UIView.animate(withDuration: 0.3, animations: {
                        self.view.layoutIfNeeded()
                    }) { _ in
                        finish()
                    }
                } else {
                    self.view.layoutIfNeeded()
                    finish()
                }
            }
        }
    }
    
    public func loadBannerAd(_ adUnit: String, callbackFunction: String) {
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if !self.isBannerEnabled {
                self.executeBannerCallback(callbackFunction, adType: "banner", status: "banner_not_enabled", adUnit: adUnit, errorCode: -2001, detailInfo: "Banner ads are not enabled")
                return
            }
            
            self.isLoadingBanner = true
            self.isBannerRequestTimedOut = false
            
            if self.bannerAdView != nil {
                self.bannerContainer.subviews.forEach { $0.removeFromSuperview() }
                self.bannerAdView = nil
            }
            
            self.setupBannerTimeout(for: callbackFunction, adUnit: adUnit)
            
            let currentAdUnit = adUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            self.currentBannerAdUnit = currentAdUnit
            self.bannerCallbackFunction = callbackFunction
            
            self.setupBannerArea()

            self.createBannerAdView(for: currentAdUnit, callbackFunction: callbackFunction)
        }
    }
    private func createBannerAdView(for adUnit: String, callbackFunction: String) {
        let containerWidth = self.bannerContainer.frame.width > 0 ? self.bannerContainer.frame.width : self.view.frame.width
        let adWidth = max(containerWidth, 320)
        let adaptiveSize = inlineAdaptiveBanner(width: adWidth, maxHeight: CGFloat(self.bannerHeight))
        
        if isAdSizeEqualToSize(size1: adaptiveSize, size2: AdSizeInvalid) {
            self.cancelBannerTimeout()
            self.isLoadingBanner = false
            self.collapseBannerArea(animated: false)
            self.executeBannerCallback(callbackFunction, adType: "banner", status: "error", adUnit: adUnit, errorCode: -3001, detailInfo: "Invalid ad size")
            return
        }
        
        self.bannerAdView = AdManagerBannerView(adSize: adaptiveSize)
        self.bannerAdView?.adUnitID = adUnit
        self.bannerAdView?.rootViewController = self
        self.bannerAdView?.delegate = self
        
        if let bannerAdView = self.bannerAdView {
            self.bannerContainer.addSubview(bannerAdView)
            self.setupBannerConstraints(bannerAdView)

            bannerAdView.paidEventHandler = { [weak self] adValue in
                guard let self = self else { return }
                self.bannerPaidEventFallbackWorkItem?.cancel()
                self.bannerPaidEventFallbackWorkItem = nil
                var extra: [String: Any] = [:]
                if let adValueDict = self.buildAdValueDict(adValue) { extra["adValue"] = adValueDict }
                let successInfo = self.buildSuccessInfoJSON(adType: "banner", adUnit: self.currentBannerAdUnit ?? "", status: "success", responseInfo: self.bannerAdView?.responseInfo, extra: extra)
                if let callbackFunction = self.bannerCallbackFunction {
                    self.executeBannerCallback(callbackFunction, adType: "banner", status: "success", adUnit: self.currentBannerAdUnit ?? "", errorCode: 0, detailInfo: successInfo)
                }
            }

            let request = makeAdRequest()
            bannerAdView.load(request)
        }
    }
    
    public func showBannerAd() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if self.isBannerEnabled && self.bannerAdView != nil {
                self.isBannerVisible = true
                self.updateBannerVisibilityInJS()
            }
        }
    }
    
    public func hideBannerAd() {
        DispatchQueue.main.async { [weak self] in
            self?.collapseBannerArea()
        }
    }
    
    public func destroyBannerAd() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if self.bannerAdView != nil {
                self.bannerContainer.subviews.forEach { $0.removeFromSuperview() }
                self.bannerAdView = nil
                self.currentBannerAdUnit = nil
                self.bannerCallbackFunction = nil
            }
            self.collapseBannerArea()
        }
    }
    
    public func isBannerAdLoaded() -> Bool {
        return bannerAdView != nil && isBannerEnabled
    }
    
    public func isBannerAdVisible() -> Bool {
        return isBannerVisible
    }
    
    private func executeBannerCallback(_ callbackFunction: String, adType: String, status: String, adUnit: String, errorCode: Int, detailInfo: String) {
        let script = "javascript:\(callbackFunction)(\"\(adType)\", \"\(status)\", \"\(adUnit)\", \"\(Self.SDK_VERSION)\", \(errorCode), \"\(escapeJavaScript(detailInfo))\");"
        webView.evaluateJavaScriptSafely(script)
    }
    
    private func createSimpleSuccessInfo(_ adType: String, adUnit: String, responseInfo: ResponseInfo? = nil) -> String {
        return buildSuccessInfoJSON(adType: adType, adUnit: adUnit, status: "success", responseInfo: responseInfo)
    }
    private func syncCookiesFromHTTPCookieStorage() {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        
        for cookie in cookies {
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { }
        }
    }

    private func syncCookiesToHTTPCookieStorage() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        setupNewMainLayout()
        setupWebView()
        setupJavaScriptInterface(for: self.webView)
        
        syncCookiesFromHTTPCookieStorage()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object:nil
        )
    }
    private func setupCookieSaveObservers() {
   
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveCookiesOnBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveCookiesOnBackground),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveCookiesOnBackground),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    public func saveCookiesToUserDefaults() {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                do {
                    let cookieData = try NSKeyedArchiver.archivedData(withRootObject: cookies, requiringSecureCoding: false)
                    DispatchQueue.main.async {
                        UserDefaults.standard.set(cookieData, forKey: "SavedWebViewCookies")
                        UserDefaults.standard.synchronize()
                    }
                } catch {
                }
            }
        }
        
        public func loadCookiesFromUserDefaults() {
            guard let cookieData = UserDefaults.standard.data(forKey: "SavedWebViewCookies") else {
                return
            }
            
            do {
                if let cookies = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(cookieData) as? [HTTPCookie] {
                    for cookie in cookies {
                        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                        }
                        
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                }
            } catch {
            }
        }
        
    
    @objc private func saveCookiesOnBackground() {
        saveCookiesToUserDefaults()
    }
    
    @objc private func appDidBecomeActive() {
        if webView != nil {
            let script = "window.dispatchEvent(new Event('visibilitychange'));"
            webView.evaluateJavaScript(script, completionHandler: nil)
            
            if isMovingToExternalApp {
                isMovingToExternalApp = false
                
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        
    }
    
    func isPreloadedAdAvailable(adType: String) -> Bool {
        switch adType.lowercased() {
        case "rewarded":
            return preloadedRewardedAd != nil
        case "interstitial":
            return preloadedInterstitialAd != nil
        case "rewarded_interstitial":
            return preloadedRewardedInterstitialAd != nil
        default:
            return false
        }
    }
    public func clearPreloadedAd(_ adType: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch adType.lowercased() {
            case "rewarded":
                self.preloadedRewardedAd = nil
                self.preloadedRewardedAdUnit = nil
            case "interstitial":
                self.preloadedInterstitialAd = nil
                self.preloadedInterstitialAdUnit = nil
            case "rewarded_interstitial":
                self.preloadedRewardedInterstitialAd = nil
                self.preloadedRewardedInterstitialAdUnit = nil
            case "all":
                self.preloadedRewardedAd = nil
                self.preloadedRewardedAdUnit = nil
                self.preloadedInterstitialAd = nil
                self.preloadedInterstitialAdUnit = nil
                self.preloadedRewardedInterstitialAd = nil
                self.preloadedRewardedInterstitialAdUnit = nil
            default:
                break
            }
        }
    }
    public func closeWebView(){
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let presentedAlert = self.presentedViewController as? UIAlertController {
                presentedAlert.dismiss(animated: false, completion: nil)
            }
            
            if !self.config.preventCache {
                self.syncCookiesToHTTPCookieStorage()
            } else {
                self.clearWebViewData()
            }
            
            InAppBrowserManager.shared.notifyBrowserClosed()
            self.dismiss(animated: true) { [weak self] in
                guard let self = self else { return }
                
                self.webView.stopLoading()
                self.webView.configuration.userContentController.removeAllUserScripts()
                
                do {
                    self.webView.configuration.userContentController.removeScriptMessageHandler(forName: "iOSInterface")
                }
                
                self.webView.navigationDelegate = nil
                self.webView.uiDelegate = nil
            }
        }
    }
    
    private func clearWebViewData() {
        webView.stopLoading()
        if config.preventCache {
            let dataStore = webView.configuration.websiteDataStore
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) {
            }
            
            HTTPCookieStorage.shared.removeCookies(since: Date(timeIntervalSince1970: 0))
            URLCache.shared.removeAllCachedResponses()
        }
        
        navigationHistory.removeAll()
        isNavigatingBack = false
        
        backActionCount = 0
        lastBackActionURL = ""
        lastBackActionTime = 0
        
    }
    private func applyImageControlSettings() {
        let imageControlScript = """
        (function() {
           var allowSave = \(config.allowImageSave ? "true" : "false");
           var allowZoom = \(config.allowImageZoom ? "true" : "false");
           var allowDrag = \(config.allowImageDrag ? "true" : "false");
           var allowSelect = \(config.allowImageSelect ? "true" : "false");
           
           var images = document.querySelectorAll('img');
           images.forEach(function(img) {
               if (!allowSave) {
                   img.style.webkitTouchCallout = 'none';
                   img.addEventListener('contextmenu', function(e) {
                       e.preventDefault();
                   }, true);
               }
               
               if (!allowDrag) {
                   img.style.webkitUserDrag = 'none';
                   img.draggable = false;
               }
               
               if (!allowSelect) {
                   img.style.webkitUserSelect = 'none';
                   img.style.userSelect = 'none';
               }
           });
           
           if (!allowZoom) {
               document.addEventListener('gesturestart', function(e) {
                   e.preventDefault();
               }, false);
               
               document.addEventListener('gesturechange', function(e) {
                   e.preventDefault();
               }, false);
           }
        })();
        """
        
        webView.evaluateJavaScript(imageControlScript, completionHandler: nil)
    }
    private func optimizeURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        
        if url.host?.contains("coupang.com") == true {
            let essentialParams = ["itemId", "vendorItemId"]
            
            if let queryItems = components?.queryItems {
                let filteredItems = queryItems.filter { item in
                    essentialParams.contains(item.name)
                }
                components?.queryItems = filteredItems.isEmpty ? nil : filteredItems
            }
        }
        
        let optimizedURL = components?.url?.absoluteString ?? urlString
        
        if optimizedURL.count > 2000 {
            if let productId = extractProductId(from: urlString) {
                return "https://www.coupang.com/vp/products/\(productId)"
            }
        }
        
        return optimizedURL
    }
    
    private func extractProductId(from urlString: String) -> String? {
        if let url = URL(string: urlString) {
            let pathComponents = url.pathComponents
            if let productsIndex = pathComponents.firstIndex(of: "products"),
               productsIndex + 1 < pathComponents.count {
                return pathComponents[productsIndex + 1]
            }
        }
        return nil
    }
    private func setupNewMainLayout() {
        view.backgroundColor = .white
        
        mainContainerStackView = UIStackView()
        mainContainerStackView.axis = .vertical
        mainContainerStackView.distribution = .fill
        mainContainerStackView.alignment = .fill
        mainContainerStackView.spacing = 0
        mainContainerStackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainContainerStackView)
        
        toolbarView = createToolbar()
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        
        webViewContainer = UIView()
        webViewContainer.translatesAutoresizingMaskIntoConstraints = false
        
        let webConfig = createEnhancedWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: webConfig)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        
        setupWebViewProperties()
        webViewContainer.addSubview(webView)
        MobileAds.shared.register(webView)
        
        loadingCover = UIView()
        loadingCover.translatesAutoresizingMaskIntoConstraints = false
        loadingCover.backgroundColor = UIColor.clear
        loadingCover.isHidden = true
        
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webViewContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webViewContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webViewContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webViewContainer.bottomAnchor),
            
        ])
        
        bannerContainer = UIView()
        bannerContainer.backgroundColor = UIColor.white
        bannerContainer.translatesAutoresizingMaskIntoConstraints = false
        bannerContainer.isHidden = true
        
        mainContainerStackView.addArrangedSubview(toolbarView)
        mainContainerStackView.addArrangedSubview(webViewContainer)
        mainContainerStackView.addArrangedSubview(bannerContainer)
        
        NSLayoutConstraint.activate([
            mainContainerStackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            mainContainerStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainContainerStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainContainerStackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            
            toolbarView.heightAnchor.constraint(equalToConstant: CGFloat(config.toolbarHeight)),
            bannerContainer.heightAnchor.constraint(equalToConstant: 0)
        ])
    }
    
    private func setupWebViewProperties() {
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.bouncesZoom = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        
        webView.scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        
        for gestureRecognizer in webView.gestureRecognizers ?? [] {
            if gestureRecognizer is UITapGestureRecognizer {
                gestureRecognizer.isEnabled = true
            } else if gestureRecognizer is UIPinchGestureRecognizer {
                gestureRecognizer.isEnabled = false
            } else if gestureRecognizer is UILongPressGestureRecognizer {
                gestureRecognizer.isEnabled = false
            }
        }
        
        if #available(iOS 13.0, *) {
            webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
    }
    private func setupMainLayout() {
        view.backgroundColor = .white
        let toolbar = createToolbar()
        view.addSubview(toolbar)
        
        let config = createEnhancedWebViewConfiguration()
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.bouncesZoom = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        
        webView.scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        
        for gestureRecognizer in webView.gestureRecognizers ?? [] {
            if gestureRecognizer is UITapGestureRecognizer {
                gestureRecognizer.isEnabled = true
            } else if gestureRecognizer is UIPinchGestureRecognizer {
                gestureRecognizer.isEnabled = false
            } else if gestureRecognizer is UILongPressGestureRecognizer {
                gestureRecognizer.isEnabled = false
            }
        }
        
        if #available(iOS 13.0, *) {
            webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        
        view.addSubview(webView)
        MobileAds.shared.register(webView)
        
        setupLoadingCover()
        
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: CGFloat(self.config.toolbarHeight)),
            
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    private func createEnhancedWebViewConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        
        let sharedProcessPool = WKProcessPool()
        config.processPool = sharedProcessPool
        
        let userContentController = WKUserContentController()
        
        
        let cookieStorage = HTTPCookieStorage.shared
        cookieStorage.cookieAcceptPolicy = .always
        
        userContentController.add(self, name: "iOSInterface")
        config.userContentController = userContentController
        config.allowsInlineMediaPlayback = true
        
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.suppressesIncrementalRendering = false
        
        if #available(iOS 14.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = []
            
            let preferences = WKWebpagePreferences()
            preferences.allowsContentJavaScript = true
            if #available(iOS 14.5, *) {
                preferences.preferredContentMode = .recommended
            }
            config.defaultWebpagePreferences = preferences
        } else {
            config.mediaPlaybackRequiresUserAction = false
            config.preferences.javaScriptEnabled = true
        }
        let imageControlScript = """
        (function() {
           
           document.addEventListener('contextmenu', function(e) {
               if (e.target.tagName === 'IMG') {
                   e.preventDefault();
                   e.stopPropagation();
                   return false;
               }
           }, true);
           
           document.addEventListener('dragstart', function(e) {
               if (e.target.tagName === 'IMG') {
                   e.preventDefault();
                   return false;
               }
           }, true);
           
           document.addEventListener('selectstart', function(e) {
               if (e.target.tagName === 'IMG') {
                   e.preventDefault();
                   return false;
               }
           }, true);
           
           function disableImageInteractions() {
               var images = document.querySelectorAll('img');
               
               images.forEach(function(img, index) {
                   if (img.dataset.protected) return; 
                   
                   img.dataset.protected = 'true';
                   
                   img.style.webkitUserSelect = 'none';
                   img.style.userSelect = 'none';
                   img.style.webkitTouchCallout = 'none';
                   img.style.webkitUserDrag = 'none';
                   img.style.pointerEvents = 'none';
                   
                   img.addEventListener('touchstart', function(e) {
                       e.preventDefault();
                       e.stopPropagation();
                   }, { passive: false, capture: true });
                   
                   img.addEventListener('touchend', function(e) {
                       e.preventDefault();
                       e.stopPropagation();
                   }, { passive: false, capture: true });
                   
                   img.addEventListener('touchmove', function(e) {
                       e.preventDefault();
                       e.stopPropagation();
                   }, { passive: false, capture: true });
                   
                   img.addEventListener('click', function(e) {
                       e.preventDefault();
                       e.stopPropagation();
                   }, true);
                   
                   img.addEventListener('dblclick', function(e) {
                       e.preventDefault();
                       e.stopPropagation();
                   }, true);
                   
                   img.addEventListener('mousedown', function(e) {
                       e.preventDefault();
                       e.stopPropagation();
                   }, true);
                   
                   img.addEventListener('mouseup', function(e) {
                       e.preventDefault();
                       e.stopPropagation();
                   }, true);
               });
           }
           
           var style = document.createElement('style');
           style.innerHTML = 
               'img {' +
               '    -webkit-user-select: none !important;' +
               '    -moz-user-select: none !important;' +
               '    -ms-user-select: none !important;' +
               '    user-select: none !important;' +
               '    -webkit-user-drag: none !important;' +
               '    -webkit-touch-callout: none !important;' +
               '    -webkit-tap-highlight-color: transparent !important;' +
               '    pointer-events: none !important;' +
               '    touch-action: none !important;' +
               '}' +
               '' +
               '.image-container, .photo-container, .img-container {' +
               '    -webkit-user-select: none !important;' +
               '    user-select: none !important;' +
               '    -webkit-touch-callout: none !important;' +
               '}' +
               '' +
               'img[src*=".jpg"], ' +
               'img[src*=".jpeg"], ' +
               'img[src*=".png"], ' +
               'img[src*=".gif"], ' +
               'img[src*=".webp"] {' +
               '    -webkit-user-select: none !important;' +
               '    user-select: none !important;' +
               '    -webkit-touch-callout: none !important;' +
               '    pointer-events: none !important;' +
               '    -webkit-user-drag: none !important;' +
               '}';
           document.head.appendChild(style);
           
           function initImageProtection() {
               disableImageInteractions();
               
               var observer = new MutationObserver(function(mutations) {
                   var hasNewImages = false;
                   
                   mutations.forEach(function(mutation) {
                       if (mutation.type === 'childList') {
                           mutation.addedNodes.forEach(function(node) {
                               if (node.nodeType === 1) {
                                   if (node.tagName === 'IMG' || (node.querySelector && node.querySelector('img'))) {
                                       hasNewImages = true;
                                   }
                               }
                           });
                       }
                   });
                   
                   if (hasNewImages) {
                       setTimeout(disableImageInteractions, 100);
                   }
               });
               
               if (document.body) {
                   observer.observe(document.body, {
                       childList: true,
                       subtree: true
                   });
               }
           }
           
           if (document.readyState === 'loading') {
               document.addEventListener('DOMContentLoaded', initImageProtection);
           } else {
               initImageProtection();
           }
           
           window.addEventListener('load', function() {
               setTimeout(disableImageInteractions, 500);
           });
           
        })();
        """
        
        let imageScript = WKUserScript(
            source: imageControlScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(imageScript)
        
        if self.config.preventCache {
            let dataStore = WKWebsiteDataStore.nonPersistent()
            config.websiteDataStore = dataStore
        } else {
            let dataStore = WKWebsiteDataStore.default()
            config.websiteDataStore = dataStore
        }
        
        config.applicationNameForUserAgent = "KakaoTalkSharing"
        
        return config
    }
    public func showLoadingCoverFromWeb() {
        DispatchQueue.main.async { [weak self] in
            self?.showLoadingCover()
        }
    }

    public func hideLoadingCoverFromWeb() {
        DispatchQueue.main.async { [weak self] in
            self?.hideLoadingCover()
        }
    }
    private func createToolbar() -> UIView {
        let toolbar = UIView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        
        if let bgColor = config.toolbarBackgroundColor {
            toolbar.backgroundColor = bgColor
        } else {
            toolbar.backgroundColor = config.toolbarMode == "dark" ? .black : .white
        }
        
        let leftButton = UIButton(type: .system)
        leftButton.translatesAutoresizingMaskIntoConstraints = false
        leftButton.tag = 100
        setupButton(leftButton, role: config.leftButtonRole, icon: config.leftButtonIcon, isLeft: true)
        
        let rightButton = UIButton(type: .system)
        rightButton.translatesAutoresizingMaskIntoConstraints = false
        rightButton.tag = 200
        setupButton(rightButton, role: config.rightButtonRole, icon: config.rightButtonIcon, isLeft: false)
        
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = config.toolbarTitle
        
        if let fontFamily = config.fontFamily {
            titleLabel.font = UIFont(name: fontFamily, size: CGFloat(config.fontSize))
        } else {
            titleLabel.font = .systemFont(ofSize: CGFloat(config.fontSize), weight: .semibold)
        }
        
        if let titleColor = config.titleTextColor {
            titleLabel.textColor = titleColor
        } else {
            titleLabel.textColor = config.toolbarMode == "dark" ? .white : .black
        }
        
        toolbar.addSubview(leftButton)
        toolbar.addSubview(rightButton)
        toolbar.addSubview(titleLabel)
        
        let leftButtonSize = CGFloat(config.backButtonIconSize)
        let rightButtonSize = CGFloat(config.closeButtonIconSize)
        
        let leftButtonLeftMargin = config.leftButtonVisible ?
            CGFloat(config.backButtonLeftMargin == -1 ? 8 : config.backButtonLeftMargin) : 0
        
        let leftButtonTopMargin = config.leftButtonVisible ?
            CGFloat(config.backButtonTopMargin == -1 ? 0 : config.backButtonTopMargin) : 0
            
        let leftButtonRightMargin = config.leftButtonVisible ?
            CGFloat(config.backButtonRightMargin == -1 ? 0 : config.backButtonRightMargin) : 0
            
        let leftButtonBottomMargin = config.leftButtonVisible ?
            CGFloat(config.backButtonBottomMargin == -1 ? 0 : config.backButtonBottomMargin) : 0
            
        let rightButtonLeftMargin = config.rightButtonVisible ?
            CGFloat(config.closeButtonLeftMargin == -1 ? 0 : config.closeButtonLeftMargin) : 0
            
        let rightButtonTopMargin = config.rightButtonVisible ?
            CGFloat(config.closeButtonTopMargin == -1 ? 0 : config.closeButtonTopMargin) : 0
            
        let rightButtonRightMargin = config.rightButtonVisible ?
            CGFloat(-(config.closeButtonRightMargin == -1 ? 8 : config.closeButtonRightMargin)) : 0
            
        let rightButtonBottomMargin = config.rightButtonVisible ?
            CGFloat(config.closeButtonBottomMargin == -1 ? 0 : config.closeButtonBottomMargin) : 0
        
        var leftButtonConstraints: [NSLayoutConstraint] = []
        var rightButtonConstraints: [NSLayoutConstraint] = []
        
        if config.leftButtonVisible {
            leftButtonConstraints = [
                leftButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: leftButtonLeftMargin),
                leftButton.widthAnchor.constraint(equalToConstant: leftButtonSize),
                leftButton.heightAnchor.constraint(equalToConstant: leftButtonSize)
            ]
            
            if config.backButtonTopMargin != -1 && config.backButtonBottomMargin != -1 {
                leftButtonConstraints.append(
                    leftButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: leftButtonTopMargin)
                )
            } else if config.backButtonTopMargin != -1 {
                leftButtonConstraints.append(
                    leftButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: leftButtonTopMargin)
                )
            } else if config.backButtonBottomMargin != -1 {
                leftButtonConstraints.append(
                    leftButton.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -leftButtonBottomMargin)
                )
            } else {
                leftButtonConstraints.append(
                    leftButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
                )
            }
        }
        
        if config.rightButtonVisible {
            rightButtonConstraints = [
                rightButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: rightButtonRightMargin),
                rightButton.widthAnchor.constraint(equalToConstant: rightButtonSize),
                rightButton.heightAnchor.constraint(equalToConstant: rightButtonSize)
            ]
            
            if config.closeButtonTopMargin != -1 && config.closeButtonBottomMargin != -1 {
                rightButtonConstraints.append(
                    rightButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: rightButtonTopMargin)
                )
            } else if config.closeButtonTopMargin != -1 {
                rightButtonConstraints.append(
                    rightButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: rightButtonTopMargin)
                )
            } else if config.closeButtonBottomMargin != -1 {
                rightButtonConstraints.append(
                    rightButton.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -rightButtonBottomMargin)
                )
            } else {
                rightButtonConstraints.append(
                    rightButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
                )
            }
        }
        
        NSLayoutConstraint.activate(leftButtonConstraints + rightButtonConstraints)
        
        switch config.titleAlignment {
        case "left":
            let leftMargin = calculateTitleLeftMargin()
            titleLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: CGFloat(leftMargin)).isActive = true
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
            
        case "right":
            let rightMargin = calculateTitleRightMargin()
            titleLabel.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: CGFloat(-rightMargin)).isActive = true
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
            
        default:
            titleLabel.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor, constant: CGFloat(config.titleCenterOffset)).isActive = true
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
        }
        
        return toolbar
    }

    private func calculateTitleLeftMargin() -> Int {
        if let customMargin = config.titleLeftMargin, customMargin != -1 {
            return customMargin
        }
        
        var leftMargin = 16
        
        if config.leftButtonVisible && config.leftButtonRole != .none {
            let buttonLeftMargin = config.backButtonLeftMargin == -1 ? 8 : config.backButtonLeftMargin
            let buttonRightMargin = config.backButtonRightMargin == -1 ? 0 : config.backButtonRightMargin
            let buttonSize = config.backButtonIconSize
            
            let buttonRightEdge = buttonLeftMargin + buttonSize + buttonRightMargin
            leftMargin = buttonRightEdge + 8
        }
        
        return leftMargin
    }

    private func calculateTitleRightMargin() -> Int {
        if let customMargin = config.titleRightMargin, customMargin != -1 {
            return customMargin
        }
        
        var rightMargin = 16
        
        if config.rightButtonVisible && config.rightButtonRole != .none {
            let buttonRightMargin = config.closeButtonRightMargin == -1 ? 8 : config.closeButtonRightMargin
            let buttonLeftMargin = config.closeButtonLeftMargin == -1 ? 0 : config.closeButtonLeftMargin
            let buttonSize = config.closeButtonIconSize
            
            let buttonLeftEdge = buttonRightMargin + buttonSize + buttonLeftMargin
            rightMargin = buttonLeftEdge + 8
        }
        
        return rightMargin
    }
    
    private func setupButton(_ button: UIButton, role: InAppBrowserConfig.ButtonRole, icon: InAppBrowserConfig.ButtonIcon, isLeft: Bool) {
        
        
        button.removeTarget(nil, action: nil, for: .allEvents)
        
        switch role {
        case .back:
            button.addTarget(self, action: #selector(performBackAction), for: .touchUpInside)
            
        case .close:
            button.addTarget(self, action: #selector(performCloseAction), for: .touchUpInside)
            
        case .none:
            button.isHidden = true
            button.isUserInteractionEnabled = false
            
            return
        }
        
        setupButtonIcon(button, icon: icon, role: role)
        
        if isLeft && !config.leftButtonVisible {
            button.isHidden = true
        } else if !isLeft && !config.rightButtonVisible {
            button.isHidden = true
        } else {
            button.isHidden = false
            button.isUserInteractionEnabled = true
        }
        
        
    }


    private func setupButtonIcon(_ button: UIButton, icon: InAppBrowserConfig.ButtonIcon, role: InAppBrowserConfig.ButtonRole) {
        
        let currentBundle = Bundle(for: InAppBrowserViewController.self)
        
        let img1 = UIImage(named: "_ico", in: Bundle.resourceBundle, compatibleWith: nil)
        
        let img2 = UIImage(named: "_ico", in: currentBundle, compatibleWith: nil)
        
        let img3 = UIImage(named: "_ico")
        
        switch icon {
        case .auto:
            if role == .back {
                let backImage = UIImage(named: "_ico", in: Bundle.resourceBundle, compatibleWith: nil) ??
                            UIImage(named: "_ico", in: currentBundle, compatibleWith: nil) ??
                            UIImage(systemName: "chevron.left")
                button.setImage(backImage, for: .normal)
            } else {
                button.setImage(UIImage(systemName: "xmark"), for: .normal)
            }
            button.tintColor = config.toolbarMode == "dark" ? .white : .black
            
        case .back:
            let backImage = UIImage(named: "_ico", in: Bundle.resourceBundle, compatibleWith: nil) ??
                        UIImage(named: "_ico", in: currentBundle, compatibleWith: nil) ??
                        UIImage(systemName: "chevron.left")
            button.setImage(backImage, for: .normal)
            button.tintColor = config.toolbarMode == "dark" ? .white : .black
            
        case .close:
            button.setImage(UIImage(systemName: "xmark"), for: .normal)
            button.tintColor = config.toolbarMode == "dark" ? .white : .black
            
        case .custom(let imageName):
            if let customImage = UIImage(named: imageName) {
                button.setImage(customImage.withRenderingMode(.alwaysOriginal), for: .normal)
            } else {
                setupButtonIcon(button, icon: .auto, role: role)
            }
        }
    }

    private func setupWebView() {
        if webView.url != nil {
            webView.stopLoading()
            if config.preventCache {
                let dataStore = webView.configuration.websiteDataStore
                let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
                dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) {}
            }
        }
        
        if let urlString = config.url {
            let finalUrl = config.preventCache ? addCacheBusterToUrl(urlString) : urlString
            let optimizedUrlString = optimizeURL(finalUrl)
            
            initialDomain = getRootDomain(from: optimizedUrlString)
            currentRootDomain = initialDomain
            
            if let url = URL(string: optimizedUrlString) {
                
                var request = URLRequest(url: url)
                
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                request.setValue("0", forHTTPHeaderField: "Expires")
                request.setValue(String(Int(Date().timeIntervalSince1970)), forHTTPHeaderField: "X-Requested-With")
                
                request.httpShouldHandleCookies = true
                
                let userAgent = generateOptimalUserAgent(for: url)
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                
                webView.load(request)
            }
        }
    }

    private func getRootDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else {
            return ""
        }
        return registrableDomain(of: host)
    }
    
    private func addCacheBusterToUrl(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        
        if components?.queryItems == nil {
            components?.queryItems = []
        }
        
        components?.queryItems?.append(URLQueryItem(name: "_cache_buster", value: timestamp))
        components?.queryItems?.append(URLQueryItem(name: "_t", value: timestamp))
        
        return components?.url?.absoluteString ?? urlString
    }
    
    private func generateOptimalUserAgent(for url: URL) -> String {
        let baseUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        
        if url.host?.contains("coupang.com") == true {
            return "\(baseUA) CoupangApp"
        } else if url.host?.contains("google.com") == true ||
                  url.host?.contains("googlesyndication.com") == true {
            return "\(baseUA) Chrome/120.0.0.0"
        }
        
        return config.userAgent
    }
    
    private func setupLoadingCover() {
        loadingCover = UIView()
        loadingCover.translatesAutoresizingMaskIntoConstraints = false
        
        if let loadingBgColor = config.loadingBackgroundColor {
            loadingCover.backgroundColor = loadingBgColor
        } else {
            loadingCover.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        }
        loadingCover.isHidden = true
        
        setupLoadingIndicator()
        
        view.addSubview(loadingCover)
        NSLayoutConstraint.activate([
            loadingCover.topAnchor.constraint(equalTo: webView.topAnchor),
            loadingCover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingCover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingCover.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    private func setupLoadingIndicator() {
        if loadingIndicator != nil {
            loadingIndicator.removeFromSuperview()
        }
        
        switch config.progressBarStyle {
        case 1:
            let progressView = UIProgressView(progressViewStyle: .default)
            progressView.translatesAutoresizingMaskIntoConstraints = false
            
            if let progressColor = config.progressBarColor {
                progressView.progressTintColor = progressColor
            } else {
                progressView.progressTintColor = UIColor(hex: "#FF4081")
            }
            
            progressView.trackTintColor = UIColor.lightGray.withAlphaComponent(0.3)
            
            loadingCover.addSubview(progressView)
            
            NSLayoutConstraint.activate([
                progressView.topAnchor.constraint(equalTo: loadingCover.topAnchor, constant: 4),
                progressView.leadingAnchor.constraint(equalTo: loadingCover.leadingAnchor, constant: 0),
                progressView.trailingAnchor.constraint(equalTo: loadingCover.trailingAnchor, constant: 0),
                progressView.heightAnchor.constraint(equalToConstant: 6)
            ])
            
            progressView.progress = 0.0
            
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 0.05)
            timer.setEventHandler { [weak progressView] in
                guard let progressView = progressView else {
                    timer.cancel()
                    return
                }
                
                let newProgress = progressView.progress + 0.03
                if newProgress >= 1.0 {
                    progressView.progress = 0.0
                } else {
                    UIView.animate(withDuration: 0.05) {
                        progressView.setProgress(newProgress, animated: true)
                    }
                }
            }
            timer.resume()
            
            loadingIndicator = progressView
            
        case 2:
            if let baseImageName = config.progressBarImageName {
                var animationImages: [UIImage] = []
                
                for i in 1...8 {
                    let imageName = "\(baseImageName)_\(i)"
                    if let image = UIImage(named: imageName) {
                        animationImages.append(image)
                    }
                }
                
                if animationImages.isEmpty {
                    if let singleImage = UIImage(named: baseImageName) {
                        let imageView = UIImageView(image: singleImage)
                        imageView.translatesAutoresizingMaskIntoConstraints = false
                        imageView.contentMode = .scaleAspectFit
                        
                        loadingCover.addSubview(imageView)
                        
                        NSLayoutConstraint.activate([
                            imageView.centerXAnchor.constraint(equalTo: loadingCover.centerXAnchor),
                            imageView.centerYAnchor.constraint(equalTo: loadingCover.centerYAnchor),
                            imageView.widthAnchor.constraint(equalToConstant: 80),
                            imageView.heightAnchor.constraint(equalToConstant: 80)
                        ])
                        
                        loadingIndicator = imageView
                    } else {
                        fallbackToDefaultIndicator()
                    }
                } else {
                    let imageView = UIImageView()
                    imageView.translatesAutoresizingMaskIntoConstraints = false
                    imageView.contentMode = .scaleAspectFit
                    imageView.animationImages = animationImages
                    imageView.animationDuration = config.progressBarAnimationDuration
                    imageView.startAnimating()
                    
                    loadingCover.addSubview(imageView)
                    
                    NSLayoutConstraint.activate([
                        imageView.centerXAnchor.constraint(equalTo: loadingCover.centerXAnchor),
                        imageView.centerYAnchor.constraint(equalTo: loadingCover.centerYAnchor),
                        imageView.widthAnchor.constraint(equalToConstant: 80),
                        imageView.heightAnchor.constraint(equalToConstant: 80)
                    ])
                    
                    loadingIndicator = imageView
                }
            } else {
                fallbackToDefaultIndicator()
            }
            
        default:
            fallbackToDefaultIndicator()
        }
    }
    
    private func fallbackToDefaultIndicator() {
        let activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        
        if let progressColor = config.progressBarColor {
            activityIndicator.color = progressColor
        } else {
            activityIndicator.color = .white
        }
        
        activityIndicator.startAnimating()
        loadingCover.addSubview(activityIndicator)
        
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: loadingCover.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: loadingCover.centerYAnchor)
        ])
        
        loadingIndicator = activityIndicator
    }
    @objc private func performBackAction() {
        handleBackAction()
    }

    @objc private func performCloseAction() {
        InAppBrowserManager.shared.notifyBrowserClosed()
        dismiss(animated: true)
    }
    func resetHistory() {
        navigationHistory.removeAll()
        isNavigatingBack = false
        
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideLoadingCover()
        
        if let currentURL = webView.url?.absoluteString {
            if !isNavigatingBack {
                if navigationHistory.last != currentURL {
                    navigationHistory.append(currentURL)
                    
                }
            } else {
                
            }
            
            if navigationHistory.count > 50 {
                navigationHistory.removeFirst()
            }
        }
        
        isNavigatingBack = false
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.sendInitialATTStatusOnce()
        }
    }
    private func handleBackAction() {
            let currentTime = Date().timeIntervalSince1970
            let currentURL = webView.url?.absoluteString ?? ""
            if currentURL == lastBackActionURL && currentTime - lastBackActionTime < 5.0 {
                backActionCount += 1
                
                if backActionCount >= 3 {
                    
                    showBackLoopAlert()
                    return
                }
            } else {
                backActionCount = 1
            }
            
            lastBackActionTime = currentTime
            lastBackActionURL = currentURL
            
            switch currentBackAction {
            case .exit:
                
                closeApp()
                
            case .historyBack:
                if shouldForceExitFromCurrentPage(currentURL) {
                    closeApp()
                    return
                }
                let hasValidBackHistory = checkValidBackHistory()
                
                if hasValidBackHistory {
                    
                    isNavigatingBack = true
                    webView.goBack()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self.checkBackNavigationResult(originalURL: currentURL)
                    }
                } else {
                    
                    closeApp()
                }
                
            case .confirmExit:
                handleConfirmExitWithDoubleTap()
                    
            case .ignore:
                return
            }
            
            
        }
    private func showExitConfirmDialog() {
        if isShowingAlert {
            return
        }
        
        let alert = UIAlertController(
            title: "앱 종료",
            message: backConfirmMessage,
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
            
        })
        
        alert.addAction(UIAlertAction(title: "확인", style: .destructive) { [weak self] _ in
            
            self?.closeApp()
        })
        
        present(alert, animated: true)
    }

    private func handleConfirmExitWithDoubleTap() {
        let currentTime = Date().timeIntervalSince1970
        
        if currentTime - lastBackPressed < backConfirmTimeout {
            closeApp()
        } else {
            lastBackPressed = currentTime
            showToast(message: backConfirmMessage, duration: backConfirmTimeout)
        }
    }
        private func shouldForceExitFromCurrentPage(_ currentURL: String) -> Bool {
            let forceExitPatterns = [
                "/success",
                "/error",
                "/complete",
                "/finish",
                "/done",
                "/result"
            ]
            
            for pattern in forceExitPatterns {
                if currentURL.contains(pattern) {
                    
                    return true
                }
            }
            
            return false
        }
        
        private func checkValidBackHistory() -> Bool {
            let currentURL = webView.url?.absoluteString ?? ""
            let backList = webView.backForwardList.backList
            
            for (index, item) in backList.enumerated() {
                let backURL = item.url.absoluteString
                
                
                if backURL != currentURL {
                    
                    return true
                }
            }
            
            
            return false
        }
        
        private func checkBackNavigationResult(originalURL: String) {
            let currentURL = webView.url?.absoluteString ?? ""
            
            if currentURL == originalURL {
                
                
                
                closeApp()
            } else {
                
                backActionCount = 0
            }
        }
        private func showBackLoopAlert() {
            
            closeApp()
        }
        
        private func closeApp() {
            
            
            backActionCount = 0
            lastBackActionURL = ""
            
            InAppBrowserManager.shared.notifyBrowserClosed()
            
            DispatchQueue.main.async { [weak self] in
                self?.dismiss(animated: true) {
                    
                }
            }
        }

    private func showToast(message: String, duration: TimeInterval = 2.0) {
        let toastLabel = UILabel()
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        toastLabel.textColor = UIColor.white
        toastLabel.font = UIFont.systemFont(ofSize: 16)
        toastLabel.textAlignment = .center
        toastLabel.text = message
        toastLabel.layer.cornerRadius = 8
        toastLabel.clipsToBounds = true
        toastLabel.numberOfLines = 0
        
        let maxSize = CGSize(width: view.frame.width - 40, height: CGFloat.greatestFiniteMagnitude)
        let expectedSize = toastLabel.sizeThatFits(maxSize)
        
        toastLabel.frame = CGRect(
            x: (view.frame.width - expectedSize.width - 20) / 2,
            y: view.frame.height - view.safeAreaInsets.bottom - 100,
            width: expectedSize.width + 20,
            height: expectedSize.height + 16
        )
        
        view.addSubview(toastLabel)
        
        UIView.animate(withDuration: 0.3, animations: {
            toastLabel.alpha = 1.0
        }) { _ in
            UIView.animate(withDuration: 0.3, delay: duration, options: [], animations: {
                toastLabel.alpha = 0.0
            }) { _ in
                toastLabel.removeFromSuperview()
            }
        }
    }
    
    public func showLoadingCover() {
        loadingCover.isHidden = false
        
        if let activityIndicator = loadingIndicator as? UIActivityIndicatorView {
            activityIndicator.startAnimating()
        }
    }
    
    public func hideLoadingCover() {
        loadingCover.isHidden = true
        
        if let activityIndicator = loadingIndicator as? UIActivityIndicatorView {
            activityIndicator.stopAnimating()
        }
    }
}
extension InAppBrowserViewController {
    
    func updateButtonRoles(leftRole: InAppBrowserConfig.ButtonRole, rightRole: InAppBrowserConfig.ButtonRole, leftIcon: InAppBrowserConfig.ButtonIcon, rightIcon: InAppBrowserConfig.ButtonIcon) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.replaceButton(tag: 100, role: leftRole, icon: leftIcon, isLeft: true)
            self.replaceButton(tag: 200, role: rightRole, icon: rightIcon, isLeft: false)
        }
    }
    
    private func replaceButton(tag: Int, role: InAppBrowserConfig.ButtonRole, icon: InAppBrowserConfig.ButtonIcon, isLeft: Bool) {
        guard let oldButton = self.view.viewWithTag(tag) as? UIButton,
              let toolbar = oldButton.superview else {
            
            return
        }
        
        let constraints = oldButton.constraints
        let superviewConstraints = toolbar.constraints.filter { constraint in
            constraint.firstItem === oldButton || constraint.secondItem === oldButton
        }
        
        oldButton.removeFromSuperview()
        
        
        let newButton = UIButton(type: .system)
        newButton.translatesAutoresizingMaskIntoConstraints = false
        newButton.tag = tag
        
        setupButton(newButton, role: role, icon: icon, isLeft: isLeft)
        
        toolbar.addSubview(newButton)
        
        for constraint in superviewConstraints {
            let newConstraint: NSLayoutConstraint
            
            if constraint.firstItem === oldButton {
                newConstraint = NSLayoutConstraint(
                    item: newButton,
                    attribute: constraint.firstAttribute,
                    relatedBy: constraint.relation,
                    toItem: constraint.secondItem,
                    attribute: constraint.secondAttribute,
                    multiplier: constraint.multiplier,
                    constant: constraint.constant
                )
            } else {
                newConstraint = NSLayoutConstraint(
                    item: constraint.firstItem as Any,
                    attribute: constraint.firstAttribute,
                    relatedBy: constraint.relation,
                    toItem: newButton,
                    attribute: constraint.secondAttribute,
                    multiplier: constraint.multiplier,
                    constant: constraint.constant
                )
            }
            
            newConstraint.priority = constraint.priority
            newConstraint.isActive = true
        }
        
        
    }
}
extension InAppBrowserViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        
        let urlString = url.absoluteString
        let currentTime = Date().timeIntervalSince1970

        if webView == popupWebView {
            if urlString == "about:blank" || urlString.isEmpty {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)

            let mainHost = self.webView.url?.host?.lowercased()
            let popupHost = url.host?.lowercased()
            if checkSameDomain(currentHost: mainHost, newHost: popupHost) {
                self.webView.load(URLRequest(url: url))
            } else {
                isMovingToExternalApp = true
                lastExternalAppTime = currentTime
                pendingExternalURL = urlString
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.destroyPopupWebView()
            }
            return
        }

        if navigationAction.navigationType == .backForward {
            isNavigatingBack = true
            
            decisionHandler(.allow)
            return
        }
        
        let timeSinceLastNavigation = currentTime - lastNavigationTime
        let isInitialLoad = webView.url == nil || webView.url?.absoluteString == "about:blank"
        let isReload = navigationAction.navigationType == .reload
        let isFormSubmission = navigationAction.navigationType == .formSubmitted
        let isOther = navigationAction.navigationType == .other
        
        let shouldNotBlock = isInitialLoad ||
                            isNavigatingBack ||
                            isReload ||
                            isFormSubmission ||
                            isOther ||
                            timeSinceLastNavigation > 0.5
        
        if !shouldNotBlock && timeSinceLastNavigation < 0.5 {
            
            decisionHandler(.cancel)
            return
        }
        
        if !isInitialLoad && !isNavigatingBack {
            lastNavigationTime = currentTime
        }
        
        isNavigatingBack = false
        
        if currentTime - lastExternalAppTime < 2.0 && urlString == pendingExternalURL {
            
            decisionHandler(.cancel)
            pendingExternalURL = nil
            return
        }
        
        if urlString.hasPrefix("about:") || urlString.hasPrefix("javascript:") || urlString.hasPrefix("data:") {
            
            decisionHandler(.allow)
            return
        }
        
        if url.scheme == "coupang" || urlString.contains("coupang://") {
            
            handleExternalApp(url: url, appName: "쿠팡", appStoreURL: "https://apps.apple.com/app/id454434967")
            decisionHandler(.cancel)
            return
        }
        
        if url.scheme == "kakaolink" || url.scheme == "kakaotalk" || urlString.contains("kakaolink://") || urlString.contains("kakaotalk://") {
            
            handleExternalApp(url: url, appName: "카카오톡", appStoreURL: "https://apps.apple.com/app/id362057947")
            decisionHandler(.cancel)
            return
        }
        
        if urlString.contains("apps.apple.com") || urlString.contains("itunes.apple.com") {
            
            isMovingToExternalApp = true
            lastExternalAppTime = currentTime
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        
        if let scheme = url.scheme, !["http", "https", "about", "data", "javascript"].contains(scheme) {
            
            handleExternalApp(url: url, appName: scheme, appStoreURL: nil)
            decisionHandler(.cancel)
            return
        }
        
        let newRootDomain = getRootDomain(from: urlString)
        let isSameDomain = (newRootDomain == initialDomain)
        if isSameDomain {
            decisionHandler(.allow)
            return
        }
        
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMainFrame {
            
            decisionHandler(.allow)
            return
        }
        
        let adDomains = [
            "googleads.g.doubleclick.net",
            "googlesyndication.com",
            "googleadservices.com",
            "adsystem.google.com",
            "doubleclick.net",
            "google.com/aclk",
            "googletagmanager.com",
            "facebook.com/tr",
            "outbrain.com",
            "taboola.com",
            "adsense.google.com"
        ]
        
        let isAdDomain = adDomains.contains { domain in
            urlString.contains(domain)
        }
        
        if navigationAction.navigationType == .linkActivated && isAdDomain {
            
            
            isMovingToExternalApp = true
            lastExternalAppTime = currentTime
            pendingExternalURL = urlString
            
            UIApplication.shared.open(url, options: [:]) { success in
                
            }
            
            decisionHandler(.cancel)
            return
        }
        
        if navigationAction.navigationType == .linkActivated {

            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func setAdLoadTimeoutMs(_ ms: Int) {
        let minTimeout = max(ms, 1000)
        self.adLoadTimeoutInterval = TimeInterval(minTimeout) / 1000.0
        updateJavaScriptTimeoutValues()
    }

    func getAdLoadTimeoutMs() -> Int {
        let result = Int(self.adLoadTimeoutInterval * 1000)
        return result
    }

    func setPreloadTimeoutMs(_ timeoutMs: Int) {
        let minTimeout = max(timeoutMs, 1000)
        self.preloadTimeoutMs = minTimeout
        updateJavaScriptTimeoutValues()
    }

    func getPreloadTimeoutMs() -> Int {
        return self.preloadTimeoutMs
    }
    private func updateJavaScriptTimeoutValues() {
            let currentAdLoadMs = getAdLoadTimeoutMs()
            let currentPreloadMs = getPreloadTimeoutMs()
            
            
            let script = """
            (function() {
                
                window._swiftAdLoadTimeoutMs = \(currentAdLoadMs);
                window._swiftPreloadTimeoutMs = \(currentPreloadMs);
                
                return true;
            })();
            """
            
            webView.evaluateJavaScriptSafely(script) { (result, error) in
                if let error = error {
                } else {
                }
            }
        }
    func getPreloadTimeoutSeconds() -> Int {
        let result = self.preloadTimeoutMs / 1000
        return result
    }
    
    func setLoadingCoverEnabled(_ enabled: Bool) {
        self.isLoadingCoverEnabled = enabled
        if !enabled && !loadingCover.isHidden {
            hideLoadingCover()
        }
    }

    func isLoadingCoverEnabledFunc() -> Bool {
        return isLoadingCoverEnabled
    }

    func isLoadingCoverVisible() -> Bool {
        return !loadingCover.isHidden
    }
    
    private func checkSameDomain(currentHost: String?, newHost: String?) -> Bool {
        guard let current = currentHost, let new = newHost else {
            return false
        }

        if current == new {
            return true
        }

        return registrableDomain(of: current) == registrableDomain(of: new)
    }

    private func registrableDomain(of host: String) -> String {
        let twoLevelSuffixes: Set<String> = [
            "co.kr", "or.kr", "ne.kr", "re.kr", "pe.kr", "go.kr", "ac.kr",
            "hs.kr", "ms.kr", "es.kr", "sc.kr", "kg.kr",
            "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
            "co.uk", "org.uk", "ac.uk", "gov.uk",
            "com.au", "net.au", "org.au",
            "com.cn", "net.cn", "org.cn",
            "com.tw", "com.hk", "com.sg", "com.br", "com.mx",
            "co.in", "co.id", "co.th", "com.vn"
        ]

        let parts = host.components(separatedBy: ".")
        guard parts.count >= 2 else { return host }

        let lastTwo = parts.suffix(2).joined(separator: ".")
        if twoLevelSuffixes.contains(lastTwo), parts.count >= 3 {
            return parts.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }
    private func handleExternalApp(url: URL, appName: String, appStoreURL: String?) {
        isMovingToExternalApp = true
        lastExternalAppTime = Date().timeIntervalSince1970
        
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:]) { success in
                
                if !success && appStoreURL != nil {
                    DispatchQueue.main.async {
                        self.showAppInstallAlert(appName: appName, appStoreURL: appStoreURL!)
                    }
                }
            }
        } else if let storeURL = appStoreURL {
            showAppInstallAlert(appName: appName, appStoreURL: storeURL)
        }
    }
        
    private func showAppInstallAlert(appName: String, appStoreURL: String) {
        let alert = UIAlertController(
            title: "\(appName) 앱이 필요합니다",
            message: "\(appName) 앱을 설치하시겠습니까?",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "설치", style: .default) { _ in
            if let url = URL(string: appStoreURL) {
                UIApplication.shared.open(url)
            }
        })
        
        alert.addAction(UIAlertAction(title: "취소", style: .cancel))
        
        present(alert, animated: true)
    }
        
        
    private func openCoupangAppStore() {
        let coupangAppStoreURL = URL(string: "https://apps.apple.com/app/id454434967")!
        UIApplication.shared.open(coupangAppStoreURL, options: [:], completionHandler: nil)
    }
    private func openKakaoAppStore() {
        let kakaoAppStoreURL = URL(string: "https://apps.apple.com/app/id362057947")!
        UIApplication.shared.open(kakaoAppStoreURL, options: [:], completionHandler: nil)
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if isLoadingCoverEnabled{
            showLoadingCover()
        }
    }
    
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        hideLoadingCover()
        
        
        if isNavigatingBack {
            
            isNavigatingBack = false
            closeApp()
        }
    }
    private func checkInitialATTStatus() {
        sendInitialATTStatus()
    }
    private func sendInitialATTStatus() {
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if #available(iOS 14.5, *) {
                let currentStatus = ATTrackingManager.trackingAuthorizationStatus
                
                self.notifyWebWithATTStatusAndAdId(status: currentStatus)
            } else {
                let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                
                self.notifyWebWithATTStatusAndAdId(adId: adId, statusString: "authorized", statusCode: 3)
            }
        }
    }
    
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        
        let requestURL = navigationAction.request.url
        let requestURLString = requestURL?.absoluteString ?? ""
        
        if requestURL == nil || requestURLString.isEmpty || requestURLString.hasPrefix("about:") {
            return makePopupWebView(with: configuration)
        }

        guard let url = requestURL else { return nil }
        let urlString = requestURLString

        if urlString.hasPrefix("javascript:") {
            return nil
        }

        let currentHost = webView.url?.host?.lowercased()
        let newHost = url.host?.lowercased()
        
        let isSameDomain = checkSameDomain(currentHost: currentHost, newHost: newHost)
        
        if isSameDomain {
            
            if !navigationHistory.contains(urlString) {
                navigationHistory.append(urlString)
            }
            
            DispatchQueue.main.async {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
        
        isMovingToExternalApp = true
        lastExternalAppTime = Date().timeIntervalSince1970
        pendingExternalURL = urlString
        
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        return nil
    }


    private func makePopupWebView(with configuration: WKWebViewConfiguration) -> WKWebView {
        destroyPopupWebView()

        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.isHidden = true
        popup.navigationDelegate = self
        popup.uiDelegate = self
        view.addSubview(popup)
        popupWebView = popup

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak popup] in
            guard let self = self, let popup = popup, popup == self.popupWebView else { return }
            self.destroyPopupWebView()
        }
        return popup
    }

    private func destroyPopupWebView() {
        popupWebView?.stopLoading()
        popupWebView?.removeFromSuperview()
        popupWebView = nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView == popupWebView {
            destroyPopupWebView()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        hideLoadingCover()

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled || nsError.code == 102 {
            return
        }

        if let urlString = config.url, let optimizedURL = URL(string: optimizeURL(urlString)) {
            let request = URLRequest(url: optimizedURL)
            webView.load(request)
        }
    }
    
    private func injectKakaoSupportScript() {
        let kakaoScript = """
        (function() {
            if (typeof Kakao !== 'undefined') {
                const originalSend = Kakao.Share.sendDefault;
                Kakao.Share.sendDefault = function(options) {
                    try {
                        return originalSend.call(this, options);
                    } catch(e) {
                        const kakaoLink = 'kakaolink://send?' + encodeURIComponent(JSON.stringify(options));
                        window.location.href = kakaoLink;
                    }
                };
                
            }
            
            window.checkKakaoTalk = function() {
                return new Promise((resolve) => {
                    const iframe = document.createElement('iframe');
                    iframe.style.display = 'none';
                    iframe.src = 'kakaolink://';
                    document.body.appendChild(iframe);
                    
                    setTimeout(() => {
                        document.body.removeChild(iframe);
                        resolve(false);
                    }, 1000);
                    
                    setTimeout(() => {
                        resolve(true); 
                    }, 100);
                });
            };
        })();
        """
        
        webView.evaluateJavaScript(kakaoScript, completionHandler: nil)
    }
    
    
    func requestRewardedAd(adUnit: String, callbackFunction: String) {
        isUsingUnifiedCallback = true
        currentCallbackType = "unified"
        if isLoadingAd {
            executeUnifiedCallback(callbackFunction: callbackFunction, adType: "rewarded", status: "already_loading", adUnit: adUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1004, detailInfo: "Ad is already being loaded")
            return
        }
        
        if let currentAd = rewardedAd, currentAdUnitId == adUnit {
            resetAdState()
        } else if rewardedAd != nil && currentAdUnitId != adUnit {
            resetAdState()
        }
        
        if isAdAvailable(adUnit: adUnit) {
            showExistingRewardedAdUnified(adUnit: adUnit, callbackFunction: callbackFunction)
        } else {
            loadNewRewardedAdUnified(adUnit: adUnit, callbackFunction: callbackFunction)
        }
    }
    
    func requestInterstitialAd(adUnit: String, callbackFunction: String) {
        isUsingUnifiedCallback = true
        currentCallbackType = "unified"
        if isLoadingAd {
            executeUnifiedCallback(callbackFunction: callbackFunction, adType: "interstitial", status: "already_loading", adUnit: adUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1004, detailInfo: "Ad is already being loaded")
            return
        }
        
        if let currentAd = interstitialAd, currentAdUnitId == adUnit {
            resetAdState()
        } else if interstitialAd != nil && currentAdUnitId != adUnit {
            resetAdState()
        }
        
        if isAdAvailableInterstitial(adUnit: adUnit) {
            showExistingInterstitialAdUnified(callbackFunction: callbackFunction, adUnit: adUnit)
        } else {
            loadNewInterstitialAdUnified(adUnit: adUnit, callbackFunction: callbackFunction)
        }
    }
    private func isAdAvailable(adUnit: String) -> Bool {
            return rewardedAd != nil && adUnit == currentAdUnitId && !isLoadingAd
        }
        
        private func isAdAvailableInterstitial(adUnit: String) -> Bool {
            return interstitialAd != nil && adUnit == currentAdUnitId && !isLoadingAd
        }
        
        private func loadNewRewardedAdUnified(adUnit: String, callbackFunction: String) {
            if isLoadingCoverEnabled {
                showLoadingCover()
            }
            isLoadingAd = true
            isAdRequestTimeOut = false
            
            let currentAdUnit = adUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            
            adLoadTimeoutWorkItem?.cancel()
            
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                
                if self.isLoadingAd {
                    if self.isLoadingCoverEnabled {
                        self.hideLoadingCover()
                    }
                    self.isLoadingAd = false
                    self.isAdRequestTimeOut = true
                    
                    let timeoutInfo = self.createTimeoutErrorInfo(adType: "rewarded", adUnit: currentAdUnit)
                    self.executeUnifiedCallback(callbackFunction: callbackFunction, adType: "rewarded", status: "timeout", adUnit: currentAdUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1001, detailInfo: timeoutInfo)
                }
            }
            
            adLoadTimeoutWorkItem = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + adLoadTimeoutInterval, execute: timeoutWork)
            
            RewardedAd.load(with: currentAdUnit, request: makeAdRequest()) { [weak self] ad, error in
                guard let self = self else { return }
                
                self.adLoadTimeoutWorkItem?.cancel()
                
                if self.isAdRequestTimeOut {
                    return
                }
                
                if self.isLoadingCoverEnabled {
                    self.hideLoadingCover()
                }
                self.isLoadingAd = false
                
                if let error = error {
                    let detailedError = self.getDetailedLoadErrorCode(error: error)
                    let detailedErrorInfo = self.createDetailedLoadErrorInfo(error: error, adType: "rewarded", adUnit: currentAdUnit)
                    
                    self.executeUnifiedCallback(callbackFunction: callbackFunction, adType: "rewarded", status: detailedError, adUnit: currentAdUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: (error as NSError).code, detailInfo: detailedErrorInfo)
                    return
                }
                
                self.rewardedAd = ad
                self.currentAdUnitId = currentAdUnit
                self.lastCallAdUnit = currentAdUnit

                ad?.paidEventHandler = { [weak self] adValue in
                    self?.pendingRewardedAdValue = adValue
                }

                DispatchQueue.main.async {
                    ad?.adMetadataDelegate = self
                }

                self.showExistingRewardedAdUnified(adUnit: adUnit, callbackFunction: callbackFunction)
            }
        }
        
        private func createNoAdAvailableInfo(adType: String, adUnit: String) -> String {
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            return """
            {"timestamp":\(timestamp),"adType":"\(adType)","adUnit":"\(adUnit)","sdkVersion":"\(Self.SDK_VERSION)","gmaSdkVersion":"\(Self.GOOGLE_SDK_VERSION)","status":"ad_not_ready","errorCategory":"AD_NOT_READY","isRetryable":true,"message":"No ad available to show","targeting":\(targetingJSONString())}
            """
        }
        private func showExistingRewardedAdUnified(adUnit: String, callbackFunction: String) {
            let callbackAdUnit = adUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            isUsingUnifiedCallback = true
            
            
            guard let rewardedAd = rewardedAd else {
                let noAdInfo = createNoAdAvailableInfo(adType: "rewarded", adUnit: callbackAdUnit)
                executeUnifiedCallback(callbackFunction: callbackFunction, adType: "rewarded", status: "ad_not_ready", adUnit: callbackAdUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1006, detailInfo: noAdInfo)
                return
            }
            
            isRewardEarned = false
            pendingCallbackFunction = callbackFunction
            
            
            rewardedAd.fullScreenContentDelegate = self
            
            rewardedAd.present(from: self) { [weak self] in
                guard let self = self else { return }

                self.isRewardEarned = true

                var extra: [String: Any] = ["eventType": "REWARD_EARNED"]
                if let adValueDict = self.buildAdValueDict(self.pendingRewardedAdValue) {
                    extra["adValue"] = adValueDict
                }
                self.pendingRewardedAdValue = nil
                let rewardInfo = self.buildSuccessInfoJSON(adType: "rewarded", adUnit: callbackAdUnit,
                                                          status: "reward_earned",
                                                          responseInfo: self.rewardedAd?.responseInfo,
                                                          extra: extra)
                self.executeUnifiedCallback(
                    callbackFunction: callbackFunction,
                    adType: "rewarded",
                    status: "reward_earned",
                    adUnit: callbackAdUnit,
                    sdkVersion: InAppBrowserViewController.SDK_VERSION,
                    errorCode: 0,
                    detailInfo: rewardInfo
                )

            }
        }
        
        private func loadNewInterstitialAdUnified(adUnit: String, callbackFunction: String) {
            if isLoadingCoverEnabled {
                showLoadingCover()
            }
            isLoadingAd = true
            isAdRequestTimeOut = false
            
            let currentAdUnit = adUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            
            adLoadTimeoutWorkItem?.cancel()
            
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                
                if self.isLoadingAd {
                    if self.isLoadingCoverEnabled {
                        self.hideLoadingCover()
                    }
                    self.isLoadingAd = false
                    self.isAdRequestTimeOut = true
                    
                    let timeoutInfo = self.createTimeoutErrorInfo(adType: "interstitial", adUnit: currentAdUnit)
                    self.executeUnifiedCallback(callbackFunction: callbackFunction, adType: "interstitial", status: "timeout", adUnit: currentAdUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1001, detailInfo: timeoutInfo)
                }
            }
            
            adLoadTimeoutWorkItem = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + adLoadTimeoutInterval, execute: timeoutWork)
            
            AdManagerInterstitialAd.load(with: currentAdUnit, request: makeAdRequest()) { [weak self] ad, error in
                guard let self = self else { return }
                
                self.adLoadTimeoutWorkItem?.cancel()
                
                if self.isAdRequestTimeOut {
                    return
                }
                
                if self.isLoadingCoverEnabled {
                    self.hideLoadingCover()
                }
                self.isLoadingAd = false
                
                if let error = error {
                    let detailedError = self.getDetailedLoadErrorCode(error: error)
                    let detailedErrorInfo = self.createDetailedLoadErrorInfo(error: error, adType: "interstitial", adUnit: currentAdUnit)
                    
                    self.executeUnifiedCallback(callbackFunction: callbackFunction, adType: "interstitial", status: detailedError, adUnit: currentAdUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: (error as NSError).code, detailInfo: detailedErrorInfo)
                    return
                }
                
                self.interstitialAd = ad
                self.lastCallAdUnit = currentAdUnit

                ad?.paidEventHandler = { [weak self] adValue in
                    self?.pendingInterstitialAdValue = adValue
                }

                self.showExistingInterstitialAdUnified(callbackFunction: callbackFunction, adUnit: currentAdUnit)
            }
        }
        
        private func showExistingInterstitialAdUnified(callbackFunction: String, adUnit: String) {
            guard let interstitialAd = interstitialAd else {
                let noAdInfo = createNoAdAvailableInfo(adType: "interstitial", adUnit: adUnit)
                executeUnifiedCallback(callbackFunction: callbackFunction, adType: "interstitial", status: "ad_not_ready", adUnit: adUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1006, detailInfo: noAdInfo)
                return
            }
            
            interstitialAd.fullScreenContentDelegate = self
            interstitialAd.present(from: self)
            pendingCallbackFunction = callbackFunction
        }
        
        private func executeUnifiedCallback(callbackFunction: String, adType: String, status: String, adUnit: String, sdkVersion: String, errorCode: Int, detailInfo: String) {
            let script = "javascript:\(callbackFunction)(\"\(adType)\", \"\(status)\", \"\(adUnit)\", \"\(Self.SDK_VERSION)\", \(errorCode), \"\(escapeJavaScript(detailInfo))\");"
            webView.evaluateJavaScriptSafely(script)
        }
    public func syncCookiesToDisk() {
            syncCookiesToHTTPCookieStorage()
        }
    private func updateBannerVisibilityInJS() {
        let script = "window._swiftBannerVisible = \(isBannerVisible);"
        webView.evaluateJavaScriptSafely(script)
    }
}

extension InAppBrowserViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "iOSInterface":
            if let type = body["type"] as? String {
                switch type {
                case "loadBannerAd":
                    if let adUnit = body["adUnit"] as? String,
                       let callbackFunction = body["callbackFunction"] as? String {
                        loadBannerAd(adUnit, callbackFunction: callbackFunction)
                    }
                case "showBannerAd":
                    showBannerAd()
                    
                case "hideBannerAd":
                    hideBannerAd()
                    
                case "destroyBannerAd":
                    destroyBannerAd()
                    
                case "isBannerAdLoaded":
                    let isLoaded = isBannerAdLoaded()
                    let script = "if(window._bannerLoadedCallback) window._bannerLoadedCallback(\(isLoaded));"
                    webView.evaluateJavaScriptSafely(script)
                    
                case "setBannerHeight":
                    if let height = body["height"] as? Int {
                        setBannerHeight(height)
                    }
                    
                case "getBannerHeight":
                    let height = getBannerHeight()
                    let script = "if(window._bannerHeightCallback) window._bannerHeightCallback(\(height));"
                    webView.evaluateJavaScriptSafely(script)
                    
                case "setBannerEnabled":
                    if let enabled = body["enabled"] as? Bool {
                        setBannerEnabled(enabled)
                    }
                    
                case "updateBannerArea":
                    if let height = body["height"] as? Int,
                       let enabled = body["enabled"] as? Bool {
                        updateBannerArea(height, enabled: enabled)
                    }
                    
                case "isBannerEnabled":
                    let enabled = isBannerEnabled
                    let script = "if(window._bannerEnabledCallback) window._bannerEnabledCallback(\(enabled));"
                    webView.evaluateJavaScriptSafely(script)
                    
                case "showLoadingCover":
                    showLoadingCoverFromWeb()
                case "hideLoadingCover":
                    hideLoadingCoverFromWeb()
                case "close":
                    closeWebView()
                case "isPreloadedAdAvailable":
                    if let adType = body["adType"] as? String {
                        let isAvailable = isPreloadedAdAvailable(adType: adType)
                        
                        DispatchQueue.main.async {
                            let script = "if(window._preloadedAdCheckCallback) window._preloadedAdCheckCallback(\(isAvailable));"
                            self.webView.evaluateJavaScriptSafely(script)
                        }
                    }
                case "isBannerAdVisible":
                    let isVisible = isBannerAdVisible()
                    
                    let script = "window._bannerVisibleStatus = \(isVisible);"
                    webView.evaluateJavaScriptSafely(script)
                    
                    DispatchQueue.main.async {
                        let callbackScript = "if(window._bannerVisibleCallback) window._bannerVisibleCallback(\(isVisible));"
                        self.webView.evaluateJavaScriptSafely(callbackScript)
                    }
                case "clearPreloadedAd":
                    if let adType = body["adType"] as? String {
                        clearPreloadedAd(adType: adType)
                    }
                case "interstitial":
                    if let adUnit = body["adUnit"] as? String,
                       let callbackFunction = body["callbackFunction"] as? String {
                        showInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
                    }
                    
                case "rewarded_interstitial":
                    if let adUnit = body["adUnit"] as? String,
                       let callbackFunction = body["callbackFunction"] as? String {
                        showRewardedInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
                    }
                    
                    if let adUnit = body["adUnit"] as? String,
                       let callbackFunction = body["callbackFunction"] as? String,
                       let delayMs = body["delayMs"] as? Int,
                       body["autoShow"] as? Bool == true {
                        autoShowRewardedInterstitialAd(adUnit: adUnit, delayMs: delayMs, callbackFunction: callbackFunction)
                    }
                    
                case "reward":
                    if let adUnit = body["adUnit"] as? String,
                       let callbackFunction = body["callbackFunction"] as? String {
                        showRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
                    }
                case "requestAdIdConsent", "requestATTPermission":
                    if let callbackFunction = body["callbackFunction"] as? String {
                        requestATTPermission(callbackFunction: callbackFunction)
                    } else {
                    }
                    
                case "checkAdIdConsentStatus", "getATTStatus":
                    if let callbackFunction = body["callbackFunction"] as? String {
                        checkATTStatus(callbackFunction: callbackFunction)
                    } else {
                    }
                    
                case "getAdvertisingId":
                    if let callbackFunction = body["callbackFunction"] as? String {
                        getAdvertisingId(callbackFunction: callbackFunction)
                    } else {
                    }
                    
                case "openExternalURL":
                    if let urlString = body["url"] as? String,
                       let url = URL(string: urlString) {
                        
                        DispatchQueue.main.async {
                            UIApplication.shared.open(url, options: [:])
                        }
                    }
                case "setBackAction":
                    if let action = body["action"] as? String {
                        setBackActionFromWeb(action)
                    }
                    
                case "setBackConfirmMessage":
                    if let message = body["message"] as? String {
                        setBackConfirmMessageFromWeb(message)
                    }
                    
                case "setBackConfirmTimeout":
                    if let timeout = body["timeout"] as? Double {
                        setBackConfirmTimeoutFromWeb(timeout)
                    }
                case "triggerBackAction":
                    handleBackAction()
                case "requestRewardedAd":
                    if let adUnit = body["adUnit"] as? String,
                       let callbackFunction = body["callbackFunction"] as? String {
                        requestRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
                    }

                case "requestInterstitialAd":
                    if let adUnit = body["adUnit"] as? String,
                       let callbackFunction = body["callbackFunction"] as? String {
                        requestInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
                    }

                case "preloadRewardedAd":
                    if let adUnit = body["adUnit"] as? String,
                       let callbackFunction = body["callbackFunction"] as? String {
                        preloadRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
                    }
                case "preloadInterstitialAd":
                    if let adUnit = body["adUnit"] as? String,
                       let callbackFunction = body["callbackFunction"] as? String {
                        preloadInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
                    }

                case "showPreloadedRewardedAd":
                    if let callbackFunction = body["callbackFunction"] as? String {
                        showPreloadedRewardedAd(callbackFunction: callbackFunction)
                    }
                case "showPreloadedInterstitialAd":
                    if let callbackFunction = body["callbackFunction"] as? String {
                        showPreloadedInterstitialAd(callbackFunction: callbackFunction)
                    }

                case "setPreloadTimeoutMs":
                    if let timeoutMs = body["timeoutMs"] as? Int {
                        setPreloadTimeoutMs(timeoutMs)
                    }

                case "setAdLoadTimeoutMs":
                    if let timeoutMs = body["timeoutMs"] as? Int {
                        setAdLoadTimeoutMs(timeoutMs)
                    }
                case "setLoadingCoverEnabled":
                    if let enabled = body["enabled"] as? Bool {
                        setLoadingCoverEnabled(enabled)
                    }

                case "syncCookies":
                    syncCookiesToDisk()

                case "setAdTargeting":
                    
                    if let targeting = body["targeting"] as? [String: String] {
                        if let jsonData = try? JSONSerialization.data(withJSONObject: targeting),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            setAdTargeting(jsonString: jsonString)
                        }
                    }

                case "updateAdTargeting":
                    
                    if let key = body["key"] as? String,
                       let value = body["value"] as? String {
                        updateAdTargeting(key: key, value: value)
                    }

                case "clearAdTargeting":
                    clearAdTargeting()

                case "getAdTargeting":
                    
                    if let callbackFunction = body["callbackFunction"] as? String {
                        if let jsonData = try? JSONSerialization.data(withJSONObject: customAdTargeting),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            let script = "if(typeof \(callbackFunction) === 'function') \(callbackFunction)(\(jsonString));"
                            webView.evaluateJavaScriptSafely(script)
                        }
                    }


                default:
                    break
                }
            } else {
                if let adUnit = body["adUnit"] as? String,
                   let callbackFunction = body["callbackFunction"] as? String {
                    showRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
                }
                
                if let adUnit = body["adUnit"] as? String,
                   let callbackFunction = body["callbackFunction"] as? String,
                   let delayMs = body["delayMs"] as? Int,
                   body["autoShow"] as? Bool == true {
                    autoShowRewardedInterstitialAd(adUnit: adUnit, delayMs: delayMs, callbackFunction: callbackFunction)
                }
            }
            
        default:
            break
        }
    }
}

extension InAppBrowserViewController {
    
    func setBackActionFromWeb(_ actionString: String) {
        switch actionString {
         case "exit", "close":
             currentBackAction = .exit
         case "confirm-exit":
             currentBackAction = .confirmExit
         case "history-back", "historyBack":
             currentBackAction = .historyBack
         case "ignore":
             currentBackAction = .ignore
         default:
             currentBackAction = .historyBack
         }
        
        
    }
    
    func setBackConfirmMessageFromWeb(_ message: String) {
        backConfirmMessage = message
    }
    
    func setBackConfirmTimeoutFromWeb(_ timeout: Double) {
        backConfirmTimeout = timeout
    }
}

extension InAppBrowserViewController {
    private var isShowingAlert: Bool {
        return presentedViewController is UIAlertController
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            
            guard !isShowingAlert,
                  let webView = self.webView,
                  webView == webView,
                  view.window != nil else {
                completionHandler()
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      !self.isShowingAlert,
                      self.view.window != nil else {
                    completionHandler()
                    return
                }
                
                let alertController = UIAlertController(
                    title: nil,
                    message: message,
                    preferredStyle: .alert
                )
                
                alertController.addAction(UIAlertAction(title: "확인", style: .default) { _ in
                    completionHandler()
                })
                
                self.present(alertController, animated: true) {
                    if alertController.presentingViewController == nil {
                        completionHandler()
                    }
                }
            }
        }
        
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            
            guard !isShowingAlert,
                  let webView = self.webView,
                  webView == webView,
                  view.window != nil else {
                completionHandler(false)
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      !self.isShowingAlert,
                      self.view.window != nil else {
                    completionHandler(false)
                    return
                }
                
                let alertController = UIAlertController(
                    title: nil,
                    message: message,
                    preferredStyle: .alert
                )
                
                alertController.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
                    completionHandler(false)
                })
                
                alertController.addAction(UIAlertAction(title: "확인", style: .default) { _ in
                    completionHandler(true)
                })
                
                self.present(alertController, animated: true) {
                    if alertController.presentingViewController == nil {
                        completionHandler(false)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            
            guard !isShowingAlert,
                  let webView = self.webView,
                  webView == webView,
                  view.window != nil else {
                completionHandler(defaultText)
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      !self.isShowingAlert,
                      self.view.window != nil else {
                    completionHandler(defaultText)
                    return
                }
                
                let alertController = UIAlertController(
                    title: nil,
                    message: prompt,
                    preferredStyle: .alert
                )
                
                alertController.addTextField { textField in
                    textField.text = defaultText
                }
                
                alertController.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
                    completionHandler(nil)
                })
                
                alertController.addAction(UIAlertAction(title: "확인", style: .default) { _ in
                    let text = alertController.textFields?.first?.text
                    completionHandler(text)
                })
                
                self.present(alertController, animated: true) {
                    if alertController.presentingViewController == nil {
                        completionHandler(defaultText)
                    }
                }
            }
        }
    func updateConfiguration(_ newConfig: InAppBrowserConfig) {
            self.config = newConfig
            
            self.currentBackAction = newConfig.backAction
            self.backConfirmMessage = newConfig.backConfirmMessage
            self.backConfirmTimeout = newConfig.backConfirmTimeout
            
        updateButtonRoles(leftRole: newConfig.leftButtonRole, rightRole: newConfig.rightButtonRole,leftIcon: newConfig.leftButtonIcon,rightIcon: newConfig.rightButtonIcon)
            
            
        }

    
    func makeAdRequest() -> AdManagerRequest {
        let request = AdManagerRequest()
        if !customAdTargeting.isEmpty {
            request.customTargeting = customAdTargeting
        }
        return request
    }

    private func targetingJSONString() -> String {
        if customAdTargeting.isEmpty { return "{}" }
        if let data = try? JSONSerialization.data(withJSONObject: customAdTargeting),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    func buildResponseInfoDict(_ responseInfo: ResponseInfo?) -> [String: Any] {
        guard let responseInfo = responseInfo else { return [:] }

        var dict: [String: Any] = [:]

        if let responseId = responseInfo.responseIdentifier {
            dict["responseId"] = responseId
        }

        let extras = responseInfo.extras
        if !extras.isEmpty {
            var extrasDict: [String: Any] = [:]
            if let creativeId = extras["creative_id"] { extrasDict["creative_id"] = creativeId }
            if let lineItemId = extras["line_item_id"] { extrasDict["line_item_id"] = lineItemId }
            for (key, val) in extras where key != "creative_id" && key != "line_item_id" {
                extrasDict[key] = JSONSerialization.isValidJSONObject(["k": val]) ? val : "\(val)"
            }
            if !extrasDict.isEmpty { dict["extrasDictionary"] = extrasDict }
        }

        if let loaded = responseInfo.loadedAdNetworkResponseInfo {
            var networkDict: [String: Any] = [:]
            networkDict["adNetworkClassName"] = loaded.adNetworkClassName
            if let sourceName = loaded.adSourceName         { networkDict["adSourceName"] = sourceName }
            if let sourceId   = loaded.adSourceID           { networkDict["adSourceID"] = sourceId }
            if let instName   = loaded.adSourceInstanceName { networkDict["adSourceInstanceName"] = instName }
            if let instId     = loaded.adSourceInstanceID   { networkDict["adSourceInstanceID"] = instId }
            networkDict["latencyMs"] = Int(loaded.latency * 1000)
            if !loaded.adUnitMapping.isEmpty {
                let safeMapping = loaded.adUnitMapping.compactMapValues { val -> Any? in
                    JSONSerialization.isValidJSONObject(["k": val]) ? val : "\(val)"
                }
                if !safeMapping.isEmpty { networkDict["adUnitMapping"] = safeMapping }
            }
            if let err = loaded.error {
                networkDict["error"] = ["code": (err as NSError).code, "message": err.localizedDescription]
            }
            dict["loadedAdNetwork"] = networkDict
        }

        let networkArray: [[String: Any]] = responseInfo.adNetworkInfoArray.map { net in
            var n: [String: Any] = [:]
            n["adNetworkClassName"] = net.adNetworkClassName
            if let sn  = net.adSourceName         { n["adSourceName"] = sn }
            if let si  = net.adSourceID           { n["adSourceID"] = si }
            if let in_ = net.adSourceInstanceName { n["adSourceInstanceName"] = in_ }
            if let ii  = net.adSourceInstanceID   { n["adSourceInstanceID"] = ii }
            n["latencyMs"] = Int(net.latency * 1000)
            if !net.adUnitMapping.isEmpty {
                let safeMapping = net.adUnitMapping.compactMapValues { val -> Any? in
                    JSONSerialization.isValidJSONObject(["k": val]) ? val : "\(val)"
                }
                if !safeMapping.isEmpty { n["adUnitMapping"] = safeMapping }
            }
            if let err = net.error {
                n["error"] = ["code": (err as NSError).code, "message": err.localizedDescription]
            }
            return n
        }
        if !networkArray.isEmpty {
            dict["adNetworkInfoArray"] = networkArray
        }

        return dict
    }

    private func buildAdValueDict(_ adValue: AdValue?) -> [String: Any]? {
        guard let adValue = adValue else { return nil }
        let valueMicros = NSDecimalNumber(decimal: adValue.value as Decimal).multiplying(byPowerOf10: 6).int64Value
        return [
            "valueMicros": valueMicros,
            "currencyCode": adValue.currencyCode,
            "precisionType": adValue.precision.rawValue
        ]
    }

    func buildSuccessInfoJSON(adType: String, adUnit: String, status: String,
                              responseInfo: ResponseInfo? = nil,
                              extra: [String: Any] = [:]) -> String {
        var dict: [String: Any] = [
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "adType": adType,
            "adUnit": adUnit,
            "sdkVersion": Self.SDK_VERSION,
            "gmaSdkVersion": Self.GOOGLE_SDK_VERSION,
            "status": status
        ]
        for (k, v) in extra { dict[k] = v }

        let riDict = buildResponseInfoDict(responseInfo)
        if !riDict.isEmpty { dict["responseInfo"] = riDict }
        if !customAdTargeting.isEmpty { dict["targeting"] = customAdTargeting }

        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let str  = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"timestamp\":\(dict["timestamp"]!),\"adType\":\"\(adType)\",\"adUnit\":\"\(adUnit)\",\"status\":\"\(status)\"}"
    }



    func setAdTargeting(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        customAdTargeting = dict
    }

    func updateAdTargeting(key: String, value: String) {
        customAdTargeting[key] = value
    }

    func clearAdTargeting() {
        customAdTargeting = [:]
    }

    func notifyAdMetadata(_ metadata: [String: Any], adType: String, callbackFunction: String) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: metadata),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        let escaped = jsonString.replacingOccurrences(of: "'", with: "\\'")
        let script = "if(typeof \(callbackFunction) === 'function') \(callbackFunction)('\(adType)', \(jsonString));"
        DispatchQueue.main.async {
            self.webView.evaluateJavaScriptSafely(script)
        }
    }


    func showRewardedAd(adUnit: String, callbackFunction: String) {
        isUsingUnifiedCallback = false
        currentCallbackType = "legacy"
        if isLoadingAd { return }
        
        if let currentAd = rewardedAd, currentAdUnitId == adUnit {
            showExistingRewardedAd(callbackFunction: callbackFunction)
        } else {
            loadNewRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
        }
    }
    
    func showInterstitialAd(adUnit: String, callbackFunction: String) {
        isUsingUnifiedCallback = false
        currentCallbackType = "legacy"
        if isLoadingAd { return }
        
        if let currentAd = interstitialAd, currentAdUnitId == adUnit {
            showExistingInterstitialAd(callbackFunction: callbackFunction)
        } else {
            loadNewInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
        }
    }
    
    func showRewardedInterstitialAd(adUnit: String, callbackFunction: String) {
        if isLoadingAd { return }
        
        self.pendingCallbackFunction = callbackFunction
        if let currentAd = rewardedInterstitialAd, currentAdUnitId == adUnit {
            showExistingRewardedInterstitialAd(callbackFunction: callbackFunction)
        } else {
            loadNewRewardedInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
        }
    }
    
    private func showExistingRewardedInterstitialAd(callbackFunction: String) {
        guard let rewardedInterstitialAd = rewardedInterstitialAd else {
            handleAdNotAvailable(callbackFunction: callbackFunction, type: "rewarded_interstitial", adUnit: currentAdUnitId, adUnitIndex: adUnitIndexCall)
            adUnitIndexCall = 0
            adUnitIndexDisplay = 1
            return
        }
        
        rewardedInterstitialAd.fullScreenContentDelegate = self
        
        rewardedInterstitialAd.present(from: self) { [weak self] in
            self?.isRewardEarned = true
            self?.pendingCallbackFunction = callbackFunction
        }
    }
    
    func autoShowRewardedInterstitialAd(adUnit: String, delayMs: Int, callbackFunction: String) {
        if isLoadingAd { return }
        
        if let currentAd = rewardedInterstitialAd, currentAdUnitId == adUnit {
            let delay = TimeInterval(delayMs) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.showExistingRewardedInterstitialAd(callbackFunction: callbackFunction)
            }
        } else {
            loadAutoShowRewardedInterstitialAd(adUnit: adUnit, delayMs: delayMs, callbackFunction: callbackFunction)
        }
    }
    
    private func getNextAdUnitFromList(adUnits: [String], currentIndex: Int) -> String? {
        if currentIndex + 1 < adUnits.count {
            return adUnits[currentIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    
    private func createDismissedWithRewardInfo(adType: String, adUnit: String, responseInfo: ResponseInfo? = nil, adValue: AdValue? = nil) -> String {
        var extra: [String: Any] = ["eventType": "AD_DISMISSED_WITH_REWARD",
                                    "message": "Ad was dismissed after reward was earned"]
        if let adValueDict = buildAdValueDict(adValue) { extra["adValue"] = adValueDict }
        return buildSuccessInfoJSON(adType: adType, adUnit: adUnit, status: "dismissed_with_reward",
                                   responseInfo: responseInfo, extra: extra)
    }
    private func loadNewRewardedAd(adUnit: String, callbackFunction: String) {
        if isLoadingCoverEnabled {
            showLoadingCover()
        }
        isLoadingAd = true
        isAdRequestTimeOut = false
        
        adLoadTimeoutWorkItem?.cancel()
        
        let adUnits = adUnit.components(separatedBy: ";")
        let currentAdUnit = adUnits[adUnitIndexCall].trimmingCharacters(in: .whitespacesAndNewlines)
        
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            if self.isLoadingAd {
                self.isAdRequestTimeOut = true
                self.hideLoadingCover()
                self.isLoadingAd = false
                        
                self.handleAdLoadError(callbackFunction: callbackFunction, type: "reward", adUnit: currentAdUnit, adUnitIndex: self.adUnitIndexDisplay)
                
                self.adUnitIndexCall = 0
                self.adUnitIndexDisplay = 1
            }
        }
        
        adLoadTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + adLoadTimeoutInterval, execute: timeoutWork)
        
        RewardedAd.load(with: currentAdUnit, request: makeAdRequest()) { [weak self] ad, error in
            guard let self = self else { return }
            
            self.adLoadTimeoutWorkItem?.cancel()
            self.adLoadTimeoutWorkItem = nil
            
            self.hideLoadingCover()
            self.isLoadingAd = false
            
            if self.isAdRequestTimeOut {
                return
            }
            
            if error != nil {
                var currentIndex = 0
                for i in 0..<adUnits.count {
                    if adUnits[i].trimmingCharacters(in: .whitespacesAndNewlines) == currentAdUnit {
                        currentIndex = i
                        self.adUnitIndexDisplay += 1
                        self.adUnitIndexCall += 1
                        break
                    }
                }
                
                let nextAdUnit = self.getNextAdUnitFromList(adUnits: adUnits, currentIndex: currentIndex)
                
                if nextAdUnit != nil {
                    self.loadNewRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
                } else {
                    self.handleAdLoadError(callbackFunction: callbackFunction, type: "reward", adUnit: currentAdUnit, adUnitIndex: self.adUnitIndexDisplay)
                    
                    self.adUnitIndexCall = 0
                    self.adUnitIndexDisplay = 1
                }
                return
            }
            
            self.rewardedAd = ad
            self.currentAdUnitId = currentAdUnit
            DispatchQueue.main.async {
                ad?.adMetadataDelegate = self
            }
            self.showExistingRewardedAd(callbackFunction: callbackFunction)
        }
    }
    
    private func loadNewInterstitialAd(adUnit: String, callbackFunction: String) {
        if isLoadingCoverEnabled {
            showLoadingCover()
        }
        isLoadingAd = true
        isAdRequestTimeOut = false
        
        adLoadTimeoutWorkItem?.cancel()
        
        let adUnits = adUnit.components(separatedBy: ";")
        let currentAdUnit = adUnits[adUnitIndexCall].trimmingCharacters(in: .whitespacesAndNewlines)
        
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            if self.isLoadingAd {
                self.isAdRequestTimeOut = true
                self.hideLoadingCover()
                self.isLoadingAd = false
            
                self.handleAdLoadError(callbackFunction: callbackFunction, type: "interstitial", adUnit: currentAdUnit, adUnitIndex: self.adUnitIndexDisplay)
                
                self.adUnitIndexCall = 0
                self.adUnitIndexDisplay = 1
            }
        }
        
        adLoadTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + adLoadTimeoutInterval, execute: timeoutWork)
        
        AdManagerInterstitialAd.load(with: currentAdUnit, request: makeAdRequest()) { [weak self] ad, error in
            guard let self = self else { return }
            
            self.adLoadTimeoutWorkItem?.cancel()
            self.adLoadTimeoutWorkItem = nil
            
            self.hideLoadingCover()
            self.isLoadingAd = false
            
            if self.isAdRequestTimeOut {
                return
            }
            
            if error != nil {
                var currentIndex = 0
                for i in 0..<adUnits.count {
                    if adUnits[i].trimmingCharacters(in: .whitespacesAndNewlines) == currentAdUnit {
                        currentIndex = i
                        self.adUnitIndexDisplay += 1
                        self.adUnitIndexCall += 1
                        break
                    }
                }
                
                let nextAdUnit = self.getNextAdUnitFromList(adUnits: adUnits, currentIndex: currentIndex)
                
                if nextAdUnit != nil {
                    self.loadNewInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
                } else {
                    self.handleAdLoadError(callbackFunction: callbackFunction, type: "interstitial", adUnit: currentAdUnit, adUnitIndex: self.adUnitIndexDisplay)
                    
                    self.adUnitIndexCall = 0
                    self.adUnitIndexDisplay = 1
                }
                return
            }
            
            self.interstitialAd = ad
            self.currentAdUnitId = currentAdUnit
            self.showExistingInterstitialAd(callbackFunction: callbackFunction)
        }
    }
    
    private func loadNewRewardedInterstitialAd(adUnit: String, callbackFunction: String) {
        if isLoadingCoverEnabled{
            showLoadingCover()
        }
        isLoadingAd = true
        isAdRequestTimeOut = false
        
        adLoadTimeoutWorkItem?.cancel()
        
        let adUnits = adUnit.components(separatedBy: ";")
        let currentAdUnit = adUnits[adUnitIndexCall].trimmingCharacters(in: .whitespacesAndNewlines)
        
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            if self.isLoadingAd {
                self.isAdRequestTimeOut = true
                self.hideLoadingCover()
                self.isLoadingAd = false
            
                self.handleAdLoadError(callbackFunction: callbackFunction, type: "rewarded_interstitial", adUnit: currentAdUnit, adUnitIndex: self.adUnitIndexDisplay)
                
                self.adUnitIndexCall = 0
                self.adUnitIndexDisplay = 1
            }
        }
        
        adLoadTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + adLoadTimeoutInterval, execute: timeoutWork)
        
        RewardedInterstitialAd.load(with: currentAdUnit, request: makeAdRequest()) { [weak self] ad, error in
            guard let self = self else { return }
            
            self.adLoadTimeoutWorkItem?.cancel()
            self.adLoadTimeoutWorkItem = nil
            
            self.hideLoadingCover()
            self.isLoadingAd = false
            
            if self.isAdRequestTimeOut {
                return
            }
            
            if error != nil {
                var currentIndex = 0
                for i in 0..<adUnits.count {
                    if adUnits[i].trimmingCharacters(in: .whitespacesAndNewlines) == currentAdUnit {
                        currentIndex = i
                        self.adUnitIndexDisplay += 1
                        self.adUnitIndexCall += 1
                        break
                    }
                }
                
                let nextAdUnit = self.getNextAdUnitFromList(adUnits: adUnits, currentIndex: currentIndex)
                
                if nextAdUnit != nil {
                    self.loadNewRewardedInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
                } else {
                    self.handleAdLoadError(callbackFunction: callbackFunction, type: "rewarded_interstitial", adUnit: currentAdUnit, adUnitIndex: self.adUnitIndexDisplay)
                    
                    self.adUnitIndexCall = 0
                    self.adUnitIndexDisplay = 1
                }
                return
            }
            
            self.rewardedInterstitialAd = ad
            self.currentAdUnitId = currentAdUnit
            self.showExistingRewardedInterstitialAd(callbackFunction: callbackFunction)
        }
    }
        
    private func showExistingInterstitialAd(callbackFunction: String) {
        guard let interstitialAd = interstitialAd else {
            handleAdNotAvailable(callbackFunction: callbackFunction, type: "interstitial", adUnit: currentAdUnitId, adUnitIndex: adUnitIndexCall)
            
            adUnitIndexCall = 0
            adUnitIndexDisplay = 1
            return
        }
        
        interstitialAd.fullScreenContentDelegate = self
        interstitialAd.present(from: self)
        pendingCallbackFunction = callbackFunction
    }
        
    private func loadAutoShowRewardedInterstitialAd(adUnit: String, delayMs: Int, callbackFunction: String) {
        
        if isLoadingCoverEnabled{
            showLoadingCover()
        }
        isLoadingAd = true
        isAdRequestTimeOut = false
        
        adLoadTimer?.invalidate()
        
        let adUnits = adUnit.components(separatedBy: ";")
        let currentAdUnit = adUnits[adUnitIndexCall].trimmingCharacters(in: .whitespacesAndNewlines)
        let timer = Timer(timeInterval: adLoadTimeoutInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                if self.isLoadingAd {
                    self.isAdRequestTimeOut = true
                    self.hideLoadingCover()
                    self.isLoadingAd = false
                    
                    self.handleAdLoadError(callbackFunction: callbackFunction, type: "rewarded_interstitial", adUnit: currentAdUnit, adUnitIndex: self.adUnitIndexCall)
                    
                    self.adUnitIndexCall = 0
                    self.adUnitIndexDisplay = 1
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        adLoadTimer = timer
        
        RewardedInterstitialAd.load(with: currentAdUnit, request: makeAdRequest()) { [weak self] ad, error in
            guard let self = self else { return }
            
            self.hideLoadingCover()
            self.isLoadingAd = false
            
            if error != nil {
                var currentIndex = 0
                for i in 0..<adUnits.count {
                    if adUnits[i].trimmingCharacters(in: .whitespacesAndNewlines) == currentAdUnit {
                        currentIndex = i
                        self.adUnitIndexDisplay += 1
                        self.adUnitIndexCall += 1
                        break
                    }
                }
                
                let nextAdUnit = self.getNextAdUnitFromList(adUnits: adUnits, currentIndex: currentIndex)
                
                if nextAdUnit != nil {
                    self.loadNewRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
                } else {
                    self.handleAdLoadError(callbackFunction: callbackFunction, type: "rewarded_interstitial", adUnit: currentAdUnit, adUnitIndex: self.adUnitIndexDisplay)
                    
                    self.adUnitIndexCall = 0
                    self.adUnitIndexDisplay = 1
                }
                return
            }
            
            self.rewardedInterstitialAd = ad
            self.currentAdUnitId = currentAdUnit
            
            let delay = TimeInterval(delayMs) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.showExistingRewardedInterstitialAd(callbackFunction: callbackFunction)
            }
            
            self.adUnitIndexCall = 0
            self.adUnitIndexDisplay = 1
        }
    }
        
    private func showExistingRewardedAd(callbackFunction: String) {
        guard let rewardedAd = rewardedAd else {
            handleAdNotAvailable(callbackFunction: callbackFunction, type: "rewarded", adUnit: currentAdUnitId, adUnitIndex: adUnitIndexCall)
            
            adUnitIndexCall = 0
            adUnitIndexDisplay = 1
            return
        }
        
        rewardedAd.fullScreenContentDelegate = self
        
        self.pendingCallbackFunction = callbackFunction
        rewardedAd.present(from: self) { [weak self] in
            self?.isRewardEarned = true
        }
    }
        
    private func handleAdNotAvailable(callbackFunction: String, type: String, adUnit: String, adUnitIndex: Int) {
        webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\"\(type)\", \"failed\", \"\(adUnit)\", \(adUnitIndex));")
    }
        
    private func handleAdLoadError(callbackFunction: String, type: String, adUnit: String, adUnitIndex: Int) {
        webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\"\(type)\", \"failed\", \"\(adUnit)\", \(adUnitIndex));")
    }
        
    private func resetAdState() {
        interstitialAd = nil
        rewardedAd = nil
        rewardedInterstitialAd = nil
        currentAdUnitId = ""
        isLoadingAd = false
    }
}
extension InAppBrowserViewController {
    private func createSimpleCancelInfo(adType: String, adUnit: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        return """
        {"timestamp":\(timestamp),"adType":"\(adType)","adUnit":"\(adUnit)","sdkVersion":"\(Self.SDK_VERSION)","gmaSdkVersion":"\(Self.GOOGLE_SDK_VERSION)","status":"cancelled","eventType":"AD_CANCELLED","message":"User cancelled the ad","targeting":\(targetingJSONString())}
        """
    }
    
    private func createDetailedPresentErrorInfo(error: Error, adType: String, adUnit: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let errorMessage = error.localizedDescription.replacingOccurrences(of: "\"", with: "\\\"")
        let errorCode = (error as NSError).code

        return """
        {"timestamp":\(timestamp),"adType":"\(adType)","adUnit":"\(adUnit)","sdkVersion":"\(Self.SDK_VERSION)","gmaSdkVersion":"\(Self.GOOGLE_SDK_VERSION)","errorType":"PRESENT_ERROR","errorCode":\(errorCode),"message":"\(errorMessage)","errorCategory":"PRESENTATION_FAILED","isRetryable":false,"targeting":\(targetingJSONString())}
        """
    }
}
extension InAppBrowserViewController {
    @available(iOS 14.5, *)
    private func notifyWebWithATTStatusAndAdId(status: ATTrackingManager.AuthorizationStatus) {
        var statusString = ""
        var statusCode = 0
        var adId = ""
        
        switch status {
        case .authorized:
            statusString = "authorized"
            statusCode = 3
            adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        case .denied:
            statusString = "denied"
            statusCode = 2
            adId = ""
        case .restricted:
            statusString = "restricted"
            statusCode = 1
            adId = ""
        case .notDetermined:
            statusString = "notDetermined"
            statusCode = 0
            adId = ""
        @unknown default:
            statusString = "unknown"
            statusCode = -1
            adId = ""
        }
        
        notifyWebWithATTStatusAndAdId(adId: adId, statusString: statusString, statusCode: statusCode)
    }
    
    private func notifyWebWithATTStatusAndAdId(adId: String, statusString: String, statusCode: Int) {
        let script = """
        (function() {
            try {
                
                if (typeof window.onReceiveAdId === 'function') {
                    window.onReceiveAdId('\(adId)', '\(statusString)', \(statusCode));
                } else {
                    
                    window._pendingAdIdData = {
                        adId: '\(adId)',
                        status: '\(statusString)',
                        statusCode: \(statusCode)
                    };
                }
                
                window.currentAdId = '\(adId)';
                window.currentATTStatus = '\(statusString)';
                window.currentATTStatusCode = \(statusCode);
                
                const event = new CustomEvent('adIdAndATTStatusReceived', { 
                    detail: {
                        adId: '\(adId)',
                        status: '\(statusString)',
                        statusCode: \(statusCode)
                    }
                });
                window.dispatchEvent(event);
                
                const callbackPatterns = [
                    'handleAdId',        
                    'processAdId',
                    'adIdCallback'
                ];
                
                callbackPatterns.forEach(pattern => {
                    if (typeof window[pattern] === 'function') {
                        try {
                            window[pattern]('\(adId)', '\(statusString)', \(statusCode));
                        } catch(e) {
                        }
                    }
                });
                
                return true;
            } catch(e) {
                return false;
            }
        })();
        """
        
        
        webView.evaluateJavaScript(script) { (result, error) in
            if let error = error {
            } else if let success = result as? Bool, success {
            } else {
            }
        }
    }
        @available(iOS 14.5, *)
        private func createATTResultJson(status: ATTrackingManager.AuthorizationStatus) -> String {
            var statusString = ""
            var statusCode = 0
            var adId = ""
            
            switch status {
            case .authorized:
                statusString = "authorized"
                statusCode = 3
                adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            case .denied:
                statusString = "denied"
                statusCode = 2
            case .restricted:
                statusString = "restricted"
                statusCode = 1
            case .notDetermined:
                statusString = "notDetermined"
                statusCode = 0
            @unknown default:
                statusString = "unknown"
                statusCode = -1
            }
            
            return """
            {
                "status": "\(statusString)",
                "statusCode": \(statusCode),
                "adId": "\(adId)"
            }
            """
        }
        
    func notifyWebWithAdId(_ adId: String) {
        
        if #available(iOS 14.5, *) {
            let currentStatus = ATTrackingManager.trackingAuthorizationStatus
            notifyWebWithATTStatusAndAdId(status: currentStatus)
        } else {
            notifyWebWithATTStatusAndAdId(adId: adId, statusString: "authorized", statusCode: 3)
        }
    }
    func openATTSettings(callbackFunction: String) {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
            webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)({success: false});")
            return
        }
        
        if UIApplication.shared.canOpenURL(settingsUrl) {
            UIApplication.shared.open(settingsUrl) { [weak self] success in
                DispatchQueue.main.async {
                    self?.webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)({success: \(success)});")
                }
            }
        } else {
            webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)({success: false});")
        }
    }

    @available(iOS 14.5, *)
    private func handleATTResult(status: ATTrackingManager.AuthorizationStatus, callbackFunction: String) {
        let canRequestPermission = (status == .notDetermined)
        let resultJson = createATTResultJson(status: status, canRequestPermission: canRequestPermission)
        
        webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\(resultJson));")
        
        if status == .authorized {
            let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            notifyWebWithAdId(adId)
        }
    }
    func requestATTPermission(callbackFunction: String) {
        
        if #available(iOS 14.5, *) {
            let currentStatus = ATTrackingManager.trackingAuthorizationStatus
            
            if currentStatus != .notDetermined {
                let resultJson = createATTResultJsonString(status: currentStatus)
                let script = "\(callbackFunction)('\(resultJson)');"
                webView.evaluateJavaScriptSafely(script)
                return
            }
            
            ATTrackingManager.requestTrackingAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    let resultJson = self.createATTResultJsonString(status: status)
                    let script = "\(callbackFunction)('\(resultJson)');"
                    
                    self.webView.evaluateJavaScriptSafely(script)
                    
                    if status == .authorized {
                        let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                        self.notifyWebWithAdId(adId)
                    }
                }
            }
        } else {
            let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            let resultJson = "{\"status\":\"authorized\",\"statusCode\":3,\"adId\":\"\(adId)\"}"
            let script = "\(callbackFunction)('\(resultJson)');"
            webView.evaluateJavaScriptSafely(script)
        }
    }

    func checkATTStatus(callbackFunction: String) {
        
        if #available(iOS 14.5, *) {
            let status = ATTrackingManager.trackingAuthorizationStatus
            let resultJson = createATTResultJsonString(status: status)
            let script = "\(callbackFunction)('\(resultJson)');"
            
            webView.evaluateJavaScriptSafely(script)
        } else {
            let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            let resultJson = "{\"status\":\"authorized\",\"statusCode\":3,\"adId\":\"\(adId)\"}"
            let script = "\(callbackFunction)('\(resultJson)');"
            webView.evaluateJavaScriptSafely(script)
        }
    }

    func getAdvertisingId(callbackFunction: String) {
        
        if #available(iOS 14.5, *) {
            let status = ATTrackingManager.trackingAuthorizationStatus
            
            if status == .authorized {
                let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                let jsonResult = "{\"adId\":\"\(adId)\",\"available\":true,\"status\":\"authorized\"}"
                let script = "\(callbackFunction)('\(jsonResult)');"
                
                webView.evaluateJavaScriptSafely(script)
            } else {
                let statusString = getATTStatusString(status)
                let jsonResult = "{\"adId\":\"\",\"available\":false,\"status\":\"\(statusString)\"}"
                let script = "\(callbackFunction)('\(jsonResult)');"
                webView.evaluateJavaScriptSafely(script)
            }
        } else {
            let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            let jsonResult = "{\"adId\":\"\(adId)\",\"available\":true,\"status\":\"authorized\"}"
            let script = "\(callbackFunction)('\(jsonResult)');"
            webView.evaluateJavaScriptSafely(script)
        }
    }

    @available(iOS 14.5, *)
    private func createATTResultJsonString(status: ATTrackingManager.AuthorizationStatus) -> String {
        var statusString = ""
        var statusCode = 0
        var adId = ""
        
        switch status {
        case .authorized:
            statusString = "authorized"
            statusCode = 3
            adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        case .denied:
            statusString = "denied"
            statusCode = 2
        case .restricted:
            statusString = "restricted"
            statusCode = 1
        case .notDetermined:
            statusString = "notDetermined"
            statusCode = 0
        @unknown default:
            statusString = "unknown"
            statusCode = -1
        }
        
        return "{\"status\":\"\(statusString)\",\"statusCode\":\(statusCode),\"adId\":\"\(adId)\"}"
    }
    private func escapeJavaScript(_ str: String) -> String {
        return str.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func createTimeoutErrorInfo(adType: String, adUnit: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        return """
        {"timestamp":\(timestamp),"adType":"\(adType)","adUnit":"\(adUnit)","sdkVersion":"\(Self.SDK_VERSION)","gmaSdkVersion":"\(Self.GOOGLE_SDK_VERSION)","status":"timeout","errorCategory":"TIMEOUT","isRetryable":true,"timeoutMs":\(preloadTimeoutMs),"targeting":\(targetingJSONString())}
        """
    }
    
    func preloadRewardedAd(adUnit: String, callbackFunction: String) {
        if isPreloadingRewardedAd {
            executeUnifiedCallback(callbackFunction: callbackFunction, adType: "preload_rewarded", status: "already_loading", adUnit: adUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1004, detailInfo: "Ad is already being loaded")
            return
        }
        
        self.pendingCallbackFunction = callbackFunction
        if preloadedRewardedAd != nil {
            preloadedRewardedAd = nil
            preloadedRewardedAdUnit = nil
        }
        
        loadPreloadedRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction, adUnitIndex: 0)
    }
    private func categorizeAdError(_ errorCode: Int) -> String {
        switch errorCode {
        case 0: return "INTERNAL_ERROR"
        case 1: return "INVALID_REQUEST"
        case 2: return "NETWORK_ERROR"
        case 3: return "NO_FILL"
        case 4: return "APP_ID_MISSING"
        case 5: return "AD_REUSED"
        case 6: return "AD_NOT_READY"
        case 7: return "AD_EXPIRED"
        case 8: return "AD_ALREADY_SHOWN"
        case 9: return "AD_LOAD_IN_PROGRESS"
        default: return "UNKNOWN_ERROR"
        }
    }
    private func isRetryableError(_ errorCode: Int) -> Bool {
        switch errorCode {
        case 0, 2, 3:
            return true
        case 1, 4, 5, 6, 7, 8, 9:
            return false
        default:
            return false
        }
    }
    private func createDetailedLoadErrorInfo(error: Error, adType: String, adUnit: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let nsError = error as NSError
        let errorCode = nsError.code
        let errorMessage = error.localizedDescription.replacingOccurrences(of: "\"", with: "\\\"")

        let failedResponseInfo = nsError.userInfo[GADErrorUserInfoKeyResponseInfo] as? ResponseInfo
        let riDict = buildResponseInfoDict(failedResponseInfo)

        var dict: [String: Any] = [
            "timestamp": timestamp,
            "adType": adType,
            "adUnit": adUnit,
            "sdkVersion": Self.SDK_VERSION,
            "gmaSdkVersion": Self.GOOGLE_SDK_VERSION,
            "errorType": "LOAD_ERROR",
            "errorCode": errorCode,
            "message": errorMessage,
            "errorCategory": categorizeAdError(errorCode),
            "isRetryable": isRetryableError(errorCode)
        ]
        if !riDict.isEmpty { dict["responseInfo"] = riDict }
        if !customAdTargeting.isEmpty { dict["targeting"] = customAdTargeting }

        if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return "{\"timestamp\":\(timestamp),\"adType\":\"\(adType)\",\"adUnit\":\"\(adUnit)\",\"errorCode\":\(errorCode),\"message\":\"\(errorMessage)\"}"
    }

    private func loadPreloadedRewardedAd(adUnit: String, callbackFunction: String, adUnitIndex: Int) {
        isPreloadingRewardedAd = true
        
        let currentAdUnit = adUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutInterval = TimeInterval(preloadTimeoutMs) / 1000.0
        
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            if self.isPreloadingRewardedAd {
                self.isPreloadingRewardedAd = false
                
                let detailedTimeoutInfo = self.createTimeoutErrorInfo(adType: "preload_rewarded", adUnit: currentAdUnit)
                self.executeUnifiedCallback(callbackFunction: callbackFunction, adType: "preload_rewarded", status: "timeout", adUnit: currentAdUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1001, detailInfo: detailedTimeoutInfo)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: timeoutWork)
        
        RewardedAd.load(with: currentAdUnit, request: makeAdRequest()) { [weak self] ad, error in
            guard let self = self else { return }
            
            timeoutWork.cancel()
            self.isPreloadingRewardedAd = false
            
            if let error = error {
                let detailedError = self.getDetailedLoadErrorCode(error: error)
                let detailedErrorInfo = self.createDetailedLoadErrorInfo(error: error, adType: "preload_rewarded", adUnit: currentAdUnit)
                
                self.executeUnifiedCallback(callbackFunction: callbackFunction, adType: "preload_rewarded", status: detailedError, adUnit: currentAdUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: (error as NSError).code, detailInfo: detailedErrorInfo)
                return
            }
            
            self.preloadedRewardedAd = ad
            self.preloadedRewardedAdUnit = currentAdUnit

            ad?.paidEventHandler = { [weak self] adValue in
                self?.pendingPreloadedRewardedAdValue = adValue
            }

            let detailedSuccessInfo = self.createDetailedSuccessInfo(adType: "preload_rewarded", adUnit: currentAdUnit, responseInfo: ad?.responseInfo)
            self.executeUnifiedCallback(callbackFunction: callbackFunction, adType: "preload_rewarded", status: "success", adUnit: currentAdUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: 0, detailInfo: detailedSuccessInfo)
        }
    }
    
    private func createDetailedSuccessInfo(adType: String, adUnit: String, responseInfo: ResponseInfo? = nil, adValue: AdValue? = nil) -> String {
        var extra: [String: Any] = [:]
        if let adValueDict = buildAdValueDict(adValue) { extra["adValue"] = adValueDict }
        return buildSuccessInfoJSON(adType: adType, adUnit: adUnit, status: "success", responseInfo: responseInfo, extra: extra.isEmpty ? [:] : extra)
    }
    
    private func createNoPreloadedAdInfo(adType: String, adUnit: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        return """
        {"timestamp":\(timestamp),"adType":"\(adType)","adUnit":"\(adUnit)","sdkVersion":"\(Self.SDK_VERSION)","gmaSdkVersion":"\(Self.GOOGLE_SDK_VERSION)","status":"no_preloaded_ad","errorCategory":"NO_PRELOADED_AD","isRetryable":false,"message":"No preloaded ad available","targeting":\(targetingJSONString())}
        """
    }
    
    func showPreloadedRewardedAd(callbackFunction: String) {
        guard let preloadedAd = preloadedRewardedAd,
              let adUnit = preloadedRewardedAdUnit else {
            let noAdInfo = createNoPreloadedAdInfo(adType: "show_preloaded_rewarded", adUnit: preloadedRewardedAdUnit ?? "")
            executeUnifiedCallback(callbackFunction: callbackFunction, adType: "show_preloaded_rewarded", status: "no_preloaded_ad", adUnit: preloadedRewardedAdUnit ?? "", sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1002, detailInfo: noAdInfo)
            return
        }
        
        let adUnitForCallback = adUnit
        isPreloadedRewardEarned = false
        preloadedPendingCallbackFunction = callbackFunction
        isUsingUnifiedCallback = true
        
        
        preloadedAd.fullScreenContentDelegate = self
        
        preloadedAd.present(from: self) { [weak self] in
            guard let self = self else { return }

            self.isPreloadedRewardEarned = true

            var extra: [String: Any] = ["eventType": "REWARD_EARNED"]
            if let adValueDict = self.buildAdValueDict(self.pendingPreloadedRewardedAdValue) {
                extra["adValue"] = adValueDict
            }
            self.pendingPreloadedRewardedAdValue = nil
            let rewardInfo = self.buildSuccessInfoJSON(adType: "show_preloaded_rewarded", adUnit: adUnitForCallback,
                                                      status: "reward_earned",
                                                      responseInfo: self.preloadedRewardedAd?.responseInfo,
                                                      extra: extra)
            self.executeUnifiedCallback(callbackFunction: callbackFunction, adType: "show_preloaded_rewarded", status: "reward_earned", adUnit: adUnitForCallback, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: 0, detailInfo: rewardInfo)
        }
    }
    
    private func createSimpleRewardEarnedInfo(adType: String, adUnit: String, responseInfo: ResponseInfo? = nil) -> String {
        return buildSuccessInfoJSON(adType: adType, adUnit: adUnit, status: "reward_earned",
                                   responseInfo: responseInfo,
                                   extra: ["eventType": "REWARD_EARNED"])
    }
    
    func preloadInterstitialAd(adUnit: String, callbackFunction: String) {
        if isPreloadingInterstitialAd {
            executeUnifiedCallback(callbackFunction: callbackFunction, adType: "preload_interstitial", status: "already_loading", adUnit: adUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1004, detailInfo: "Ad is already being loaded")
            return
        }
        
        if preloadedInterstitialAd != nil {
            preloadedInterstitialAd = nil
            preloadedInterstitialAdUnit = nil
        }
        
        loadPreloadedInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction, adUnitIndex: 0)
    }
    private func getDetailedLoadErrorCode(error: Error) -> String {
            let errorCode = (error as NSError).code
            
            switch errorCode {
            case 0: return "load_internal_error"
            case 1: return "load_invalid_request"
            case 2: return "load_network_error"
            case 3: return "load_no_fill"
            case 4: return "load_app_id_missing"
            default: return "load_unknown_error_\(errorCode)"
            }
        }
    private func loadPreloadedInterstitialAd(adUnit: String, callbackFunction: String, adUnitIndex: Int) {
        isPreloadingInterstitialAd = true
        
        let currentAdUnit = adUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutInterval = TimeInterval(preloadTimeoutMs) / 1000.0
        
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            if self.isPreloadingInterstitialAd {
                self.isPreloadingInterstitialAd = false
                
                let detailedTimeoutInfo = self.createTimeoutErrorInfo(adType: "preload_interstitial", adUnit: currentAdUnit)
                self.executeUnifiedCallback(callbackFunction: callbackFunction, adType: "preload_interstitial", status: "timeout", adUnit: currentAdUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1001, detailInfo: detailedTimeoutInfo)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: timeoutWork)
        
        AdManagerInterstitialAd.load(with: currentAdUnit, request: makeAdRequest()) { [weak self] ad, error in
            guard let self = self else { return }
            
            timeoutWork.cancel()
            self.isPreloadingInterstitialAd = false
            
            if let error = error {
                let detailedError = self.getDetailedLoadErrorCode(error: error)
                let detailedErrorInfo = self.createDetailedLoadErrorInfo(error: error, adType: "preload_interstitial", adUnit: currentAdUnit)
                
                self.executeUnifiedCallback(callbackFunction: callbackFunction, adType: "preload_interstitial", status: detailedError, adUnit: currentAdUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: (error as NSError).code, detailInfo: detailedErrorInfo)
                return
            }
            
            self.preloadedInterstitialAd = ad
            self.preloadedInterstitialAdUnit = currentAdUnit

            ad?.paidEventHandler = { [weak self] adValue in
                self?.pendingPreloadedInterstitialAdValue = adValue
            }

            let detailedSuccessInfo = self.createDetailedSuccessInfo(adType: "preload_interstitial", adUnit: currentAdUnit, responseInfo: ad?.responseInfo)
            self.executeUnifiedCallback(callbackFunction: callbackFunction, adType: "preload_interstitial", status: "success", adUnit: currentAdUnit, sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: 0, detailInfo: detailedSuccessInfo)
        }
    }
    
    func showPreloadedInterstitialAd(callbackFunction: String) {
        guard let preloadedAd = preloadedInterstitialAd,
              let adUnit = preloadedInterstitialAdUnit else {
            let noAdInfo = createNoPreloadedAdInfo(adType: "show_preloaded_interstitial", adUnit: preloadedInterstitialAdUnit ?? "")
            executeUnifiedCallback(callbackFunction: callbackFunction, adType: "show_preloaded_interstitial", status: "no_preloaded_ad", adUnit: preloadedInterstitialAdUnit ?? "", sdkVersion: InAppBrowserViewController.SDK_VERSION, errorCode: -1002, detailInfo: noAdInfo)
            return
        }
        
        let adUnitForCallback = adUnit
        preloadedPendingCallbackFunction = callbackFunction
        
        preloadedAd.fullScreenContentDelegate = self
        preloadedAd.present(from: self)
        isUsingUnifiedCallback = true
        
    }
    
    
    func clearPreloadedAd(adType: String) {
        switch adType.lowercased() {
        case "rewarded":
            preloadedRewardedAd = nil
            preloadedRewardedAdUnit = nil
        case "interstitial":
            preloadedInterstitialAd = nil
            preloadedInterstitialAdUnit = nil
        case "rewarded_interstitial":
            preloadedRewardedInterstitialAd = nil
            preloadedRewardedInterstitialAdUnit = nil
        case "all":
            preloadedRewardedAd = nil
            preloadedRewardedAdUnit = nil
            preloadedInterstitialAd = nil
            preloadedInterstitialAdUnit = nil
            preloadedRewardedInterstitialAd = nil
            preloadedRewardedInterstitialAdUnit = nil
        default:
            break
        }
    }

    private func sendInitialATTStatusOnce() {
        
        if #available(iOS 14.5, *) {
            let currentStatus = ATTrackingManager.trackingAuthorizationStatus
            
            
            self.notifyWebWithATTStatusAndAdId(status: currentStatus)
        } else {
            let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            
            
            self.notifyWebWithATTStatusAndAdId(adId: adId, statusString: "authorized", statusCode: 3)
        }
        
    }
    @available(iOS 14.5, *)
   private func getATTStatusString(_ status: ATTrackingManager.AuthorizationStatus) -> String {
       switch status {
       case .authorized: return "authorized"
       case .denied: return "denied"
       case .restricted: return "restricted"
       case .notDetermined: return "notDetermined"
       @unknown default: return "unknown"
       }
   }
    @available(iOS 14.5, *)
    private func createATTResultJson(status: ATTrackingManager.AuthorizationStatus, canRequestPermission: Bool) -> String {
        var statusString = ""
        var statusCode = 0
        var adId = ""
        
        switch status {
        case .authorized:
            statusString = "authorized"
            statusCode = 3
            adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            
        case .denied:
            statusString = "denied"
            statusCode = 2
            adId = ""
            
        case .restricted:
            statusString = "restricted"
            statusCode = 1
            adId = ""
            
        case .notDetermined:
            statusString = "notDetermined"
            statusCode = 0
            adId = ""
            
        @unknown default:
            statusString = "unknown"
            statusCode = -1
            adId = ""
        }
        
        let resultJson = """
        {
            "status": "\(statusString)",
            "statusCode": \(statusCode),
            "adId": "\(adId)",
            "canRequestPermission": \(canRequestPermission)
        }
        """
        
        return resultJson
    }
}


extension InAppBrowserViewController: FullScreenContentDelegate {
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        var adType = "reward"
        let adname = currentAdUnitId
        let adnum = adUnitIndexDisplay
        
        if ad is AdManagerInterstitialAd {
            adType = "interstitial"
        } else if ad is RewardedInterstitialAd {
            adType = "rewarded_interstitial"
        }
        
        let isPreloadedAd = (ad === preloadedRewardedAd || ad === preloadedInterstitialAd)
        let callbackToUse = isPreloadedAd ? preloadedPendingCallbackFunction : pendingCallbackFunction
        let rewardEarned = isPreloadedAd ? isPreloadedRewardEarned : isRewardEarned
        let adUnit = isPreloadedAd ? (preloadedRewardedAdUnit ?? preloadedInterstitialAdUnit ?? adname) : adname
        
        
        if ad is AdManagerInterstitialAd {
            if let callbackFunction = callbackToUse {
                if isUsingUnifiedCallback {
                    let adValue = isPreloadedAd ? pendingPreloadedInterstitialAdValue : pendingInterstitialAdValue
                    let successInfo = createDetailedSuccessInfo(
                        adType: isPreloadedAd ? "show_preloaded_interstitial" : adType,
                        adUnit: adUnit,
                        responseInfo: (ad as? AdManagerInterstitialAd)?.responseInfo ?? (ad as? RewardedAd)?.responseInfo,
                        adValue: adValue
                    )
                    if isPreloadedAd { pendingPreloadedInterstitialAdValue = nil } else { pendingInterstitialAdValue = nil }
                    executeUnifiedCallback(
                        callbackFunction: callbackFunction,
                        adType: isPreloadedAd ? "show_preloaded_interstitial" : adType,
                        status: "success",
                        adUnit: adUnit,
                        sdkVersion: InAppBrowserViewController.SDK_VERSION,
                        errorCode: 0,
                        detailInfo: successInfo
                    )
                } else {
                    webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\"\(adType)\", \"success\", \"\(adUnit)\", \(adnum));")
                }
            }

            if isPreloadedAd {
                preloadedInterstitialAd = nil
                preloadedInterstitialAdUnit = nil
                preloadedPendingCallbackFunction = nil
            } else {
                resetAdState()
                adUnitIndexCall = 0
                adUnitIndexDisplay = 1
            }

            isUsingUnifiedCallback = false
            currentCallbackType = "legacy"
            return
        }
        
        if let callbackFunction = callbackToUse {
            if rewardEarned {
                if isUsingUnifiedCallback {
                    let adValue = isPreloadedAd ? pendingPreloadedRewardedAdValue : pendingRewardedAdValue
                    let rewardInfo = createDismissedWithRewardInfo(
                        adType: isPreloadedAd ? "show_preloaded_rewarded" : adType,
                        adUnit: adUnit,
                        responseInfo: (ad as? RewardedAd)?.responseInfo,
                        adValue: adValue
                    )
                    if isPreloadedAd { pendingPreloadedRewardedAdValue = nil } else { pendingRewardedAdValue = nil }
                    executeUnifiedCallback(
                        callbackFunction: callbackFunction,
                        adType: isPreloadedAd ? "show_preloaded_rewarded" : adType,
                        status: "dismissed_with_reward",
                        adUnit: adUnit,
                        sdkVersion: InAppBrowserViewController.SDK_VERSION,
                        errorCode: 0,
                        detailInfo: rewardInfo
                    )
                } else {
                    webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\"\(adType)\", \"dismissed_with_reward\", \"\(adUnit)\", \(adnum));")
                }
                
                if isPreloadedAd {
                    isPreloadedRewardEarned = false
                } else {
                    isRewardEarned = false
                }
            } else {
                if isUsingUnifiedCallback {
                    let cancelInfo = createSimpleCancelInfo(
                        adType: isPreloadedAd ? "show_preloaded_rewarded" : adType,
                        adUnit: adUnit
                    )
                    executeUnifiedCallback(
                        callbackFunction: callbackFunction,
                        adType: isPreloadedAd ? "show_preloaded_rewarded" : adType,
                        status: "cancelled",
                        adUnit: adUnit,
                        sdkVersion: InAppBrowserViewController.SDK_VERSION,
                        errorCode: -1003,
                        detailInfo: cancelInfo
                    )
                } else {
                    webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\"\(adType)\", \"cancelled\", \"\(adUnit)\", \(adnum));")
                }
            }
        }

        if isPreloadedAd {
            preloadedRewardedAd = nil
            preloadedRewardedAdUnit = nil
            preloadedPendingCallbackFunction = nil
            isPreloadedRewardEarned = false
        } else {
            resetAdState()
            adUnitIndexCall = 0
            adUnitIndexDisplay = 1
        }
        
        isUsingUnifiedCallback = false
        currentCallbackType = "legacy"
    }
    
    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        var adType = "reward"
        if ad is AdManagerInterstitialAd {
            adType = "interstitial"
        } else if ad is RewardedInterstitialAd {
            adType = "rewarded_interstitial"
        }
        
        let isPreloadedAd = (ad === preloadedRewardedAd || ad === preloadedInterstitialAd)
        let callbackToUse = isPreloadedAd ? preloadedPendingCallbackFunction : pendingCallbackFunction
        let adUnit = isPreloadedAd ? (preloadedRewardedAdUnit ?? preloadedInterstitialAdUnit ?? currentAdUnitId) : currentAdUnitId
        
        if let callbackFunction = callbackToUse {
            if isUsingUnifiedCallback {
                let errorInfo = createDetailedPresentErrorInfo(
                    error: error,
                    adType: isPreloadedAd ? "show_preloaded_\(adType)" : adType,
                    adUnit: adUnit
                )
                executeUnifiedCallback(
                    callbackFunction: callbackFunction,
                    adType: isPreloadedAd ? "show_preloaded_\(adType)" : adType,
                    status: "present_failed",
                    adUnit: adUnit,
                    sdkVersion: InAppBrowserViewController.SDK_VERSION,
                    errorCode: (error as NSError).code,
                    detailInfo: errorInfo
                )
            } else {
                webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\"\(adType)\", \"failed\", \"\(adUnit)\", \(adUnitIndexDisplay));")
            }
        }
        
        if isPreloadedAd {
            if ad === preloadedRewardedAd {
                preloadedRewardedAd = nil
                preloadedRewardedAdUnit = nil
            } else if ad === preloadedInterstitialAd {
                preloadedInterstitialAd = nil
                preloadedInterstitialAdUnit = nil
            }
            preloadedPendingCallbackFunction = nil
            isPreloadedRewardEarned = false
        } else {
            resetAdState()
        }
        
        isUsingUnifiedCallback = false
        currentCallbackType = "legacy"
    }
}


private func convertStringToButtonRole(_ roleString: String) -> InAppBrowserConfig.ButtonRole {
    switch roleString {
    case "back": return .back
    case "close": return .close
    case "none": return .none
    default: return .back
    }
}


extension WKWebView {
    func evaluateJavaScriptSafely(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        DispatchQueue.main.async {
            self.evaluateJavaScript(script, completionHandler: completion)
        }
    }
}

extension Bundle {
    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        let bundleName = "InAppBrowserSDK_InAppBrowserSDK"
        
        if let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL) {
            return bundle
        }
        
        let currentBundle = Bundle(for: InAppBrowserViewController.self)
        if let bundleURL = currentBundle.url(forResource: bundleName, withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL) {
            return bundle
        }
        
        return currentBundle
        #endif
    }
}

extension InAppBrowserViewController: @MainActor AdMetadataDelegate {
    @MainActor
    func adMetadataDidChange(_ ad: any AdMetadataProvider) {
        let metadata = ad.adMetadata ?? [:]
        var metaDict: [String: Any] = [:]

        if let adId = metadata[GADAdMetadataKey(rawValue: "AdId")] as? String, !adId.isEmpty {
            metaDict["AdId"] = adId
        }
        if let adTitle = metadata[GADAdMetadataKey(rawValue: "AdTitle")] as? String, !adTitle.isEmpty {
            metaDict["AdTitle"] = adTitle
        }
        if let creativeId = metadata[GADAdMetadataKey(rawValue: "CreativeId")] as? String, !creativeId.isEmpty {
            metaDict["CreativeId"] = creativeId
        }
        if let adSystem = metadata[GADAdMetadataKey(rawValue: "AdSystem")] as? String, !adSystem.isEmpty {
            metaDict["AdSystem"] = adSystem
        }
        if let dealId = metadata[GADAdMetadataKey(rawValue: "DealId")] as? String, !dealId.isEmpty {
            metaDict["DealId"] = dealId
        }
        if let durationMs = metadata[GADAdMetadataKey(rawValue: "CreativeDurationMs")] as? Int {
            metaDict["CreativeDurationMs"] = durationMs
            if durationMs > 0 {
                metaDict["CreativeDurationSec"] = durationMs / 1000
            }
        }
        if let traffickingParams = metadata[GADAdMetadataKey(rawValue: "TraffickingParameters")] as? String,
           !traffickingParams.isEmpty {
            metaDict["TraffickingParameters"] = traffickingParams
            var parsedParams: [String: String] = [:]
            for pair in traffickingParams.components(separatedBy: "&") {
                let parts = pair.components(separatedBy: "=")
                if parts.count == 2, !parts[0].isEmpty {
                    parsedParams[parts[0]] = parts[1]
                }
            }
            if !parsedParams.isEmpty {
                metaDict["TraffickingParametersParsed"] = parsedParams
            }
        }
        if let mediaURL = metadata[GADAdMetadataKey(rawValue: "MediaURL")] as? String, !mediaURL.isEmpty {
            metaDict["MediaURL"] = mediaURL
        }
        if let wrappers = metadata[GADAdMetadataKey(rawValue: "Wrappers")] as? [[String: String]], !wrappers.isEmpty {
            var wrapperList: [[String: String]] = []
            for wrapper in wrappers {
                var w: [String: String] = [:]
                if let wAdId       = wrapper["AdId"],       !wAdId.isEmpty       { w["AdId"] = wAdId }
                if let wAdSystem   = wrapper["AdSystem"],   !wAdSystem.isEmpty   { w["AdSystem"] = wAdSystem }
                if let wCreativeId = wrapper["CreativeId"], !wCreativeId.isEmpty { w["CreativeId"] = wCreativeId }
                wrapperList.append(w)
            }
            metaDict["Wrappers"] = wrapperList
            metaDict["WrapperDepth"] = wrapperList.count
        }

        guard !metaDict.isEmpty,
              let jsonData = try? JSONSerialization.data(withJSONObject: metaDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        let script = "if(typeof window.onAdMetadataReceived === 'function') window.onAdMetadataReceived(\(jsonString));"
        DispatchQueue.main.async {
            self.webView.evaluateJavaScriptSafely(script)
        }
    }
}
