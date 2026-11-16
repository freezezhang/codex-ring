import Foundation

public struct QuotaAlertPreferences:Codable,Equatable {
    public var enabled=false
    public var lowQuota=true
    public var remainingThreshold=20
    public var predictedExhaustion=true
    public var predictionMinutes=60
    public var restored=true
    public var resetCards=true
    public var cardDays=3
    public init() {}
    public mutating func normalize() {
        remainingThreshold=min(99,max(1,remainingThreshold))
        predictionMinutes=min(1440,max(5,predictionMinutes))
        cardDays=min(30,max(1,cardDays))
    }
}

public struct QuotaAlert:Equatable {
    public enum Kind:String { case low,prediction,restored,card }
    public let kind:Kind
    public let key:String
    public let title:String
    public let body:String
}
public struct QuotaAlertResult {
    public var alerts:[QuotaAlert]=[]
    public var celebrate=false
}

/// Consume successful live fetches only. Baselines are session-local: opening the
/// app, switching pools, and debug previews must never manufacture a reset.
/// Receipts persist independently so ordinary warnings survive app restarts.
public struct QuotaAlertEngine {
    private struct Observation { let remaining:Double;let reset:Date?;let fetched:Date }
    private var previous:[QuotaPeriod:Observation]=[:]
    private var pool:String?
    public private(set) var receipts:[String:Date]
    public init(receipts:[String:Date]=[:]) { self.receipts=receipts }
    public mutating func clearBaseline() { previous.removeAll();pool=nil }
    public mutating func evaluate(_ snapshot:QuotaSnapshot,preferences:RingPreferences,notificationsAllowed:Bool,now:Date)->QuotaAlertResult {
        var result=QuotaAlertResult()
        guard snapshot.source == .official,snapshot.failure == nil,!snapshot.loading,
              (-60...300).contains(now.timeIntervalSince(snapshot.fetchedAt)),
              let selected=snapshot.selectedPoolID(preferences.bucketID) else { return result }
        receipts=receipts.filter { now.timeIntervalSince($0.value)<35*86400 }
        if pool != selected { previous.removeAll();pool=selected }
        var options=preferences.alerts;options.normalize()
        let notify=options.enabled && notificationsAllowed
        for period in QuotaPeriod.allCases {
            let display=snapshot.display(selectedID:selected,period:period,now:now)
            guard let remaining=display.remaining,remaining.isFinite,(0...100).contains(remaining) else { continue }
            let reset=display.quota?.resetsAt
            let old=previous[period]
            guard old == nil || snapshot.fetchedAt>old!.fetched else { continue }
            previous[period]=Observation(remaining:remaining,reset:reset,fetched:snapshot.fetchedAt)
            let name=period.quotaName
            let percent=Int(remaining.rounded())
            // A missing deadline gets a session-independent identity. Metadata
            // returning later is treated as a new known cycle, not a reset.
            let boundary=reset.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
            let cycle="\(selected)/\(period.rawValue)/\(boundary)"
            if let old,now.timeIntervalSince(old.fetched)<=600 {
                let advanced=old.reset.flatMap { before in reset.map { $0.timeIntervalSince(before)>60 } } ?? false
                let recovered=old.remaining<=0 && remaining>0
                let resetConfirmed=remaining-old.remaining>=10 && (advanced || remaining>=99)
                if recovered || resetConfirmed {
                    let key="restore/\(cycle)"
                    if receipts[key] == nil {
                        receipts[key]=now
                        if notify && options.restored {
                            result.alerts.append(QuotaAlert(kind:.restored,key:key,title:L10n.format("alert.restored.title",name),
                                                            body:L10n.format("alert.restored.body",percent)))
                        }
                        if preferences.resetConfetti { result.celebrate=true }
                    }
                }
            }
            if notify && options.lowQuota && remaining<Double(options.remainingThreshold) {
                append(.low,key:"low/\(cycle)",title:L10n.format("alert.low.title",name),
                       body:L10n.format("alert.low.body",percent,options.remainingThreshold),now:now,to:&result)
            }
            if notify && options.predictedExhaustion && remaining>0,
               let eta=QuotaPace(used:100-remaining,period:period,resetsAt:reset,now:now,
                                 workDays:preferences.quotaPanel.weeklySchedule.workDays)?.secondsToExhaustion,
               eta<=Double(options.predictionMinutes)*60 {
                append(.prediction,key:"prediction/\(cycle)",title:L10n.format("alert.prediction.title",name),
                       body:L10n.format("alert.prediction.body",max(1,Int(ceil(eta/60)))),now:now,to:&result)
            }
        }
        if notify && options.resetCards {
            for card in snapshot.resetCards?.details ?? [] where card.available {
                guard let expiry=card.expiresAt,expiry>now,expiry.timeIntervalSince(now)<=Double(options.cardDays)*86400 else { continue }
                // Cards expiring together form one event; no fabricated identity.
                append(.card,key:"card/\(selected)/\(Int(expiry.timeIntervalSince1970))",title:L10n.string("alert.card.title"),
                       body:L10n.format("alert.card.body",QuotaDateText.string(expiry)),now:now,to:&result)
            }
        }
        return result
    }
    private mutating func append(_ kind:QuotaAlert.Kind,key:String,title:String,body:String,now:Date,to result:inout QuotaAlertResult) {
        guard receipts[key] == nil else { return }
        receipts[key]=now
        result.alerts.append(QuotaAlert(kind:kind,key:key,title:title,body:body))
    }
}
