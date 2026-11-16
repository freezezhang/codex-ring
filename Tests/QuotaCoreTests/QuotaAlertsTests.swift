import XCTest
@testable import QuotaCore

final class QuotaAlertsTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    func snapshot(_ remaining:Double,at date:Date,reset:Date?=nil,source:QuotaSource = .official,failure:QuotaFailure?=nil,cards:ResetCards?=nil)->QuotaSnapshot {
        QuotaSnapshot(source:source,fetchedAt:date,quotas:[WeeklyQuota(id:"codex/primary",label:"Codex",remaining:remaining,resetsAt:reset,period:.fiveHours)],failure:failure,resetCards:cards)
    }
    var preferences:RingPreferences {
        var p=RingPreferences();p.alerts.enabled=true;p.resetConfetti=true;return p
    }
    func testWarningReceiptsSurviveRestartAndRearmAtNewBoundary() throws {
        var engine=QuotaAlertEngine()
        let reset=now.addingTimeInterval(7200)
        let first=engine.evaluate(snapshot(10,at:now,reset:reset),preferences:preferences,notificationsAllowed:true,now:now)
        XCTAssertEqual(first.alerts.filter{$0.kind == .low}.count,1)
        XCTAssertFalse(first.celebrate)
        let saved=try JSONEncoder().encode(engine.receipts)
        engine=QuotaAlertEngine(receipts:try JSONDecoder().decode([String:Date].self,from:saved))
        XCTAssertTrue(engine.evaluate(snapshot(9,at:now,reset:reset),preferences:preferences,notificationsAllowed:true,now:now).alerts.isEmpty)
        let next=now.addingTimeInterval(7201)
        let result=engine.evaluate(snapshot(10,at:next,reset:next.addingTimeInterval(7200)),preferences:preferences,notificationsAllowed:true,now:next)
        XCTAssertEqual(result.alerts.filter{$0.kind == .low}.count,1)
        XCTAssertFalse(result.celebrate)
    }
    func testRecoveryAndConfettiFireOnceAndIgnoreJitter() {
        var engine=QuotaAlertEngine();let reset=now.addingTimeInterval(7200)
        _=engine.evaluate(snapshot(0,at:now,reset:reset),preferences:preferences,notificationsAllowed:true,now:now)
        let later=now.addingTimeInterval(60)
        let result=engine.evaluate(snapshot(100,at:later,reset:reset.addingTimeInterval(3600)),preferences:preferences,notificationsAllowed:true,now:later)
        XCTAssertEqual(result.alerts.map(\.kind),[.restored]);XCTAssertTrue(result.celebrate)
        XCTAssertFalse(engine.evaluate(snapshot(100,at:later.addingTimeInterval(60),reset:reset.addingTimeInterval(3600)),preferences:preferences,notificationsAllowed:true,now:later.addingTimeInterval(60)).celebrate)
        XCTAssertFalse(engine.evaluate(snapshot(99,at:later.addingTimeInterval(120),reset:reset.addingTimeInterval(3600)),preferences:preferences,notificationsAllowed:true,now:later.addingTimeInterval(120)).celebrate)
    }
    func testInvalidAndDebugSamplesCannotCreateRecovery() {
        for bad in [snapshot(0,at:now,source:.debug),snapshot(0,at:now,failure:.connection),snapshot(0,at:now.addingTimeInterval(-301)),snapshot(0,at:now,reset:now.addingTimeInterval(-1))] {
            var engine=QuotaAlertEngine()
            XCTAssertTrue(engine.evaluate(bad,preferences:preferences,notificationsAllowed:true,now:now).alerts.isEmpty)
            XCTAssertFalse(engine.evaluate(snapshot(100,at:now.addingTimeInterval(60)),preferences:preferences,notificationsAllowed:true,now:now.addingTimeInterval(60)).celebrate)
        }
    }
    func testIndependentPermissionAndAnimationSwitches() {
        var engine=QuotaAlertEngine(),p=preferences
        p.alerts.enabled=false
        _=engine.evaluate(snapshot(0,at:now),preferences:p,notificationsAllowed:false,now:now)
        let result=engine.evaluate(snapshot(100,at:now.addingTimeInterval(60)),preferences:p,notificationsAllowed:false,now:now.addingTimeInterval(60))
        XCTAssertTrue(result.alerts.isEmpty);XCTAssertTrue(result.celebrate)
        engine=QuotaAlertEngine();p.resetConfetti=false;p.alerts.enabled=true
        _=engine.evaluate(snapshot(0,at:now),preferences:p,notificationsAllowed:true,now:now)
        let notified=engine.evaluate(snapshot(100,at:now.addingTimeInterval(60)),preferences:p,notificationsAllowed:true,now:now.addingTimeInterval(60))
        XCTAssertEqual(notified.alerts.map(\.kind),[.restored]);XCTAssertFalse(notified.celebrate)
    }
    func testDeadlineChangingWithoutUsageRecoveryIsNotReset() {
        var engine=QuotaAlertEngine()
        _=engine.evaluate(snapshot(40,at:now,reset:now.addingTimeInterval(100)),preferences:preferences,notificationsAllowed:true,now:now)
        let later=now.addingTimeInterval(60)
        XCTAssertFalse(engine.evaluate(snapshot(39,at:later,reset:now.addingTimeInterval(1000)),preferences:preferences,notificationsAllowed:true,now:later).celebrate)
    }
    func testCardExpiryBoundariesAndDuplicateDates() {
        let expiry=now.addingTimeInterval(3*86400)
        let cards=ResetCards(availableCount:5,details:[
            ResetCard(title:"reset",expiresAt:expiry,status:"available"),
            ResetCard(title:"reset",expiresAt:expiry,status:"available"),
            ResetCard(title:"reset",expiresAt:now,status:"available"),
            ResetCard(title:"reset",expiresAt:expiry.addingTimeInterval(1),status:"available"),
            ResetCard(title:"reset",expiresAt:now.addingTimeInterval(60),status:"used")])
        var engine=QuotaAlertEngine()
        let result=engine.evaluate(snapshot(100,at:now,cards:cards),preferences:preferences,notificationsAllowed:true,now:now)
        XCTAssertEqual(result.alerts.map(\.kind),[.card])
        XCTAssertTrue(engine.evaluate(snapshot(100,at:now,cards:cards),preferences:preferences,notificationsAllowed:true,now:now).alerts.isEmpty)
    }
    func testPredictionUsesPaceAndNoWarningAtExactRemainingThreshold() {
        var engine=QuotaAlertEngine()
        // 1 hour elapsed, 80% used: 15 minutes until exhaustion.
        let result=engine.evaluate(snapshot(20,at:now,reset:now.addingTimeInterval(4*3600)),preferences:preferences,notificationsAllowed:true,now:now)
        XCTAssertEqual(result.alerts.map(\.kind),[.prediction])
    }
    func testBaselineResetAndLongGapSuppressCelebration() {
        var engine=QuotaAlertEngine()
        _=engine.evaluate(snapshot(0,at:now),preferences:preferences,notificationsAllowed:true,now:now)
        engine.clearBaseline()
        XCTAssertFalse(engine.evaluate(snapshot(100,at:now.addingTimeInterval(60)),preferences:preferences,notificationsAllowed:true,now:now.addingTimeInterval(60)).celebrate)
        _=engine.evaluate(snapshot(0,at:now.addingTimeInterval(120)),preferences:preferences,notificationsAllowed:true,now:now.addingTimeInterval(120))
        XCTAssertFalse(engine.evaluate(snapshot(100,at:now.addingTimeInterval(1000)),preferences:preferences,notificationsAllowed:true,now:now.addingTimeInterval(1000)).celebrate)
    }
}
