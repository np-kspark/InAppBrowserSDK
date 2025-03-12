import XCTest
@testable import InAppBrowserSDK

final class InAppBrowserSDKTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // 테스트 설정 코드
    }
    
    override func tearDown() {
        // 테스트 정리 코드
        super.tearDown()
    }
    
    // InAppBrowserConfig 테스트
    func testConfigBuilder() {
        let config = InAppBrowserConfig.Builder()
            .setUrl("https://example.com")
            .setToolbarTitle("Test Browser")
            .build()
        
        XCTAssertEqual(config.url, "https://example.com")
        XCTAssertEqual(config.toolbarTitle, "Test Browser")
    }
    
    
    // 다른 테스트 메서드들...
}
