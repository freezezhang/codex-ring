import Foundation

/// Explicit, session-only display overrides. Never changes account data or saved preferences.
public struct QuotaDebugState:Equatable {
    public var isEnabled:Bool
    public var weekUsed:Double { didSet { weekUsed=Self.clamped(weekUsed) } }
    public var fiveHoursUsed:Double { didSet { fiveHoursUsed=Self.clamped(fiveHoursUsed) } }
    public init(isEnabled:Bool=false,weekUsed:Double=0,fiveHoursUsed:Double=0) {
        self.isEnabled=isEnabled
        self.weekUsed=Self.clamped(weekUsed);self.fiveHoursUsed=Self.clamped(fiveHoursUsed)
    }
    private static func clamped(_ value:Double)->Double { value.isFinite ? min(100,max(0,value)):0 }
    public func snapshot(live:QuotaSnapshot,selectedID:String?=nil,now:Date=Date())->QuotaSnapshot {
        guard isEnabled else { return live }
        let pool=live.selectedPoolID(selectedID) ?? "codex"
        let quotas=[QuotaPeriod.week,.fiveHours].map { period in
            WeeklyQuota(id:"\(pool)/\(period == .week ? "secondary":"primary")",label:pool,
                        remaining:100-(period == .week ? weekUsed:fiveHoursUsed),
                        resetsAt:live.display(selectedID:pool,period:period,now:now).quota?.resetsAt
                            ?? (period == .fiveHours ? now.addingTimeInterval(3600):nil),period:period)
        }
        return QuotaSnapshot(source:.debug,fetchedAt:live.fetchedAt,quotas:quotas,
                             capabilitiesKnown:true,resetCards:live.resetCards)
    }
}
