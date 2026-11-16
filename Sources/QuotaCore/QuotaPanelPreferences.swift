import Foundation

public enum WeeklyPaceSchedule:Int,Codable,CaseIterable {
    case automatic=0,four=4,five=5,six=6,seven=7
    public var title:String { self == .automatic ? L10n.string("schedule.automatic"):L10n.format("schedule.days",rawValue) }
    public var workDays:Int? { self == .automatic ? nil:rawValue }
}
public enum QuotaTickStyle:String,Codable,CaseIterable {
    case hidden,subtle,highContrast
    public var title:String {
        switch self {
        case .hidden:return L10n.string("tick.hidden")
        case .subtle:return L10n.string("tick.subtle")
        case .highContrast:return L10n.string("tick.highContrast")
        }
    }
}
public enum QuotaResetStyle:String,Codable,CaseIterable {
    case countdown,dateTime
    public var title:String { self == .countdown ? L10n.string("resetStyle.countdown"):L10n.string("resetStyle.dateTime") }
}
public struct QuotaPanelPreferences:Codable,Equatable {
    public var showPace=true
    public var weeklySchedule:WeeklyPaceSchedule = .seven
    public var tickStyle:QuotaTickStyle = .subtle
    public var resetStyle:QuotaResetStyle = .countdown
    public init() {}
    private enum CodingKeys:String,CodingKey { case showPace,weeklySchedule,tickStyle,resetStyle }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        showPace=(try? c.decode(Bool.self,forKey:.showPace)) ?? true
        weeklySchedule=(try? c.decode(WeeklyPaceSchedule.self,forKey:.weeklySchedule)) ?? .seven
        tickStyle=(try? c.decode(QuotaTickStyle.self,forKey:.tickStyle)) ?? .subtle
        resetStyle=(try? c.decode(QuotaResetStyle.self,forKey:.resetStyle)) ?? .countdown
    }
}
