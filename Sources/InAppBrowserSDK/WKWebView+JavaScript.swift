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
        let script = """
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
                }
            };
            
            // Android 인터페이스와의 호환성을 위한 별칭
            window.AndroidInterface = window.iOSInterface;
        """
        
        let userScript = WKUserScript(source: script,
                                    injectionTime: .atDocumentStart,
                                    forMainFrameOnly: true)
        
        webView.configuration.userContentController.addUserScript(userScript)
    }
}
