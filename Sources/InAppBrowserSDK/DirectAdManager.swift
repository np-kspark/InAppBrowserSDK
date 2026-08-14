import Foundation
import UIKit
import GoogleMobileAds

public struct DirectAdParticipationStatus: Decodable, Sendable {
    public let participated: Bool
    public let participatedAt: String?
    public let rewardType: String?

    enum CodingKeys: String, CodingKey {
        case participated
        case participatedAt = "participated_at"
        case rewardType     = "reward_type"
    }
}

@MainActor
public final class DirectAdManager {

    @MainActor
    public protocol Listener: AnyObject {
        func onRewardGranted(eventId: String)
        func onDismiss()
        func onFailed(error: String)
    }

    public static let shared = DirectAdManager()
    private init() {}

    private var initialized = false
    private weak var activeViewController: DirectAdViewController?
    private var loaderHelper: AdLoaderHelper?
    private var adLoader: AdLoader?

    public var checkEndpoint = "https://direct.thenextpaper.com/check.php"

    public func initialize() {
        guard !initialized else { return }
        MobileAds.shared.start { _ in
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        initialized = true
    }

    public func showAd(
        from viewController: UIViewController,
        adUnitId: String,
        formatId: String,
        targeting: [String: String]? = nil,
        listener: Listener?
    ) {
        guard initialized else {
            listener?.onFailed(error: "not initialized")
            return
        }

        let helper = AdLoaderHelper(
            formatId: formatId,
            onReceived: { [weak self, weak viewController] ad in
                guard let self, let viewController else {
                    return
                }
                Task { @MainActor in
                    self.adLoader = nil
                    self.present(ad: ad, from: viewController, listener: listener)
                }
            },
            onFailed: { [weak self] error in
                Task { @MainActor in
                    listener?.onFailed(error: error.localizedDescription)
                    self?.loaderHelper = nil
                    self?.adLoader = nil
                }
            }
        )
        loaderHelper = helper

        let loader = AdLoader(
            adUnitID: adUnitId,
            rootViewController: viewController,
            adTypes: [.customNative],
            options: nil
        )
        loader.delegate = helper
        adLoader = loader

        let request = AdManagerRequest()
        if let targeting { request.customTargeting = targeting }
        loader.load(request)
    }

    public func checkParticipation(eventId: String) async throws -> DirectAdParticipationStatus {
        guard var components = URLComponents(string: checkEndpoint) else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "token",    value: getOrCreateToken()),
            URLQueryItem(name: "event_id", value: eventId),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(DirectAdParticipationStatus.self, from: data)
    }

    public func showAdIfNotParticipated(
        from viewController: UIViewController,
        adUnitId: String,
        formatId: String,
        eventId: String,
        targeting: [String: String]? = nil,
        listener: Listener?,
        onAlreadyParticipated: ((DirectAdParticipationStatus) -> Void)? = nil
    ) {
        Task {
            do {
                let status = try await checkParticipation(eventId: eventId)
                if status.participated {
                    onAlreadyParticipated?(status)
                } else {
                    showAd(
                        from: viewController,
                        adUnitId: adUnitId,
                        formatId: formatId,
                        targeting: targeting,
                        listener: listener
                    )
                }
            } catch {
                listener?.onFailed(error: "참여 여부 확인 실패: \(error.localizedDescription)")
            }
        }
    }

    @objc private func appWillEnterForeground() {
        activeViewController?.checkVisitDuration()
    }

    private func present(
        ad: CustomNativeAd,
        from viewController: UIViewController,
        listener: Listener?
    ) {
        let title      = ad.string(forKey: "Direct_Ad_Title") ?? ""
        let headline   = ad.string(forKey: "Direct_Ad_Headline") ?? ""
        let landingUrl = ad.string(forKey: "Direct_Ad_Landing_Url") ?? ""
        let eventId    = ad.string(forKey: "Direct_Event_Id") ?? ""
        let visitStr   = ad.string(forKey: "Direct_Visit_Seconds") ?? ""
        let triggerStr = ad.string(forKey: "Direct_Reward_Trigger") ?? ""
        let isEventStr = ad.string(forKey: "Direct_Is_Event") ?? ""
        let ctaVisit   = ad.string(forKey: "Direct_Cta_Visit_Text") ?? ""
        let ctaEvent   = ad.string(forKey: "Direct_Cta_Event_Text") ?? ""
        let ctaReward  = ad.string(forKey: "Direct_Cta_Reward_Text") ?? ""
        let imgUrl     = ad.image(forKey: "Direct_Ad_Img_Url")?.imageURL?.absoluteString ?? ""

        let visitSec: TimeInterval = {
            let v = Int(visitStr.trimmingCharacters(in: .whitespaces)) ?? 0
            return v > 0 ? TimeInterval(v) : 5.0
        }()

        let trigger: DirectAdViewController.RewardTrigger =
            triggerStr.trimmingCharacters(in: .whitespaces).lowercased() == "true"
                ? .closeButton : .visitDuration
        let isEvent = isEventStr.trimmingCharacters(in: .whitespaces).lowercased() == "true"

        let token    = getOrCreateToken()
        let clickUrl = appendParams(normalizeUrl(landingUrl), token: token, eventId: eventId)

        let config = DirectAdViewController.Config(
            advertiserName: title,
            headline: headline.isEmpty ? title : headline,
            imageUrl: imgUrl,
            clickUrl: clickUrl,
            visitSeconds: visitSec,
            trigger: trigger,
            isEvent: isEvent,
            ctaVisitText: ctaVisit,
            ctaEventText: ctaEvent,
            ctaRewardText: ctaReward,
            eventId: eventId
        )

        let presentingVC = viewController.topMostViewController()
        let adVC = DirectAdViewController(
            config: config,
            trackingAd: ad,
            participationChecker: { [weak self] eventId in
                guard let self else { return false }
                let status = try? await self.checkParticipation(eventId: eventId)
                return status?.participated ?? false
            },
            onRewardGranted: { [weak self] in
                listener?.onRewardGranted(eventId: eventId)
                self?.loaderHelper = nil
                self?.activeViewController = nil
            },
            onDismiss: { [weak self] in
                listener?.onDismiss()
                self?.loaderHelper = nil
                self?.activeViewController = nil
            }
        )
        activeViewController = adVC
        presentingVC.present(adVC, animated: true)
        loaderHelper = nil
    }

    private func getOrCreateToken() -> String {
        let key = "direct_ad_token"
        if let token = UserDefaults.standard.string(forKey: key) { return token }
        let token = UUID().uuidString
        UserDefaults.standard.set(token, forKey: key)
        return token
    }

    private func normalizeUrl(_ url: String) -> String {
        guard !url.isEmpty else { return "" }
        return (url.hasPrefix("http://") || url.hasPrefix("https://")) ? url : "https://\(url)"
    }

    private func appendParams(_ url: String, token: String, eventId: String) -> String {
        guard !url.isEmpty else { return "" }
        let sep = url.contains("?") ? "&" : "?"
        let t = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        let e = eventId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? eventId
        return "\(url)\(sep)token=\(t)&event_id=\(e)"
    }

}

private final class AdLoaderHelper: NSObject, CustomNativeAdLoaderDelegate, AdLoaderDelegate {
    private let formatId: String
    private let onReceived: (CustomNativeAd) -> Void
    private let onFailed: (Error) -> Void

    init(
        formatId: String,
        onReceived: @escaping (CustomNativeAd) -> Void,
        onFailed: @escaping (Error) -> Void
    ) {
        self.formatId   = formatId
        self.onReceived = onReceived
        self.onFailed   = onFailed
    }

    func customNativeAdFormatIDs(for adLoader: AdLoader) -> [String] { [formatId] }

    func adLoader(_ adLoader: AdLoader, didReceive customNativeAd: CustomNativeAd) {
        onReceived(customNativeAd)
    }

    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        onFailed(error)
    }
}

private extension UIViewController {
    func topMostViewController() -> UIViewController {
        if let presented = presentedViewController { return presented.topMostViewController() }
        if let nav = self as? UINavigationController { return nav.visibleViewController?.topMostViewController() ?? self }
        if let tab = self as? UITabBarController { return tab.selectedViewController?.topMostViewController() ?? self }
        return self
    }
}
