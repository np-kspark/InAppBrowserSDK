import UIKit
import WebKit
import GoogleMobileAds
import AppTrackingTransparency
import AdSupport
import Foundation

class InAppBrowserViewController: UIViewController, WKUIDelegate {
    
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
        // 백 액션 설정 초기화
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
    
    // ✅ 앱이 포그라운드로 돌아올 때 처리
    @objc private func appDidBecomeActive() {
        if webView != nil {
            let script = "window.dispatchEvent(new Event('visibilitychange'));"
            webView.evaluateJavaScript(script, completionHandler: nil)
            
            // ✅ 외부 앱에서 돌아온 경우 플래그 리셋
            if isMovingToExternalApp {
                isMovingToExternalApp = false
                
                // 1초 후 중복 로드 방지 해제
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.pendingExternalURL = nil
                }
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        
        // ✅ 웹뷰 정리
        if let webView = webView {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "iOSInterface")
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        
        // ✅ 현재 표시중인 Alert 해제
        if let presentedAlert = presentedViewController as? UIAlertController {
            presentedAlert.dismiss(animated: false, completion: nil)
        }
    }
    
    public func closeWebView(){
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // ✅ Alert가 표시중이면 먼저 해제
            if let presentedAlert = self.presentedViewController as? UIAlertController {
                presentedAlert.dismiss(animated: false, completion: nil)
            }
            
            InAppBrowserManager.shared.notifyBrowserClosed()
            self.dismiss(animated: true) { [weak self] in
                guard let self = self else { return }
                
                self.webView.stopLoading()
                self.webView.configuration.userContentController.removeAllUserScripts()
                
                // ✅ 안전하게 handler 제거
                do {
                    self.webView.configuration.userContentController.removeScriptMessageHandler(forName: "iOSInterface")
                } catch {
                }
                
                self.webView.navigationDelegate = nil
                self.webView.uiDelegate = nil
            }
        }
    }
    
    // URL 최적화 함수 (쿠팡 URL 문제 해결)
    private func optimizeURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        
        // 쿠팡 특화 최적화
        if url.host?.contains("coupang.com") == true {
            // 필수 파라미터만 유지
            let essentialParams = ["itemId", "vendorItemId"]
            
            if let queryItems = components?.queryItems {
                let filteredItems = queryItems.filter { item in
                    essentialParams.contains(item.name)
                }
                components?.queryItems = filteredItems.isEmpty ? nil : filteredItems
            }
        }
        
        // URL 길이 체크 및 단축
        let optimizedURL = components?.url?.absoluteString ?? urlString
        
        // 2000자 이상이면 기본 상품 페이지로 리다이렉트
        if optimizedURL.count > 2000 {
            if let productId = extractProductId(from: urlString) {
                return "https://www.coupang.com/vp/products/\(productId)"
            }
        }
        
        return optimizedURL
    }
    
    // 상품 ID 추출
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
        
        // Setup toolbar
        let toolbar = createToolbar()
        view.addSubview(toolbar)
        
        // Setup WebView with enhanced configuration
        let config = createEnhancedWebViewConfiguration()
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        
        // iOS 16.4+ 디버깅 지원 추가
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        
        view.addSubview(webView)
        MobileAds.shared.register(webView)
        
        // Setup loading cover
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
    
    // 향상된 WebView 설정
    private func createEnhancedWebViewConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        
        // 쿠키 설정
        let cookieStorage = HTTPCookieStorage.shared
        cookieStorage.cookieAcceptPolicy = .always
        
        userContentController.add(self, name: "iOSInterface")
        config.userContentController = userContentController
        config.allowsInlineMediaPlayback = true
        
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        
        // iOS 버전별 설정
        if #available(iOS 14.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = []
            
            let preferences = WKWebpagePreferences()
            preferences.allowsContentJavaScript = true
            config.defaultWebpagePreferences = preferences
        } else {
            config.mediaPlaybackRequiresUserAction = false
            config.preferences.javaScriptEnabled = true
        }
        
        
        // 데이터 저장소 설정
        let dataStore = WKWebsiteDataStore.default()
        config.websiteDataStore = dataStore
        
        // 카카오톡 공유를 위한 URL 스킴 처리 추가
        config.applicationNameForUserAgent = "KakaoTalkSharing"
        
        return config
    }
    private func createToolbar() -> UIView {
        let toolbar = UIView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        
        // 툴바 배경색 설정
        if let bgColor = config.toolbarBackgroundColor {
            toolbar.backgroundColor = bgColor
        } else {
            toolbar.backgroundColor = config.toolbarMode == "dark" ? .black : .white
        }
        
        // 왼쪽 버튼 (leftButtonRole에 따라)
        let leftButton = UIButton(type: .system)
        leftButton.translatesAutoresizingMaskIntoConstraints = false
        leftButton.tag = 100 // ✅ 왼쪽 버튼 태그
        setupButton(leftButton, role: config.leftButtonRole, icon: config.leftButtonIcon, isLeft: true)
        
        // 오른쪽 버튼 (rightButtonRole에 따라)
        let rightButton = UIButton(type: .system)
        rightButton.translatesAutoresizingMaskIntoConstraints = false
        rightButton.tag = 200 // ✅ 오른쪽 버튼 태그
        setupButton(rightButton, role: config.rightButtonRole, icon: config.rightButtonIcon, isLeft: false)
        
        // 제목 레이블
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = config.toolbarTitle
        
        // 폰트 설정
        if let fontFamily = config.fontFamily {
            titleLabel.font = UIFont(name: fontFamily, size: CGFloat(config.fontSize))
        } else {
            titleLabel.font = .systemFont(ofSize: CGFloat(config.fontSize), weight: .semibold)
        }
        
        // 제목 색상 설정
        if let titleColor = config.titleTextColor {
            titleLabel.textColor = titleColor
        } else {
            titleLabel.textColor = config.toolbarMode == "dark" ? .white : .black
        }
        
        toolbar.addSubview(leftButton)
        toolbar.addSubview(rightButton)
        toolbar.addSubview(titleLabel)
        
        // 버튼 크기 상수
        let leftButtonSize = CGFloat(config.backButtonIconSize)
        let rightButtonSize = CGFloat(config.closeButtonIconSize)
        
        // === 왼쪽 버튼 마진 계산 ===
        let leftButtonLeftMargin = config.leftButtonVisible ?
            CGFloat(config.backButtonLeftMargin == -1 ? 8 : config.backButtonLeftMargin) : 0
        
        let leftButtonTopMargin = config.leftButtonVisible ?
            CGFloat(config.backButtonTopMargin == -1 ? 0 : config.backButtonTopMargin) : 0
            
        let leftButtonRightMargin = config.leftButtonVisible ?
            CGFloat(config.backButtonRightMargin == -1 ? 0 : config.backButtonRightMargin) : 0
            
        let leftButtonBottomMargin = config.leftButtonVisible ?
            CGFloat(config.backButtonBottomMargin == -1 ? 0 : config.backButtonBottomMargin) : 0
            
        // === 오른쪽 버튼 마진 계산 ===
        let rightButtonLeftMargin = config.rightButtonVisible ?
            CGFloat(config.closeButtonLeftMargin == -1 ? 0 : config.closeButtonLeftMargin) : 0
            
        let rightButtonTopMargin = config.rightButtonVisible ?
            CGFloat(config.closeButtonTopMargin == -1 ? 0 : config.closeButtonTopMargin) : 0
            
        let rightButtonRightMargin = config.rightButtonVisible ?
            CGFloat(-(config.closeButtonRightMargin == -1 ? 8 : config.closeButtonRightMargin)) : 0
            
        let rightButtonBottomMargin = config.rightButtonVisible ?
            CGFloat(config.closeButtonBottomMargin == -1 ? 0 : config.closeButtonBottomMargin) : 0
        
        // 버튼 제약 조건 설정
        var leftButtonConstraints: [NSLayoutConstraint] = []
        var rightButtonConstraints: [NSLayoutConstraint] = []
        
        // === 왼쪽 버튼 제약 조건 ===
        if config.leftButtonVisible {
            leftButtonConstraints = [
                leftButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: leftButtonLeftMargin),
                leftButton.widthAnchor.constraint(equalToConstant: leftButtonSize),
                leftButton.heightAnchor.constraint(equalToConstant: leftButtonSize)
            ]
            
            // 상하 마진이 모두 설정된 경우
            if config.backButtonTopMargin != -1 && config.backButtonBottomMargin != -1 {
                leftButtonConstraints.append(
                    leftButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: leftButtonTopMargin)
                )
            } else if config.backButtonTopMargin != -1 {
                // Top 마진만 설정된 경우
                leftButtonConstraints.append(
                    leftButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: leftButtonTopMargin)
                )
            } else if config.backButtonBottomMargin != -1 {
                // Bottom 마진만 설정된 경우
                leftButtonConstraints.append(
                    leftButton.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -leftButtonBottomMargin)
                )
            } else {
                // 기본: 수직 중앙 정렬
                leftButtonConstraints.append(
                    leftButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
                )
            }
        }
        
        // === 오른쪽 버튼 제약 조건 ===
        if config.rightButtonVisible {
            rightButtonConstraints = [
                rightButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: rightButtonRightMargin),
                rightButton.widthAnchor.constraint(equalToConstant: rightButtonSize),
                rightButton.heightAnchor.constraint(equalToConstant: rightButtonSize)
            ]
            
            // 상하 마진이 모두 설정된 경우
            if config.closeButtonTopMargin != -1 && config.closeButtonBottomMargin != -1 {
                rightButtonConstraints.append(
                    rightButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: rightButtonTopMargin)
                )
            } else if config.closeButtonTopMargin != -1 {
                // Top 마진만 설정된 경우
                rightButtonConstraints.append(
                    rightButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: rightButtonTopMargin)
                )
            } else if config.closeButtonBottomMargin != -1 {
                // Bottom 마진만 설정된 경우
                rightButtonConstraints.append(
                    rightButton.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -rightButtonBottomMargin)
                )
            } else {
                // 기본: 수직 중앙 정렬
                rightButtonConstraints.append(
                    rightButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
                )
            }
        }
        
        // 제약 조건 활성화
        NSLayoutConstraint.activate(leftButtonConstraints + rightButtonConstraints)
        
        // 제목 정렬에 따른 제약 조건 설정
        switch config.titleAlignment {
        case "left":
            let leftMargin = calculateTitleLeftMargin()
            titleLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: CGFloat(leftMargin)).isActive = true
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
            
        case "right":
            let rightMargin = calculateTitleRightMargin()
            titleLabel.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: CGFloat(-rightMargin)).isActive = true
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
            
        default: // center
            titleLabel.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor, constant: CGFloat(config.titleCenterOffset)).isActive = true
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
        }
        
        return toolbar
    }

    // 타이틀 왼쪽 마진 계산 함수 수정
    private func calculateTitleLeftMargin() -> Int {
        if let customMargin = config.titleLeftMargin, customMargin != -1 {
            return customMargin
        }
        
        // 자동 계산: 왼쪽 버튼 영역 고려
        var leftMargin = 16 // 기본 마진
        
        if config.leftButtonVisible && config.leftButtonRole != .none {
            let buttonLeftMargin = config.backButtonLeftMargin == -1 ? 8 : config.backButtonLeftMargin
            let buttonRightMargin = config.backButtonRightMargin == -1 ? 0 : config.backButtonRightMargin
            let buttonSize = config.backButtonIconSize
            
            // 왼쪽 버튼의 실제 오른쪽 끝 위치 계산
            let buttonRightEdge = buttonLeftMargin + buttonSize + buttonRightMargin
            leftMargin = buttonRightEdge + 8 // 버튼 오른쪽 끝 + 간격(8dp)
        }
        
        return leftMargin
    }

    // 타이틀 오른쪽 마진 계산 함수 수정
    private func calculateTitleRightMargin() -> Int {
        if let customMargin = config.titleRightMargin, customMargin != -1 {
            return customMargin
        }
        
        // 자동 계산: 오른쪽 버튼 영역 고려
        var rightMargin = 16 // 기본 마진
        
        if config.rightButtonVisible && config.rightButtonRole != .none {
            let buttonRightMargin = config.closeButtonRightMargin == -1 ? 8 : config.closeButtonRightMargin
            let buttonLeftMargin = config.closeButtonLeftMargin == -1 ? 0 : config.closeButtonLeftMargin
            let buttonSize = config.closeButtonIconSize
            
            // 오른쪽 버튼의 실제 왼쪽 끝까지의 거리 계산
            let buttonLeftEdge = buttonRightMargin + buttonSize + buttonLeftMargin
            rightMargin = buttonLeftEdge + 8 // 버튼 왼쪽 끝 + 간격(8dp)
        }
        
        return rightMargin
    }
    
    // 버튼 설정 함수
    // 버튼 설정 함수에 디버깅 추가
    private func setupButton(_ button: UIButton, role: InAppBrowserConfig.ButtonRole, icon: InAppBrowserConfig.ButtonIcon, isLeft: Bool) {
        
        
        button.removeTarget(nil, action: nil, for: .allEvents)
        
        // 1. 버튼 기능 설정
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
        
        // 2. 버튼 아이콘 설정
        setupButtonIcon(button, icon: icon, role: role)
        
        // 3. 버튼 가시성 설정
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
        switch icon {
        case .auto:
            // 역할에 따라 자동 아이콘
            if role == .back {
                button.setImage(UIImage(systemName: "chevron.left"), for: .normal)
            } else {
                button.setImage(UIImage(systemName: "xmark"), for: .normal)
            }
            button.tintColor = config.toolbarMode == "dark" ? .white : .black
            
        case .back:
            // 항상 뒤로가기 화살표
            button.setImage(UIImage(systemName: "chevron.left"), for: .normal)
            button.tintColor = config.toolbarMode == "dark" ? .white : .black
            
        case .close:
            // 항상 X 아이콘
            button.setImage(UIImage(systemName: "xmark"), for: .normal)
            button.tintColor = config.toolbarMode == "dark" ? .white : .black
            
        case .custom(let imageName):
            // 커스텀 이미지
            if let customImage = UIImage(named: imageName) {
                button.setImage(customImage.withRenderingMode(.alwaysOriginal), for: .normal)
            } else {
                // 폴백: 역할에 따라 기본 아이콘
                setupButtonIcon(button, icon: .auto, role: role)
            }
        }
    }
    
    private func setupWebView() {
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
                
                // 캐시 방지 헤더 추가
                if config.preventCache {
                    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
                    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                    request.setValue("0", forHTTPHeaderField: "Expires")
                }
                
                request.httpShouldHandleCookies = true
                
                let userAgent = generateOptimalUserAgent(for: url)
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                
                webView.load(request)
            }
        }
    }

    // 캐시 버스터 추가 메서드
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
    
    // 최적 User-Agent 생성
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
        case 1: // 수평 프로그레스바
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
            
        case 2: // 사용자 정의 애니메이션 이미지
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
            
        default: // 기본 원형 인디케이터
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
        
        // ✅ 네비게이션 완료 후 상태 확인
        
        
        
        
        
        // ✅ 히스토리 추적
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
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.checkInitialATTStatus()
        }
    }
    // 백 액션 처리 함수 추가
    private func handleBackAction() {
            let currentTime = Date().timeIntervalSince1970
            let currentURL = webView.url?.absoluteString ?? ""
            
            
            
            
            
            
            
            // ✅ 같은 URL에서 5초 내에 3번 이상 뒤로가기 시도하면 강제 종료
            if currentURL == lastBackActionURL && currentTime - lastBackActionTime < 5.0 {
                backActionCount += 1
                
                if backActionCount >= 3 {
                    
                    showBackLoopAlert()
                    return
                }
            } else {
                // 다른 URL이거나 시간이 지났으면 카운트 리셋
                backActionCount = 1
            }
            
            lastBackActionTime = currentTime
            lastBackActionURL = currentURL
            
            switch currentBackAction {
            case .exit:
                
                closeApp()
                
            case .historyBack:
                
                
                // ✅ 특정 페이지에서는 바로 종료 (success, error 페이지 등)
                if shouldForceExitFromCurrentPage(currentURL) {
                    
                    closeApp()
                    return
                }
                
                // ✅ BackList 검사 - 다른 URL이 있는지 확인
                let hasValidBackHistory = checkValidBackHistory()
                
                if hasValidBackHistory {
                    
                    isNavigatingBack = true
                    webView.goBack()
                    
                    // ✅ 3초 후에도 같은 URL이면 강제 종료
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self.checkBackNavigationResult(originalURL: currentURL)
                    }
                } else {
                    
                    closeApp()
                }
                
            case .confirmExit, .ignore:
                
                closeApp()
            }
            
            
        }
        
        // ✅ 특정 페이지에서 강제 종료해야 하는지 확인
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
        
        // ✅ 유효한 뒤로가기 히스토리가 있는지 확인
        private func checkValidBackHistory() -> Bool {
            let currentURL = webView.url?.absoluteString ?? ""
            let backList = webView.backForwardList.backList
            
            
            
            
            
            // BackList에 현재 URL과 다른 URL이 있는지 확인
            for (index, item) in backList.enumerated() {
                let backURL = item.url.absoluteString
                
                
                if backURL != currentURL {
                    
                    return true
                }
            }
            
            
            return false
        }
        
        // ✅ 뒤로가기 실행 후 결과 확인
        private func checkBackNavigationResult(originalURL: String) {
            let currentURL = webView.url?.absoluteString ?? ""
            
            if currentURL == originalURL {
                
                
                
                closeApp()
            } else {
                
                // 성공하면 카운트 리셋
                backActionCount = 0
            }
        }
        
        // ✅ 뒤로가기 루프 감지 시 바로 종료
        private func showBackLoopAlert() {
            
            closeApp()
        }
        
        // ✅ 홈 페이지로 이동 (사용하지 않으므로 제거)
        // private func goToHomePage() { ... }
        
        // ✅ 앱 종료 함수 개선
        private func closeApp() {
            
            
            // 카운트 리셋
            backActionCount = 0
            lastBackActionURL = ""
            
            InAppBrowserManager.shared.notifyBrowserClosed()
            
            DispatchQueue.main.async { [weak self] in
                self?.dismiss(animated: true) {
                    
                }
            }
        }

    // 토스트 메시지 표시 함수 (iOS용)
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
    
    // ✅ 버튼을 아예 새로 만들어서 교체하는 방법
    func updateButtonRoles(leftRole: InAppBrowserConfig.ButtonRole, rightRole: InAppBrowserConfig.ButtonRole, leftIcon: InAppBrowserConfig.ButtonIcon, rightIcon: InAppBrowserConfig.ButtonIcon) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            
            
            // ✅ 기존 버튼들을 완전히 교체
            self.replaceButton(tag: 100, role: leftRole, icon: leftIcon, isLeft: true)
            self.replaceButton(tag: 200, role: rightRole, icon: rightIcon, isLeft: false)
        }
    }
    
    // ✅ 버튼을 완전히 새로 만들어서 교체
    private func replaceButton(tag: Int, role: InAppBrowserConfig.ButtonRole, icon: InAppBrowserConfig.ButtonIcon, isLeft: Bool) {
        // 기존 버튼 찾기
        guard let oldButton = self.view.viewWithTag(tag) as? UIButton,
              let toolbar = oldButton.superview else {
            
            return
        }
        
        
        
        // 기존 버튼의 제약조건들 저장
        let constraints = oldButton.constraints
        let superviewConstraints = toolbar.constraints.filter { constraint in
            constraint.firstItem === oldButton || constraint.secondItem === oldButton
        }
        
        // 기존 버튼 제거
        oldButton.removeFromSuperview()
        
        
        // 새 버튼 생성
        let newButton = UIButton(type: .system)
        newButton.translatesAutoresizingMaskIntoConstraints = false
        newButton.tag = tag
        
        // 새 버튼 설정
        setupButton(newButton, role: role, icon: icon, isLeft: isLeft)
        
        // 툴바에 추가
        toolbar.addSubview(newButton)
        
        // 제약조건 복원
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

    // InAppBrowserViewController.swift - 네비게이션 타이밍 로직 수정
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        
        let urlString = url.absoluteString
        let currentTime = Date().timeIntervalSince1970
        
        
        
        
        
        
        
        
        
        // ✅ 뒤로가기/앞으로가기 감지
        if navigationAction.navigationType == .backForward {
            isNavigatingBack = true
            
            decisionHandler(.allow)
            return
        }
        
        // ✅ 너무 빠른 연속 네비게이션 방지 조건 개선
        let timeSinceLastNavigation = currentTime - lastNavigationTime
        let isInitialLoad = webView.url == nil || webView.url?.absoluteString == "about:blank"
        let isReload = navigationAction.navigationType == .reload
        let isFormSubmission = navigationAction.navigationType == .formSubmitted
        let isOther = navigationAction.navigationType == .other
        
        // ✅ 차단하지 않을 조건들
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
        
        // ✅ 첫 로드나 특별한 경우가 아닐 때만 시간 업데이트
        if !isInitialLoad && !isNavigatingBack {
            lastNavigationTime = currentTime
        }
        
        isNavigatingBack = false
        
        // ✅ 외부 앱에서 돌아온 직후의 중복 로드 방지
        if currentTime - lastExternalAppTime < 2.0 && urlString == pendingExternalURL {
            
            decisionHandler(.cancel)
            pendingExternalURL = nil
            return
        }
        
        // ✅ JavaScript나 about: 스킴은 항상 허용
        if urlString.hasPrefix("about:") || urlString.hasPrefix("javascript:") || urlString.hasPrefix("data:") {
            
            decisionHandler(.allow)
            return
        }
        
        // ✅ 쿠팡 앱 스킴 처리
        if url.scheme == "coupang" || urlString.contains("coupang://") {
            
            handleExternalApp(url: url, appName: "쿠팡", appStoreURL: "https://apps.apple.com/app/id454434967")
            decisionHandler(.cancel)
            return
        }
        
        // ✅ 카카오톡 스킴 처리
        if url.scheme == "kakaolink" || url.scheme == "kakaotalk" || urlString.contains("kakaolink://") || urlString.contains("kakaotalk://") {
            
            handleExternalApp(url: url, appName: "카카오톡", appStoreURL: "https://apps.apple.com/app/id362057947")
            decisionHandler(.cancel)
            return
        }
        
        // ✅ App Store 링크 처리
        if urlString.contains("apps.apple.com") || urlString.contains("itunes.apple.com") {
            
            isMovingToExternalApp = true
            lastExternalAppTime = currentTime
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        
        // ✅ 기타 커스텀 스킴 처리
        if let scheme = url.scheme, !["http", "https", "about", "data", "javascript"].contains(scheme) {
            
            handleExternalApp(url: url, appName: scheme, appStoreURL: nil)
            decisionHandler(.cancel)
            return
        }
        
        // ✅ 도메인 비교
        let currentHost = webView.url?.host?.lowercased()
        let newHost = url.host?.lowercased()
        
        // 현재 URL이 없는 경우 (첫 로드) 허용
        if currentHost == nil {
            
            decisionHandler(.allow)
            return
        }
        
        // ✅ 같은 도메인 또는 서브도메인 체크
        let isSameDomain = checkSameDomain(currentHost: currentHost, newHost: newHost)
        
        if isSameDomain {
            
            decisionHandler(.allow)
            return
        }
        
        // ✅ iframe 내 광고 로드는 허용
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMainFrame {
            
            decisionHandler(.allow)
            return
        }
        
        // ✅ 광고 도메인 처리
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
        
        // ✅ 광고 클릭 처리 (링크 활성화인 경우에만)
        if navigationAction.navigationType == .linkActivated && isAdDomain {
            
            
            isMovingToExternalApp = true
            lastExternalAppTime = currentTime
            pendingExternalURL = urlString
            
            UIApplication.shared.open(url, options: [:]) { success in
                
            }
            
            decisionHandler(.cancel)
            return
        }
        
        // ✅ 일반 외부 도메인 링크 클릭 처리
        if navigationAction.navigationType == .linkActivated {
            
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        
        // ✅ 기타 모든 네비게이션 허용
        decisionHandler(.allow)
    }


    // ✅ 도메인 비교 함수 추가
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
        
        // ✅ 앱 설치 안내 통합 함수
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
    // 카카오톡 앱스토어 열기 함수 추가
    private func openKakaoAppStore() {
        let kakaoAppStoreURL = URL(string: "https://apps.apple.com/app/id362057947")!
        UIApplication.shared.open(kakaoAppStoreURL, options: [:], completionHandler: nil)
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        showLoadingCover()
    }
    
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        hideLoadingCover()
        
        
        // 뒤로가기 중 실패한 경우 처리
        if isNavigatingBack {
            
            isNavigatingBack = false
            closeApp()
        }
    }
    // webView didFinish에서 호출할 함수
    private func checkInitialATTStatus() {
        if #available(iOS 14.5, *) {
            let currentStatus = ATTrackingManager.trackingAuthorizationStatus
            
            switch currentStatus {
            case .authorized:
                let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                notifyWebWithAdId(adId)
                
            case .denied, .restricted:
                notifyWebWithAdId("")
                
            case .notDetermined:
                ATTrackingManager.requestTrackingAuthorization { status in
                    DispatchQueue.main.async {
                        let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                        self.notifyWebWithAdId(adId)
                    }
                }
                
            @unknown default:
                notifyWebWithAdId("")
            }
        } else {
            // iOS 14.5 이전 버전에서는 바로 광고 ID 제공
            let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            notifyWebWithAdId(adId)
        }
    }
    
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            
            guard let url = navigationAction.request.url else {
                return nil
            }
            
            let urlString = url.absoluteString
            
            
            // ✅ 같은 도메인 새 창은 현재 WebView에서 로드 (히스토리 유지)
            let currentHost = webView.url?.host?.lowercased()
            let newHost = url.host?.lowercased()
            
            if checkSameDomain(currentHost: currentHost, newHost: newHost) {
                
                
                // ✅ 새 창 요청도 히스토리에 기록
                if !navigationHistory.contains(urlString) {
                    navigationHistory.append(urlString)
                }
                
                webView.load(URLRequest(url: url))
                return nil
            }
            
            // ✅ 외부 도메인은 외부 브라우저에서 열기
            
            isMovingToExternalApp = true
            lastExternalAppTime = Date().timeIntervalSince1970
            pendingExternalURL = urlString
            
            UIApplication.shared.open(url, options: [:]) { success in
                
            }
            return nil
        }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        hideLoadingCover()
        
        // URL 오류 시 최적화된 URL로 재시도
        if let urlString = config.url, let optimizedURL = URL(string: optimizeURL(urlString)) {
            let request = URLRequest(url: optimizedURL)
            webView.load(request)
        }
    }
    
    // 카카오 지원 스크립트 주입
    private func injectKakaoSupportScript() {
        let kakaoScript = """
        (function() {
            // 카카오 SDK가 로드되었는지 확인
            if (typeof Kakao !== 'undefined') {
                // 기존 카카오 공유 함수를 확장
                const originalSend = Kakao.Share.sendDefault;
                Kakao.Share.sendDefault = function(options) {
                    try {
                        return originalSend.call(this, options);
                    } catch(e) {
                        // 네이티브 앱으로 공유 시도
                        const kakaoLink = 'kakaolink://send?' + encodeURIComponent(JSON.stringify(options));
                        window.location.href = kakaoLink;
                    }
                };
                
                console.log('카카오 공유 기능이 향상되었습니다.');
            }
            
            // 카카오톡 앱 감지 및 설치 유도
            window.checkKakaoTalk = function() {
                return new Promise((resolve) => {
                    const iframe = document.createElement('iframe');
                    iframe.style.display = 'none';
                    iframe.src = 'kakaolink://';
                    document.body.appendChild(iframe);
                    
                    setTimeout(() => {
                        document.body.removeChild(iframe);
                        resolve(false); // 설치되지 않음
                    }, 1000);
                    
                    // 앱이 열리면 이 타이머는 실행되지 않음
                    setTimeout(() => {
                        resolve(true); // 설치됨
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
    // 개발/테스트용 ATT 리셋 함수 (실제 배포에서는 제거 권장)
//    func requestAdidConsentAgain() {
//        if #available(iOS 14.5, *) {
//            // UserDefaults에서 ATT 관련 데이터 삭제 (완전하지 않음)
//            let bundleId = Bundle.main.bundleIdentifier ?? ""
//            UserDefaults.standard.removeObject(forKey: "ATTrackingManagerStatus_\(bundleId)")
//            
//            // 강제로 권한 요청 다시 시도
//            ATTrackingManager.requestTrackingAuthorization { status in
//                DispatchQueue.main.async {
//                    
//                }
//            }
//        }
//    }
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
                
                case "requestAdIdConsent":
                    if let callbackFunction = body["callbackFunction"] as? String {
                        requestATTPermission(callbackFunction: callbackFunction)
                    }
                    
                case "checkAdIdConsentStatus":
                    if let callbackFunction = body["callbackFunction"] as? String {
                        checkATTStatus(callbackFunction: callbackFunction)
                    }
                
                // 백 액션 제어 추가
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
                    
//                case "requestAdidConsentAgain":
//                    requestAdidConsentAgain()
                    
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
    
    // 웹에서 백 액션 설정
    func setBackActionFromWeb(_ actionString: String) {
        switch actionString {
        case "exit", "close":
            currentBackAction = .exit
        case "history-back", "historyBack":
            currentBackAction = .historyBack
        default:
            currentBackAction = .historyBack
        }
        
        
    }
    
    // 웹에서 확인 메시지 설정
    func setBackConfirmMessageFromWeb(_ message: String) {
        backConfirmMessage = message
//        
    }
    
    // 웹에서 확인 타임아웃 설정
    func setBackConfirmTimeoutFromWeb(_ timeout: Double) {
        backConfirmTimeout = timeout
//        
    }
}
// MARK: - Ad Related Functions
extension InAppBrowserViewController {
    private var isShowingAlert: Bool {
        return presentedViewController is UIAlertController
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            
            // 안전장치: 이미 Alert가 표시중이거나 웹뷰가 없으면 즉시 처리
            guard !isShowingAlert,
                  let webView = self.webView,
                  webView == webView,
                  view.window != nil else {
                completionHandler()
                return
            }
            
            // 메인 큐에서 안전하게 처리
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
                
                // ✅ 확인 버튼 - 반드시 completionHandler 호출
                alertController.addAction(UIAlertAction(title: "확인", style: .default) { _ in
                    completionHandler()
                })
                
                // ✅ Alert 표시 시도
                self.present(alertController, animated: true) {
                    // 표시에 실패했다면 completionHandler 호출
                    if alertController.presentingViewController == nil {
                        completionHandler()
                    }
                }
            }
        }
        
        // ✅ JavaScript Confirm 안전하게 표시
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
                
                // ✅ 취소와 확인 버튼
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

        // ✅ JavaScript Prompt 안전하게 표시
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
                
                // ✅ 텍스트 필드 추가
                alertController.addTextField { textField in
                    textField.text = defaultText
                }
                
                // ✅ 취소와 확인 버튼
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
    // ✅ JavaScript alert 처리 - 안전한 버전
//    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
//        
//        // 즉시 완료 처리 - 크래시 방지
//        
//        completionHandler()
//    }
    
//    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
//        
//        // 즉시 true로 완료 처리
//        
//        completionHandler(true)
//    }

//    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
//        
//        // 즉시 기본값으로 완료 처리
//        
//        completionHandler(defaultText ?? "")
//    }
    func updateConfiguration(_ newConfig: InAppBrowserConfig) {
            // ✅ config 자체를 교체
            self.config = newConfig
            
            // 백 액션 설정 업데이트
            self.currentBackAction = newConfig.backAction
            self.backConfirmMessage = newConfig.backConfirmMessage
            self.backConfirmTimeout = newConfig.backConfirmTimeout
            
            // ✅ 버튼 역할 실시간 업데이트
            updateButtonRoles(leftRole: newConfig.leftButtonRole, rightRole: newConfig.rightButtonRole)
            
            
        }
    // 보상형 광고 표시
    func showRewardedAd(adUnit: String, callbackFunction: String) {
        if isLoadingAd { return }
        
        if let currentAd = rewardedAd, currentAdUnitId == adUnit {
            showExistingRewardedAd(callbackFunction: callbackFunction)
        } else {
            loadNewRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
        }
    }
    
    // 전면 광고 표시
    func showInterstitialAd(adUnit: String, callbackFunction: String) {
        if isLoadingAd { return }
        
        if let currentAd = interstitialAd, currentAdUnitId == adUnit {
            showExistingInterstitialAd(callbackFunction: callbackFunction)
        } else {
            loadNewInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
        }
    }
    
    // 보상형 전면 광고 표시
    func showRewardedInterstitialAd(adUnit: String, callbackFunction: String) {
        if isLoadingAd { return }
        
        self.pendingCallbackFunction = callbackFunction
        if let currentAd = rewardedInterstitialAd, currentAdUnitId == adUnit {
            showExistingRewardedInterstitialAd(callbackFunction: callbackFunction)
        } else {
            loadNewRewardedInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
        }
    }
    
    // 기존 보상형 전면 광고 표시
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
    
    // 자동 보상형 전면 광고 표시
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
    
    // 새 보상형 광고 로드
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
    
    // 새 전면 광고 로드
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
    
    // 새 보상형 전면 광고 로드
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
        
    // 기존 보상형 광고 표시
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
        
    // 광고 사용 불가능 처리
    private func handleAdNotAvailable(callbackFunction: String, type: String, adUnit: String, adUnitIndex: Int) {
        webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\"\(type)\", \"failed\", \"\(adUnit)\", \(adUnitIndex));")
    }
        
    // 광고 로드 오류 처리
    private func handleAdLoadError(callbackFunction: String, type: String, adUnit: String, adUnitIndex: Int) {
        webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)(\"\(type)\", \"failed\", \"\(adUnit)\", \(adUnitIndex));")
    }
        
    // 광고 상태 초기화
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
    
    // ATT 상태 확인
    func checkATTStatus(callbackFunction: String) {
        if #available(iOS 14.5, *) {
            let status = ATTrackingManager.trackingAuthorizationStatus
//            handleATTResult(status: status, callbackFunction: callbackFunction)
        } else {
            let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)({status: 'authorized', adId: '\(adId)'});")
        }
    }

    
    // ATT 결과 처리
    @available(iOS 14.5, *)
    private func handleATTResult(status: ATTrackingManager.AuthorizationStatus, callbackFunction: String) {
        var statusString = ""
        var adId = ""
        
        switch status {
        case .authorized:
            statusString = "authorized"
            adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            
        case .denied:
            statusString = "denied"
            adId = ""
            
        case .restricted:
            statusString = "restricted"
            adId = ""
            
        case .notDetermined:
            statusString = "notDetermined"
            adId = ""
            
        @unknown default:
            statusString = "unknown"
            adId = ""
        }
        
        webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)({status: '\(statusString)', adId: '\(adId)'});")
        notifyWebWithAdId(adId)
    }
    
    func requestATTPermission(callbackFunction: String) {
        if #available(iOS 14.5, *) {
            let currentStatus = ATTrackingManager.trackingAuthorizationStatus
            
            // 이미 결정된 상태라면 설정 앱으로 안내
            if currentStatus != .notDetermined {
                // 이미 결정된 경우 현재 상태만 반환
                handleATTResult(status: currentStatus, callbackFunction: callbackFunction)
                return
            }
            
            // 아직 결정되지 않은 경우에만 ATT 팝업 표시
            ATTrackingManager.requestTrackingAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    self?.handleATTResult(status: status, callbackFunction: callbackFunction)
                }
            }
        } else {
            // iOS 14.5 미만에서는 바로 광고 ID 제공
            let adId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)({status: 'authorized', adId: '\(adId)'});")
            notifyWebWithAdId(adId)
        }
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
// InAppBrowserViewController.swift에 추가
extension InAppBrowserViewController {
    // 런타임에 버튼 역할 업데이트
    func updateButtonRoles(leftRole: InAppBrowserConfig.ButtonRole, rightRole: InAppBrowserConfig.ButtonRole) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            
            
            // ✅ 태그로 버튼 찾기
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

// MARK: - WKUIDelegate Functions
extension InAppBrowserViewController {
    
    // 웹페이지에 광고 ID 전달
    func notifyWebWithAdId(_ adId: String) {
        let script = """
        (function() {
            try {
                if (typeof window.onReceiveAdId === 'function') {
                    window.onReceiveAdId('\(adId)');
                    return true;
                }
            } catch(e) {
                console.error('광고 ID 전달 중 오류 발생: ' + e);
                return false;
            }
        })();
        """
        
        webView.evaluateJavaScript(script) { (result, error) in
            if let error = error {
//                
            } else if let success = result as? Bool {
//                
            }
        }
    }
}

// WKWebView JavaScript 실행 확장
extension WKWebView {
    func evaluateJavaScriptSafely(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        DispatchQueue.main.async {
            self.evaluateJavaScript(script, completionHandler: completion)
        }
    }
}
