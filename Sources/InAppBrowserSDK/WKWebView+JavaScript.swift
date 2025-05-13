import WebKit

extension WKWebView {
    func evaluateJavaScriptSafely(_ script: String) {
        DispatchQueue.main.async {
            self.evaluateJavaScript(script) { (result, error) in
                if let error = error {
                    print("JavaScript Error: \(error)")
                }
            }
        }
    }
}
// JavaScript Interface Helper
extension InAppBrowserViewController {
    func setupJavaScriptInterface(for webView: WKWebView) {
        // 기본 인터페이스는 그대로 유지
        let basicScript = """
            window.iOSInterface = {
                // 보상형 광고 트리거
                triggerAd: function(adUnit, callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'reward',
                        adUnit: adUnit,
                        callbackFunction: callbackFunction
                    });
                },
                
                // 전면 광고 트리거
                triggerinterstitialAd: function(adUnit, callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'interstitial',
                        adUnit: adUnit,
                        callbackFunction: callbackFunction
                    });
                },
                
                // 보상형 전면 광고 트리거
                triggerRewardedInterstitialAd: function(adUnit, callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'rewarded_interstitial',
                        adUnit: adUnit,
                        callbackFunction: callbackFunction
                    });
                },
                
                // 자동 표시 보상형 전면 광고
                preloadAndAutoShowAd: function(adUnit, delayMs, callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'rewarded_interstitial',
                        adUnit: adUnit,
                        delayMs: delayMs,
                        callbackFunction: callbackFunction,
                        autoShow: true
                    });
                },
                    
                // 웹뷰 닫기 기능 추가
                closeWebView: function() {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'close'
                    });
                },
                
                // 광고 ID 수집 동의 요청
                requestAdIdConsent: function(callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'requestAdIdConsent',
                        callbackFunction: callbackFunction
                    });
                },
                
                // 광고 ID 수집 동의 상태 확인
                checkAdIdConsentStatus: function(callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'checkAdIdConsentStatus',
                        callbackFunction: callbackFunction
                    });
                },
                
                // 광고 ID 수집 동의 초기화 (재요청용)
                requestAdidConsentAgain: function() {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'requestAdidConsentAgain'
                    });
                }
            };
            
            // Android 인터페이스와의 호환성을 위한 별칭
            window.AndroidInterface = window.iOSInterface;
        """
        
        // DOM 스토리지 활성화를 위한 별도의 스크립트
        let storageScript = """
            (function() {
                // DOM 스토리지 초기화 테스트
                try {
                    localStorage.setItem('test-storage', 'enabled');
                    console.log('localStorage 테스트: ' + localStorage.getItem('test-storage'));
                    
                    // 브라우저 콘솔에서 확인할 수 있는 테스트 함수 추가
                    window.checkStorage = function() {
                        return {
                            localStorage: localStorage.getItem('test-storage'),
                            storageAvailable: typeof localStorage !== 'undefined'
                        };
                    };
                } catch(e) {
                    console.error('localStorage 오류: ' + e);
                }
            })();
        """
        
        // 기본 인터페이스 스크립트 추가
        let userScript = WKUserScript(
            source: basicScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(userScript)
        
        // 스토리지 스크립트 추가
        let storageUserScript = WKUserScript(
            source: storageScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        webView.configuration.userContentController.addUserScript(storageUserScript)
    }
    
    // WebView 설정을 최적화하는 함수 추가
    func enhanceWebViewConfiguration(_ webView: WKWebView) {
        // 1. 쿠키 수락 정책 설정
        HTTPCookieStorage.shared.cookieAcceptPolicy = .always
        
        // 2. DOM 스토리지가 활성화되었는지 테스트
        let testStorageScript = """
        (function() {
            try {
                localStorage.setItem('test-key', 'test-value');
                var result = localStorage.getItem('test-key');
                return { success: result === 'test-value', value: result };
            } catch(e) {
                return { success: false, error: e.toString() };
            }
        })();
        """
        
        webView.evaluateJavaScript(testStorageScript) { (result, error) in
            if let resultDict = result as? [String: Any], let success = resultDict["success"] as? Bool {
                print("DOM 스토리지 테스트: \(success ? "성공" : "실패")")
            } else if let error = error {
                print("DOM 스토리지 테스트 오류: \(error.localizedDescription)")
            }
        }
        
        // 3. 서드파티 도메인에 대한 테스트 쿠키 설정
        setupTestCookiesForThirdPartyDomains(webView)
    }
    
    // 테스트용 서드파티 쿠키 설정
    private func setupTestCookiesForThirdPartyDomains(_ webView: WKWebView) {
        let thirdPartyDomains = [
            "doubleclick.net",
            "google-analytics.com",
            "facebook.com", 
            "adservice.google.com"
        ]
        
        for domain in thirdPartyDomains {
            if let cookie = HTTPCookie(properties: [
                .domain: domain,
                .path: "/",
                .name: "pre-visit-cookie",
                .value: "enabled",
                .secure: true,
                .expires: NSDate(timeIntervalSinceNow: 86400) // 1일
            ]) {
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
        }
    }
}

