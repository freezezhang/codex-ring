import Foundation

public struct QuotaMenuCardRow:Equatable {
    public let text:String
    public let expiryBand:ResetCardExpiryBand
    public let expiresAt:Date?
    public func expiryBand(at now:Date)->ResetCardExpiryBand {
        ResetCardExpiryBand(expiresAt:expiresAt,now:now)
    }
    public func displayText(at now:Date)->String {
        guard let expiresAt else { return text }
        let remaining=expiresAt.timeIntervalSince(now)
        guard remaining.isFinite else { return text }
        guard remaining>0 else { return "已过期" }
        guard expiryBand(at:now) == .red else { return text }
        let seconds=Int(ceil(remaining))
        return "\(seconds/3600)时\((seconds%3600)/60)分\(seconds%60)秒"
    }
}

public struct QuotaMenuRow:Equatable,Identifiable {
    public let period:QuotaPeriod
    public var id:String { period.rawValue }
    public var title:String { period == .week ? "本周":"5小时" }
    public let used:Double?
    public let usedText:String
    public let remainingText:String
    public let statusText:String
    public let resetText:String
    public let resetsAt:Date?
    public let paceValidUntil:Date?
    public let panel:QuotaPanelPreferences
    public let metric:DisplayMetric
    public func pace(at now:Date)->QuotaPace? {
        guard panel.showPace,let used,paceValidUntil.map({ now<=$0 }) ?? true else { return nil }
        return QuotaPace(used:used,period:period,resetsAt:resetsAt,now:now,workDays:panel.weeklySchedule.workDays)
    }
    public func progressPosition(_ usedPercent:Double)->Double { metric == .used ? usedPercent:100-usedPercent }
    public var progressPercent:Double? { used.map(progressPosition) }
    public var progressText:String { metric.shortTitle+" "+(metric == .used ? usedText:remainingText) }
    public var divisionMarkers:[Double] {
        panel.tickStyle == .hidden ? []:QuotaPace.divisions(for:period,workDays:panel.weeklySchedule.workDays).map(progressPosition).sorted()
    }
    public func resetDescription(at now:Date)->String {
        guard panel.resetStyle == .dateTime else { return resetCountdown(at:now) }
        guard let resetsAt,resetsAt.timeIntervalSince1970.isFinite else { return "重置时间未提供" }
        return resetsAt>now ? "重置于 "+resetText:"等待重置"
    }
    public func resetCountdown(at now:Date)->String {
        guard let resetsAt else { return "重置时间未提供" }
        let interval=resetsAt.timeIntervalSince(now)
        guard interval.isFinite else { return "重置时间未提供" }
        guard interval>0 else { return "等待重置" }
        let seconds=Int64(min(ceil(interval),315_576_000_000))
        var text=""
        if seconds>=86400 { text += "\(seconds/86400)天" }
        if seconds>=3600 { text += "\((seconds%86400)/3600)时" }
        if seconds>=60 { text += "\((seconds%3600)/60)分" }
        return text+"\(seconds%60)秒 后重置"
    }
    public var band:UsageBand? { used.map(UsageBand.init(used:)) }
}

/// One source of truth for menu-bar numbers and the expanded quota panel.
/// The bar, rings and panel share the display metric. Unknown/stale data never
/// becomes a fabricated 0% or 100%.
public struct QuotaMenuPresentation:Equatable {
    public let title:String
    public let selectionText:String
    public let help:String
    public let rows:[QuotaMenuRow]
    public let updatedText:String
    public let cardsSummary:String
    public let showsResetCards:Bool
    public let cardRows:[QuotaMenuCardRow]
    public var cardLines:[String] { cardRows.map(\.text) }
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
                                resetText:reset.map { QuotaDateText.string($0) } ?? "未提供",resetsAt:reset,
                                paceValidUntil:snapshot.source == .debug ? nil:snapshot.fetchedAt.addingTimeInterval(300),
                                panel:preferences.quotaPanel,metric:preferences.metric)
        }
        updatedText=lastRefreshedAt.map { "刷新于 "+QuotaDateText.string($0,includeSeconds:true,includeDate:false) } ?? "尚未刷新"
        cardsSummary=metadata.resetCards.map { $0.availableCount.map { "\($0) 张可用" } ?? "数量未知" } ?? "未提供"
        showsResetCards=metadata.resetCards.map { cards in
            cards.availableCount.map { $0>0 } ?? (cards.details?.contains(where: \.available) ?? false)
        } ?? false
        let details=QuotaDetailsPresentation(snapshot:snapshot,metadataSnapshot:metadata,preferences:preferences,
                                            fiveHourSupport:fiveHourSupport,lastRefreshedAt:lastRefreshedAt,now:now)
        // Preserve unknown, expired and partially available metadata notices.
        let cardLines=showsResetCards ? details.resetMenuLines.filter { $0.hasPrefix("重置卡过期 ") }
            .map { String($0.dropFirst("重置卡过期 ".count)) }:[]
        // The detail presentation emits available cards in metadata order,
        // followed by any missing-detail notice, which has no expiry date.
        let available=metadata.resetCards?.details?.filter(\.available) ?? []
        cardRows=cardLines.enumerated().map { index,text in
            let expiry=available.indices.contains(index) ? available[index].expiresAt:nil
            return QuotaMenuCardRow(text:text,expiryBand:ResetCardExpiryBand(expiresAt:expiry,now:now),expiresAt:expiry)
        }
        metadataNotice=details.metadataNotice
    }
}
