import Foundation

public enum WeeklyPaceSchedule:Int,Codable,CaseIterable {
    case automatic=0,four=4,five=5,six=6,seven=7
    public var title:String { self == .automatic ? "自动（按7天）":"\(rawValue)天" }
    public var workDays:Int? { self == .automatic ? nil:rawValue }
}
public enum QuotaTickStyle:String,Codable,CaseIterable {
    case hidden,subtle,highContrast
    public var title:String {
        switch self { case .hidden:return "隐藏";case .subtle:return "柔和";case .highContrast:return "高对比度" }
    }
}
public enum QuotaResetStyle:String,Codable,CaseIterable {
    case countdown,dateTime
    public var title:String { self == .countdown ? "倒计时":"日期时间" }
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
