import Foundation

/// One format for refreshes, quota resets and card expiry dates, independent of the host timezone.
public enum QuotaDateText {
    public static func string(_ date:Date?)->String {
        guard let date else { return "—" }
        let formatter=DateFormatter()
        formatter.locale=Locale(identifier:"zh_CN")
        formatter.calendar=Calendar(identifier:.gregorian)
        formatter.timeZone=TimeZone(identifier:"Asia/Shanghai")
        formatter.dateFormat="yyyy年M月d日 'GMT+8' HH:mm"
        return formatter.string(from:date)
    }
}
