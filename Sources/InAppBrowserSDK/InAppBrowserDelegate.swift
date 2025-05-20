import UIKit

protocol InAppBrowserDelegate: AnyObject {  // public 제거
    func browserDidClose(_ browser: InAppBrowserViewController)
}
