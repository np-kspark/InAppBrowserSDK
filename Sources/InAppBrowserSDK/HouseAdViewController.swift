import UIKit
import WebKit

/**
 Android `HouseAdDialog.java` 의 iOS 대응 구현체.

 지원 광고 유형:
  - `.html`    : 외부 네트워크 배너 등 서드파티 HTML 소재 (`HouseAdData.fromHtml`)
  - `.youtube` : YouTube 영상 ID 또는 URL (`HouseAdData.fromYouTube`)

 사용 예시:
 ```swift
 let data = HouseAdViewController.HouseAdData.fromHtml(htmlString)
 let vc = HouseAdViewController(
     data: data,
     requiredVisitSeconds: 7,
     rewardTrigger: .visitDuration,
     onRewardGranted: { },
     onDismiss: { }
 )
 vc.setTitleText("쿠팡 특가 이벤트")
 present(vc, animated: true)
 ```

 체류 시간 체크:
 앱이 포그라운드로 돌아올 때 `checkVisitDuration()` 이 호출되어야 한다.
 `HouseAdManager` 를 통해 띄우면 자동으로 연결된다.
 */
public final class HouseAdViewController: UIViewController {

    // MARK: - 데이터 모델

    public enum AdType {
        case html
        case youtube
    }

    public enum RewardTrigger {
        case visitDuration
        case closeButton
    }

    public struct HouseAdData {
        public let type: AdType
        public let htmlString: String
        public let youtubeVideoId: String

        private init(type: AdType, html: String, videoId: String) {
            self.type = type
            self.htmlString = html
            self.youtubeVideoId = videoId
        }

        /// 서드파티 HTML 소재로 광고 데이터 생성
        public static func fromHtml(_ html: String) -> HouseAdData {
            HouseAdData(type: .html, html: html, videoId: "")
        }

        /// YouTube 영상 ID 또는 URL 로 광고 데이터 생성.
        /// 지원 형식: watch?v= / youtu.be/ / embed/ / shorts/ / 11자리 ID
        public static func fromYouTube(_ input: String) -> HouseAdData {
            HouseAdData(type: .youtube, html: "", videoId: extractYouTubeId(input))
        }

        static func extractYouTubeId(_ input: String) -> String {
            guard !input.isEmpty else { return "" }
            if input.count == 11, !input.contains("/"), !input.contains(".") { return input }

            guard let url = URL(string: input), let host = url.host else { return input }
            let path = url.path

            if host.contains("youtu.be") {
                return String(path.dropFirst())            // "/VIDEO_ID"
            }
            if path.hasPrefix("/embed/") {
                return String(path.dropFirst("/embed/".count))
            }
            if path.hasPrefix("/shorts/") {
                return String(path.dropFirst("/shorts/".count))
            }
            if let items = URLComponents(string: input)?.queryItems,
               let v = items.first(where: { $0.name == "v" })?.value {
                return v
            }
            return input
        }
    }

    // MARK: - 색상

    private enum C {
        static let accent  = UIColor(red: 26/255.0, green: 51/255.0, blue: 128/255.0, alpha: 1)
        static let divider = UIColor(white: 0.83, alpha: 1)
        static let dismiss = UIColor(white: 0.5, alpha: 1)
    }

    // MARK: - 상태

    private let data: HouseAdData
    private let rewardTrigger: RewardTrigger
    private let onRewardGranted: () -> Void
    private let onDismissed: () -> Void

    private var remainingTime: TimeInterval
    private var clickTime: Date?
    private var isWaitingForReturn = false
    private var hasReportedClick = false

    private var dialogTitle = "즉시 보상 당첨!"

    // MARK: - UI

    private var adWebView: WKWebView!
    private var titleLabel: UILabel!
    private var remainingLabel: UILabel?

    // MARK: - Init

    public init(
        data: HouseAdData,
        requiredVisitSeconds: TimeInterval = 5,
        rewardTrigger: RewardTrigger = .visitDuration,
        onRewardGranted: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.data            = data
        self.remainingTime   = requiredVisitSeconds
        self.rewardTrigger   = rewardTrigger
        self.onRewardGranted = onRewardGranted
        self.onDismissed     = onDismiss
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle   = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        adWebView?.stopLoading()
        adWebView?.navigationDelegate = nil
        adWebView?.uiDelegate = nil
    }

    /// 상단 타이틀 변경. `present` 전후 모두 호출 가능.
    @discardableResult
    public func setTitleText(_ text: String) -> Self {
        dialogTitle = text
        titleLabel?.text = text
        return self
    }

    // MARK: - 레이아웃

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        buildLayout()
        loadAdContent()
    }

    private func buildLayout() {
        // 카드
        let card = UIView()
        card.backgroundColor = .white
        card.layer.cornerRadius = 16
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        // 타이틀
        titleLabel = UILabel()
        titleLabel.text = dialogTitle
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = .black
        titleLabel.textAlignment = .center
        let titleWrap = wrap(titleLabel, insets: .init(top: 16, left: 16, bottom: 16, right: 16))
        stack.addArrangedSubview(titleWrap)

        stack.addArrangedSubview(makeDivider())

        // 광고 WebView (300x250 소재 + 안내 문구가 잘리지 않는 높이)
        adWebView = makeAdWebView()
        adWebView.translatesAutoresizingMaskIntoConstraints = false
        adWebView.heightAnchor.constraint(equalToConstant: 310).isActive = true
        stack.addArrangedSubview(adWebView)

        stack.addArrangedSubview(makeDivider())

        if rewardTrigger == .closeButton {
            stack.addArrangedSubview(makeCloseButtonArea())
        } else {
            stack.addArrangedSubview(makeVisitInfoArea())
            stack.addArrangedSubview(makeDivider())
            stack.addArrangedSubview(makeGiveUpButton())
        }
    }

    private func makeCloseButtonArea() -> UIView {
        let btn = UIButton(type: .system)
        btn.setTitle("닫기", for: .normal)
        btn.titleLabel?.font = .boldSystemFont(ofSize: 16)
        btn.setTitleColor(.white, for: .normal)
        btn.backgroundColor = C.accent
        btn.layer.cornerRadius = 8
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 52).isActive = true
        btn.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        return wrap(btn, insets: .init(top: 12, left: 16, bottom: 12, right: 16))
    }

    private func makeVisitInfoArea() -> UIView {
        let verb = (data.type == .youtube) ? "영상 클릭하고 YouTube에서" : "배너 클릭하고 새창에서"
        let secs = max(1, Int(remainingTime))

        let line1 = UILabel()
        line1.text = verb
        line1.font = .boldSystemFont(ofSize: 15)
        line1.textColor = C.accent
        line1.textAlignment = .center

        let line2 = UILabel()
        line2.text = "\(secs)초 이상 머물고 보상받기"
        line2.font = .systemFont(ofSize: 13)
        line2.textColor = C.accent.withAlphaComponent(0.9)
        line2.textAlignment = .center
        remainingLabel = line2

        let v = UIStackView(arrangedSubviews: [line1, line2])
        v.axis = .vertical
        v.alignment = .center
        v.spacing = 2
        return wrap(v, insets: .init(top: 12, left: 16, bottom: 12, right: 16))
    }

    private func makeGiveUpButton() -> UIView {
        let btn = UIButton(type: .system)
        btn.setTitle("보상 포기하기", for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14)
        btn.setTitleColor(C.dismiss, for: .normal)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 48).isActive = true
        btn.addTarget(self, action: #selector(giveUpTapped), for: .touchUpInside)
        return btn
    }

    private func makeDivider() -> UIView {
        let v = UIView()
        v.backgroundColor = C.divider
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func wrap(_ child: UIView, insets: UIEdgeInsets) -> UIView {
        let container = UIView()
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom)
        ])
        return container
    }

    // MARK: - WebView

    private func makeAdWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        return wv
    }

    private func loadAdContent() {
        switch data.type {
        case .html:
            // 소재가 보낸 HTML 원문을 그대로 렌더링한다.
            // 상대 경로 해석을 위해 baseURL 을 지정한다.
            adWebView.loadHTMLString(
                Self.wrapHtmlCreative(data.htmlString),
                baseURL: URL(string: "https://nextpaper.co.kr")
            )
        case .youtube:
            // YouTube embed 는 WebView 내 재생이 차단되므로
            // 썸네일 + 재생버튼을 띄우고 탭하면 외부 앱으로 이동시킨다.
            adWebView.loadHTMLString(
                Self.youtubeThumbnailHtml(videoId: data.youtubeVideoId),
                baseURL: URL(string: "https://www.youtube.com")
            )
        }
    }

    /// 소재에 viewport 가 없으면 기기 폭 기준으로 렌더링되도록 감싼다.
    /// 없을 경우 WKWebView 가 980px 폭으로 레이아웃한 뒤 축소해 소재가 1/3 크기로 보인다.
    static func wrapHtmlCreative(_ html: String) -> String {
        let lower = html.lowercased()
        if lower.contains("name=\"viewport\"") || lower.contains("name='viewport'") {
            return html
        }
        return """
        <!DOCTYPE html><html><head>
        <meta charset='utf-8'>
        <meta name='viewport' content='width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no'>
        <style>html,body{margin:0;padding:0;width:100%;height:100%;}</style>
        </head><body>\(html)</body></html>
        """
    }

    static func youtubeThumbnailHtml(videoId: String) -> String {
        let thumb = "https://img.youtube.com/vi/\(videoId)/hqdefault.jpg"
        let watch = "https://www.youtube.com/watch?v=\(videoId)"
        return """
        <!DOCTYPE html><html><head>
        <meta name='viewport' content='width=device-width,initial-scale=1.0,maximum-scale=1.0'>
        <style>
          *{margin:0;padding:0;box-sizing:border-box}
          html,body{width:100%;height:100%;background:#000}
          a{display:block;width:100%;height:100%;position:relative;text-decoration:none}
          img{width:100%;height:100%;object-fit:cover;display:block}
          .play{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);
                width:64px;height:44px;background:rgba(255,0,0,0.88);border-radius:10px;
                display:flex;align-items:center;justify-content:center}
          .play::after{content:'';margin-left:5px;border-style:solid;
                border-width:9px 0 9px 15px;border-color:transparent transparent transparent #fff}
        </style></head>
        <body><a href='\(watch)'><img src='\(thumb)' alt=''><div class='play'></div></a></body>
        </html>
        """
    }

    // MARK: - 내부/외부 URL 판정

    /// 다이얼로그 WebView 안에서 그대로 로드할 URL 인지 판정.
    /// 광고 인프라 리소스는 내부 유지, 그 외 네비게이션은 외부로 내보낸다.
    private func isInternalUrl(_ url: String) -> Bool {
        let adDomains = ["doubleclick.net", "googlesyndication.com",
                         "googletagmanager.com", "googletagservices.com"]
        for d in adDomains where url.contains(d) { return true }

        switch data.type {
        case .html:
            // HTML 소재는 리소스 로드만 허용하고 링크 이동은 외부로 보낸다.
            return false
        case .youtube:
            if url.contains("youtube.com/watch") || url.contains("youtu.be/")
                || url.contains("m.youtube.com/watch") || url.contains("youtube.com/shorts") {
                return false
            }
            return url.contains("youtube.com") || url.contains("ytimg.com")
                || url.contains("googlevideo.com") || url.contains("ggpht.com")
        }
    }

    /// Google 광고 추적 래퍼 URL 에서 최종 목적지를 추출한다.
    /// doubleclick.net?adurl=https://example.com → https://example.com
    private func unwrapAdClickUrl(_ url: String) -> String {
        guard url.contains("doubleclick.net")
                || url.contains("googleadservices.com")
                || url.contains("google.com/aclk") else { return url }

        guard let items = URLComponents(string: url)?.queryItems else { return url }
        for key in ["adurl", "u", "url"] {
            if let dest = items.first(where: { $0.name == key })?.value,
               dest.hasPrefix("http") {
                return dest
            }
        }
        return url
    }

    // MARK: - 외부 이동 & 체류 시간

    private func openExternalUrl(_ urlString: String) {
        guard !hasReportedClick else { return }       // 중복 클릭 방지

        var s = unwrapAdClickUrl(urlString)
        guard !s.isEmpty else { return }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://\(s)" }
        guard let url = URL(string: s) else { return }

        hasReportedClick   = true
        clickTime          = Date()
        isWaitingForReturn = true

        UIApplication.shared.open(url) { [weak self] success in
            guard let self, !success else { return }
            // 열 수 있는 앱/브라우저가 없으면 클릭 상태를 되돌린다
            self.hasReportedClick   = false
            self.isWaitingForReturn = false
            self.clickTime          = nil
        }

        // 3초 후 재클릭 허용
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { self?.hasReportedClick = false }
        }
    }

    /**
     광고 클릭 후 앱으로 복귀했을 때 체류 시간을 검사한다.

     앱이 포그라운드로 돌아오는 시점에 호출해야 한다.
     `HouseAdManager` 를 통해 띄웠다면 자동으로 호출된다.
     */
    public func checkVisitDuration() {
        guard isWaitingForReturn, let clickTime else { return }

        let elapsed = Date().timeIntervalSince(clickTime)
        self.clickTime     = nil
        isWaitingForReturn = false
        hasReportedClick   = false

        if rewardTrigger == .closeButton { return }

        remainingTime = max(0, remainingTime - elapsed)

        if remainingTime <= 0 {
            finish(rewarded: true)
        } else {
            let secs = max(1, Int(ceil(remainingTime)))
            remainingLabel?.text = "\(secs)초 더 머물고 보상받기"
            showVisitTooShortAlert(remainingSec: secs)
        }
    }

    // MARK: - 액션

    @objc private func closeButtonTapped() {
        finish(rewarded: true)
    }

    @objc private func giveUpTapped() {
        let alert = UIAlertController(
            title: "보상 포기",
            message: "보상을 받을 수 없습니다.\n포기하시겠습니까?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "계속하기", style: .cancel))
        alert.addAction(UIAlertAction(title: "포기하기", style: .destructive) { [weak self] _ in
            self?.finish(rewarded: false)
        })
        present(alert, animated: true)
    }

    private func showVisitTooShortAlert(remainingSec: Int) {
        let alert = UIAlertController(
            title: "안내",
            message: "아직 \(remainingSec)초 더 머물러야 합니다.\n배너를 다시 클릭해 주세요.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "확인", style: .default))
        present(alert, animated: true)
    }

    private func finish(rewarded: Bool) {
        adWebView?.stopLoading()
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            rewarded ? self.onRewardGranted() : self.onDismissed()
        }
    }
}

// MARK: - WKNavigationDelegate

extension HouseAdViewController: WKNavigationDelegate {

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url?.absoluteString else {
            decisionHandler(.allow); return
        }

        // ① 서브프레임(iframe 등) 로드는 그대로 허용 — 소재 렌더링에 필요하다
        if let target = navigationAction.targetFrame, !target.isMainFrame {
            decisionHandler(.allow); return
        }

        // ② 최초 HTML 주입 / 내부 스킴은 허용
        if url.hasPrefix("about:") || url.hasPrefix("data:") {
            decisionHandler(.allow); return
        }

        // ③ 광고 인프라 리소스(YouTube 썸네일 등)는 내부 유지
        if isInternalUrl(url) {
            decisionHandler(.allow); return
        }

        // ④ 나머지 메인 프레임 이동 / 새 창 요청 → 외부 브라우저로
        //    doubleclick 추적 URL 도 여기서 unwrap 되어 열린다
        openExternalUrl(url)
        decisionHandler(.cancel)
    }
}

// MARK: - WKUIDelegate

extension HouseAdViewController: WKUIDelegate {

    /// `window.open()` / `target="_blank"` 대응 — 새 창 요청을 외부 이동으로 바꾼다.
    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url?.absoluteString, !url.isEmpty {
            openExternalUrl(url)
        }
        return nil
    }
}
