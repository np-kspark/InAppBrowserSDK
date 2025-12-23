import Foundation
import AdSupport
import UIKit

@MainActor
public class AdConsentManager {
    public static let shared = AdConsentManager()
    
    private let userDefaultsKey = "ad_id_consent_status"
    
    public enum ConsentStatus: String {
        case unknown = "unknown"
        case granted = "granted"
        case denied = "denied"
    }
    
    private init() {}
    
    public func getConsentStatus() -> ConsentStatus {
        let status = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ConsentStatus.unknown.rawValue
        return ConsentStatus(rawValue: status) ?? .unknown
    }
    
    public func setConsentStatus(_ status: ConsentStatus) {
        UserDefaults.standard.set(status.rawValue, forKey: userDefaultsKey)
    }
    
    public func getAdvertisingID() -> String? {
        if getConsentStatus() == .granted {
            return ASIdentifierManager.shared().advertisingIdentifier.uuidString
        }
        return nil
    }
    
    public func requestConsent(from viewController: UIViewController, completion: @escaping (Bool) -> Void) {

        showCustomConsentDialog(from: viewController, completion: completion)
    }
    

    private func showCustomConsentDialog(from viewController: UIViewController, completion: @escaping (Bool) -> Void) {
        let alertController = UIAlertController(
            title: "광고 ID 수집 동의",
            message: "더 나은 서비스 제공을 위해 광고 식별자를 수집하는 것에 동의하시겠습니까? 이 정보는 맞춤형 광고 제공에 사용됩니다.",
            preferredStyle: .alert
        )
        
        let denyAction = UIAlertAction(title: "거부", style: .cancel) { _ in
            self.setConsentStatus(.denied)
            completion(false)
        }
        
        let allowAction = UIAlertAction(title: "동의", style: .default) { _ in
            self.setConsentStatus(.granted)
            completion(true)
        }
        
        alertController.addAction(denyAction)
        alertController.addAction(allowAction)
        
        viewController.present(alertController, animated: true)
    }
    
    public func resetConsentStatus() {
        setConsentStatus(.unknown)
    }
}
