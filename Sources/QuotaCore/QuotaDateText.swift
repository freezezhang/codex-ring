import Foundation

/// One format for refreshes, quota resets and card expiry dates, independent of the host timezone.
public enum QuotaDateText {
    public static func string(_ date:Date?,includeSeconds:Bool=false)->String {
        guard let date else { return "—" }
        let formatter=DateFormatter()
        formatter.locale=Locale(identifier:"zh_CN")
        formatter.calendar=Calendar(identifier:.gregorian)
        formatter.timeZone=TimeZone(identifier:"Asia/Shanghai")
        formatter.dateFormat=includeSeconds ? "yyyy.MM.dd HH:mm:ss":"yyyy.MM.dd HH:mm"
        return formatter.string(from:date)
    }
}
