import XCTest
@testable import QuotaCore

final class CodexFollowTests:XCTestCase {
    func testBasicFollowingRetainsWindowOnInactiveDesktopWithoutAXPermission() {
        let main=window(),offscreen=window(onScreen:false)
        let result=CodexFollow.basicWindows(candidates:[offscreen],previous:[main],hasObservedWindow:true)
        XCTAssertEqual(CodexFollow.action(enabled:true,windows:result),.hidden)
    }
    func testBasicFollowingReattachesWhenReturningToCodexDesktop() {
        let visible=window()
        let result=CodexFollow.basicWindows(candidates:[visible],previous:[window(onScreen:false)],hasObservedWindow:true)
        XCTAssertEqual(CodexFollow.action(enabled:true,windows:result),.attach(visible))
    }
    func testBasicFollowingDoesNotAdoptHiddenRendererAfterMainWindowCloses() {
        let helper=window(2,onScreen:false)
        let result=CodexFollow.basicWindows(candidates:[helper],previous:[window()],hasObservedWindow:true)
        XCTAssertEqual(CodexFollow.action(enabled:true,windows:result),.free)
    }
    func testBasicFollowingWaitsWhenLaunchedOnADifferentDesktop() {
        let result=CodexFollow.basicWindows(candidates:[window(onScreen:false)],previous:[],hasObservedWindow:false)
        XCTAssertEqual(CodexFollow.action(enabled:true,windows:result),.hidden)
    }
    func testMissingAccessibilityWindowOnAnotherSpaceDoesNotRestoreFreeRing() {
        let previous=window()
        let retained=CodexFollow.retainedOffscreenWindows(previous:[previous],registeredIDs:[previous.id])
        XCTAssertEqual(retained.count,1)
        XCTAssertEqual(CodexFollow.action(enabled:true,windows:retained),.hidden)
    }
    func testConfirmedClosedWindowDoesNotRetainDesktopBinding() {
        let retained=CodexFollow.retainedOffscreenWindows(previous:[window()],registeredIDs:[])
        XCTAssertEqual(CodexFollow.action(enabled:true,windows:retained),.free)
    }
    private func window(_ id:UInt32=1,onScreen:Bool=true,focused:Bool=false)->CodexFollowWindow {
        CodexFollowWindow(id:id,frame:CGRect(x:100,y:100,width:900,height:700),isOnScreen:onScreen,isFocused:focused)
    }
    func testDisabledAlwaysKeepsFreeMovement() {
        XCTAssertEqual(CodexFollow.action(enabled:false,windows:[window()]),.free)
        XCTAssertEqual(CodexFollow.action(enabled:false,windows:[window(onScreen:false)]),.free)
    }
    func testClosedOrAllMinimizedWindowsRestoreFreePosition() {
        XCTAssertEqual(CodexFollow.action(enabled:true,windows:[]),.free)
    }
    func testWindowOnAnotherDesktopHidesRingInsteadOfFallingBack() {
        XCTAssertEqual(CodexFollow.action(enabled:true,windows:[window(onScreen:false)]),.hidden)
    }
    func testFocusedVisibleWindowWinsAmongMultipleWindows() {
        let front=window(),focused=window(2,focused:true)
        XCTAssertEqual(CodexFollow.action(enabled:true,windows:[front,focused]),.attach(focused))
    }
    func testFocusedWindowOnAnotherSpaceDoesNotHideVisibleCodexWindow() {
        let visible=window(),other=window(2,onScreen:false,focused:true)
        XCTAssertEqual(CodexFollow.action(enabled:true,windows:[other,visible]),.attach(visible))
    }
    func testMovingAndResizingWindowKeepsRelativeAnchor() {
        let a=CGRect(x:100,y:100,width:900,height:700),b=CGRect(x:-1920,y:200,width:1600,height:900)
        let anchor=PanelPosition(x:0.3,y:0.8)
        for area in [a,b] {
            let frame=CodexFollow.frame(in:area,size:76,anchor:anchor)
            XCTAssertTrue(area.contains(frame))
            let restored=CodexFollow.anchor(for:frame,in:area)
            XCTAssertEqual(restored.x,anchor.x,accuracy:0.00001);XCTAssertEqual(restored.y,anchor.y,accuracy:0.00001)
        }
    }
    func testDefaultPositionAvoidsWindowTitleBar() {
        let area=CGRect(x:0,y:0,width:900,height:700)
        let frame=CodexFollow.frame(in:area,size:64,anchor:nil)
        XCTAssertEqual(frame.maxY,area.maxY-48);XCTAssertEqual(frame.maxX,area.maxX-12)
    }
    func testPartiallyOffscreenWindowUsesVisibleArea() {
        let screen=CGRect(x:0,y:0,width:1000,height:800)
        let area=CodexFollow.area(window:CGRect(x:-600,y:100,width:900,height:1000),screen:screen)
        XCTAssertTrue(screen.contains(CodexFollow.frame(in:area,size:76,anchor:nil)))
    }
    func testOutOfRangeOrInvalidAnchorsAreClamped() {
        let area=CGRect(x:0,y:0,width:900,height:700)
        for anchor in [PanelPosition(x:-1,y:2),PanelPosition(x:.nan,y:.infinity)] {
            XCTAssertTrue(area.contains(CodexFollow.frame(in:area,size:76,anchor:anchor)))
        }
    }
    func testOldAndMalformedPreferencesLeaveFollowDisabled() throws {
        for json in ["{}","{\"followCodex\":\"bad\"}"] {
            let p=try JSONDecoder().decode(RingPreferences.self,from:Data(json.utf8))
            XCTAssertFalse(p.followCodex);XCTAssertNil(p.codexAnchor)
        }
    }
    func testFollowingPreferenceDoesNotReplaceFreeDesktopPosition() throws {
        var p=RingPreferences();p.position=PanelPosition(x:400,y:500)
        p.followCodex=true;p.codexAnchor=PanelPosition(x:0.6,y:0.9)
        var decoded=try JSONDecoder().decode(RingPreferences.self,from:JSONEncoder().encode(p))
        decoded.followCodex=false
        XCTAssertEqual(decoded.position,PanelPosition(x:400,y:500));XCTAssertEqual(decoded.codexAnchor,p.codexAnchor)
    }
}
