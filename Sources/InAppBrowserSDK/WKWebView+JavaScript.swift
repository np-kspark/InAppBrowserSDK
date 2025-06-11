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

extension InAppBrowserViewController {
    func setupJavaScriptInterface(for webView: WKWebView) {
        let basicScript = """
            window.iOSInterface = {
                triggerAd: function(adUnit, callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'reward',
                        adUnit: adUnit,
                        callbackFunction: callbackFunction
                    });
                },
                openExternalURL: function(url) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'openExternalURL',
                        url: url
                    });
                },

                triggerinterstitialAd: function(adUnit, callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'interstitial',
                        adUnit: adUnit,
                        callbackFunction: callbackFunction
                    });
                },
                
                triggerRewardedInterstitialAd: function(adUnit, callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'rewarded_interstitial',
                        adUnit: adUnit,
                        callbackFunction: callbackFunction
                    });
                },
                
                preloadAndAutoShowAd: function(adUnit, delayMs, callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'rewarded_interstitial',
                        adUnit: adUnit,
                        delayMs: delayMs,
                        callbackFunction: callbackFunction,
                        autoShow: true
                    });
                },
                    
                closeWebView: function() {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'close'
                    });
                },
                
                requestAdIdConsent: function(callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'requestAdIdConsent',
                        callbackFunction: callbackFunction
                    });
                },
                
                checkAdIdConsentStatus: function(callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'checkAdIdConsentStatus',
                        callbackFunction: callbackFunction
                    });
                },
                
                requestATTPermission: function(callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'requestATTPermission',
                        callbackFunction: callbackFunction
                    });
                },
                
                getATTStatus: function(callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'getATTStatus',
                        callbackFunction: callbackFunction
                    });
                },
                
                getAdvertisingId: function(callbackFunction) {
                    window.webkit.messageHandlers.iOSInterface.postMessage({
                        type: 'getAdvertisingId',
                        callbackFunction: callbackFunction
                    });
                },
                
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
            
            window.AndroidInterface = window.iOSInterface;
        """
        
        let kakaoEnhancementScript = """
            (function() {
                window.enhanceKakaoShare = function() {
                    if (typeof Kakao !== 'undefined' && Kakao.Share) {
                        const originalSendDefault = Kakao.Share.sendDefault;
                        const originalSendScrap = Kakao.Share.sendScrap;
                        
                        Kakao.Share.sendDefault = function(options) {
                            try {
                                return originalSendDefault.call(this, options);
                            } catch(e) {
                                
                                const shareData = {
                                    objectType: options.objectType || 'feed',
                                    content: options.content || {},
                                    buttons: options.buttons || []
                                };
                                
                                const kakaoLink = 'kakaolink://send?template_json=' + 
                                    encodeURIComponent(JSON.stringify(shareData));
                                
                                const tempLink = document.createElement('a');
                                tempLink.href = kakaoLink;
                                tempLink.click();
                                
                                setTimeout(function() {
                                    if (confirm('카카오톡이 설치되어 있지 않습니다. 설치하시겠습니까?')) {
                                        window.open('https://apps.apple.com/app/id362057947', '_blank');
                                    }
                                }, 1000);
                            }
                        };
                        
                        if (originalSendScrap) {
                            Kakao.Share.sendScrap = function(options) {
                                try {
                                    return originalSendScrap.call(this, options);
                                } catch(e) {
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
                        
                        return true;
                    }
                    return false;
                };
                
                let kakaoCheckCount = 0;
                const kakaoChecker = setInterval(function() {
                    kakaoCheckCount++;
                    
                    if (typeof Kakao !== 'undefined') {
                        window.enhanceKakaoShare();
                        clearInterval(kakaoChecker);
                    } else if (kakaoCheckCount > 50) { 
                        clearInterval(kakaoChecker);
                    }
                }, 100);
                
                window.checkKakaoTalkInstalled = function() {
                    return new Promise(function(resolve) {
                        const iframe = document.createElement('iframe');
                        iframe.style.display = 'none';
                        iframe.src = 'kakaotalk://';
                        document.body.appendChild(iframe);
                        
                        const timeout = setTimeout(function() {
                            document.body.removeChild(iframe);
                            resolve(false); 
                        }, 2000);
                        
                        window.addEventListener('blur', function() {
                            clearTimeout(timeout);
                            document.body.removeChild(iframe);
                            resolve(true); 
                        }, { once: true });
                    });
                };
            })();
        """
        
        let urlOptimizationScript = """
            (function() {
                // URL 길이 체크 및 최적화
                window.optimizeCurrentUrl = function() {
                    const currentUrl = window.location.href;
                    
                    if (currentUrl.length > 2000) {
                        
                        if (currentUrl.includes('coupang.com')) {
                            const url = new URL(currentUrl);
                            const params = new URLSearchParams(url.search);
                            
                            const essentialParams = ['itemId', 'vendorItemId'];
                            const newParams = new URLSearchParams();
                            
                            essentialParams.forEach(function(param) {
                                if (params.has(param)) {
                                    newParams.set(param, params.get(param));
                                }
                            });
                            
                            const optimizedUrl = url.origin + url.pathname + '?' + newParams.toString();
                            
                            return optimizedUrl;
                        }
                    }
                    
                    return currentUrl;
                };
                
                window.addEventListener('error', function(e) {
                    
                    if (e.message && e.message.includes('URL')) {
                        const optimizedUrl = window.optimizeCurrentUrl();
                        if (optimizedUrl !== window.location.href) {
                            window.location.href = optimizedUrl;
                        }
                    }
                });
                
                window.addEventListener('unhandledrejection', function(e) {
                    
                    if (e.reason && e.reason.toString().includes('network')) {
                    }
                });
                
            })();
        """
        let windowOpenScript = """
        (function() {
            const originalOpen = window.open;
            
            window.open = function(url, name, features) {
                try {
                    
                    if (!url || url === '' || url === 'about:blank') {
                        return originalOpen.call(this, url, name, features);
                    }
                    
                    let fullUrl = url;
                    if (!url.startsWith('http://') && !url.startsWith('https://') && !url.startsWith('javascript:')) {
                        const baseUrl = window.location.origin;
                        if (url.startsWith('/')) {
                            fullUrl = baseUrl + url;
                        } else {
                            const currentPath = window.location.pathname;
                            const basePath = currentPath.substring(0, currentPath.lastIndexOf('/') + 1);
                            fullUrl = baseUrl + basePath + url;
                        }
                    }
                    
                    
                    return originalOpen.call(this, fullUrl, name, features);
                    
                } catch (e) {
                    return originalOpen.call(this, url, name, features);
                }
            };
            
            
            window.checkPopupBlocked = function() {
                try {
                    const popup = window.open('about:blank', '_blank', 'width=1,height=1');
                    if (popup) {
                        popup.close();
                        return false;
                    } else {
                        return true; 
                    }
                } catch (e) {
                    return true;
                }
            };
            
        })();
        """
        
        let postLoadScript = """
        (function() {
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', function() {
                });
            } else {
            }
            
            document.addEventListener('click', function(e) {
                const target = e.target;
                if (target.onclick && target.onclick.toString().includes('window.open')) {
                    
                }
            });
        })();
        """
        
        let scripts = [
            (basicScript, WKUserScriptInjectionTime.atDocumentStart, true),
            (windowOpenScript, WKUserScriptInjectionTime.atDocumentStart, false),
            (kakaoEnhancementScript, WKUserScriptInjectionTime.atDocumentEnd, false),
            (urlOptimizationScript, WKUserScriptInjectionTime.atDocumentEnd, true),
            (postLoadScript, WKUserScriptInjectionTime.atDocumentEnd, false)
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
    
}
