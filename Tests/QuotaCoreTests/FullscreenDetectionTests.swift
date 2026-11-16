import XCTest
@testable import QuotaCore

final class FullscreenDetectionTests:XCTestCase {
    private let display=CGRect(x:2560,y:288,width:1920,height:1080)
    func testNativeFullscreenDoesNotNeedApplicationPresentationFlag() {
        XCTAssertTrue(FullscreenDetection.coversDisplay(window:display,display:display))
    }
    func testOrdinaryMaximizedWindowIsNotFullscreen() {
        let workArea=CGRect(x:2560,y:319,width:1920,height:1049)
        XCTAssertFalse(FullscreenDetection.coversDisplay(window:workArea,display:display))
    }
    func testWindowOnOtherDisplayDoesNotMatch() {
        XCTAssertFalse(FullscreenDetection.coversDisplay(window:CGRect(x:0,y:0,width:1920,height:1080),display:display))
    }
    func testOversizedAndSpanningWindowsDoNotMatch() {
        XCTAssertFalse(FullscreenDetection.coversDisplay(window:display.insetBy(dx:-20,dy:-20),display:display))
        XCTAssertFalse(FullscreenDetection.coversDisplay(window:CGRect(x:0,y:0,width:4480,height:1440),display:display))
    }
    func testNegativeDisplayOrigin() {
        let screen=CGRect(x:-1920,y:-400,width:1920,height:1080)
        XCTAssertTrue(FullscreenDetection.coversDisplay(window:screen,display:screen))
    }
    func testNotchSafeAreaStillRequiresFullHeightBelowNotch() {
        let screen=CGRect(x:0,y:0,width:1512,height:982)
        XCTAssertTrue(FullscreenDetection.coversDisplay(window:CGRect(x:0,y:32,width:1512,height:950),display:screen,topInset:32))
        XCTAssertFalse(FullscreenDetection.coversDisplay(window:CGRect(x:0,y:32,width:1512,height:880),display:screen,topInset:32))
    }
    func testRoundingAndInvalidFrames() {
        XCTAssertTrue(FullscreenDetection.coversDisplay(window:display.insetBy(dx:0.5,dy:0.5),display:display))
        XCTAssertFalse(FullscreenDetection.coversDisplay(window:.zero,display:display))
        XCTAssertFalse(FullscreenDetection.coversDisplay(window:.null,display:display))
    }
}
