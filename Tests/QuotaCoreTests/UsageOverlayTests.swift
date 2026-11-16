import XCTest
@testable import QuotaCore

final class UsageOverlayTests:XCTestCase {
    func testSidebarProbesStayInWindowAcrossDisplaysAndReachEligibleControls() {
        for origin in [CGPoint.zero,CGPoint(x:2560,y:-400),CGPoint(x:-1920,y:200)] {
            let window=CGRect(origin:origin,size:CGSize(width:1200,height:800))
            let region=CodexFollow.usageSearchRegion(window:window)
            let points=CodexFollow.usageProbePoints(window:window)
            XCTAssertTrue(points.allSatisfy { region.contains($0) && window.contains($0) })
            for x in stride(from:region.minX,through:region.maxX-26,by:7) {
                for y in stride(from:region.minY,through:region.maxY-26,by:7) {
                    let control=CGRect(x:x,y:y,width:26,height:26)
                    XCTAssertTrue(points.contains(where:control.contains),"No probe in \(control)")
                }
            }
        }
    }
    func testSidebarSearchRegionIsClippedToSmallWindow() {
        let window=CGRect(x:20,y:40,width:160,height:120)
        XCTAssertEqual(CodexFollow.usageSearchRegion(window:window),window)
        XCTAssertFalse(CodexFollow.usageProbePoints(window:window).isEmpty)
        XCTAssertTrue(CodexFollow.usageProbePoints(window:window).allSatisfy(window.contains))
        XCTAssertTrue(CodexFollow.usageProbePoints(window:.zero).isEmpty)
    }
    func testOverlayCentersOnControlAcrossDisplays() throws {
        for origin in [CGPoint.zero,CGPoint(x:2560,y:288),CGPoint(x:-1920,y:-1080)] {
            let window=CGRect(origin:origin,size:CGSize(width:1200,height:800))
            let control=CGRect(x:origin.x+8,y:origin.y+52,width:36,height:36)
            let overlay=try XCTUnwrap(CodexFollow.usageOverlayFrame(control:control,window:window))
            XCTAssertEqual(overlay.width,26);XCTAssertEqual(overlay.height,26)
            XCTAssertEqual(overlay.midX,control.midX);XCTAssertEqual(overlay.midY,control.midY)
            XCTAssertTrue(control.contains(overlay))
        }
    }
    func testMissingOrInvalidControlCannotProduceGuessedPlacement() {
        let window=CGRect(x:0,y:0,width:1200,height:800)
        for control in [CGRect.zero,CGRect(x:-30,y:10,width:36,height:36),
                        CGRect(x:8,y:52,width:400,height:36),CGRect(x:8,y:52,width:36,height:100),
                        CGRect(x:8,y:52,width:24,height:24)] {
            XCTAssertNil(CodexFollow.usageOverlayFrame(control:control,window:window))
        }
    }
    func testOverlayOptInPreservesNormalPreferences() throws {
        var p=RingPreferences();p.size = .large;p.followCodex=false
        p.position=PanelPosition(x:400,y:300);p.codexAnchor=PanelPosition(x:0.2,y:0.3)
        let original=p
        p.overlayCodexUsage=true
        let decoded=try JSONDecoder().decode(RingPreferences.self,from:JSONEncoder().encode(p))
        XCTAssertTrue(decoded.overlayCodexUsage);XCTAssertFalse(decoded.followCodex)
        p.overlayCodexUsage=false;XCTAssertEqual(p,original)
        XCTAssertFalse(try JSONDecoder().decode(RingPreferences.self,from:Data("{}".utf8)).overlayCodexUsage)
    }
}
