import XCTest
@testable import QuotaCore

final class RingSpacePresentationTests:XCTestCase {
    func testOrdinaryDesktopChangesDoNotEnableFullscreenSurface() {
        var state=RingSpacePresentation()
        XCTAssertEqual(state.surface,.desktop)
        for _ in 0..<3 { XCTAssertEqual(state.observe(systemIsFullscreen:false,ownAppIsActive:false),.desktop) }
    }
    func testEnterFullscreenThenReturnToDesktop() {
        var state=RingSpacePresentation()
        XCTAssertEqual(state.observe(systemIsFullscreen:true,ownAppIsActive:false),.fullscreen)
        XCTAssertEqual(state.observe(systemIsFullscreen:false,ownAppIsActive:false),.desktop)
    }
    func testOurSettingsActivationDoesNotDismissFullscreenRing() {
        var state=RingSpacePresentation()
        state.observe(systemIsFullscreen:true,ownAppIsActive:false)
        XCTAssertEqual(state.observe(systemIsFullscreen:false,ownAppIsActive:true),.fullscreen)
        XCTAssertEqual(state.observe(systemIsFullscreen:true,ownAppIsActive:false),.fullscreen)
        XCTAssertEqual(state.observe(systemIsFullscreen:false,ownAppIsActive:false),.desktop)
    }
    func testLaunchingOnFullscreenAndSwitchingBetweenFullscreenApps() {
        var state=RingSpacePresentation()
        for _ in 0..<3 { XCTAssertEqual(state.observe(systemIsFullscreen:true,ownAppIsActive:false),.fullscreen) }
    }
    func testOurOwnWindowDoesNotEnableFullscreenFromOrdinaryDesktop() {
        var state=RingSpacePresentation()
        XCTAssertEqual(state.observe(systemIsFullscreen:true,ownAppIsActive:true),.desktop)
    }
    func testFullscreenPlacementKeepsRelativePositionOnAnotherMonitor() {
        let source=CGRect(x:0,y:0,width:2560,height:1440)
        let target=CGRect(x:2560,y:72,width:1920,height:1080)
        let frame=CGRect(x:1267,y:707,width:26,height:26)
        let moved=Docking.relocated(frame,from:source,to:target)
        XCTAssertEqual(moved.midX,target.midX);XCTAssertEqual(moved.midY,target.midY)
        XCTAssertEqual(moved.size,frame.size);XCTAssertTrue(target.contains(moved))
        XCTAssertEqual(frame.origin.x,1267)
    }
    func testFullscreenPlacementClampsAtDisplayEdgesAndNegativeOrigins() {
        let source=CGRect(x:0,y:0,width:2560,height:1440)
        let target=CGRect(x:-1920,y:0,width:1920,height:1080)
        let frame=CGRect(x:2540,y:1420,width:64,height:64)
        let moved=Docking.relocated(frame,from:source,to:target)
        XCTAssertTrue(target.contains(moved));XCTAssertEqual(moved.maxX,target.maxX);XCTAssertEqual(moved.maxY,target.maxY)
    }
    func testFullscreenPlacementDoesNotDriftOnSameDisplay() {
        let screen=CGRect(x:0,y:118,width:2560,height:1291)
        let frame=CGRect(x:1267,y:750,width:26,height:26)
        XCTAssertEqual(Docking.relocated(frame,from:screen,to:screen),frame)
    }
}
