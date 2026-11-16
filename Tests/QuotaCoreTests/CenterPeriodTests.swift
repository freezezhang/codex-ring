import XCTest
@testable import QuotaCore

final class CenterPeriodTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1793700000)
    func snapshot(expiredFiveHours:Bool=false)->QuotaSnapshot {
        QuotaSnapshot(source:.official,fetchedAt:now,quotas:[
            WeeklyQuota(id:"codex/secondary",label:"codex",remaining:68,resetsAt:now.addingTimeInterval(86400)),
            WeeklyQuota(id:"codex/primary",label:"codex",remaining:19.5,resetsAt:now.addingTimeInterval(expiredFiveHours ? -1:3600),period:.fiveHours)
        ])
    }
    func testDualRingCenterSelectionDoesNotChangeRingOrderOrValues() {
        var p=RingPreferences();p.showFiveHours=true
        let week=RingComposition(snapshot:snapshot(),preferences:p,fiveHourSupport:true,now:now)
        XCTAssertEqual(week.centerPeriod,.week);XCTAssertEqual(week.center.value,68)
        p.centerPeriod = .fiveHours
        let five=RingComposition(snapshot:snapshot(),preferences:p,fiveHourSupport:true,now:now)
        XCTAssertEqual(five.centerPeriod,.fiveHours);XCTAssertEqual(five.center.value,19.5)
        XCTAssertEqual(five.outerPeriod,.week);XCTAssertEqual(five.innerPeriod,.fiveHours)
        XCTAssertEqual(five.outer.value,week.outer.value);XCTAssertEqual(five.inner?.value,week.inner?.value)
        p.metric = .used
        XCTAssertEqual(RingComposition(snapshot:snapshot(),preferences:p,fiveHourSupport:true,now:now).center.value,80.5)
    }
    func testSingleRingUsesItsOwnValueAndKeepsDualRingPreference() {
        var p=RingPreferences();p.centerPeriod = .fiveHours
        let week=RingComposition(snapshot:snapshot(),preferences:p,fiveHourSupport:true,now:now)
        XCTAssertNil(week.inner);XCTAssertEqual(week.centerPeriod,.week);XCTAssertEqual(week.center.value,68)
        XCTAssertEqual(p.centerPeriod,.fiveHours)
        p.showWeek=false;p.showFiveHours=true;p.centerPeriod = .week
        let five=RingComposition(snapshot:snapshot(),preferences:p,fiveHourSupport:true,now:now)
        XCTAssertNil(five.inner);XCTAssertEqual(five.centerPeriod,.fiveHours);XCTAssertEqual(five.center.value,19.5)
    }
    func testWeekOnlyAccountUsesWeekWithoutOverwritingSelectedCenter() {
        var p=RingPreferences();p.showFiveHours=true;p.centerPeriod = .fiveHours
        let c=RingComposition(snapshot:snapshot(),preferences:p,fiveHourSupport:false,now:now)
        XCTAssertNil(c.inner);XCTAssertEqual(c.centerPeriod,.week);XCTAssertEqual(c.center.value,68)
        XCTAssertEqual(p.centerPeriod,.fiveHours)
    }
    func testExpiredSelectedCenterIsNotReplacedWithHealthyWeekNumber() {
        var p=RingPreferences();p.showFiveHours=true;p.centerPeriod = .fiveHours
        let c=RingComposition(snapshot:snapshot(expiredFiveHours:true),preferences:p,fiveHourSupport:true,now:now)
        XCTAssertEqual(c.outer.value,68);XCTAssertEqual(c.centerPeriod,.fiveHours)
        XCTAssertNil(c.center.value);XCTAssertEqual(c.center.text,"—");XCTAssertEqual(c.center.display.status,.expired)
    }
    func testCenterSelectionPersistsAndOldOrUnknownValuesDefaultToWeek() throws {
        let name="local.freeze.center-tests.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        var p=RingPreferences();p.centerPeriod = .fiveHours;p.showFiveHours=true
        PreferencesStore(defaults:defaults).save(p)
        XCTAssertEqual(PreferencesStore(defaults:defaults).load(),p)
        for text in ["{}","{\"centerPeriod\":\"unknown\"}"] {
            XCTAssertEqual(try JSONDecoder().decode(RingPreferences.self,from:Data(text.utf8)).centerPeriod,.week)
        }
    }
    func testTooltipAndAccessibilityIdentifyChosenCenter() {
        var p=RingPreferences();p.showFiveHours=true;p.centerPeriod = .fiveHours
        let c=RingComposition(snapshot:snapshot(),preferences:p,fiveHourSupport:true,now:now)
        XCTAssertTrue(c.accessibilityText.contains("中心数字仅表示5小时额度"))
        let info=QuotaDetailsPresentation(snapshot:snapshot(),preferences:p,fiveHourSupport:true,lastRefreshedAt:now,now:now)
        XCTAssertTrue(info.tooltip.contains("中心数字：5小时 · 剩余19.5%"))
        XCTAssertTrue(info.tooltip.contains("1周：剩余68%"))
    }
}
