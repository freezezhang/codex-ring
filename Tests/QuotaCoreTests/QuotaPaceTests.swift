import XCTest
@testable import QuotaCore

final class QuotaPaceTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    func testWeeklyAverageProjectsExhaustionBeforeReset() throws {
        // Three days elapsed, half consumed: the remaining half lasts three days.
        let pace=try XCTUnwrap(QuotaPace(used:50,period:.week,resetsAt:now.addingTimeInterval(4*86400),now:now))
        XCTAssertEqual(pace.expectedUsed,300/7,accuracy:0.0001)
        XCTAssertEqual(pace.delta,50-300/7,accuracy:0.0001)
        XCTAssertEqual(pace.position,.ahead)
        XCTAssertEqual(pace.secondsToExhaustion,3*86400)
        XCTAssertEqual(pace.summary,"超额 7% · 预计 3天0小时 后耗尽")
        XCTAssertFalse(pace.lastsUntilReset)
    }
    func testScreenshotDeficitIsPercentagePointDifference() throws {
        let pace=try XCTUnwrap(QuotaPace(used:26,period:.week,resetsAt:now.addingTimeInterval(0.95*7*86400),now:now))
        XCTAssertEqual(pace.paceText,"超额 21%")
        XCTAssertEqual(try XCTUnwrap(pace.markerPercent),5,accuracy:0.001)
        XCTAssertEqual(try XCTUnwrap(pace.secondsToExhaustion),0.05*7*86400*74/26,accuracy:0.001)
    }
    func testFiveHourWindowUsesFiveHoursInsteadOfWeek() throws {
        let pace=try XCTUnwrap(QuotaPace(used:80,period:.fiveHours,resetsAt:now.addingTimeInterval(4*3600),now:now))
        XCTAssertEqual(pace.expectedUsed,20)
        XCTAssertEqual(pace.delta,60)
        XCTAssertEqual(pace.secondsToExhaustion,900)
        XCTAssertEqual(pace.forecastText,"预计 15分钟 后耗尽")
    }
    func testLowAndZeroUsageLastUntilReset() throws {
        for used in [0.0,5] {
            let pace=try XCTUnwrap(QuotaPace(used:used,period:.week,resetsAt:now.addingTimeInterval(4*86400),now:now))
            XCTAssertTrue(pace.lastsUntilReset)
            XCTAssertNil(pace.secondsToExhaustion)
            XCTAssertEqual(pace.position,.behind)
            XCTAssertEqual(pace.forecastText,"预计可用至重置")
        }
    }
    func testOnPaceToleranceAndExactResetEquality() throws {
        for used in [48.0,50,52] {
            let pace=try XCTUnwrap(QuotaPace(used:used,period:.week,resetsAt:now.addingTimeInterval(3.5*86400),now:now))
            XCTAssertEqual(pace.paceText,"节奏正常");XCTAssertNil(pace.markerPercent)
            if used == 50 { XCTAssertTrue(pace.lastsUntilReset) }
        }
    }
    func testMissingInvalidExpiredAndEarlyWindowsDoNotInventForecasts() {
        for reset in [nil,now,now.addingTimeInterval(-1),now.addingTimeInterval(8*86400),now.addingTimeInterval(7*86400),now.addingTimeInterval(0.98*7*86400),Date(timeIntervalSince1970:.infinity)] {
            XCTAssertNil(QuotaPace(used:20,period:.week,resetsAt:reset,now:now))
        }
        for used in [Double.nan,.infinity,-1,100,101] {
            XCTAssertNil(QuotaPace(used:used,period:.week,resetsAt:now.addingTimeInterval(86400),now:now))
        }
    }
    func testDurationFormattingDoesNotRoundNearExhaustionUpToAnHour() throws {
        let pace=try XCTUnwrap(QuotaPace(used:99.9,period:.fiveHours,resetsAt:now.addingTimeInterval(4*3600),now:now))
        XCTAssertEqual(pace.forecastText,"预计 不足1分钟 后耗尽")
        XCTAssertEqual(QuotaPace.divisions(for:.fiveHours),[20,40,60,80])
        XCTAssertEqual(QuotaPace.divisions(for:.week).count,6)
    }
    func testMenuForecastIgnoresMetricButRejectsStaleFailedAndUnknownData() throws {
        let quota=WeeklyQuota(id:"codex/secondary",label:"Codex",remaining:50,resetsAt:now.addingTimeInterval(4*86400))
        let live=QuotaSnapshot(source:.official,fetchedAt:now,quotas:[quota])
        func menu(_ snapshot:QuotaSnapshot,_ metric:DisplayMetric = .used)->QuotaMenuRow {
            var prefs=RingPreferences();prefs.metric=metric
            return QuotaMenuPresentation(snapshot:snapshot,metadata:live,preferences:prefs,fiveHourSupport:false,lastRefreshedAt:now,now:now).rows[0]
        }
        let row=menu(live)
        XCTAssertNotNil(row.pace(at:now))
        XCTAssertEqual(row.pace(at:now),menu(live,.remaining).pace(at:now))
        XCTAssertNil(row.pace(at:now.addingTimeInterval(301)))
        XCTAssertNil(menu(QuotaSnapshot(source:.official,fetchedAt:now,quotas:[quota],failure:.connection)).pace(at:now))
        XCTAssertNil(menu(QuotaSnapshot(source:.official,fetchedAt:now.addingTimeInterval(-301),quotas:[quota])).pace(at:now))
        XCTAssertNil(menu(QuotaSnapshot(source:.official,fetchedAt:now)).pace(at:now))
        let debug=QuotaDebugState(isEnabled:true,weekUsed:50).snapshot(live:live)
        XCTAssertNotNil(menu(debug).pace(at:now.addingTimeInterval(301)))
    }
}
