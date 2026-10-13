import UIKit
import WebKit

/**
 Android `InAppBrowserManager.loadHouseAdData()` 의 iOS 대응 구현체.

 동작 구조
 ```
 loadHouseAdData(adUnitId:targeting:listener:)
       │
       ├─ 화면 밖 WKWebView 생성 (사용자에게 보이지 않음)
       │     └─ gpt.js 로 광고 슬롯 렌더링
       │          └─ 소재가 window.parent.postMessage({ type:'updateDiv', ... })
       │
       ├─ onHouseAdData(adType:content:)   ← 웹뷰 즉시 파괴
       │
       └─ HouseAdViewController 표시
 ```

 소재가 10초 안에 `postMessage` 를 보내지 않으면 `onHouseAdFailed()` 로 끝난다.
 */
@MainActor
public final class HouseAdManager: NSObject {

    // MARK: - Listener

    @MainActor
    public protocol HouseAdDataListener: AnyObject {
        /// - Parameters:
        ///   - adType: 소재가 보낸 `adType` ("html" / "youtube" / 그 외)
        ///   - content: postMessage payload 전체 JSON 문자열
        func onHouseAdData(adType: String, content: String)
        func onHouseAdFailed()
    }

    @MainActor
    public protocol HouseAdShowListener: AnyObject {
        func onRewardGranted()
        func onDismiss()
        func onFailed(error: String)
    }

    // MARK: - Singleton

    public static let shared = HouseAdManager()
    private override init() { super.init() }

    /// 소재 렌더링 타임아웃(초). 이 시간 안에 postMessage 가 없으면 실패 처리한다.
    public var loadTimeout: TimeInterval = 10

    private var initialized = false
    private var dataWebView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private weak var dataListener: (any HouseAdDataListener)?
    private weak var activeViewController: HouseAdViewController?
    private var handled = false

    private static let bridgeName = "houseAdBridge"

    // MARK: - 초기화

    /// 앱 시작 시 1회 호출. 포그라운드 복귀 감지를 등록한다.
    public func initialize() {
        guard !initialized else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        initialized = true
    }

    @objc private func appWillEnterForeground() {
        Task { @MainActor in
            activeViewController?.checkVisitDuration()
        }
    }

    // MARK: - 소재 데이터 요청

    /**
     GAM 광고 단위에서 소재 데이터를 가져온다.

     - Parameters:
        - viewController: 화면 밖 웹뷰를 붙일 기준 뷰컨트롤러
        - adUnitId: `/네트워크코드/광고단위`
        - targeting: 키-값 타게팅. 없으면 nil
        - listener: 수신 콜백
     */
    @MainActor
    public func loadHouseAdData(
        from viewController: UIViewController,
        adUnitId: String,
        targeting: [String: String]? = nil,
        listener: (any HouseAdDataListener)?
    ) {
        destroyDataWebView()

        handled      = false
        dataListener = listener

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()
        config.userContentController.add(self, name: Self.bridgeName)

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), configuration: config)
        wv.navigationDelegate = self
        wv.isHidden = false                 // 렌더링이 되어야 postMessage 가 발화된다
        wv.alpha = 0.01                     // 화면 밖 + 거의 투명

        // 화면 밖에 배치 (Android 의 leftMargin/topMargin = -10000 대응)
        wv.frame.origin = CGPoint(x: -10000, y: -10000)
        viewController.view.addSubview(wv)
        dataWebView = wv

        wv.loadHTMLString(
            Self.buildHouseAdHtml(adUnitId: adUnitId, targeting: targeting),
            baseURL: URL(string: "https://nextpaper.co.kr")
        )

        timeoutTask?.cancel()
        let seconds = loadTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.fail() }
        }
    }

    /// 소재 데이터 요청 + 표시를 한 번에 처리하는 간편 API.
    @MainActor
    public func showHouseAd(
        from viewController: UIViewController,
        adUnitId: String,
        targeting: [String: String]? = nil,
        listener: (any HouseAdShowListener)?
    ) {
        let bridge = ShowBridge(manager: self, viewController: viewController, listener: listener)
        showBridge = bridge
        loadHouseAdData(from: viewController, adUnitId: adUnitId, targeting: targeting, listener: bridge)
    }

    private var showBridge: ShowBridge?

    // MARK: - 표시

    /**
     수신한 소재 데이터로 광고 다이얼로그를 띄운다.

     `adType` 이 `"youtube"` 면 YouTube, 그 외에는 `html` 필드를 HTML 소재로 처리한다.
     - Returns: 표시 성공 여부. 처리할 수 없는 소재면 false
     */
    @MainActor
    @discardableResult
    public func present(
        from viewController: UIViewController,
        adType: String,
        content: String,
        onRewardGranted: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any] else {
            return false
        }

        let visitSec = TimeInterval((json["visitSeconds"] as? Int) ?? 5)
        let data: HouseAdViewController.HouseAdData

        if adType.lowercased() == "youtube" {
            let url = (json["url"] as? String) ?? ""
            guard !url.isEmpty else { return false }
            data = .fromYouTube(url)
        } else {
            let html = (json["html"] as? String) ?? ""
            guard !html.isEmpty else { return false }
            data = .fromHtml(html)
        }

        let vc = HouseAdViewController(
            data: data,
            requiredVisitSeconds: max(1, visitSec),
            rewardTrigger: .visitDuration,
            onRewardGranted: { [weak self] in
                self?.activeViewController = nil
                onRewardGranted()
            },
            onDismiss: { [weak self] in
                self?.activeViewController = nil
                onDismiss()
            }
        )

        if let title = json["title"] as? String, !title.isEmpty {
            vc.setTitleText(title)
        }

        activeViewController = vc
        viewController.topMostViewController().present(vc, animated: true)
        return true
    }

    /// 포그라운드 복귀 시 체류 시간 검사. `initialize()` 를 호출했다면 자동으로 처리된다.
    @MainActor
    public func checkVisitDuration() {
        activeViewController?.checkVisitDuration()
    }

    // MARK: - 내부

    @MainActor
    private func fail() {
        guard !handled else { return }
        handled = true
        timeoutTask?.cancel()
        let l = dataListener
        destroyDataWebView()
        l?.onHouseAdFailed()
    }

    @MainActor
    private func destroyDataWebView() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let wv = dataWebView {
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
            wv.removeFromSuperview()
        }
        dataWebView = nil
    }

    // MARK: - GPT 페이지

    static func buildHouseAdHtml(adUnitId: String, targeting: [String: String]?) -> String {
        var targetingScript = ""
        if let targeting, !targeting.isEmpty {
            for (k, v) in targeting {
                let ek = k.replacingOccurrences(of: "'", with: "\\'")
                let ev = v.replacingOccurrences(of: "'", with: "\\'")
                targetingScript += "slot.setTargeting('\(ek)','\(ev)');"
            }
        }

        return """
        <!DOCTYPE html><html><head>
        <script async src='https://securepubads.g.doubleclick.net/tag/js/gpt.js'></script>
        <script>
        var _handled=false;
        function _send(type, payload){
          if(_handled) return; _handled=true;
          window.webkit.messageHandlers.\(bridgeName).postMessage({ event:'data', adType:type, content:payload });
        }
        function fail(){
          if(_handled) return; _handled=true;
          window.webkit.messageHandlers.\(bridgeName).postMessage({ event:'failed' });
        }
        window.googletag = window.googletag || {cmd: []};
        googletag.cmd.push(function(){
          window.removeEventListener('message', _msgHandler);
          window.addEventListener('message', _msgHandler);
          var slot = googletag.defineSlot('\(adUnitId)', [[300,300]], 'ad-slot');
          \(targetingScript)
          slot.addService(googletag.pubads());
          googletag.pubads().enableSingleRequest();
          googletag.pubads().addEventListener('slotRenderEnded', function(e){
            if (e.isEmpty) fail();
          });
          googletag.enableServices();
          googletag.display('ad-slot');
        });
        function _msgHandler(e){
          try{
            var d = (typeof e.data === 'string') ? JSON.parse(e.data) : e.data;
            if (d && d.type === 'updateDiv') {
              _send(d.adType || 'direct', JSON.stringify(d));
            }
          }catch(ex){}
        }
        </script></head>
        <body style='margin:0;padding:0'>
        <div id='ad-slot' style='width:300px;height:300px'></div>
        </body></html>
        """
    }
}

// MARK: - WKScriptMessageHandler

extension HouseAdManager: WKScriptMessageHandler {

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        guard message.name == Self.bridgeName,
              let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }

        Task { @MainActor in
            switch event {
            case "data":
                guard !self.handled else { return }
                self.handled = true
                self.timeoutTask?.cancel()

                let adType  = (body["adType"] as? String) ?? "direct"
                let content = (body["content"] as? String) ?? "{}"
                let l = self.dataListener
                self.destroyDataWebView()
                l?.onHouseAdData(adType: adType, content: content)

            case "failed":
                self.fail()

            default:
                break
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension HouseAdManager: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.fail() }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.fail() }
    }
}

// MARK: - showHouseAd 용 내부 브리지

private final class ShowBridge: HouseAdManager.HouseAdDataListener {
    private unowned let manager: HouseAdManager
    private weak var viewController: UIViewController?
    private weak var listener: (any HouseAdManager.HouseAdShowListener)?

    init(manager: HouseAdManager,
         viewController: UIViewController,
         listener: (any HouseAdManager.HouseAdShowListener)?) {
        self.manager = manager
        self.viewController = viewController
        self.listener = listener
    }

    @MainActor
    func onHouseAdData(adType: String, content: String) {
        guard let vc = viewController else { return }
        let ok = manager.present(
            from: vc,
            adType: adType,
            content: content,
            onRewardGranted: { [weak self] in self?.listener?.onRewardGranted() },
            onDismiss:       { [weak self] in self?.listener?.onDismiss() }
        )
        if !ok { listener?.onFailed(error: "unsupported creative (adType=\(adType))") }
    }

    @MainActor
    func onHouseAdFailed() {
        listener?.onFailed(error: "no fill")
    }
}

// MARK: - UIViewController 유틸
// DirectAdManager.swift 에도 동명 private extension 이 있으므로 파일 스코프로 제한한다.

private extension UIViewController {
    func topMostViewController() -> UIViewController {
        if let presented = presentedViewController {
            return presented.topMostViewController()
        }
        if let nav = self as? UINavigationController, let visible = nav.visibleViewController {
            return visible.topMostViewController()
        }
        if let tab = self as? UITabBarController, let selected = tab.selectedViewController {
            return selected.topMostViewController()
        }
        return self
    }
}
