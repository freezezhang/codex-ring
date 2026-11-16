import XCTest
@testable import QuotaCore
final class PeriodAndCardsTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1793700000)
    func payload(five:Bool=true,plan:String="pro")->[String:Any] {
        var bucket:[String:Any]=["planType":plan,"secondary":["usedPercent":91,"windowDurationMins":10080,"resetsAt":1793800000]]
        if five { bucket["primary"]=["usedPercent":71,"windowDurationMins":300,"resetsAt":1793705000] }
        return ["rateLimitsByLimitId":["codex":bucket]]
    }
    func testPeriodsReadFromDurationNotPositionOrPlanName() {
        let s=QuotaParser.parse(payload(),at:now)
        XCTAssertEqual(s.display(period:.week,now:now).remaining,9)
        XCTAssertEqual(s.display(period:.fiveHours,now:now).remaining,29)
        var c=QuotaCapabilities();c.observe(s);XCTAssertEqual(c.fiveHourSupport,true)
        c.observe(QuotaParser.parse(payload(five:false),at:now));XCTAssertEqual(c.fiveHourSupport,false)
    }
    func testDualRingsHaveIndependentValuesColorsAndResetTimes() {
        var p=RingPreferences();p.showFiveHours=true
        let s=QuotaParser.parse(payload(),at:now),c=RingComposition(snapshot:s,preferences:p,fiveHourSupport:true,now:now)
        XCTAssertEqual(c.outerPeriod,.week);XCTAssertEqual(c.innerPeriod,.fiveHours)
        XCTAssertEqual(c.outer.value,9);XCTAssertEqual(c.inner?.value,29)
        XCTAssertEqual(c.outer.band,.red);XCTAssertEqual(c.inner?.band,.yellow)
        XCTAssertNotEqual(c.outer.display.quota?.resetsAt,c.inner?.display.quota?.resetsAt)
        XCTAssertTrue(c.accessibilityText.contains("中心数字仅表示1周"))
    }
    func testSelectOnlyFiveHoursAndSwitchMetric() {
        var p=RingPreferences();p.showWeek=false;p.showFiveHours=true;p.metric = .used
        let c=RingComposition(snapshot:QuotaParser.parse(payload(),at:now),preferences:p,fiveHourSupport:true,now:now)
        XCTAssertEqual(c.outerPeriod,.fiveHours);XCTAssertNil(c.inner);XCTAssertEqual(c.outer.value,71);XCTAssertEqual(c.outer.band,.yellow)
    }
    func testMissingFiveHoursFallsBackToWeekWithoutClearingPreference() {
        var p=RingPreferences();p.showWeek=false;p.showFiveHours=true
        let c=RingComposition(snapshot:QuotaParser.parse(payload(five:false),at:now),preferences:p,fiveHourSupport:false,now:now)
        XCTAssertEqual(c.outerPeriod,.week);XCTAssertNil(c.inner);XCTAssertEqual(c.outer.value,9)
        XCTAssertTrue(p.showFiveHours);XCTAssertFalse(p.showWeek)
    }
    func testQueryFailureAndLoadingDoNotEraseKnownWindowCapability() {
        var c=QuotaCapabilities();XCTAssertNil(c.fiveHourSupport)
        c.observe(QuotaParser.parse(payload(),at:now));XCTAssertEqual(c.fiveHourSupport,true)
        c.observe(QuotaSnapshot(source:.official,fetchedAt:now,failure:.connection));XCTAssertEqual(c.fiveHourSupport,true)
        c.observe(QuotaSnapshot(source:.official,fetchedAt:now,loading:true));XCTAssertEqual(c.fiveHourSupport,true)
        c.observe(QuotaParser.parse([:],at:now));XCTAssertEqual(c.fiveHourSupport,true)
    }
    func testOneExpiredPeriodDoesNotEraseOtherPeriod() {
        var p=payload();var map=p["rateLimitsByLimitId"] as! [String:[String:Any]]
        map["codex"]?["primary"]=["usedPercent":71,"windowDurationMins":300,"resetsAt":now.timeIntervalSince1970-1]
        p["rateLimitsByLimitId"]=map
        var preferences=RingPreferences();preferences.showFiveHours=true
        let c=RingComposition(snapshot:QuotaParser.parse(p,at:now),preferences:preferences,fiveHourSupport:true,now:now)
        XCTAssertEqual(c.outer.value,9);XCTAssertNil(c.inner?.value);XCTAssertEqual(c.inner?.display.status,.expired)
    }
    func testNoPeriodsSelectedDecodesToVisibleWeek() throws {
        let p=try JSONDecoder().decode(RingPreferences.self,from:Data("{\"showWeek\":false,\"showFiveHours\":false}".utf8))
        XCTAssertTrue(p.showWeek)
    }
    func testMenuStartsWithRefreshPinResetAndSettings() {
        var p=RingPreferences()
        XCTAssertEqual(RingMenuSpec.entries(for:p),[.refresh,.positionLock(locked:false),.reset,.settings,.quit])
        p.positionLocked=true
        XCTAssertEqual(RingMenuSpec.entries(for:p),[.refresh,.positionLock(locked:true),.reset,.settings,.quit])
    }
    func testRefreshPeriodAndSelectionsPersist() throws {
        let name="local.freeze.quota-tests.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        var p=RingPreferences();p.refreshInterval = .fiveMinutes;p.showFiveHours=true;p.positionLocked=true
        PreferencesStore(defaults:defaults).save(p)
        let restored=PreferencesStore(defaults:try XCTUnwrap(UserDefaults(suiteName:name))).load()
        XCTAssertEqual(restored,p);XCTAssertEqual(restored.refreshInterval.rawValue,300)
        XCTAssertEqual(try JSONDecoder().decode(RingPreferences.self,from:Data("{\"refreshInterval\":3}".utf8)).refreshInterval,.oneMinute)
    }
    func testOverlayForcesLockAndRejectsTogglesWithoutChangingNormalPreference() throws {
        for original in [false,true] {
            var p=RingPreferences();p.positionLocked=original;p.overlayCodexUsage=true
            XCTAssertTrue(p.effectivePositionLocked)
            XCTAssertFalse(p.canTogglePositionLock)
            XCTAssertEqual(RingMenuSpec.entries(for:p)[1],.positionLock(locked:true))
            p.togglePositionLock();p.togglePositionLock()
            XCTAssertEqual(p.positionLocked,original)
            p=try JSONDecoder().decode(RingPreferences.self,from:JSONEncoder().encode(p))
            XCTAssertTrue(p.effectivePositionLocked)
            XCTAssertFalse(p.canTogglePositionLock)
            p.overlayCodexUsage=false
            XCTAssertEqual(p.effectivePositionLocked,original)
            XCTAssertTrue(p.canTogglePositionLock)
            p.togglePositionLock()
            XCTAssertEqual(p.effectivePositionLocked,!original)
        }
    }
    func testMissingPermissionDisablesOverlayAndDoesNotEnableItWhenGrantedLater() throws {
        for locked in [false,true] {
            var p=RingPreferences();p.overlayCodexUsage=true;p.positionLocked=locked;p.followCodex=true
            p.reconcileOverlayPermission(granted:true)
            XCTAssertTrue(p.overlayCodexUsage)
            p.reconcileOverlayPermission(granted:false)
            XCTAssertFalse(p.overlayCodexUsage)
            XCTAssertEqual(p.effectivePositionLocked,locked)
            XCTAssertTrue(p.followCodex)
            p=try JSONDecoder().decode(RingPreferences.self,from:JSONEncoder().encode(p))
            XCTAssertFalse(p.overlayCodexUsage)
            p.reconcileOverlayPermission(granted:true)
            XCTAssertFalse(p.overlayCodexUsage)
            p.overlayCodexUsage=true
            p.reconcileOverlayPermission(granted:true)
            XCTAssertTrue(p.overlayCodexUsage)
        }
    }
    func testResetCardCountIsAuthoritativeAndExpiresInUnixSeconds() throws {
        let cards=try XCTUnwrap(ResetCardsParser.parse(["availableCount":2,"credits":[["status":"available","title":"我的重置卡","expiresAt":1793800000,"id":"not-retained"]]]))
        XCTAssertEqual(cards.availableCount,2);XCTAssertEqual(cards.details?.count,1)
        XCTAssertEqual(cards.details?.first?.expiresAt?.timeIntervalSince1970,1793800000)
        XCTAssertFalse(String(reflecting:cards).contains("not-retained"))
    }
    func testResetCardsMissingDetailsAndUnknownAreNotZeroOrNeverExpire() throws {
        XCTAssertNil(ResetCardsParser.parse(NSNull()))
        let c=try XCTUnwrap(ResetCardsParser.parse(["availableCount":2,"credits":NSNull()]))
        XCTAssertEqual(c.availableCount,2);XCTAssertNil(c.details)
        let d=try XCTUnwrap(ResetCardsParser.parse(["credits":[["status":"available","expiresAt":NSNull()]]]))
        XCTAssertNil(d.availableCount);XCTAssertNil(d.details?.first?.expiresAt)
        XCTAssertEqual(ResetCardsParser.parse(["availableCount":0,"credits":[]])?.availableCount,0)
    }
    func testResetCardsReadThroughSameQuotaResponse() {
        var p=payload();p["rateLimitResetCredits"]=["availableCount":3,"credits":NSNull()]
        XCTAssertEqual(QuotaParser.parse(p,at:now).resetCards?.availableCount,3)
    }
    func testPeriodsNeverSilentlyUseDifferentQuotaPools() {
        let q=[WeeklyQuota(id:"codex/secondary",label:"codex",remaining:8,resetsAt:now.addingTimeInterval(1000)),
               WeeklyQuota(id:"other/primary",label:"other",remaining:70,resetsAt:now.addingTimeInterval(1000),period:.fiveHours)]
        let s=QuotaSnapshot(source:.official,fetchedAt:now,quotas:q)
        var capability=QuotaCapabilities();capability.observe(s)
        XCTAssertEqual(capability.support(for:"codex"),false);XCTAssertEqual(capability.support(for:"other"),true)
        XCTAssertNil(s.display(selectedID:"codex",period:.fiveHours,now:now).remaining)
        var p=RingPreferences();p.showFiveHours=true
        let c=RingComposition(snapshot:s,preferences:p,fiveHourSupport:capability.fiveHourSupport,now:now)
        XCTAssertNil(c.inner);XCTAssertEqual(c.outer.value,8)
    }
}
