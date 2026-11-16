import XCTest
@testable import QuotaCore

final class AutomaticQuotaSelectionTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    func snapshot(week:Double?,five:Double?,weekReset:TimeInterval?=nil,fiveReset:TimeInterval?=nil)->QuotaSnapshot {
        QuotaSnapshot(source:.official,fetchedAt:now,quotas:[
            WeeklyQuota(id:"codex/secondary",label:"Codex",remaining:week,resetsAt:weekReset.map{now.addingTimeInterval($0)},period:.week),
            WeeklyQuota(id:"codex/primary",label:"Codex",remaining:five,resetsAt:fiveReset.map{now.addingTimeInterval($0)},period:.fiveHours)])
    }
    func choose(_ s:QuotaSnapshot)->QuotaPeriod? {
        AutomaticQuotaSelection.select(snapshot:s,preferences:RingPreferences(),periods:[.week,.fiveHours],now:now)
    }
    func testDepletedWinsAndUnknownNeverLooksDepleted() {
        XCTAssertEqual(choose(snapshot(week:0,five:10,fiveReset:14000)),.week)
        XCTAssertEqual(choose(snapshot(week:nil,five:90)),.fiveHours)
        XCTAssertNil(choose(snapshot(week:nil,five:nil)))
    }
    func testEarlierForecastWinsOverHigherUsage() {
        XCTAssertEqual(choose(snapshot(week:10,five:20,weekReset:500000,fiveReset:14000)),.fiveHours)
    }
    func testFallbackUsesActualUsageRegardlessOfDisplayMetric() {
        XCTAssertEqual(choose(snapshot(week:40,five:20)),.fiveHours)
        var p=RingPreferences();p.showFiveHours=true;p.automaticCenter=true;p.metric = .used
        let s=snapshot(week:40,five:20)
        XCTAssertEqual(RingComposition(snapshot:s,preferences:p,fiveHourSupport:true,now:now).centerPeriod,.fiveHours)
        p.metric = .remaining
        XCTAssertEqual(RingComposition(snapshot:s,preferences:p,fiveHourSupport:true,now:now).centerPeriod,.fiveHours)
        p.showFiveHours=false
        XCTAssertEqual(RingComposition(snapshot:s,preferences:p,fiveHourSupport:true,now:now).centerPeriod,.week)
        p.showFiveHours=true;p.automaticCenter=false;p.centerPeriod = .week
        XCTAssertEqual(RingComposition(snapshot:s,preferences:p,fiveHourSupport:true,now:now).centerPeriod,.week)
    }
    func testOldSettingsKeepManualSelectionAndNewSettingsRoundTrip() throws {
        let old=try JSONDecoder().decode(RingPreferences.self,from:Data("{\"centerPeriod\":\"fiveHours\"}".utf8))
        XCTAssertFalse(old.automaticCenter);XCTAssertEqual(old.centerPeriod,.fiveHours)
        XCTAssertFalse(old.alerts.enabled);XCTAssertFalse(old.resetConfetti)
        var p=old;p.automaticCenter=true;p.resetConfetti=true;p.alerts.enabled=true;p.alerts.cardDays=7
        XCTAssertEqual(try JSONDecoder().decode(RingPreferences.self,from:JSONEncoder().encode(p)),p)
    }
}
