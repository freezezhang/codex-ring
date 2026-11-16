import XCTest
@testable import QuotaCore

final class QuotaPanelSettingsTests:XCTestCase {
    override func setUp() { super.setUp();L10n.apply(languageCode:"zh-Hans") }
    let now=Date(timeIntervalSince1970:1_800_000_000)
    func row(_ options:QuotaPanelPreferences,period:QuotaPeriod = .week,metric:DisplayMetric = .used)->QuotaMenuRow {
        var p=RingPreferences();p.quotaPanel=options;p.metric=metric
        let snapshot=QuotaSnapshot(source:.official,fetchedAt:now,quotas:[
            WeeklyQuota(id:"codex/secondary",label:"Codex",remaining:20,resetsAt:now.addingTimeInterval(4*86400)),
            WeeklyQuota(id:"codex/primary",label:"Codex",remaining:60,resetsAt:now.addingTimeInterval(4*3600),period:.fiveHours)])
        return QuotaMenuPresentation(snapshot:snapshot,metadata:snapshot,preferences:p,fiveHourSupport:true,lastRefreshedAt:now,now:now).rows.first(where:{$0.period == period})!
    }
    func testOldAndPartialSettingsRetainCurrentDisplay() throws {
        let p=try JSONDecoder().decode(RingPreferences.self,from:Data("{}".utf8))
        XCTAssertEqual(p.quotaPanel,QuotaPanelPreferences())
        let partial=try JSONDecoder().decode(RingPreferences.self,from:Data(#"{"quotaPanel":{"showPace":false,"weeklySchedule":123,"tickStyle":"invalid"}}"#.utf8))
        XCTAssertFalse(partial.quotaPanel.showPace)
        XCTAssertEqual(partial.quotaPanel.weeklySchedule,.seven)
        XCTAssertEqual(partial.quotaPanel.tickStyle,.subtle)
        let legacy=try JSONDecoder().decode(RingPreferences.self,from:Data(#"{"metric":"used","quotaPanel":{"metric":"remaining","showWarningMarkers":true,"showPace":false}}"#.utf8))
        XCTAssertEqual(legacy.metric,.used)
        XCTAssertFalse(legacy.quotaPanel.showPace)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy.quotaPanel)) as? [String:Any])
        XCTAssertNil(json["metric"])
        XCTAssertNil(json["showWarningMarkers"])
    }
    func testAllPanelChoicesPersistAlongsideSharedMetric() {
        let suite="QuotaPanelSettingsTests.\(UUID().uuidString)"
        let isolated=UserDefaults(suiteName:suite)!
        defer { isolated.removePersistentDomain(forName:suite) }
        let store=PreferencesStore(defaults:isolated)
        var p=RingPreferences();p.metric = .used
        p.quotaPanel.showPace=false
        p.quotaPanel.weeklySchedule = .five;p.quotaPanel.tickStyle = .highContrast;p.quotaPanel.resetStyle = .dateTime
        store.save(p)
        XCTAssertEqual(store.load(),p)
        XCTAssertEqual(store.load().metric,.used)
    }
    func testRemainingFillMirrorsPaceWithoutChangingMeaning() throws {
        let options=QuotaPanelPreferences()
        let used=row(options,metric:.used)
        let remaining=row(options,metric:.remaining)
        XCTAssertEqual(used.progressPercent,80);XCTAssertEqual(remaining.progressPercent,20)
        XCTAssertEqual(remaining.progressText,"剩余 20%")
        XCTAssertEqual(remaining.band,.orange)
        let pace=try XCTUnwrap(remaining.pace(at:now))
        XCTAssertEqual(pace,used.pace(at:now))
        XCTAssertEqual(remaining.progressPosition(try XCTUnwrap(pace.markerPercent)),100-pace.expectedUsed)
    }
    func testVisibilityControlsAreIndependentAndDateFormatIsSelectable() {
        var options=QuotaPanelPreferences()
        options.showPace=false;options.tickStyle = .hidden
        let hidden=row(options)
        XCTAssertNil(hidden.pace(at:now));XCTAssertTrue(hidden.divisionMarkers.isEmpty)
        XCTAssertEqual(hidden.progressPercent,80)
        options.showPace=true
        XCTAssertNotNil(row(options).pace(at:now))
        options.resetStyle = .dateTime
        let dates=row(options)
        XCTAssertEqual(dates.resetDescription(at:now),"重置于 "+QuotaDateText.string(now.addingTimeInterval(4*86400)))
        XCTAssertEqual(dates.resetDescription(at:now.addingTimeInterval(4*86400)),"等待重置")
        XCTAssertTrue(hidden.resetDescription(at:now).hasSuffix("后重置"))
    }
    func testAutomaticAndWorkdayDivisionsDoNotAlterFiveHourDivisions() {
        var options=QuotaPanelPreferences();options.weeklySchedule = .automatic
        XCTAssertTrue(row(options).divisionMarkers.isEmpty)
        XCTAssertEqual(row(options,period:.fiveHours).divisionMarkers,[20,40,60,80])
        options.weeklySchedule = .five
        XCTAssertEqual(row(options).divisionMarkers,[20,40,60,80])
        options.weeklySchedule = .four
        XCTAssertEqual(row(options).divisionMarkers,[25,50,75])
        XCTAssertEqual(row(options,period:.fiveHours).divisionMarkers,[20,40,60,80])
    }
    func calendar(_ zone:String="UTC")->Calendar {
        var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:zone)!;return c
    }
    func date(_ day:Int,_ hour:Int=0,calendar:Calendar)->Date {
        calendar.date(from:DateComponents(year:2026,month:11,day:day,hour:hour))!
    }
    func testFiveDayPredictionSkipsWeekendInWallClockETA() throws {
        let c=calendar(),time=date(6,12,calendar:c),reset=date(10,calendar:c)
        // Tuesday → Tuesday window, Friday noon: 3.5 / 5 working days elapsed.
        let pace=try XCTUnwrap(QuotaPace(used:80,period:.week,resetsAt:reset,now:time,workDays:5,calendar:c))
        XCTAssertEqual(pace.expectedUsed,70,accuracy:0.0001)
        XCTAssertEqual(pace.secondsToExhaustion,date(9,9,calendar:c).timeIntervalSince(time))
        XCTAssertEqual(pace.forecastText,"预计 2天21小时 后耗尽")
        let linear=try XCTUnwrap(QuotaPace(used:80,period:.week,resetsAt:reset,now:time,workDays:7,calendar:c))
        XCTAssertEqual(linear.expectedUsed,50)
        XCTAssertEqual(linear.secondsToExhaustion,0.875*86400)
    }
    func testWeekendProgressIsFlatAndETAIncludesTimeUntilMonday() throws {
        let c=calendar(),reset=date(10,calendar:c)
        let sat=try XCTUnwrap(QuotaPace(used:90,period:.week,resetsAt:reset,now:date(7,12,calendar:c),workDays:5,calendar:c))
        let sun=try XCTUnwrap(QuotaPace(used:90,period:.week,resetsAt:reset,now:date(8,12,calendar:c),workDays:5,calendar:c))
        XCTAssertEqual(sat.expectedUsed,80);XCTAssertEqual(sat.expectedUsed,sun.expectedUsed)
        XCTAssertEqual(try XCTUnwrap(sat.secondsToExhaustion)-XCTUnwrap(sun.secondsToExhaustion),86400,accuracy:0.001)
        let five=try XCTUnwrap(QuotaPace(used:80,period:.fiveHours,resetsAt:now.addingTimeInterval(4*3600),now:now,workDays:4,calendar:c))
        XCTAssertEqual(five.secondsToExhaustion,900);XCTAssertNil(five.workDays)
    }
    func testLocalDayBoundariesHandleDaylightSavingWeekend() throws {
        let c=calendar("America/Los_Angeles")
        let reset=c.date(from:DateComponents(year:2026,month:3,day:10))!
        let friday=c.date(from:DateComponents(year:2026,month:3,day:6,hour:12))!
        let pace=try XCTUnwrap(QuotaPace(used:80,period:.week,resetsAt:reset,now:friday,workDays:5,calendar:c))
        let eta=try XCTUnwrap(pace.secondsToExhaustion)
        let end=friday.addingTimeInterval(eta)
        XCTAssertEqual(c.component(.weekday,from:end),2) // Monday after DST shift.
        XCTAssertLessThan(eta,3*86400)
        XCTAssertGreaterThan(eta,2*86400)
    }
}
