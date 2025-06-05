import WebKit

extension WKWebView {
    func evaluateJavaScriptSafely(_ script: String) {
        DispatchQueue.main.async {
            self.evaluateJavaScript(script) { (result, error) in
                if let error = error {
                    
                }
            }
        }
    }
}

// JavaScript Interface Helper
extension InAppBrowserViewController {
    func setupJavaScriptInterface(for webView: WKWebView) {
        // 기본 인터페이스 스크립트
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
                    
                // 웹뷰 닫기 기능
                closeWebView: function() {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'close'
                    });
                },
                
                // ATT 권한 요청
                requestAdIdConsent: function(callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'requestAdIdConsent',
                        callbackFunction: callbackFunction
                    });
                },
                
                // ATT 권한 상태 확인
                checkAdIdConsentStatus: function(callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'checkAdIdConsentStatus',
                        callbackFunction: callbackFunction
                    });
                },
                
                
                // 백 액션 제어 함수들 추가
                setBackAction: function(action) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'setBackAction',
                        action: action
                    });
                },
                
                setBackConfirmMessage: function(message) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'setBackConfirmMessage',
                        message: message
                    });
                },
                
                setBackConfirmTimeout: function(timeout) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'setBackConfirmTimeout',
                        timeout: timeout
                    });
                },
                           
                triggerBackAction: function() {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'triggerBackAction'
                    });
                }
            };
            
            // Android 인터페이스와의 호환성을 위한 별칭
            window.AndroidInterface = window.iOSInterface;
        """
        
        // 카카오 공유 향상 스크립트
        let kakaoEnhancementScript = """
            (function() {
                // 카카오 공유 기능 향상
                window.enhanceKakaoShare = function() {
                    if (typeof Kakao !== 'undefined' && Kakao.Share) {
                        // 원본 함수 백업
                        const originalSendDefault = Kakao.Share.sendDefault;
                        const originalSendScrap = Kakao.Share.sendScrap;
                        
                        // sendDefault 함수 오버라이드
                        Kakao.Share.sendDefault = function(options) {
                            try {
                                console.log('카카오 공유 시도:', options);
                                return originalSendDefault.call(this, options);
                            } catch(e) {
                                console.log('일반 카카오 공유 실패, 앱 연동 시도:', e);
                                
                                // 카카오톡 앱으로 공유 시도
                                const shareData = {
                                    objectType: options.objectType || 'feed',
                                    content: options.content || {},
                                    buttons: options.buttons || []
                                };
                                
                                const kakaoLink = 'kakaolink://send?template_json=' + 
                                    encodeURIComponent(JSON.stringify(shareData));
                                
                                // 카카오톡 앱 열기 시도
                                const tempLink = document.createElement('a');
                                tempLink.href = kakaoLink;
                                tempLink.click();
                                
                                // 실패하면 카카오톡 설치 페이지로 이동
                                setTimeout(function() {
                                    if (confirm('카카오톡이 설치되어 있지 않습니다. 설치하시겠습니까?')) {
                                        window.open('https://apps.apple.com/app/id362057947', '_blank');
                                    }
                                }, 1000);
                            }
                        };
                        
                        // sendScrap 함수 오버라이드
                        if (originalSendScrap) {
                            Kakao.Share.sendScrap = function(options) {
                                try {
                                    return originalSendScrap.call(this, options);
                                } catch(e) {
                                    console.log('카카오 스크랩 공유 실패:', e);
                                    // sendDefault로 폴백
                                    Kakao.Share.sendDefault({
                                        objectType: 'feed',
                                        content: {
                                            title: options.requestUrl ? '페이지 공유' : '링크 공유',
                                            description: '공유된 링크를 확인해보세요',
                                            imageUrl: '',
                                            link: {
                                                mobileWebUrl: options.requestUrl || window.location.href,
                                                webUrl: options.requestUrl || window.location.href
                                            }
                                        }
                                    });
                                }
                            };
                        }
                        
                        console.log('카카오 공유 기능이 향상되었습니다.');
                        return true;
                    }
                    return false;
                };
                
                // 페이지 로드 완료 후 카카오 SDK 초기화 감지
                let kakaoCheckCount = 0;
                const kakaoChecker = setInterval(function() {
                    kakaoCheckCount++;
                    
                    if (typeof Kakao !== 'undefined') {
                        window.enhanceKakaoShare();
                        clearInterval(kakaoChecker);
                    } else if (kakaoCheckCount > 50) { // 5초 후 중단
                        clearInterval(kakaoChecker);
                    }
                }, 100);
                
                // 카카오톡 앱 설치 여부 확인 함수
                window.checkKakaoTalkInstalled = function() {
                    return new Promise(function(resolve) {
                        const iframe = document.createElement('iframe');
                        iframe.style.display = 'none';
                        iframe.src = 'kakaotalk://';
                        document.body.appendChild(iframe);
                        
                        const timeout = setTimeout(function() {
                            document.body.removeChild(iframe);
                            resolve(false); // 설치되지 않음
                        }, 2000);
                        
                        // 앱이 열리면 이 이벤트가 발생
                        window.addEventListener('blur', function() {
                            clearTimeout(timeout);
                            document.body.removeChild(iframe);
                            resolve(true); // 설치됨
                        }, { once: true });
                    });
                };
            })();
        """
        
        // DOM 스토리지 및 쿠키 향상 스크립트
        let storageEnhancementScript = """
            (function() {
                // 로컬 스토리지 테스트 및 향상
                try {
                    localStorage.setItem('test-storage', 'enabled');
                    console.log('localStorage 활성화됨:', localStorage.getItem('test-storage'));
                    
                    // 스토리지 확인 함수 추가
                    window.checkStorage = function() {
                        return {
                            localStorage: typeof localStorage !== 'undefined' && localStorage.getItem('test-storage'),
                            sessionStorage: typeof sessionStorage !== 'undefined',
                            cookieEnabled: navigator.cookieEnabled,
                            storageQuota: navigator.storage ? 'available' : 'unavailable'
                        };
                    };
                    
                    // 쿠키 설정 함수
                    window.setCookieEnhanced = function(name, value, days) {
                        let expires = '';
                        if (days) {
                            const date = new Date();
                            date.setTime(date.getTime() + (days * 24 * 60 * 60 * 1000));
                            expires = '; expires=' + date.toUTCString();
                        }
                        document.cookie = name + '=' + (value || '') + expires + '; path=/; SameSite=None; Secure';
                    };
                    
                    // 쿠키 읽기 함수
                    window.getCookieEnhanced = function(name) {
                        const nameEQ = name + '=';
                        const ca = document.cookie.split(';');
                        for (let i = 0; i < ca.length; i++) {
                            let c = ca[i];
                            while (c.charAt(0) === ' ') c = c.substring(1, c.length);
                            if (c.indexOf(nameEQ) === 0) return c.substring(nameEQ.length, c.length);
                        }
                        return null;
                    };
                    
                } catch(e) {
                    console.error('스토리지 초기화 오류:', e);
                }
                
                // 서드파티 쿠키 지원 테스트
                window.testThirdPartyCookies = function() {
                    const testDomains = ['doubleclick.net', 'google-analytics.com', 'facebook.com'];
                    const results = {};
                    
                    testDomains.forEach(function(domain) {
                        try {
                            // 테스트 이미지로 서드파티 쿠키 확인
                            const img = new Image();
                            img.onload = function() {
                                results[domain] = 'accessible';
                            };
                            img.onerror = function() {
                                results[domain] = 'blocked';
                            };
                            img.src = 'https://' + domain + '/favicon.ico?t=' + Date.now();
                        } catch(e) {
                            results[domain] = 'error';
                        }
                    });
                    
                    return results;
                };
                
                console.log('스토리지 및 쿠키 향상 기능이 활성화되었습니다.');
            })();
        """
        
        // URL 길이 최적화 및 에러 처리 스크립트
        let urlOptimizationScript = """
            (function() {
                // URL 길이 체크 및 최적화
                window.optimizeCurrentUrl = function() {
                    const currentUrl = window.location.href;
                    
                    if (currentUrl.length > 2000) {
                        console.warn('URL이 너무 깁니다 (' + currentUrl.length + '자). 최적화를 권장합니다.');
                        
                        // 쿠팡 URL 최적화
                        if (currentUrl.includes('coupang.com')) {
                            const url = new URL(currentUrl);
                            const params = new URLSearchParams(url.search);
                            
                            // 필수 파라미터만 유지
                            const essentialParams = ['itemId', 'vendorItemId'];
                            const newParams = new URLSearchParams();
                            
                            essentialParams.forEach(function(param) {
                                if (params.has(param)) {
                                    newParams.set(param, params.get(param));
                                }
                            });
                            
                            const optimizedUrl = url.origin + url.pathname + '?' + newParams.toString();
                            console.log('최적화된 URL:', optimizedUrl);
                            
                            return optimizedUrl;
                        }
                    }
                    
                    return currentUrl;
                };
                
                // 페이지 로드 에러 처리
                window.addEventListener('error', function(e) {
                    console.error('페이지 로드 에러:', e);
                    
                    // URL 관련 에러인 경우 최적화 시도
                    if (e.message && e.message.includes('URL')) {
                        const optimizedUrl = window.optimizeCurrentUrl();
                        if (optimizedUrl !== window.location.href) {
                            console.log('URL 최적화로 인한 페이지 새로고침');
                            window.location.href = optimizedUrl;
                        }
                    }
                });
                
                // 네트워크 에러 감지 및 처리
                window.addEventListener('unhandledrejection', function(e) {
                    console.error('처리되지 않은 Promise 거부:', e.reason);
                    
                    if (e.reason && e.reason.toString().includes('network')) {
                        console.log('네트워크 오류 감지됨');
                        // 네트워크 오류 시 재시도 로직 추가 가능
                    }
                });
                
                console.log('URL 최적화 및 에러 처리 기능이 활성화되었습니다.');
            })();
        """
        
        // 스크립트들을 WKUserScript로 등록
        let scripts = [
            (basicScript, WKUserScriptInjectionTime.atDocumentStart, true),
            (kakaoEnhancementScript, WKUserScriptInjectionTime.atDocumentEnd, false),
            (storageEnhancementScript, WKUserScriptInjectionTime.atDocumentEnd, false),
            (urlOptimizationScript, WKUserScriptInjectionTime.atDocumentEnd, true)
        ]
        
        for (script, time, mainFrameOnly) in scripts {
            let userScript = WKUserScript(
                source: script,
                injectionTime: time,
                forMainFrameOnly: mainFrameOnly
            )
            webView.configuration.userContentController.addUserScript(userScript)
        }
    }
    
    // WebView 설정을 최적화하는 함수
    func enhanceWebViewConfiguration(_ webView: WKWebView) {
        // 1. 쿠키 수락 정책 설정
        HTTPCookieStorage.shared.cookieAcceptPolicy = .always
        
        // 2. DOM 스토리지 테스트
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
                
            } else if let error = error {
                
            }
        }
        
        // 3. 서드파티 도메인 쿠키 설정
        setupCookiesForDomains(webView)
    }
    
    // 주요 도메인들에 대한 쿠키 사전 설정
    private func setupCookiesForDomains(_ webView: WKWebView) {
        let domains = [
            "coupang.com",
            "kakao.com",
            "doubleclick.net",
            "google-analytics.com",
            "facebook.com",
            "adservice.google.com"
        ]
        
        for domain in domains {
            if let cookie = HTTPCookie(properties: [
                .domain: domain,
                .path: "/",
                .name: "webview-session",
                .value: "enabled-\(Date().timeIntervalSince1970)",
                .secure: true,
                .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict,
                .expires: NSDate(timeIntervalSinceNow: 86400) // 1일
            ]) {
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
        }
    }
}
