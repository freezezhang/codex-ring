import XCTest
@testable import QuotaCore

final class HoverAndDebugTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1793700000)
    func live(five:Bool=true,cards:ResetCards?=nil)->QuotaSnapshot {
        var quotas=[WeeklyQuota(id:"codex/secondary",label:"Codex",remaining:68,resetsAt:now.addingTimeInterval(86400))]
        if five { quotas.append(WeeklyQuota(id:"codex/primary",label:"Codex",remaining:19.5,resetsAt:now.addingTimeInterval(3600),period:.fiveHours)) }
        return QuotaSnapshot(source:.official,fetchedAt:now,quotas:quotas,resetCards:cards)
    }
    func details(_ snapshot:QuotaSnapshot,preferences:RingPreferences=RingPreferences(),support:Bool?=true,lastRefresh:Date?=nil)->QuotaDetailsPresentation {
        QuotaDetailsPresentation(snapshot:snapshot,preferences:preferences,fiveHourSupport:support,lastRefreshedAt:lastRefresh,now:now)
    }
    func testHoverUsesSelectedMetricAndExactPercentage() {
        var p=RingPreferences()
        XCTAssertTrue(details(live(),preferences:p).tooltip.contains("1周：剩余68%"))
        p.metric = .used
        let tip=details(live(),preferences:p).tooltip
        XCTAssertTrue(tip.contains("1周：已用32%"));XCTAssertFalse(tip.contains("剩余68%"))
        p.showWeek=false;p.showFiveHours=true
        XCTAssertTrue(details(live(),preferences:p).tooltip.contains("5小时：已用80.5%"))
    }
    func testDualRingHoverHasBothValuesAndSeparateResetTimes() {
        var p=RingPreferences();p.showFiveHours=true
        let information=details(live(),preferences:p,lastRefresh:now)
        XCTAssertTrue(information.tooltip.contains("1周：剩余68%"))
        XCTAssertTrue(information.tooltip.contains("5小时：剩余19.5%"))
        XCTAssertTrue(information.tooltip.contains("上次刷新时间：\(QuotaDateText.string(now))"))
        XCTAssertEqual(information.resetLines,[
            "1周系统自动重置：\(QuotaDateText.string(now.addingTimeInterval(86400)))",
            "5小时系统自动重置：\(QuotaDateText.string(now.addingTimeInterval(3600)))"
        ])
        for line in information.resetLines { XCTAssertTrue(information.tooltip.contains(line)) }
        XCTAssertEqual(Array(information.resetMenuLines.prefix(2)),[
            "5小时重置于 2026.11.03 19:00",
            "本周重置于 2026.11.04 18:00"
        ])
    }
    func testResetMenuUsesAccountWindowsRegardlessOfVisibleRings() {
        // The default only shows the weekly ring, but both reset times matter.
        XCTAssertTrue(details(live()).resetMenuLines.contains("5小时重置于 2026.11.03 19:00"))
        let weekOnly=details(live(five:false),support:false).resetMenuLines
        XCTAssertEqual(weekOnly.first,"本周重置于 2026.11.04 18:00")
        XCTAssertFalse(weekOnly.contains { $0.hasPrefix("5小时") })
    }
    func testFirstLoadDoesNotInventRefreshOrResetDates() {
        let information=details(QuotaSnapshot(source:.official,fetchedAt:now,loading:true),support:nil)
        XCTAssertTrue(information.tooltip.contains("上次刷新时间：尚未刷新"))
        XCTAssertEqual(information.resetLines,["1周系统自动重置：未提供"])
        XCTAssertEqual(information.cardLines,["重置卡：未提供"])
        XCTAssertEqual(information.metadataNotice,"重置信息：正在加载")
        XCTAssertFalse(information.tooltip.contains("0%"))
    }
    func testHoverAndMenuShareCardNamesExpiryAndMissingDetails() {
        let expiry=now.addingTimeInterval(10000)
        let cards=ResetCards(availableCount:3,details:[
            ResetCard(title:"Full reset",expiresAt:expiry,status:"available"),
            ResetCard(title:"Other",expiresAt:nil,status:"available"),
            ResetCard(title:"Redeemed",expiresAt:expiry,status:"used")
        ])
        let information=details(live(cards:cards))
        XCTAssertEqual(information.cardLines,["重置卡：3 张可用",
            "完全重置　将于 \(QuotaDateText.string(expiry)) 到期","Other　到期时间未知","重置卡到期时间未提供"])
        for line in information.cardLines { XCTAssertTrue(information.tooltip.contains(line)) }
        XCTAssertFalse(information.tooltip.contains("Redeemed"))
        XCTAssertTrue(information.resetMenuLines.contains("重置卡到期 2026.11.03 20:46"))
    }
    func testZeroUnknownAndExpiredCardsRemainDistinct() {
        XCTAssertEqual(details(live(cards:ResetCards(availableCount:0,details:[]))).cardLines,["重置卡：0 张可用"])
        let unknown=details(live(cards:ResetCards(availableCount:nil,details:nil))).cardLines
        XCTAssertTrue(unknown.contains("重置卡：数量未知"));XCTAssertTrue(unknown.contains("重置卡到期时间未提供"))
        let expired=ResetCards(availableCount:1,details:[ResetCard(title:"Full reset",expiresAt:now,status:"available")])
        XCTAssertTrue(details(live(cards:expired)).cardLines[1].contains("已于"))
    }
    func testFailureRetainsLastSuccessfulRefreshLabelWithoutFakingPercentages() {
        let failed=QuotaSnapshot(source:.official,fetchedAt:now,failure:.connection)
        let information=details(failed,lastRefresh:now.addingTimeInterval(-120))
        XCTAssertTrue(information.tooltip.contains("上次刷新时间：\(QuotaDateText.string(now.addingTimeInterval(-120)))"))
        XCTAssertTrue(information.tooltip.contains("连接失败"));XCTAssertFalse(information.tooltip.contains("100%"))
        XCTAssertEqual(information.metadataNotice,"重置信息：刷新失败")
    }
    func testStaleDataDoesNotAppearAsCurrentPercentage() {
        let old=QuotaSnapshot(source:.official,fetchedAt:now.addingTimeInterval(-301),quotas:live().quotas)
        let information=details(old)
        XCTAssertTrue(information.tooltip.contains("数据已过期"));XCTAssertFalse(information.tooltip.contains("剩余68%"))
        XCTAssertEqual(information.metadataNotice,"重置信息：数据已过期")
    }
    func testDisabledDebugPreservesLiveDataAndCapabilities() {
        let state=QuotaDebugState(weekUsed:90,fiveHoursUsed:80)
        let real=live(five:false),visible=state.snapshot(live:real)
        XCTAssertEqual(visible.source,.official);XCTAssertEqual(visible.quotas,real.quotas)
        var capabilities=QuotaCapabilities();capabilities.observe(visible)
        XCTAssertEqual(capabilities.fiveHourSupport,false)
    }
    func testDebugAddsFiveHoursForWeekOnlyAccountAndUsesIndependentThresholds() {
        let real=live(five:false),state=QuotaDebugState(isEnabled:true,weekUsed:71,fiveHoursUsed:92)
        let visible=state.snapshot(live:real)
        var p=RingPreferences();p.showFiveHours=true
        let composition=RingComposition(snapshot:visible,preferences:p,fiveHourSupport:true,now:now)
        XCTAssertEqual(visible.source,.debug)
        XCTAssertEqual(composition.outer.value,29);XCTAssertEqual(composition.inner?.value,8)
        XCTAssertEqual(composition.outer.band,.yellow);XCTAssertEqual(composition.inner?.band,.red)
        XCTAssertTrue(composition.accessibilityText.contains("调试模式"))
        XCTAssertNil(real.display(period:.fiveHours,now:now).remaining)
        var capabilities=QuotaCapabilities();capabilities.observe(real);capabilities.observe(visible)
        XCTAssertEqual(capabilities.fiveHourSupport,false)
    }
    func testDebugSimulatesMissingFiveHourResetButPreservesOtherMetadata() {
        let real=live(five:false),state=QuotaDebugState(isEnabled:true,weekUsed:12,fiveHoursUsed:34)
        let visible=state.snapshot(live:real,now:now)
        XCTAssertEqual(visible.fetchedAt,real.fetchedAt)
        XCTAssertEqual(visible.display(period:.fiveHours,now:now).quota?.resetsAt,now.addingTimeInterval(3600))
        XCTAssertNil(real.display(period:.fiveHours,now:now).quota?.resetsAt)
        XCTAssertNil(visible.resetCards)
        let information=QuotaDetailsPresentation(snapshot:visible,metadataSnapshot:real,preferences:RingPreferences(),fiveHourSupport:true,lastRefreshedAt:now,now:now)
        XCTAssertTrue(information.tooltip.hasPrefix("调试模式"))
        XCTAssertTrue(information.resetLines.contains("5小时系统自动重置：\(QuotaDateText.string(now.addingTimeInterval(3600)))"))
        XCTAssertTrue(information.resetMenuLines.contains("5小时重置于 2026.11.03 19:00"))
        XCTAssertTrue(information.tooltip.contains("上次刷新时间：\(QuotaDateText.string(now))"))
    }
    func testDebugStillWorksWhenLiveQueryIsFailedOrExpiredAndDisablingRestoresFailure() {
        let real=QuotaSnapshot(source:.official,fetchedAt:now.addingTimeInterval(-600),quotas:live().quotas,failure:.connection)
        var state=QuotaDebugState(isEnabled:true,weekUsed:100,fiveHoursUsed:0)
        let debug=state.snapshot(live:real)
        XCTAssertEqual(debug.display(now:now).remaining,0)
        XCTAssertEqual(debug.display(period:.fiveHours,now:now).remaining,100)
        state.isEnabled=false
        XCTAssertEqual(state.snapshot(live:real).display(now:now).status,.connection)
        XCTAssertNil(state.snapshot(live:real).display(now:now).remaining)
    }
    func testDebugClampsNumericInputsAndCanReturnToBothEndpoints() {
        var state=QuotaDebugState(isEnabled:true,weekUsed:-1,fiveHoursUsed:101)
        XCTAssertEqual(state.weekUsed,0);XCTAssertEqual(state.fiveHoursUsed,100)
        state.weekUsed = .nan;state.fiveHoursUsed = .infinity
        XCTAssertEqual(state.weekUsed,0);XCTAssertEqual(state.fiveHoursUsed,0)
        state.weekUsed=100;state.fiveHoursUsed=80.5
        XCTAssertEqual(state.snapshot(live:live()).display(now:now).remaining,0)
        XCTAssertEqual(state.snapshot(live:live()).display(period:.fiveHours,now:now).remaining,19.5)
    }
    func testDebugAndTooltipNormalizeLegacyBucketIDsWithoutMixingPools() {
        var p=RingPreferences();p.bucketID="other/secondary";p.showFiveHours=true
        let other=WeeklyQuota(id:"other/secondary",label:"Other",remaining:40,resetsAt:now.addingTimeInterval(2000))
        let real=QuotaSnapshot(source:.official,fetchedAt:now,quotas:live().quotas+[other])
        let visible=QuotaDebugState(isEnabled:true,weekUsed:25,fiveHoursUsed:50).snapshot(live:real,selectedID:p.bucketID,now:now)
        XCTAssertEqual(Set(visible.quotas.map(\.poolID)),["other"])
        let composition=RingComposition(snapshot:visible,preferences:p,fiveHourSupport:true,now:now)
        XCTAssertEqual(composition.outer.value,75);XCTAssertEqual(composition.inner?.value,50)
        let information=QuotaDetailsPresentation(snapshot:visible,metadataSnapshot:real,preferences:p,fiveHourSupport:true,lastRefreshedAt:now,now:now)
        XCTAssertEqual(information.resetLines.last,"5小时系统自动重置：\(QuotaDateText.string(now.addingTimeInterval(3600)))")
        XCTAssertTrue(information.resetMenuLines.contains("5小时重置于 2026.11.03 19:00"))
    }
}
