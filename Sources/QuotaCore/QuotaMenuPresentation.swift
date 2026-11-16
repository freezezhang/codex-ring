import Foundation

public struct QuotaMenuRow:Equatable,Identifiable {
    public let period:QuotaPeriod
    public var id:String { period.rawValue }
    public var title:String { period == .week ? "本周":"5小时" }
    public let used:Double?
    public let usedText:String
    public let remainingText:String
    public let statusText:String
    public let resetText:String
    public var band:UsageBand? { used.map(UsageBand.init(used:)) }
}

/// One source of truth for menu-bar numbers and the expanded quota panel.
/// The bar follows the chosen metric and visible periods; progress bars always show
/// usage. Unknown/stale data never becomes a fabricated 0% or 100%.
public struct QuotaMenuPresentation:Equatable {
    public let title:String
    public let selectionText:String
    public let help:String
    public let rows:[QuotaMenuRow]
    public let updatedText:String
    public let cardsSummary:String
    public let showsResetCards:Bool
    public let cardLines:[String]
    public let metadataNotice:String?
    public let isDebug:Bool
    public init(snapshot:QuotaSnapshot,metadata:QuotaSnapshot,preferences:RingPreferences,
                fiveHourSupport:Bool?,lastRefreshedAt:Date?,now:Date=Date()) {
        let composition=RingComposition(snapshot:snapshot,preferences:preferences,fiveHourSupport:fiveHourSupport,now:now)
        isDebug=snapshot.source == .debug
        var selected=[(composition.outerPeriod,composition.outer)]
        if let inner=composition.inner,let period=composition.innerPeriod { selected.append((period,inner)) }
        title=selected.map { $0.1.text }.joined(separator:" | ")
        selectionText=selected.map { period,item in
            (period == .week ? "本周":"5小时")+preferences.metric.shortTitle+" "+item.text
        }.joined(separator:" · ")
        help="CodexRing · "+(isDebug ? "调试 · ":"")+selected.map { period,item in
            (period == .week ? "本周":"5小时")+preferences.metric.shortTitle+" "+item.text+(item.value == nil ? " · "+item.display.subtitle:"")
        }.joined(separator:" | ")
        let pool=snapshot.selectedPoolID(preferences.bucketID)
        let metadataPool=metadata.selectedPoolID(preferences.bucketID)
        rows=(fiveHourSupport == true ? [QuotaPeriod.fiveHours,.week]:[.week]).map { period in
            let display=snapshot.display(selectedID:pool,period:period,now:now)
            let used=RingPresentation(display:display,metric:.used)
            let remaining=RingPresentation(display:display,metric:.remaining)
            let reset=snapshot.source == .debug && period == .fiveHours
                ? display.quota?.resetsAt
                : metadata.display(selectedID:metadataPool,period:period,now:now).quota?.resetsAt
            return QuotaMenuRow(period:period,used:used.value,usedText:used.text,
                                remainingText:remaining.text,statusText:display.subtitle,
                                resetText:reset.map { QuotaDateText.string($0) } ?? "未提供")
        }
        updatedText=lastRefreshedAt.map { "刷新于 "+QuotaDateText.string($0,includeSeconds:true) } ?? "尚未刷新"
        cardsSummary=metadata.resetCards.map { $0.availableCount.map { "\($0) 张可用" } ?? "数量未知" } ?? "未提供"
        showsResetCards=metadata.resetCards.map { cards in
            cards.availableCount.map { $0>0 } ?? (cards.details?.contains(where: \.available) ?? false)
        } ?? false
        let details=QuotaDetailsPresentation(snapshot:snapshot,metadataSnapshot:metadata,preferences:preferences,
                                            fiveHourSupport:fiveHourSupport,lastRefreshedAt:lastRefreshedAt,now:now)
        // Preserve unknown, expired and partially available metadata notices.
        cardLines=showsResetCards ? details.resetMenuLines.filter { $0.hasPrefix("重置卡到期 ") }
            .map { String($0.dropFirst("重置卡到期 ".count)) }:[]
        metadataNotice=details.metadataNotice
    }
}
