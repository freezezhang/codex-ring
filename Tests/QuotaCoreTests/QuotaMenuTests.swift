import XCTest
@testable import QuotaCore

final class QuotaMenuTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1793700000)
    func live(five:Bool=true)->QuotaSnapshot {
        var rows=[WeeklyQuota(id:"codex/secondary",label:"Codex",remaining:55,resetsAt:now.addingTimeInterval(86400))]
        if five { rows.append(WeeklyQuota(id:"codex/primary",label:"Codex",remaining:17.5,resetsAt:now.addingTimeInterval(3600),period:.fiveHours)) }
        return QuotaSnapshot(source:.official,fetchedAt:now,quotas:rows)
    }
    func data(_ snapshot:QuotaSnapshot,preferences:RingPreferences=RingPreferences(),support:Bool?=true)->QuotaMenuPresentation {
        QuotaMenuPresentation(snapshot:snapshot,metadata:snapshot,preferences:preferences,fiveHourSupport:support,lastRefreshedAt:now,now:now)
    }
    func testMenuNumbersFollowMetricAndVisiblePeriodsButIgnoreCenterChoice() {
        var p=RingPreferences();p.showFiveHours=true;p.metric = .used
        let week=data(live(),preferences:p)
        XCTAssertEqual(week.title,"45% | 82.5%");XCTAssertEqual(week.rows.map(\.used),[82.5,45])
        XCTAssertEqual(week.rows.map(\.period),[.fiveHours,.week])
        p.centerPeriod = .fiveHours;p.metric = .remaining
        let five=data(live(),preferences:p)
        XCTAssertEqual(five.title,"55% | 17.5%");XCTAssertEqual(five.selectionText,"本周剩余 55% · 5小时剩余 17.5%")
        XCTAssertEqual(five.rows,week.rows);XCTAssertEqual(five.rows[0].band,.orange)
        XCTAssertEqual(week.updatedText,"刷新于 18:00:00")
        XCTAssertFalse(five.title.contains("剩余"));XCTAssertFalse(five.title.contains("已用"))
    }
    func testUnavailableFiveHoursIsHiddenAndCannotControlBar() {
        var p=RingPreferences();p.showFiveHours=true;p.centerPeriod = .fiveHours
        let view=data(live(five:false),preferences:p,support:false)
        XCTAssertEqual(view.rows.map(\.period),[.week]);XCTAssertEqual(view.title,"55%")
    }
    func testPanelShowsSupportedPeriodsRegardlessOfVisibleRings() {
        var p=RingPreferences();p.showWeek=false;p.showFiveHours=true
        let view=data(live(),preferences:p)
        XCTAssertEqual(view.rows.count,2);XCTAssertEqual(view.title,"17.5%")
    }
    func testFailureLoadingAndStaleHaveNoProgressOrFakeNumber() {
        let snapshots=[QuotaSnapshot(source:.official,fetchedAt:now,loading:true),
                       QuotaSnapshot(source:.official,fetchedAt:now,failure:.connection),
                       QuotaSnapshot(source:.official,fetchedAt:now.addingTimeInterval(-301),quotas:live().quotas)]
        for snapshot in snapshots {
            let view=data(snapshot)
            XCTAssertEqual(view.title,"—");XCTAssertTrue(view.rows.allSatisfy{$0.used == nil})
            XCTAssertNotNil(view.metadataNotice)
        }
    }
    func testDebugLabelStaysOutOfBarAndMetadataRemainsReal() {
        let metadata=live()
        let debug=QuotaDebugState(isEnabled:true,weekUsed:90,fiveHoursUsed:20).snapshot(live:metadata)
        var p=RingPreferences();p.metric = .used
        let view=QuotaMenuPresentation(snapshot:debug,metadata:metadata,preferences:p,fiveHourSupport:true,lastRefreshedAt:now,now:now)
        XCTAssertEqual(view.title,"90%");XCTAssertTrue(view.help.contains("调试"))
        XCTAssertEqual(view.rows.map(\.used),[20,90]);XCTAssertEqual(view.cardsSummary,"未提供")
        XCTAssertEqual(view.rows[0].resetText,data(metadata).rows[0].resetText)
    }
    func testMenuVisibilityPersistsAndExistingSettingsEnableIt() throws {
        XCTAssertTrue(try JSONDecoder().decode(RingPreferences.self,from:Data("{}".utf8)).showMenuBar)
        var p=RingPreferences();p.showMenuBar=false
        XCTAssertEqual(try JSONDecoder().decode(RingPreferences.self,from:JSONEncoder().encode(p)),p)
    }
    func testCardColorsFollowRealExpiryAfterFilteringUsedCardsAndMissingDetails() {
        let cards=ResetCards(availableCount:5,details:[
            ResetCard(title:"Used",expiresAt:now,status:"used"),
            ResetCard(title:"Soon",expiresAt:now.addingTimeInterval(36*3600),status:"available"),
            ResetCard(title:"Unknown",expiresAt:nil,status:"available"),
            ResetCard(title:"Later",expiresAt:now.addingTimeInterval(96*3600),status:"available"),
            ResetCard(title:"Expired",expiresAt:now.addingTimeInterval(-1),status:"available")
        ])
        let real=QuotaSnapshot(source:.official,fetchedAt:now,quotas:live().quotas,resetCards:cards)
        let debug=QuotaDebugState(isEnabled:true).snapshot(live:live(),now:now)
        let view=QuotaMenuPresentation(snapshot:debug,metadata:real,preferences:RingPreferences(),fiveHourSupport:true,lastRefreshedAt:now,now:now)
        XCTAssertEqual(view.cardRows.map(\.expiryBand),[.orange,.normal,.yellow,.red,.normal])
        XCTAssertEqual(view.cardLines[0],"2026.11.05 06:00")
        XCTAssertEqual(view.cardLines[1],"时间未提供")
        XCTAssertTrue(view.cardLines[3].contains("已过期"))
        XCTAssertEqual(view.cardLines.last,"部分时间未提供")
        let later=QuotaMenuPresentation(snapshot:debug,metadata:real,preferences:RingPreferences(),fiveHourSupport:true,lastRefreshedAt:now,now:now.addingTimeInterval(12*3600))
        XCTAssertEqual(later.cardRows[0].expiryBand,.red)
    }
    func testCardsSectionOnlyAppearsWhenAvailableCardsAreReported() {
        let available=ResetCard(title:"Full reset",expiresAt:now.addingTimeInterval(3600),status:"available")
        let used=ResetCard(title:"Full reset",expiresAt:nil,status:"used")
        let cases:[(ResetCards?,Bool)]=[
            (nil,false),
            (ResetCards(availableCount:0,details:[]),false),
            (ResetCards(availableCount:nil,details:nil),false),
            (ResetCards(availableCount:nil,details:[used]),false),
            (ResetCards(availableCount:0,details:[available]),false),
            (ResetCards(availableCount:1,details:nil),true),
            (ResetCards(availableCount:nil,details:[available]),true)
        ]
        for (cards,visible) in cases {
            let snapshot=QuotaSnapshot(source:.official,fetchedAt:now,quotas:live().quotas,resetCards:cards)
            let view=data(snapshot)
            XCTAssertEqual(view.showsResetCards,visible)
            XCTAssertEqual(view.cardLines.isEmpty,!visible)
        }
    }
    func testDebugResetFallbackIsSharedByPanelAndMenuAndKeepsProvidedDates() {
        let renderingTime=now.addingTimeInterval(120)
        var state=QuotaDebugState(isEnabled:true)
        for hasFive in [false,true] {
            let metadata=live(five:hasFive)
            let debug=state.snapshot(live:metadata,now:renderingTime)
            let view=QuotaMenuPresentation(snapshot:debug,metadata:metadata,preferences:RingPreferences(),fiveHourSupport:true,lastRefreshedAt:now,now:renderingTime)
            let details=QuotaDetailsPresentation(snapshot:debug,metadataSnapshot:metadata,preferences:RingPreferences(),fiveHourSupport:true,lastRefreshedAt:now,now:renderingTime)
            let expected=hasFive ? "19:00":"19:02"
            XCTAssertEqual(view.rows[0].resetText,"2026.11.03 "+expected)
            XCTAssertTrue(details.resetMenuLines.contains("5小时重置于 2026.11.03 "+expected))
            XCTAssertEqual(view.rows[1].resetText,"2026.11.04 18:00")
        }
        state.isEnabled=false
        XCTAssertNil(state.snapshot(live:live(five:false),now:renderingTime).display(period:.fiveHours,now:renderingTime).quota?.resetsAt)
    }
}
