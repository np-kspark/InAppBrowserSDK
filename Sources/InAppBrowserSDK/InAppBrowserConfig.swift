import Foundation
import UIKit

public class InAppBrowserConfig {
    var toolbarMode: String = "dark"
    var toolbarTitle: String = "Default Title"
    var titleAlignment: String = "left"
    var url: String?
    var isFullscreen: Bool = true
    var isDebugEnabled: Bool = false
    var userAgent: String = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    
    // UI 커스터마이징 옵션
    var fontFamily: String?
    var fontSize: Int = 18
    var toolbarBackgroundColor: UIColor?
    var titleTextColor: UIColor?
    var backButtonImageName: String?
    var closeButtonImageName: String?
    
    // 버튼 역할 설정 추가
    var leftButtonRole: ButtonRole = .back
    var rightButtonRole: ButtonRole = .close
    var leftButtonVisible: Bool = true
    var rightButtonVisible: Bool = true
    var leftButtonIcon: ButtonIcon = .auto
    var rightButtonIcon: ButtonIcon = .auto
    
    // 백 액션 제어 추가
    var backAction: BackAction = .historyBack
    var backConfirmMessage: String = "한번 더 누르면 창이 닫힙니다"
    var backConfirmTimeout: TimeInterval = 2.0
    
    // 로딩 커스터마이징 옵션
    var loadingBackgroundColor: UIColor?
    var progressBarColor: UIColor?
    var progressBarStyle: Int = 0
    var progressBarImageName: String?
    var backButtonLeftMargin: Int = -1
    var closeButtonLeftMargin: Int = -1
    var backButtonIconSize: Int = 33
    var closeButtonIconSize: Int = 33
    var toolbarHeight: Int = 56
    var progressBarAnimationDuration: Double = 3.0
    
    var titleLeftMargin: Int? = nil
    var titleRightMargin: Int? = nil
    var titleCenterOffset: Int = 0
    var backButtonTopMargin: Int = -1
    var backButtonBottomMargin: Int = -1
    var backButtonRightMargin: Int = -1
    var closeButtonRightMargin: Int = -1
    var closeButtonTopMargin: Int = -1
    var closeButtonBottomMargin: Int = -1

    // 캐시 방지 설정 추가
    var preventCache: Bool = true
    
    // 버튼 역할 열거형
    public enum ButtonRole {
        case back    // 뒤로가기
        case close   // 닫기
        case none    // 비활성화
    }
    
    // 백 액션 열거형 추가
    public enum BackAction {
        case exit           // 바로 종료
        case confirmExit    // 확인 후 종료 (더블탭)
        case historyBack    // 히스토리 뒤로가기 → 종료
        case ignore         // 무시 (아무것도 안함)
    }
    
    public enum ButtonIcon {
        case auto           // 역할에 따라 자동 (back=화살표, close=X)
        case back           // 항상 뒤로가기 화살표
        case close          // 항상 X 아이콘
        case custom(String) // 커스텀 이미지
    }
    
    private init() {}
    
    public class Builder {
        private let config: InAppBrowserConfig
        
        public init() {
            config = InAppBrowserConfig()
        }
        
        public func setToolbarMode(_ mode: String) -> Builder {
            config.toolbarMode = mode
            return self
        }
        
        public func setToolbarTitle(_ title: String) -> Builder {
            config.toolbarTitle = title
            return self
        }
        
        public func setTitleAlignment(_ alignment: String) -> Builder {
            config.titleAlignment = alignment
            return self
        }
        
        public func setUrl(_ url: String) -> Builder {
            config.url = url
            return self
        }
        
        public func setFullscreen(_ fullscreen: Bool) -> Builder {
            config.isFullscreen = fullscreen
            return self
        }
        
        public func setDebugEnabled(_ enabled: Bool) -> Builder {
            config.isDebugEnabled = enabled
            return self
        }
        
        public func setUserAgent(_ userAgent: String) -> Builder {
            config.userAgent = userAgent
            return self
        }
        
        // 버튼 역할 설정 메소드 추가
        public func setLeftButtonRole(_ role: ButtonRole) -> Builder {
            config.leftButtonRole = role
            return self
        }
        
        public func setRightButtonRole(_ role: ButtonRole) -> Builder {
            config.rightButtonRole = role
            return self
        }
        
        public func setLeftButtonIcon(_ icon: ButtonIcon) -> Builder {
            config.leftButtonIcon = icon
            return self
        }

        public func setRightButtonIcon(_ icon: ButtonIcon) -> Builder {
            config.rightButtonIcon = icon
            return self
        }
        
        public func setLeftButtonVisible(_ visible: Bool) -> Builder {
            config.leftButtonVisible = visible
            return self
        }
        
        public func setRightButtonVisible(_ visible: Bool) -> Builder {
            config.rightButtonVisible = visible
            return self
        }
        
        // 백 액션 설정 메소드 추가
        public func setBackAction(_ action: BackAction) -> Builder {
            config.backAction = action
            return self
        }
        
        public func setBackConfirmMessage(_ message: String) -> Builder {
            config.backConfirmMessage = message
            return self
        }
        
        public func setBackConfirmTimeout(_ timeout: TimeInterval) -> Builder {
            config.backConfirmTimeout = timeout
            return self
        }
        
        public func setTitleLeftMargin(_ margin: Int) -> Builder {
            config.titleLeftMargin = margin
            return self
        }

        public func setTitleRightMargin(_ margin: Int) -> Builder {
            config.titleRightMargin = margin
            return self
        }

        public func setTitleCenterOffset(_ offset: Int) -> Builder {
            config.titleCenterOffset = offset
            return self
        }
        
        // UI 커스터마이징 옵션
        public func setFontFamily(_ fontFamily: String) -> Builder {
            config.fontFamily = fontFamily
            return self
        }
        
        public func setFontSize(_ fontSize: Int) -> Builder {
            config.fontSize = fontSize
            return self
        }
        
        public func setToolbarBackgroundColor(_ color: UIColor) -> Builder {
            config.toolbarBackgroundColor = color
            return self
        }
        
        public func setTitleTextColor(_ color: UIColor) -> Builder {
            config.titleTextColor = color
            return self
        }
        
        public func setBackButtonIcon(_ imageName: String) -> Builder {
            config.backButtonImageName = imageName
            return self
        }
        
        public func setCloseButtonIcon(_ imageName: String) -> Builder {
            config.closeButtonImageName = imageName
            return self
        }
        
        // 로딩 커스터마이징 옵션
        public func setLoadingBackgroundColor(_ color: UIColor) -> Builder {
            config.loadingBackgroundColor = color
            return self
        }
        
        public func setProgressBarColor(_ color: UIColor) -> Builder {
            config.progressBarColor = color
            return self
        }
        
        public func setProgressBarStyle(_ style: Int) -> Builder {
            config.progressBarStyle = style
            return self
        }
        
        public func setProgressBarImage(_ imageName: String, animationDuration: Double = 3.0) -> Builder {
            config.progressBarImageName = imageName
            config.progressBarAnimationDuration = animationDuration
            config.progressBarStyle = 2
            return self
        }
        
        public func setBackButtonLeftMargin(_ margin: Int) -> Builder {
            config.backButtonLeftMargin = margin
            return self
        }
        
        public func setCloseButtonRightMargin(_ margin: Int) -> Builder {
            config.closeButtonRightMargin = margin
            return self
        }
        
        public func setToolbarHeight(_ height: Int) -> Builder {
            config.toolbarHeight = height
            return self
        }
        
        public func setBackButtonIconSize(_ size: Int) -> Builder {
            config.backButtonIconSize = size
            return self
        }
        
        public func setCloseButtonIconSize(_ size: Int) -> Builder {
            config.closeButtonIconSize = size
            return self
        }
        public func setBackButtonTopMargin(_ margin: Int) -> Builder {
            config.backButtonTopMargin = margin
            return self
        }

        public func setBackButtonBottomMargin(_ margin: Int) -> Builder {
            config.backButtonBottomMargin = margin
            return self
        }

        public func setBackButtonRightMargin(_ margin: Int) -> Builder {
            config.backButtonRightMargin = margin
            return self
        }

        public func setCloseButtonLeftMargin(_ margin: Int) -> Builder {
            config.closeButtonLeftMargin = margin
            return self
        }

        public func setCloseButtonTopMargin(_ margin: Int) -> Builder {
            config.closeButtonTopMargin = margin
            return self
        }

        public func setCloseButtonBottomMargin(_ margin: Int) -> Builder {
            config.closeButtonBottomMargin = margin
            return self
        }

        public func setPreventCache(_ prevent: Bool) -> Builder {
            config.preventCache = prevent
            return self
        }
        
        public func build() -> InAppBrowserConfig {
            return config
        }
    }
}
