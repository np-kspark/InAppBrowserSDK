import Foundation
import AdSupport
import UIKit

public class AdConsentManager {
    public static let shared = AdConsentManager()
    
    private let userDefaultsKey = "ad_id_consent_status"
    
    public enum ConsentStatus: String {
        case unknown = "unknown"
        case granted = "granted"
        case denied = "denied"
    }
    
    private init() {}
    
    // 사용자 동의 상태 확인
    public func getConsentStatus() -> ConsentStatus {
        let status = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ConsentStatus.unknown.rawValue
        return ConsentStatus(rawValue: status) ?? .unknown
    }
    
    // 사용자 동의 상태 저장
    public func setConsentStatus(_ status: ConsentStatus) {
        UserDefaults.standard.set(status.rawValue, forKey: userDefaultsKey)
    }
    
    // 광고 ID 가져오기 (동의한 경우에만)
    public func getAdvertisingID() -> String? {
        if getConsentStatus() == .granted {
            return ASIdentifierManager.shared().advertisingIdentifier.uuidString
        }
        return nil
    }
    
    // 동의 다이얼로그 표시 및 결과 처리
    public func requestConsent(from viewController: UIViewController, completion: @escaping (Bool) -> Void) {
        // 여기서는 iOS 14+ 분기 처리 없이 단순화
        showCustomConsentDialog(from: viewController, completion: completion)
    }
    
    // 커스텀 동의 다이얼로그 표시
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
    
    // 동의 상태 초기화 (재요청용)
    public func resetConsentStatus() {
        setConsentStatus(.unknown)
    }
}
