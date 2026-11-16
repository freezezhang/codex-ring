import Foundation

/// One format for refreshes, quota resets and card expiry dates, independent of the host timezone.
public enum QuotaDateText {
    public static func string(_ date:Date?,includeSeconds:Bool=false,includeDate:Bool=true)->String {
        guard let date else { return "—" }
        let formatter=DateFormatter()
        formatter.locale=Locale(identifier:"zh_CN")
        formatter.calendar=Calendar(identifier:.gregorian)
        formatter.timeZone=TimeZone(identifier:"Asia/Shanghai")
        formatter.dateFormat=(includeDate ? "yyyy.MM.dd ":"")+(includeSeconds ? "HH:mm:ss":"HH:mm")
        return formatter.string(from:date)
    }
}
