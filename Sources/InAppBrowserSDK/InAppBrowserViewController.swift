import UIKit
import WebKit
import GoogleMobileAds
import Foundation

class InAppBrowserViewController: UIViewController, WKUIDelegate {
    weak var delegate: InAppBrowserDelegate?
    private var webView: WKWebView!
    private var loadingCover: UIView!
    private var loadingIndicator: UIView! // 로딩 인디케이터 (프로그레스바 또는 이미지)
    private var rewardedAd: RewardedAd?
    private var interstitialAd: InterstitialAd?
    private var rewardedInterstitialAd: RewardedInterstitialAd?
    private var currentAdUnitId: String = ""
    private var isLoadingAd: Bool = false
    private var isRewardEarned: Bool = false
    private var pendingCallbackFunction: String?
    
    private let config: InAppBrowserConfig
    
    private let adLoadTimeoutInterval: TimeInterval = 7.0
    private var adLoadTimer: Timer?
    private var adLoadTimeoutWorkItem: DispatchWorkItem?
    private var isAdRequestTimeOut: Bool = false
    
    private var adUnitIndexCall: Int = 0
    private var adUnitIndexDisplay: Int = 1
    private var lastCallAdUnit: String = ""
    private var callBackAdUnit: String = ""
    
    init(config: InAppBrowserConfig) {
        self.config = config
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
    @objc private func appDidBecomeActive(){
        if webView != nil {
            let script = "window.dispatchEvent(new Event('visibilitychange'));"
            webView.evaluateJavaScript(script, completionHandler:nil)
        }
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    public func closeWebView(){
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.browserDidClose(self)
            self.dismiss(animated: true) {
                // 웹뷰 정리
                self.webView.stopLoading()
                self.webView.configuration.userContentController.removeAllUserScripts()
                self.webView.configuration.userContentController.removeScriptMessageHandler(forName: "iOSInterface")
            }
        }
    }
    private func setupMainLayout() {
        view.backgroundColor = .white
        
        // Setup toolbar
        let toolbar = createToolbar()
        view.addSubview(toolbar)
        
        // Setup WebView
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        let cookieStorage = HTTPCookieStorage.shared
        cookieStorage.cookieAcceptPolicy = .always
        
        userContentController.add(self, name: "iOSInterface")
        config.userContentController = userContentController
        config.allowsInlineMediaPlayback = true
        
        // iOS 14 이하 대응 코드
        if #available(iOS 14.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = []
            
            let preferences = WKWebpagePreferences()
            preferences.allowsContentJavaScript = true
            config.defaultWebpagePreferences = preferences
        } else {
            // iOS 14 이전 버전용 코드
            config.mediaPlaybackRequiresUserAction = false
            config.preferences.javaScriptEnabled = true
        }
        
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        
        let dataStore = WKWebsiteDataStore.default()
        config.websiteDataStore = dataStore
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
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
    
    private func createToolbar() -> UIView {
        let toolbar = UIView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        
        // 툴바 배경색 설정
        if let bgColor = config.toolbarBackgroundColor {
            toolbar.backgroundColor = bgColor
        } else {
            toolbar.backgroundColor = config.toolbarMode == "dark" ? .black : .white
        }
        
        // 뒤로가기 버튼
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        
        if let backIconName = config.backButtonImageName, let image = UIImage(named: backIconName) {
            backButton.setImage(image, for: .normal)
            let originalBackImage = image.withRenderingMode(.alwaysOriginal)
            backButton.setImage(originalBackImage, for: .normal)
        } else {
            // 기본 아이콘
            backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
            backButton.tintColor = config.toolbarMode == "dark" ? .white : .black
        }
        backButton.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        
        // 닫기 버튼
        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        
        if let closeIconName = config.closeButtonImageName, let image = UIImage(named: closeIconName) {
            closeButton.setImage(image, for: .normal)
            let originalCloseImage = image.withRenderingMode(.alwaysOriginal)
            closeButton.setImage(originalCloseImage, for: .normal)
        } else {
            // 기본 아이콘
            closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
            closeButton.tintColor = config.toolbarMode == "dark" ? .white : .black
        }
        closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        
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
        
        toolbar.addSubview(backButton)
        toolbar.addSubview(closeButton)
        toolbar.addSubview(titleLabel)
        
        // 기본 제약 조건 설정
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: CGFloat(config.backButtonLeftMargin)),
            // backButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: 0),
            //backButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 10),
            //backButton.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 0),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: CGFloat(config.backButtonIconSize)),
            backButton.heightAnchor.constraint(equalToConstant: CGFloat(config.backButtonIconSize)),
            
            
            //closeButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 0),
            //closeButton.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 0),
            //closeButton.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 0),
            closeButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: CGFloat(config.closeButtonRightMargin)),
            closeButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: CGFloat(config.closeButtonIconSize)),
            closeButton.heightAnchor.constraint(equalToConstant: CGFloat(config.closeButtonIconSize))
        ])
        
        // 제목 정렬에 따른 제약 조건 설정
        switch config.titleAlignment {
        case "left":
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 16).isActive = true
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
        case "right":
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -16).isActive = true
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
        default: // center
            titleLabel.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor).isActive = true
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
        }
        
        return toolbar
    }
    
    private func setupWebView() {
        if let url = URL(string: config.url ?? "") {
            let websiteDataStore = WKWebsiteDataStore.default()
            let httpCookieStore = websiteDataStore.httpCookieStore
            
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = true
            request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
            webView.load(request)
        }
    }
        
    private func setupLoadingCover() {
            loadingCover = UIView()
            loadingCover.translatesAutoresizingMaskIntoConstraints = false
            
            // 로딩 배경색 설정
            if let loadingBgColor = config.loadingBackgroundColor {
                loadingCover.backgroundColor = loadingBgColor
            } else {
                loadingCover.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            }
            loadingCover.isHidden = true
            
            // 프로그레스바 스타일에 따라 로딩 인디케이터 설정
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
        // 기존 로딩 인디케이터가 있다면 제거
        if loadingIndicator != nil {
            loadingIndicator.removeFromSuperview()
        }
        
        switch config.progressBarStyle {
        case 1: // 수평 프로그레스바
            let progressView = UIProgressView(progressViewStyle: .default)
            progressView.translatesAutoresizingMaskIntoConstraints = false
            
            // 프로그레스바 색상 설정
            if let progressColor = config.progressBarColor {
                progressView.progressTintColor = progressColor
            } else {
                // 기본 색상을 눈에 띄는 색상으로 설정
                progressView.progressTintColor = UIColor(hex: "#FF4081") // 밝은 핑크색
            }
            
            // 배경 트랙 색상 설정 - 약간 투명하게
            progressView.trackTintColor = UIColor.lightGray.withAlphaComponent(0.3)
            
            loadingCover.addSubview(progressView)
            
            NSLayoutConstraint.activate([
                progressView.topAnchor.constraint(equalTo: loadingCover.topAnchor, constant: 4),
                progressView.leadingAnchor.constraint(equalTo: loadingCover.leadingAnchor, constant: 0),
                progressView.trailingAnchor.constraint(equalTo: loadingCover.trailingAnchor, constant: 0),
                progressView.heightAnchor.constraint(equalToConstant: 6) // 높이를 6으로 증가
            ])
            
            // 애니메이션 효과 추가
            progressView.progress = 0.0
            
            // 움직임이 더 확실하게 보이도록 진행 속도 증가
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak progressView] timer in
                guard let progressView = progressView else {
                    timer.invalidate()
                    return
                }
                
                let newProgress = progressView.progress + 0.03 // 더 빠르게 진행
                if newProgress >= 1.0 {
                    // 0으로 바로 돌아가는 대신 애니메이션 없이 리셋 후 다시 시작
                    progressView.progress = 0.0
                } else {
                    // 애니메이션과 함께 진행 업데이트
                    UIView.animate(withDuration: 0.05, animations: {
                        progressView.setProgress(newProgress, animated: true)
                    })
                }
            }
            
            loadingIndicator = progressView
        case 2: // 사용자 정의 애니메이션 이미지
            if let baseImageName = config.progressBarImageName {
                // 애니메이션용 이미지 배열 설정
                var animationImages: [UIImage] = []
                
                // 이미지 이름 형식: "이미지이름_1", "이미지이름_2" 등으로 가정
                for i in 1...8 { // 최대 8개 프레임으로 가정
                    let imageName = "\(baseImageName)_\(i)"
                    if let image = UIImage(named: imageName) {
                        animationImages.append(image)
                    }
                }
                
                // 이미지가 없으면 기본 이미지 하나라도 사용
                if animationImages.isEmpty {
                    if let singleImage = UIImage(named: baseImageName) {
                        // 단일 이미지를 정적으로 표시 (회전 애니메이션 없음)
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
                    // 여러 이미지로 애니메이션 생성
                    let imageView = UIImageView()
                    print("Animation duration: \(config.progressBarAnimationDuration) seconds")
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
        
        // 인디케이터 색상 설정
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
        @objc private func backButtonTapped() {
            if webView.canGoBack {
                webView.goBack()
            }else {
//                dismiss(animated: true)
                // delegate 호출 추가
                delegate?.browserDidClose(self)
                dismiss(animated: true)
            }
        }
        
        @objc private func closeButtonTapped() {
            self.delegate?.browserDidClose(self)
            dismiss(animated: true)
        }
        
        private func showLoadingCover() {
            loadingCover.isHidden = false
            
            // 활동 표시기일 경우 애니메이션 시작
            if let activityIndicator = loadingIndicator as? UIActivityIndicatorView {
                activityIndicator.startAnimating()
            }
        }
        
        private func hideLoadingCover() {
            loadingCover.isHidden = true
            
            // 활동 표시기일 경우 애니메이션 중지
            if let activityIndicator = loadingIndicator as? UIActivityIndicatorView {
                activityIndicator.stopAnimating()
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
        
        // Google 로그인 관련 URL은 허용
        if url.absoluteString.contains("accounts.google.com") ||
           url.absoluteString.contains("oauth2.googleapis.com") {
            decisionHandler(.allow)
            return
        }
        
        // 광고 클릭 시에만 외부 브라우저로 열기 (사용자 액션 확인)
        if navigationAction.navigationType == .linkActivated {
            let currentHost = URL(string: config.url ?? "")?.host
            let newHost = url.host
            
            if currentHost != newHost {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }
        
        // iframe 내에서의 자동 리다이렉트 허용 (MainFrame이 아닌 경우)
        if let isMainFrame = navigationAction.targetFrame?.isMainFrame, !isMainFrame {
            decisionHandler(.allow)
            return
        }
        
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        showLoadingCover()
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideLoadingCover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.requestAdIdConsentAndNotifyWeb()
        }
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
                    
                    // 자동 광고 표시 처리
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
                
                // 광고 ID 관련 새로운 메시지 타입 처리
                case "requestAdIdConsent":
                    if let callbackFunction = body["callbackFunction"] as? String {
                        requestAdIdConsent(callbackFunction: callbackFunction)
                    }
                    
                case "checkAdIdConsentStatus":
                    if let callbackFunction = body["callbackFunction"] as? String {
                        checkAdIdConsentStatus(callbackFunction: callbackFunction)
                    }
                case "requestAdidConsentAgain":
                    // 기존 동의 상태 초기화
                    AdConsentManager.shared.resetConsentStatus()
                    
                    // 웹페이지에 재설정 알림
                    webView.evaluateJavaScript("") { _, _ in
                        // 명시적으로 동의 창 표시 (기존 상태 확인 로직 건너뛰기)
                        let alertController = UIAlertController(
                            title: "광고 ID 수집 동의",
                            message: "더 나은 서비스 제공을 위해 광고 식별자를 수집하는 것에 동의하시겠습니까? 이 정보는 맞춤형 광고 제공에 사용됩니다.",
                            preferredStyle: .alert
                        )
                        
                        let denyAction = UIAlertAction(title: "거부", style: .cancel) { _ in
                            AdConsentManager.shared.setConsentStatus(.denied)
                            self.notifyWebWithAdId("")
                        }
                        
                        let allowAction = UIAlertAction(title: "동의", style: .default) { _ in
                            AdConsentManager.shared.setConsentStatus(.granted)
                            let adId = AdConsentManager.shared.getAdvertisingID() ?? ""
                            self.notifyWebWithAdId(adId)
                        }
                        
                        alertController.addAction(denyAction)
                        alertController.addAction(allowAction)
                        
                        self.present(alertController, animated: true)
                    }
                    
                default:
                    break
                }
            } else {
                if let adUnit = body["adUnit"] as? String,
                   let callbackFunction = body["callbackFunction"] as? String {
                    showRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
                }
                
                // 자동 광고 표시 처리
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

// MARK: - Ad Related Functions
extension InAppBrowserViewController {
    // JavaScript alert 처리
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alertController = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "확인", style: .default) { _ in
                completionHandler()
            })
            present(alertController, animated: true, completion: nil)
        }
        
        // JavaScript confirm 처리
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alertController = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
                completionHandler(false)
            })
            alertController.addAction(UIAlertAction(title: "확인", style: .default) { _ in
                completionHandler(true)
            })
            present(alertController, animated: true, completion: nil)
        }
        
        // JavaScript prompt 처리
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alertController = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alertController.addTextField { textField in
                textField.text = defaultText
            }
            alertController.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
                completionHandler(nil)
            })
            alertController.addAction(UIAlertAction(title: "확인", style: .default) { _ in
                completionHandler(alertController.textFields?.first?.text)
            })
            present(alertController, animated: true, completion: nil)
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
            handleAdNotAvailable(callbackFunction: callbackFunction, type: "rewarded_interstitial",adUnit:currentAdUnitId, adUnitIndex:adUnitIndexCall)
            
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
            // 딜레이 후 광고 표시
            let delay = TimeInterval(delayMs) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.showExistingRewardedInterstitialAd(callbackFunction: callbackFunction)
            }
        } else {
            loadAutoShowRewardedInterstitialAd(adUnit: adUnit, delayMs: delayMs, callbackFunction: callbackFunction)
        }
    }
    private func getNextAdUnitFromList(adUnits: [String], currentIndex: Int) -> String? {
        // 다음 인덱스가 배열 범위 내에 있는지 확인
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
        
        // 기존 타임아웃 작업 취소
        adLoadTimeoutWorkItem?.cancel()
        
        // 세미콜론으로 분리된 광고 단위 처리
        let adUnits = adUnit.components(separatedBy: ";")
        let currentAdUnit = adUnits[adUnitIndexCall].trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 새 타임아웃 작업 생성 (iOS 13 이하 호환)
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            if self.isLoadingAd {
                self.isAdRequestTimeOut = true
                self.hideLoadingCover()
                self.isLoadingAd = false
                        
                self.handleAdLoadError(callbackFunction: callbackFunction, type: "reward", adUnit: currentAdUnit, adUnitIndex: self.adUnitIndexDisplay)
                
                // 타임아웃 시 즉시 중단하고 인덱스 초기화
                self.adUnitIndexCall = 0
                self.adUnitIndexDisplay = 1
            }
        }
        
        // 타임아웃 작업 저장 및 예약
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
                
                // 다음 인덱스 계산
                var currentIndex = 0
                for i in 0..<adUnits.count {
                    if adUnits[i].trimmingCharacters(in: .whitespacesAndNewlines) == currentAdUnit {
                        currentIndex = i
                        self.adUnitIndexDisplay += 1
                        self.adUnitIndexCall += 1
                        break
                    }
                }
                
                // 다음 광고 단위가 있는지 확인
                let nextAdUnit = self.getNextAdUnitFromList(adUnits: adUnits, currentIndex: currentIndex)
                
                if nextAdUnit != nil {
                    // 원래 adUnit 문자열을 그대로 재사용 (내부적으로 인덱스가 변경됨)
                    self.loadNewRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
                } else {
                    // 더 이상 시도할 광고 단위가 없는 경우
                    self.handleAdLoadError(callbackFunction: callbackFunction, type: "reward",adUnit:currentAdUnit,adUnitIndex:adUnitIndexDisplay)
                    
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
        
        // 세미콜론으로 분리된 광고 단위 처리
        let adUnits = adUnit.components(separatedBy: ";")
        let currentAdUnit = adUnits[adUnitIndexCall].trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 새 타임아웃 작업 생성
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            if self.isLoadingAd {
                self.isAdRequestTimeOut = true
                self.hideLoadingCover()
                self.isLoadingAd = false
            
                self.handleAdLoadError(callbackFunction: callbackFunction, type: "interstitial", adUnit: currentAdUnit, adUnitIndex: self.adUnitIndexDisplay)
                
                // 타임아웃 시 즉시 중단하고 인덱스 초기화
                self.adUnitIndexCall = 0
                self.adUnitIndexDisplay = 1
            }
        }
        
        // 타임아웃 작업 저장 및 예약
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
                
                // 다음 인덱스 계산
                var currentIndex = 0
                for i in 0..<adUnits.count {
                    if adUnits[i].trimmingCharacters(in: .whitespacesAndNewlines) == currentAdUnit {
                        currentIndex = i
                        self.adUnitIndexDisplay += 1
                        self.adUnitIndexCall += 1
                        break
                    }
                }
                
                // 다음 광고 단위가 있는지 확인
                let nextAdUnit = self.getNextAdUnitFromList(adUnits: adUnits, currentIndex: currentIndex)
                
                if nextAdUnit != nil {
                    // 원래 adUnit 문자열을 그대로 재사용 (내부적으로 인덱스가 변경됨)
                    self.loadNewInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
                } else {
                    // 더 이상 시도할 광고 단위가 없는 경우
                    self.handleAdLoadError(callbackFunction: callbackFunction, type: "interstitial",adUnit:currentAdUnit,adUnitIndex:adUnitIndexDisplay)
                    
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
        
        // 세미콜론으로 분리된 광고 단위 처리
        let adUnits = adUnit.components(separatedBy: ";")
        let currentAdUnit = adUnits[adUnitIndexCall].trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 새 타임아웃 작업 생성
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            if self.isLoadingAd {
                self.isAdRequestTimeOut = true
                self.hideLoadingCover()
                self.isLoadingAd = false
            
                self.handleAdLoadError(callbackFunction: callbackFunction, type: "rewarded_interstitial", adUnit: currentAdUnit, adUnitIndex: self.adUnitIndexDisplay)
                
                // 타임아웃 시 즉시 중단하고 인덱스 초기화
                self.adUnitIndexCall = 0
                self.adUnitIndexDisplay = 1
            }
        }
        
        // 타임아웃 작업 저장 및 예약
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
                
                // 다음 인덱스 계산
                var currentIndex = 0
                for i in 0..<adUnits.count {
                    if adUnits[i].trimmingCharacters(in: .whitespacesAndNewlines) == currentAdUnit {
                        currentIndex = i
                        self.adUnitIndexDisplay += 1
                        self.adUnitIndexCall += 1
                        break
                    }
                }
                
                // 다음 광고 단위가 있는지 확인
                let nextAdUnit = self.getNextAdUnitFromList(adUnits: adUnits, currentIndex: currentIndex)
                
                if nextAdUnit != nil {
                    // 원래 adUnit 문자열을 그대로 재사용 (내부적으로 인덱스가 변경됨)
                    self.loadNewRewardedInterstitialAd(adUnit: adUnit, callbackFunction: callbackFunction)
                } else {
                    // 더 이상 시도할 광고 단위가 없는 경우
                    self.handleAdLoadError(callbackFunction: callbackFunction, type: "rewarded_interstitial",adUnit:currentAdUnit,adUnitIndex:adUnitIndexDisplay)
                    
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
            handleAdNotAvailable(callbackFunction: callbackFunction, type: "interstitial",adUnit:currentAdUnitId, adUnitIndex:adUnitIndexCall)
            
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
        
        // 세미콜론으로 분리된 광고 단위 처리
        let adUnits = adUnit.components(separatedBy: ";")
        let currentAdUnit = adUnits[adUnitIndexCall].trimmingCharacters(in: .whitespacesAndNewlines)
        
        
        // 타임아웃 타이머 설정
        adLoadTimer = Timer.scheduledTimer(withTimeInterval: adLoadTimeoutInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            if self.isLoadingAd {
                self.isAdRequestTimeOut = true
                self.hideLoadingCover()
                self.isLoadingAd = false
            
                self.handleAdLoadError(callbackFunction: callbackFunction, type: "rewarded_interstitial",adUnit:currentAdUnit,adUnitIndex:adUnitIndexCall)
                
                self.adUnitIndexCall = 0
                self.adUnitIndexDisplay = 1
            }
        }
            RewardedInterstitialAd.load(with: currentAdUnit, request: Request()) { [weak self] ad, error in
                guard let self = self else { return }
                
                self.hideLoadingCover()
                self.isLoadingAd = false
                
                
                if error != nil {
                    
                    // 다음 인덱스 계산
                    var currentIndex = 0
                    for i in 0..<adUnits.count {
                        if adUnits[i].trimmingCharacters(in: .whitespacesAndNewlines) == currentAdUnit {
                            currentIndex = i
                            self.adUnitIndexDisplay += 1
                            self.adUnitIndexCall += 1
                            break
                        }
                    }
                    
                    // 다음 광고 단위가 있는지 확인
                    let nextAdUnit = self.getNextAdUnitFromList(adUnits: adUnits, currentIndex: currentIndex)
                    
                    if nextAdUnit != nil {
                        // 원래 adUnit 문자열을 그대로 재사용 (내부적으로 인덱스가 변경됨)
                        self.loadNewRewardedAd(adUnit: adUnit, callbackFunction: callbackFunction)
                    } else {
                        // 더 이상 시도할 광고 단위가 없는 경우
                        self.handleAdLoadError(callbackFunction: callbackFunction, type: "rewarded_interstitial",adUnit:currentAdUnit,adUnitIndex:adUnitIndexDisplay)
                        
                        self.adUnitIndexCall = 0
                        self.adUnitIndexDisplay = 1
                    }
                    return
                }
                
                self.rewardedInterstitialAd = ad
                self.currentAdUnitId = currentAdUnit
                
                // 딜레이 후 광고 표시
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
                handleAdNotAvailable(callbackFunction: callbackFunction, type: "rewarded",adUnit:currentAdUnitId, adUnitIndex:adUnitIndexCall )
                
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
    
        // 광고 ID 수집 동의 요청 및 처리
        func requestAdIdConsent(callbackFunction: String) {
            let consentStatus = AdConsentManager.shared.getConsentStatus()
            
            // 이미 동의한 경우 바로 결과 반환
            if consentStatus == .granted {
                let adId = AdConsentManager.shared.getAdvertisingID() ?? ""
                webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)({status: 'granted', adId: '\(adId)'});")
                notifyWebWithAdId(adId)
                return
            }
            
            // 동의하지 않았거나 알 수 없는 상태인 경우 동의 요청
            AdConsentManager.shared.requestConsent(from: self) { granted in
                if granted {
                    let adId = AdConsentManager.shared.getAdvertisingID() ?? ""
                    self.webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)({status: 'granted', adId: '\(adId)'});")
                    self.notifyWebWithAdId(adId)
                } else {
                    self.webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)({status: 'denied', adId: ''});")
                    self.notifyWebWithAdId("")
                }
            }
        }
        
        // 광고 ID 수집 동의 상태 초기화 (재요청용)
        func resetAdIdConsent(callbackFunction: String) {
            AdConsentManager.shared.resetConsentStatus()
            webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)({status: 'reset'});")
        }
        
        // 현재 광고 ID 수집 동의 상태 확인
        func checkAdIdConsentStatus(callbackFunction: String) {
            let status = AdConsentManager.shared.getConsentStatus()
            var adId = ""
            
            if status == .granted {
                adId = AdConsentManager.shared.getAdvertisingID() ?? ""
            }
            
            webView.evaluateJavaScriptSafely("javascript:\(callbackFunction)({status: '\(status.rawValue)', adId: '\(adId)'});")
        }
    }

    // MARK: - FullScreenContentDelegate
    extension InAppBrowserViewController: FullScreenContentDelegate {
        func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
            // 광고 유형 식별
            var adType = "reward"
            let adname = currentAdUnitId
            let adnum = adUnitIndexDisplay
            if ad is InterstitialAd {
                adType = "interstitial"
            } else if ad is RewardedInterstitialAd {
                adType = "rewarded_interstitial"
            }
            print(isRewardEarned)
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
            // 광고 유형 식별
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
// MARK: - WKUIDelegate
extension InAppBrowserViewController {
    
    func requestAdIdConsentAndNotifyWeb() {
        if #available(iOS 14.5, *) {
            let consentStatus = AdConsentManager.shared.getConsentStatus()
            
            switch consentStatus {
            case .granted:
                let adId = AdConsentManager.shared.getAdvertisingID() ?? ""
                notifyWebWithAdId(adId)
                
            case .denied:
                notifyWebWithAdId("")
                
            case .unknown:
                AdConsentManager.shared.requestConsent(from: self) { granted in
                    if granted {
                        let adId = AdConsentManager.shared.getAdvertisingID() ?? ""
                        self.notifyWebWithAdId(adId)
                    } else {
                        self.notifyWebWithAdId("")
                    }
                }
            }
        } else {
            // iOS 14.5 이전 버전에서는 동의 없이 광고 ID 사용 가능
            let adId = AdConsentManager.shared.getAdvertisingID() ?? ""
            notifyWebWithAdId(adId)
        }
    }
    func notifyWebWithAdId(_ adId: String) {
        //print("광고 ID 전달 시도: \(adId)")
        
        // 자바스크립트 실행 방식 개선
        let script = """
        (function() {
            try {
                // 1. 함수가 존재하는지 확인
                if (typeof window.onReceiveAdId === 'function') {
                    // 2. 함수 직접 호출
                    window.onReceiveAdId('\(adId)');
                    return true;
                } else {
                    // 3. 함수가 없으면 전역 변수 설정 
                    //window._pendingAdId = '\(adId)';
                    
                    // 4. 함수 정의 및 즉시 호출
                    //window.onReceiveAdId = function(receivedAdId) {
                    //    alert('광고 ID: ' + receivedAdId);
                    //};
                    
                    // 5. 정의된 함수 즉시 호출
                    //window.onReceiveAdId('\(adId)');
                    
                    //return false;
                }
            } catch(e) {
                alert('광고 ID 전달 중 오류 발생: ' + e);
                return false;
            }
        })();
        """
        
        // 중요: 여기에 실행 코드 추가
        webView.evaluateJavaScript(script) { (result, error) in
            if let error = error {
                print("광고 ID 전달 오류: \(error.localizedDescription)")
            } else if let success = result as? Bool {
                print("광고 ID 전달 결과: \(success ? "성공" : "실패")")
            }
        }
    }
}

extension WKWebView {
    func evaluateJavaScriptSafely(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        DispatchQueue.main.async {
            self.evaluateJavaScript(script, completionHandler: completion)
        }
    }
}
