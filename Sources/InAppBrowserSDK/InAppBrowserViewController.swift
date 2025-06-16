import UIKit
import WebKit
import GoogleMobileAds
import AppTrackingTransparency
import AdSupport
import Foundation

class InAppBrowserViewController: UIViewController, WKUIDelegate {
    
    static func clearAllWebViewCache() {
        
        // WKWebsiteDataStore의 모든 데이터 정리
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) {
        }
        
        HTTPCookieStorage.shared.removeCookies(since: Date(timeIntervalSince1970: 0))
        
        URLCache.shared.removeAllCachedResponses()
        
        let defaults = UserDefaults.standard
        let webViewKeys = defaults.dictionaryRepresentation().keys.filter { key in
            key.contains("WebKit") || key.contains("com.apple.WebKit")
        }
        
        for key in webViewKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
            }
    
    private var webView: WKWebView!
    private var loadingCover: UIView!
    private var loadingIndicator: UIView!
    private var rewardedAd: RewardedAd?
    private var interstitialAd: InterstitialAd?
    private var rewardedInterstitialAd: RewardedInterstitialAd?
    private var currentAdUnitId: String = ""
    private var isLoadingAd: Bool = false
    private var isRewardEarned: Bool = false
    private var pendingCallbackFunction: String?
    
    private var config: InAppBrowserConfig
    
    private let adLoadTimeoutInterval: TimeInterval = 7.0
    private var adLoadTimer: Timer?
    private var adLoadTimeoutWorkItem: DispatchWorkItem?
    private var isAdRequestTimeOut: Bool = false
    
    private var adUnitIndexCall: Int = 0
    private var adUnitIndexDisplay: Int = 1
    private var lastCallAdUnit: String = ""
    private var callBackAdUnit: String = ""
    
    // URL 최적화를 위한 추가 속성
    private var originalURL: String?
    private var optimizedURL: String?
    
    // 백 액션 제어를 위한 추가 속성
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
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupMainLayout()
        setupWebView()
        setupJavaScriptInterface(for: self.webView)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object:nil
        )
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
        
        if let webView = webView {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "iOSInterface")
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            
            let dataStore = webView.configuration.websiteDataStore
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) { }
        }
        
        if let presentedAlert = presentedViewController as? UIAlertController {
            presentedAlert.dismiss(animated: false, completion: nil)
        }
        
    }
    
    public func closeWebView(){
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let presentedAlert = self.presentedViewController as? UIAlertController {
                presentedAlert.dismiss(animated: false, completion: nil)
            }
            
            self.clearWebViewData()
            
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
        // 웹뷰 로딩 중지
        webView.stopLoading()
        
        // 캐시와 쿠키 정리
        let dataStore = webView.configuration.websiteDataStore
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        
        dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) {
        }
        
        // HTTP 쿠키 정리
        HTTPCookieStorage.shared.removeCookies(since: Date(timeIntervalSince1970: 0))
        
        // URL 캐시 정리
        URLCache.shared.removeAllCachedResponses()
        
        // 네비게이션 히스토리 초기화
        navigationHistory.removeAll()
        isNavigatingBack = false
        
        // 백 액션 관련 변수 초기화
        backActionCount = 0
        lastBackActionURL = ""
        lastBackActionTime = 0
        
    }
    private func applyImageControlSettings() {
        let imageControlScript = """
        (function() {
            const allowSave = \(config.allowImageSave ? "true" : "false");
            const allowZoom = \(config.allowImageZoom ? "true" : "false");
            const allowDrag = \(config.allowImageDrag ? "true" : "false");
            const allowSelect = \(config.allowImageSelect ? "true" : "false");
            
            
            const images = document.querySelectorAll('img');
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
                gestureRecognizer.isEnabled = true // 탭은 허용 (링크 클릭 등)
            } else if gestureRecognizer is UIPinchGestureRecognizer {
                gestureRecognizer.isEnabled = false // 핀치 줌 완전 차단
            } else if gestureRecognizer is UILongPressGestureRecognizer {
                gestureRecognizer.isEnabled = false // 길게 누르기 차단
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
            
            // 1. 이미지 컨텍스트 메뉴 비활성화 (길게 누르기 방지)
            document.addEventListener('contextmenu', function(e) {
                if (e.target.tagName === 'IMG') {
                    e.preventDefault();
                    e.stopPropagation();
                    return false;
                }
            }, true);
            
            // 2. 이미지 드래그 방지
            document.addEventListener('dragstart', function(e) {
                if (e.target.tagName === 'IMG') {
                    e.preventDefault();
                    return false;
                }
            }, true);
            
            // 3. 이미지 선택 방지
            document.addEventListener('selectstart', function(e) {
                if (e.target.tagName === 'IMG') {
                    e.preventDefault();
                    return false;
                }
            }, true);
            
            // 4. 모든 이미지에 터치 이벤트 제어 적용
            function disableImageInteractions() {
                const images = document.querySelectorAll('img');
                
                images.forEach(function(img, index) {
                    if (img.dataset.protected) return; 
                    
                    img.dataset.protected = 'true';
                    
                    // CSS 스타일 강제 적용
                    img.style.webkitUserSelect = 'none';
                    img.style.userSelect = 'none';
                    img.style.webkitTouchCallout = 'none';
                    img.style.webkitUserDrag = 'none';
                    img.style.pointerEvents = 'none';
                    
                    // 터치 이벤트 차단
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
                    
                    // 클릭 이벤트 차단
                    img.addEventListener('click', function(e) {
                        e.preventDefault();
                        e.stopPropagation();
                    }, true);
                    
                    // 더블클릭 차단 (줌 방지)
                    img.addEventListener('dblclick', function(e) {
                        e.preventDefault();
                        e.stopPropagation();
                    }, true);
                    
                    // 마우스 이벤트 차단
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
            
            // 5. CSS 스타일로 추가 보호
            const style = document.createElement('style');
            style.innerHTML = \'
                img {
                    -webkit-user-select: none !important;
                    -moz-user-select: none !important;
                    -ms-user-select: none !important;
                    user-select: none !important;
                    -webkit-user-drag: none !important;
                    -webkit-touch-callout: none !important;
                    -webkit-tap-highlight-color: transparent !important;
                    pointer-events: none !important;
                    touch-action: none !important;
                }
                
                /* 이미지 컨테이너도 보호 */
                .image-container, .photo-container, .img-container {
                    -webkit-user-select: none !important;
                    user-select: none !important;
                    -webkit-touch-callout: none !important;
                }
                
                /* 특정 클래스 이미지들 추가 보호 */
                img[src*=".jpg"], 
                img[src*=".jpeg"], 
                img[src*=".png"], 
                img[src*=".gif"], 
                img[src*=".webp"] {
                    -webkit-user-select: none !important;
                    user-select: none !important;
                    -webkit-touch-callout: none !important;
                    pointer-events: none !important;
                    -webkit-user-drag: none !important;
                }
            \';
            document.head.appendChild(style);
            
            // 6. 초기 실행 및 DOM 변경 감지
            function initImageProtection() {
                disableImageInteractions();
                
                // DOM 변경 감지하여 새로운 이미지들에도 적용
                const observer = new MutationObserver(function(mutations) {
                    let hasNewImages = false;
                    
                    mutations.forEach(function(mutation) {
                        if (mutation.type === 'childList') {
                            mutation.addedNodes.forEach(function(node) {
                                if (node.nodeType === 1) { // Element node
                                    if (node.tagName === 'IMG' || node.querySelector && node.querySelector('img')) {
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
            
            // 7. 실행
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
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) { }
            config.websiteDataStore = dataStore
        }
        
        config.applicationNameForUserAgent = "KakaoTalkSharing"
        
        return config
    }
    private func createToolbar() -> UIView {
        let toolbar = UIView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        
        if let bgColor = config.toolbarBackgroundColor {
            toolbar.backgroundColor = bgColor
        } else {
            toolbar.backgroundColor = config.toolbarMode == "dark" ? .black : .white
        }
        
        // 왼쪽 버튼 (leftButtonRole에 따라)
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
        
        // _ico 이미지 테스트
        print("\n🔍 _ico 이미지 테스트:")
        
        let currentBundle = Bundle(for: InAppBrowserViewController.self)
        print("📦 현재 번들: \(currentBundle.bundlePath)")
        
        // 방법 1: Bundle.module
        let img1 = UIImage(named: "_ico", in: Bundle.module, compatibleWith: nil)
        print("방법1 (Bundle.module): \(img1 != nil ? "✅ 성공" : "❌ 실패")")
        
        // 방법 2: 현재 번들
        let img2 = UIImage(named: "_ico", in: currentBundle, compatibleWith: nil)
        print("방법2 (현재 번들): \(img2 != nil ? "✅ 성공" : "❌ 실패")")
        
        // 방법 3: 기본
        let img3 = UIImage(named: "_ico")
        print("방법3 (기본): \(img3 != nil ? "✅ 성공" : "❌ 실패")")
        
        // 기존 로직
        switch icon {
        case .auto:
            if role == .back {
                // _ico 시도
                let backImage = UIImage(named: "_ico", in: Bundle.module, compatibleWith: nil) ??
                               UIImage(named: "_ico", in: currentBundle, compatibleWith: nil) ??
                               UIImage(systemName: "chevron.left")
                button.setImage(backImage, for: .normal)
                print("백 버튼 이미지: \(backImage != nil ? "적용됨" : "실패")")
            } else {
                button.setImage(UIImage(systemName: "xmark"), for: .normal)
            }
            button.tintColor = config.toolbarMode == "dark" ? .white : .black
            
        case .back:
            button.setImage(UIImage(systemName: "chevron.left"), for: .normal)
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
            
            // 기존 데이터 정리
            let dataStore = webView.configuration.websiteDataStore
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) {
            }
        }
        
        if let urlString = config.url {
            let finalUrl = config.preventCache ? addCacheBusterToUrl(urlString) : urlString
            let optimizedUrlString = optimizeURL(finalUrl)
            
            
            if let url = URL(string: optimizedUrlString) {
                // 캐시 방지 설정
                if config.preventCache {
                    let dataStore = WKWebsiteDataStore.nonPersistent()
                    webView.configuration.websiteDataStore = dataStore
                }
                
                var request = URLRequest(url: url)
                
                if config.preventCache {
                    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
                    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                    request.setValue("0", forHTTPHeaderField: "Expires")
                    request.setValue(String(Int(Date().timeIntervalSince1970)), forHTTPHeaderField: "X-Requested-With")
                }
                
                request.httpShouldHandleCookies = true
                
                let userAgent = generateOptimalUserAgent(for: url)
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                
                webView.load(request)
            }
        }
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
            
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak progressView] timer in
                guard let progressView = progressView else {
                    timer.invalidate()
                    return
                }
                
                let newProgress = progressView.progress + 0.03
                if newProgress >= 1.0 {
                    progressView.progress = 0.0
                } else {
                    UIView.animate(withDuration: 0.05, animations: {
                        progressView.setProgress(newProgress, animated: true)
                    })
                }
            }
            
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

    // 추가: 더블 탭 확인 방식을 원한다면 이 메서드도 사용 가능
    private func handleConfirmExitWithDoubleTap() {
        let currentTime = Date().timeIntervalSince1970
        
        if currentTime - lastBackPressed < backConfirmTimeout {
            // 지정된 시간 내에 두 번째 탭 - 앱 종료
            closeApp()
        } else {
            // 첫 번째 탭 - 토스트 메시지 표시
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
    
    private func showLoadingCover() {
        loadingCover.isHidden = false
        
        if let activityIndicator = loadingIndicator as? UIActivityIndicatorView {
            activityIndicator.startAnimating()
        }
    }
    
    private func hideLoadingCover() {
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
// MARK: - WKNavigationDelegate
extension InAppBrowserViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        
        let urlString = url.absoluteString
        let currentTime = Date().timeIntervalSince1970
        
        
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
        
        let currentHost = webView.url?.host?.lowercased()
        let newHost = url.host?.lowercased()
        
        if currentHost == nil {
            
            decisionHandler(.allow)
            return
        }
        
        let isSameDomain = checkSameDomain(currentHost: currentHost, newHost: newHost)
        
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


    private func checkSameDomain(currentHost: String?, newHost: String?) -> Bool {
        guard let current = currentHost, let new = newHost else {
            return false
        }
        
        if current == new {
            return true
        }
        
        let currentParts = current.components(separatedBy: ".")
        let newParts = new.components(separatedBy: ".")
        
        guard currentParts.count >= 2, newParts.count >= 2 else {
            return false
        }
        
        let currentDomain = currentParts.suffix(2).joined(separator: ".")
        let newDomain = newParts.suffix(2).joined(separator: ".")
        
        let isSameBaseDomain = currentDomain == newDomain
        
        
        
        return isSameBaseDomain
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
        showLoadingCover()
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
        
        guard let url = navigationAction.request.url else {
            return nil
        }
        
        let urlString = url.absoluteString
        let isWindowOpen = navigationAction.navigationType == .other
       
        
        let currentHost = webView.url?.host?.lowercased()
        let newHost = url.host?.lowercased()
        
        
        let isJavaScriptLink = urlString.hasPrefix("javascript:") || urlString.hasPrefix("about:")
        
        if isJavaScriptLink {
            DispatchQueue.main.async {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
        
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
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        hideLoadingCover()
        
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
}

// MARK: - WKScriptMessageHandler
extension InAppBrowserViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        
        switch message.name {
        case "iOSInterface":
            if let type = body["type"] as? String {
                switch type {
                case "close":
                    closeWebView()
                    
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
                    }
                case "checkAdIdConsentStatus", "getATTStatus":
                    if let callbackFunction = body["callbackFunction"] as? String {
                        checkATTStatus(callbackFunction: callbackFunction)
                    }
                    
                case "getAdvertisingId":
                    if let callbackFunction = body["callbackFunction"] as? String {
                        getAdvertisingId(callbackFunction: callbackFunction)
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
// MARK: - Web Control Functions (백 액션 제어)
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
// MARK: - Ad Related Functions
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
            
            updateButtonRoles(leftRole: newConfig.leftButtonRole, rightRole: newConfig.rightButtonRole)
            
            
        }
    func showRewardedAd(adUnit: String, callbackFunction: String) {
        if isLoadingAd { return }
        
        if let currentAd = rewardedAd, currentAdUnitId == adUnit {
            showExistingRewardedAd(callbackFunction: callbackFunction)
        } else {
            loadNewRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
        }
    }
    
    func showInterstitialAd(adUnit: String, callbackFunction: String) {
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
    
    private func loadNewRewardedAd(adUnit: String, callbackFunction: String) {
        showLoadingCover()
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
        
        RewardedAd.load(with: currentAdUnit, request: Request()) { [weak self] ad, error in
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
            self.showExistingRewardedAd(callbackFunction: callbackFunction)
        }
    }
    
    private func loadNewInterstitialAd(adUnit: String, callbackFunction: String) {
        showLoadingCover()
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
        
        InterstitialAd.load(with: currentAdUnit, request: Request()) { [weak self] ad, error in
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
        showLoadingCover()
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
        
        RewardedInterstitialAd.load(with: currentAdUnit, request: Request()) { [weak self] ad, error in
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
        showLoadingCover()
        isLoadingAd = true
        isAdRequestTimeOut = false
        
        adLoadTimer?.invalidate()
        
        let adUnits = adUnit.components(separatedBy: ";")
        let currentAdUnit = adUnits[adUnitIndexCall].trimmingCharacters(in: .whitespacesAndNewlines)
        
        adLoadTimer = Timer.scheduledTimer(withTimeInterval: adLoadTimeoutInterval, repeats: false) { [weak self] _ in
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
        
        RewardedInterstitialAd.load(with: currentAdUnit, request: Request()) { [weak self] ad, error in
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
        if !isRewardEarned {
            pendingCallbackFunction = nil
        }
    }
}

// MARK: - ATT (App Tracking Transparency) Functions
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
                
                // 1. onReceiveAdId 함수 호출 체크 및 실행 (한 번만!)
                if (typeof window.onReceiveAdId === 'function') {
                    window.onReceiveAdId('\(adId)', '\(statusString)', \(statusCode));
                } else {
                    
                    // 함수가 없다면 나중에 호출될 수 있도록 데이터 저장
                    window._pendingAdIdData = {
                        adId: '\(adId)',
                        status: '\(statusString)',
                        statusCode: \(statusCode)
                    };
                    console.log('📦 데이터를 window._pendingAdIdData에 저장');
                }
                
                // 2. 전역 변수 업데이트
                window.currentAdId = '\(adId)';
                window.currentATTStatus = '\(statusString)';
                window.currentATTStatusCode = \(statusCode);
                console.log('📝 전역 변수 업데이트 완료');
                
                // 3. 커스텀 이벤트 발생
                const event = new CustomEvent('adIdAndATTStatusReceived', { 
                    detail: {
                        adId: '\(adId)',
                        status: '\(statusString)',
                        statusCode: \(statusCode)
                    }
                });
                window.dispatchEvent(event);
                
                const callbackPatterns = [
                    'handleAdId',        // onReceiveAdId 제거!
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
    func getAdvertisingId(callbackFunction: String) {
        
        if #available(iOS 14.5, *) {
            let status = ATTrackingManager.trackingAuthorizationStatus
            
            if status == .authorized {
                let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                let jsonResult = """
                {"adId": "\(adId)", "available": true, "status": "authorized"}
                """
                
                webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)('\(jsonResult)');")
            } else {
                let jsonResult = """
                {"adId": "", "available": false, "status": "\(getATTStatusString(status))"}
                """
                webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)('\(jsonResult)');")
            }
        } else {
            let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            let jsonResult = """
            {"adId": "\(adId)", "available": true, "status": "authorized"}
            """
            webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)('\(jsonResult)');")
        }
    }

    func checkATTStatus(callbackFunction: String) {
        
        if #available(iOS 14.5, *) {
            let status = ATTrackingManager.trackingAuthorizationStatus
            let resultJson = createATTResultJson(status: status)
            
            webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\(resultJson));")
        } else {
            let resultJson = """
            {"status": "authorized", "statusCode": 3, "adId": "\(ASIdentifierManager.shared().advertisingIdentifier.uuidString)"}
            """
            webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\(resultJson));")
        }
    }

    func requestATTPermission(callbackFunction: String) {
        
        if #available(iOS 14.5, *) {
            let currentStatus = ATTrackingManager.trackingAuthorizationStatus
            
            if currentStatus != .notDetermined {
                // 이미 결정된 상태 - 콜백만 실행
                let resultJson = createATTResultJson(status: currentStatus)
                webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\(resultJson));")
                return
            }
            
            // ATT 팝업 표시
            ATTrackingManager.requestTrackingAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    let resultJson = self.createATTResultJson(status: status)
                    
                    self.webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\(resultJson));")
                }
            }
        } else {
            let resultJson = """
            {"status": "authorized", "statusCode": 3, "adId": "\(ASIdentifierManager.shared().advertisingIdentifier.uuidString)"}
            """
            webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\(resultJson));")
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

// MARK: - FullScreenContentDelegate
extension InAppBrowserViewController: FullScreenContentDelegate {
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        var adType = "reward"
        let adname = currentAdUnitId
        let adnum = adUnitIndexDisplay
        
        if ad is InterstitialAd {
            adType = "interstitial"
        } else if ad is RewardedInterstitialAd {
            adType = "rewarded_interstitial"
        }
        
        if isRewardEarned {
            if let callbackFunction = pendingCallbackFunction {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\"\(adType)\", \"success\", \"\(adname)\", \(adnum));")
                    self?.isRewardEarned = false
                    self?.pendingCallbackFunction = nil
                }
            }
        } else {
            if let callbackFunction = pendingCallbackFunction {
                webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\"\(adType)\", \"cancelled\", \"\(currentAdUnitId)\", \(adUnitIndexDisplay));")
            }
        }
        
        resetAdState()
        adUnitIndexCall = 0
        adUnitIndexDisplay = 1
    }
    
    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        var adType = "reward"
        if ad is InterstitialAd {
            adType = "interstitial"
        } else if ad is RewardedInterstitialAd {
            adType = "rewarded_interstitial"
        }
        
        if let callbackFunction = pendingCallbackFunction {
            webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\"\(adType)\", \"failed\", \"\(currentAdUnitId)\", \(adUnitIndexDisplay));")
        }
        resetAdState()
    }
    
}
extension InAppBrowserViewController {
    func updateButtonRoles(leftRole: InAppBrowserConfig.ButtonRole, rightRole: InAppBrowserConfig.ButtonRole) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            
            if let leftButton = self.view.viewWithTag(100) as? UIButton {
                
                self.setupButton(leftButton, role: leftRole, icon: self.config.leftButtonIcon, isLeft: true)
                
            } else {
                
            }
            
            if let rightButton = self.view.viewWithTag(200) as? UIButton {
                
                self.setupButton(rightButton, role: rightRole, icon: self.config.rightButtonIcon, isLeft: false)
                
            } else {
                
            }
        }
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
    static var module: Bundle {
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
        
        // 3. Fallback
        return currentBundle
    }
}
