import Foundation

/// Detailed accessibility text and the compact hover card.
public struct QuotaDetailsPresentation {
    public let tooltip:String
    public let hoverCardText:String
    public let resetLines:[String]
    public let cardLines:[String]
    public let metadataNotice:String?
    /// Dates and availability messages for the quota panel.
    let cardExpiryTexts:[String]
    public init(snapshot:QuotaSnapshot,metadataSnapshot:QuotaSnapshot?=nil,preferences:RingPreferences,
                fiveHourSupport:Bool?,lastRefreshedAt:Date?,now:Date=Date()) {
        let metadata=metadataSnapshot ?? snapshot
        let pool=metadata.selectedPoolID(preferences.bucketID)
        func resetDate(_ period:QuotaPeriod)->Date? {
            if snapshot.source == .debug,period == .fiveHours {
                return snapshot.display(selectedID:preferences.bucketID,period:period,now:now).quota?.resetsAt
            }
            return metadata.display(selectedID:pool,period:period,now:now).quota?.resetsAt
        }
        let composition=RingComposition(snapshot:snapshot,preferences:preferences,fiveHourSupport:fiveHourSupport,now:now)
        var usage=[L10n.format("details.periodLine",composition.outerPeriod.title,Self.usage(composition.outer))]
        if let inner=composition.inner,let period=composition.innerPeriod {
            usage.append(L10n.format("details.periodLine",period.title,Self.usage(inner)))
            usage.append(L10n.format("details.center",composition.centerPeriod.title,Self.usage(composition.center)))
        }
        if snapshot.source == .debug { usage.insert(L10n.string("status.debug"),at:0) }
        let periods:[QuotaPeriod]=fiveHourSupport == true ? [.week,.fiveHours]:[.week]
        func date(_ value:Date?)->String {
            guard let value else { return L10n.string("common.notProvided") }
            return QuotaDateText.string(value)
        }
        resetLines=periods.map { period in
            L10n.format("details.autoReset",period.title,date(resetDate(period)))
        }
        if let cards=metadata.resetCards {
            let available=cards.details?.filter(\.available) ?? []
            var lines=[L10n.format("details.cards",Self.cardCount(cards.availableCount))]
            lines += available.map { L10n.format("details.cardLine",$0.displayTitle,$0.expiryText(now:now)) }
            if cards.availableCount.map({$0>available.count}) == true || (cards.availableCount == nil && available.isEmpty) {
                lines.append(L10n.string("details.cardsExpiryMissing"))
            }
            cardLines=lines
        } else { cardLines=[L10n.format("details.cards",L10n.string("common.notProvided"))] }
        if metadata.failure != nil { metadataNotice=L10n.string("metadata.failed") }
        else if metadata.loading { metadataNotice=L10n.string("metadata.loading") }
        else if now.timeIntervalSince(metadata.fetchedAt)>300 || metadata.fetchedAt.timeIntervalSince(now)>60 {
            metadataNotice=L10n.string("metadata.stale")
        } else { metadataNotice=nil }
        let refresh=L10n.format("details.lastRefreshed",lastRefreshedAt.map { QuotaDateText.string($0) } ?? L10n.string("common.neverRefreshed"))
        var sections=[usage.joined(separator:"\n"),refresh,resetLines.joined(separator:"\n"),cardLines.joined(separator:"\n")]
        if let metadataNotice { sections.append(metadataNotice) }
        let offline=snapshot.failure == .offline
        tooltip=(offline ? [L10n.string("status.offline"),refresh]:sections).joined(separator:"\n\n")
        let usagePool=snapshot.selectedPoolID(preferences.bucketID)
        let quotaItems=periods.map { period -> String in
            let item=RingPresentation(display:snapshot.display(selectedID:usagePool,period:period,now:now),metric:preferences.metric)
            return item.value == nil ? L10n.format("hover.periodStatus",period.shortName,item.display.subtitle)
                : period.value(preferences.metric.value(item.text))
        }
        hoverCardText=offline ? L10n.string("status.offline")
            : ((snapshot.source == .debug ? [L10n.string("status.debug")]:[])+quotaItems).joined(separator:"\n")
        var cardTexts:[String]=[]
        if let cards=metadata.resetCards {
            let available=cards.details?.filter(\.available) ?? []
            cardTexts += available.map { card in
                card.expiresAt.map { $0<=now ? L10n.format("menu.cardExpired",date($0)):date($0) } ?? L10n.string("cards.timeMissing")
            }
            if cards.availableCount == 0,available.isEmpty { cardTexts.append(L10n.string("cards.none")) }
            else if available.isEmpty || cards.availableCount.map({$0>available.count}) == true { cardTexts.append(L10n.string("cards.partialTimeMissing")) }
        } else { cardTexts.append(L10n.string("common.notProvided")) }
        cardExpiryTexts=cardTexts
    }
    static func cardCount(_ count:Int?)->String {
        count.map { L10n.format("cards.available",$0) } ?? L10n.string("cards.countUnknown")
    }
    private static func usage(_ presentation:RingPresentation)->String {
        presentation.value == nil ? presentation.display.subtitle:presentation.metric.compactValue(presentation.text)
    }
}
