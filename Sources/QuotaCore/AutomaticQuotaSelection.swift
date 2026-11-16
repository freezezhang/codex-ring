import Foundation

/// Ordering adapted from CodexBar (MIT); see THIRD_PARTY_NOTICES.md.
public enum AutomaticQuotaSelection {
    public static func select(snapshot:QuotaSnapshot,preferences:RingPreferences,periods:[QuotaPeriod],now:Date)->QuotaPeriod? {
        let pool=snapshot.selectedPoolID(preferences.bucketID)
        let candidates=periods.compactMap { period -> (QuotaPeriod,Double,TimeInterval?)? in
            let display=snapshot.display(selectedID:pool,period:period,now:now)
            guard let remaining=display.remaining,remaining.isFinite,(0...100).contains(remaining) else { return nil }
            let used=100-remaining
            let eta=QuotaPace(used:used,period:period,resetsAt:display.quota?.resetsAt,now:now,
                              workDays:preferences.quotaPanel.weeklySchedule.workDays)?.secondsToExhaustion
            return (period,used,eta)
        }
        return candidates.reduce(nil as (QuotaPeriod,Double,TimeInterval?)?) { best,next in
            guard let best else { return next }
            if (best.1>=100) != (next.1>=100) { return next.1>=100 ? next:best }
            if (best.2 != nil) != (next.2 != nil) { return next.2 != nil ? next:best }
            if let a=best.2,let b=next.2,a != b { return b<a ? next:best }
            return next.1>best.1 ? next:best
        }?.0
    }
}
