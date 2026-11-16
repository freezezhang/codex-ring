import Foundation

/// Linear window pacing adapted from CodexBar's UsagePace (MIT).
/// See THIRD_PARTY_NOTICES.md. This is a projection, not a billing overage.
public struct QuotaPace:Equatable {
    public enum Position:Equatable { case ahead,balanced,behind }
    public let workDays:Int?
    public let expectedUsed:Double
    public let delta:Double
    public let secondsToExhaustion:TimeInterval?
    public let lastsUntilReset:Bool
    public var position:Position { abs(delta)<=2 ? .balanced:(delta>0 ? .ahead:.behind) }
    public var markerPercent:Double? { position == .balanced ? nil:expectedUsed }
    public var paceText:String {
        switch position {
        case .balanced:return L10n.string("pace.balanced")
        case .ahead:return L10n.format("pace.ahead",Int(abs(delta).rounded()))
        case .behind:return L10n.format("pace.behind",Int(abs(delta).rounded()))
        }
    }
    public var forecastText:String {
        guard !lastsUntilReset,let seconds=secondsToExhaustion else { return L10n.string("pace.lastsUntilReset") }
        let minutes=Int(seconds/60)
        let duration:String
        if minutes>=1440 { duration=L10n.format("pace.duration.daysHours",minutes/1440,(minutes%1440)/60) }
        else if minutes>=60 { duration=L10n.format("pace.duration.hoursMinutes",minutes/60,minutes%60) }
        else if minutes>0 { duration=L10n.format("unit.minutes",minutes) }
        else { duration=L10n.string("pace.duration.underMinute") }
        return L10n.format("pace.forecast",duration)
    }
    public var summary:String { paceText+" · "+forecastText }
    public var explanation:String {
        let basis=workDays.map { L10n.format("pace.basis.workDays",$0) } ?? L10n.string("pace.basis.elapsed")
        return L10n.format("pace.explanation",basis)
    }
    public init?(used:Double,period:QuotaPeriod,resetsAt:Date?,now:Date,
                 workDays:Int?=nil,calendar:Calendar = .current) {
        guard used.isFinite,used>=0,used<100,let resetsAt else { return nil }
        let duration:TimeInterval=period == .week ? 7*86400:5*3600
        let remaining=resetsAt.timeIntervalSince(now)
        guard remaining.isFinite,remaining>0,remaining<=duration else { return nil }
        self.workDays=period == .week ? workDays.flatMap { (4...6).contains($0) ? $0:nil }:nil
        var elapsed=duration-remaining,total=duration
        var intervals:[DateInterval]?
        if let days=self.workDays {
            guard let work=Self.workIntervals(start:resetsAt.addingTimeInterval(-duration),end:resetsAt,
                                             days:days,calendar:calendar) else { return nil }
            intervals=work
            total=work.reduce(0) { $0+$1.duration }
            elapsed=work.reduce(0) { $0+max(0,min(now,$1.end).timeIntervalSince($1.start)) }
            guard total>0 else { return nil }
        }
        expectedUsed=elapsed/total*100
        // Match CodexBar's warm-up: early-cycle averages are too unstable.
        guard expectedUsed>=3 else { return nil }
        delta=used-expectedUsed
        let candidate=used>0 ? (100-used)*elapsed/used:Double.infinity
        lastsUntilReset=candidate>=total-elapsed
        if lastsUntilReset { secondsToExhaustion=nil }
        else if let intervals {
            // Convert working seconds back to wall-clock time, skipping days off.
            var needed=candidate
            var eta:TimeInterval?
            for interval in intervals where interval.end>now {
                let start=max(now,interval.start)
                let available=interval.end.timeIntervalSince(start)
                if needed<=available { eta=start.timeIntervalSince(now)+needed;break }
                needed -= available
            }
            guard let eta else { return nil }
            secondsToExhaustion=eta
        } else { secondsToExhaustion=candidate }
    }
    private static func workIntervals(start:Date,end:Date,days:Int,calendar:Calendar)->[DateInterval]? {
        var cursor=start,result:[DateInterval]=[]
        while cursor<end {
            guard let next=calendar.date(byAdding:.day,value:1,to:calendar.startOfDay(for:cursor)),next>cursor else { return nil }
            let stop=min(next,end)
            let weekday=calendar.component(.weekday,from:cursor)
            let isoDay=weekday == 1 ? 7:weekday-1
            if isoDay<=days { result.append(DateInterval(start:cursor,end:stop)) }
            cursor=stop
        }
        return result
    }
    /// Neutral day/hour dividers, independent of the moving pace marker.
    public static func divisions(for period:QuotaPeriod,workDays:Int?=7)->[Double] {
        guard let count=period == .week ? workDays:5,(2...7).contains(count) else { return [] }
        return (1..<count).map { Double($0)*100/Double(count) }
    }
}
