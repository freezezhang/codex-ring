import XCTest
import CoreGraphics
@testable import QuotaCore
final class QuotaCoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1793700000)
    func week(_ used: Any = 31, duration: Any = 10080, reset: Any = 1793800000) -> [String: Any] {
        ["usedPercent": used, "windowDurationMins": duration, "resetsAt": reset]
    }
    func parse(_ w: [String: Any]) -> QuotaSnapshot { QuotaParser.parse(["rateLimits": ["secondary": w]], at: now) }
    func testRemainingAndReset() {
        let q = parse(week()).quotas[0]
        XCTAssertEqual(q.remaining, 69); XCTAssertEqual(q.resetsAt?.timeIntervalSince1970, 1793800000)
        XCTAssertEqual(parse(week()).display(now: now).centerText, "69%")
    }
    func testBothWindowSlotsAndMultipleBuckets() {
        let p: [String: Any] = ["rateLimitsByLimitId": ["a": ["primary": week(10)], "b": ["secondary": week(80)]], "rateLimits": ["secondary": week(1)]]
        let s = QuotaParser.parse(p, at: now)
        XCTAssertEqual(s.quotas.map(\.remaining), [90, 20]); XCTAssertEqual(s.display(selectedID: "b/secondary", now: now).remaining, 20)
    }
    func testEmptyMapDoesNotFallBack() {
        let p: [String: Any] = ["rateLimitsByLimitId": [:], "rateLimits": ["secondary": week()]]
        XCTAssertTrue(QuotaParser.parse(p, at: now).quotas.isEmpty)
    }
    func testNullMapFallsBack() {
        let p: [String: Any] = ["rateLimitsByLimitId": NSNull(), "rateLimits": ["primary": week()]]
        XCTAssertEqual(QuotaParser.parse(p, at: now).quotas.count, 1)
    }
    func testUnknownAndNonWeeklyDuration() {
        for duration: Any in [NSNull(), 20160, "10080", true] {
            XCTAssertTrue(parse(week(duration: duration)).quotas.isEmpty)
        }
    }
    func testUnknownUsageNotZero() {
        for used: Any in [NSNull(), "31", true] {
            XCTAssertNil(parse(week(used)).display(now: now).remaining)
        }
    }
    func testClampingAndZero() {
        for (used, remaining) in [(0, 100), (100, 0), (-10, 100), (110, 0)] {
            XCTAssertEqual(parse(week(used)).display(now: now).remaining, Double(remaining))
        }
    }
    func testExpiredDoesNotInferReplenishment() {
        let d = parse(week(reset: now.timeIntervalSince1970)).display(now: now)
        XCTAssertEqual(d.status, .expired); XCTAssertNil(d.remaining)
    }
    func testStaleFiveMinutes() {
        let s = parse(week())
        XCTAssertEqual(s.display(now: now.addingTimeInterval(301)).status, .stale)
        XCTAssertNotNil(s.display(now: now.addingTimeInterval(299)).remaining)
    }
    func testFailureNeverDisplaysOldPercentage() {
        let s = QuotaSnapshot(source: .official, fetchedAt: now, quotas: parse(week()).quotas, failure: .connection)
        XCTAssertNil(s.display(now: now).remaining); XCTAssertEqual(s.display(now: now).status, .connection)
    }
    func testNoWeeklyBucketAndUnknownReset() {
        XCTAssertEqual(QuotaParser.parse([:], at: now).display(now: now).status, .unavailable)
        XCTAssertNil(parse(week(reset: NSNull())).quotas[0].resetsAt)
        XCTAssertEqual(parse(week(reset: NSNull())).display(now: now).remaining, 69)
    }
    func testPrivateFieldsAreNotInModel() {
        let s = QuotaParser.parse(["rateLimits": ["secondary": week()], "access_token": "private-secret"], at: now)
        XCTAssertFalse(String(reflecting: s).contains("private-secret"))
    }
    let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    func testFourEdgesLeaveRecoverableSliver() {
        let f = CGRect(x: -1800, y: 400, width: 104, height: 104)
        for edge in DockEdge.allCases {
            let hidden = Docking.hidden(f, edge: edge, screen: screen)
            let intersection = hidden.intersection(screen)
            XCTAssertFalse(intersection.isNull)
            XCTAssertTrue(screen.contains(hidden), "A tucked window must not spill onto an adjacent monitor")
            if edge == .left || edge == .right { XCTAssertEqual(intersection.width, Docking.handle) }
            else { XCTAssertEqual(intersection.height, Docking.handle) }
            XCTAssertTrue(screen.contains(Docking.revealed(f, edge: edge, screen: screen)))
        }
    }
    func testSnapThresholdAndNegativeMonitorCoordinates() {
        XCTAssertEqual(Docking.nearestEdge(CGRect(x: -1910, y: 400, width: 104, height: 104), screen: screen), .left)
        XCTAssertNil(Docking.nearestEdge(CGRect(x: -1500, y: 400, width: 104, height: 104), screen: screen))
    }
    func testClampOffscreenAfterDisplayChange() {
        let f = Docking.clamped(CGRect(x: 2000, y: -300, width: 104, height: 104), to: screen)
        XCTAssertTrue(screen.contains(f))
    }
}
