import Foundation

/// Detailed accessibility text and the compact hover card.
public struct QuotaDetailsPresentation {
    public let tooltip:String
    public let hoverCardText:String
    public let resetMenuLines:[String]
    public let resetLines:[String]
    public let cardLines:[String]
    public let metadataNotice:String?
    public init(snapshot:QuotaSnapshot,metadataSnapshot:QuotaSnapshot?=nil,preferences:RingPreferences,
                fiveHourSupport:Bool?,lastRefreshedAt:Date?,now:Date=Date()) {
        let metadata=metadataSnapshot ?? snapshot
        let pool=metadata.selectedPoolID(preferences.bucketID)
        let composition=RingComposition(snapshot:snapshot,preferences:preferences,fiveHourSupport:fiveHourSupport,now:now)
        var usage=["\(composition.outerPeriod.title)：\(Self.usage(composition.outer))"]
        if let inner=composition.inner,let period=composition.innerPeriod {
            usage.append("\(period.title)：\(Self.usage(inner))")
            usage.append("中心数字：\(composition.centerPeriod.title) · \(Self.usage(composition.center))")
        }
        if snapshot.source == .debug { usage.insert("调试模式",at:0) }
        let periods:[QuotaPeriod]=fiveHourSupport == true ? [.week,.fiveHours]:[.week]
        resetLines=periods.map { period in
            let date=metadata.display(selectedID:pool,period:period,now:now).quota?.resetsAt
            return "\(period.title)系统自动重置：\(date.map { QuotaDateText.string($0) } ?? "未提供")"
        }
        if let cards=metadata.resetCards {
            let available=cards.details?.filter(\.available) ?? []
            var lines=["重置卡：\(cards.availableCount.map { "\($0) 张可用" } ?? "数量未知")"]
            lines += available.map { "\($0.displayTitle)　\($0.expiryText(now:now))" }
            if cards.availableCount.map({$0>available.count}) == true || (cards.availableCount == nil && available.isEmpty) {
                lines.append("重置卡到期时间未提供")
            }
            cardLines=lines
        } else { cardLines=["重置卡：未提供"] }
        if metadata.failure != nil { metadataNotice="重置信息：刷新失败" }
        else if metadata.loading { metadataNotice="重置信息：正在加载" }
        else if now.timeIntervalSince(metadata.fetchedAt)>300 || metadata.fetchedAt.timeIntervalSince(now)>60 {
            metadataNotice="重置信息：数据已过期"
        } else { metadataNotice=nil }
        let refresh="上次刷新时间：\(lastRefreshedAt.map { QuotaDateText.string($0) } ?? "尚未刷新")"
        var sections=[usage.joined(separator:"\n"),refresh,resetLines.joined(separator:"\n"),cardLines.joined(separator:"\n")]
        if let metadataNotice { sections.append(metadataNotice) }
        tooltip=sections.joined(separator:"\n\n")
        let formatter=DateFormatter()
        formatter.locale=Locale(identifier:"zh_CN");formatter.calendar=Calendar(identifier:.gregorian)
        formatter.timeZone=TimeZone(identifier:"Asia/Shanghai")
        func date(_ value:Date?,format:String)->String {
            guard let value else { return "未提供" }
            formatter.dateFormat=format;return formatter.string(from:value)
        }
        let usagePool=snapshot.selectedPoolID(preferences.bucketID)
        let quotaItems=periods.map { period -> String in
            let item=RingPresentation(display:snapshot.display(selectedID:usagePool,period:period,now:now),metric:preferences.metric)
            let name=period == .week ? "本周":"5小时"
            return item.value == nil ? name+" "+item.display.subtitle:name+preferences.metric.shortTitle+" "+item.text
        }
        hoverCardText=((snapshot.source == .debug ? ["调试模式"]:[])+quotaItems).joined(separator:"\n")
        var rows=["自动重置于 "+date(metadata.display(selectedID:pool,period:.week,now:now).quota?.resetsAt,format:"yyyy.MM.dd HH:mm")]
        if let cards=metadata.resetCards {
            let available=cards.details?.filter(\.available) ?? []
            rows += available.map { card in
                "重置卡到期 "+(card.expiresAt.map { date($0,format:"yyyy-MM-dd HH:mm")+($0<=now ? "（已过期）":"") } ?? "时间未提供")
            }
            if cards.availableCount == 0,available.isEmpty { rows.append("重置卡到期 无可用卡") }
            else if available.isEmpty || cards.availableCount.map({$0>available.count}) == true { rows.append("重置卡到期 部分时间未提供") }
        } else { rows.append("重置卡到期 未提供") }
        if let metadataNotice { rows.append(metadataNotice) }
        resetMenuLines=rows
    }
    private static func usage(_ presentation:RingPresentation)->String {
        presentation.value == nil ? presentation.display.subtitle:"\(presentation.metric.shortTitle)\(presentation.text)"
    }
}
