import Foundation
import CoreFoundation
public enum ResetCardExpiryBand:Equatable {
    case normal,yellow,orange,red
    public init(expiresAt:Date?,now:Date=Date()) {
        guard let expiresAt else { self = .normal;return }
        let remaining=expiresAt.timeIntervalSince(now)
        if remaining<=24*3600 { self = .red }
        else if remaining<=72*3600 { self = .orange }
        else if remaining<=7*24*3600 { self = .yellow }
        else { self = .normal }
    }
}
public struct ResetCard:Equatable {
    public let title:String
    public let expiresAt:Date?
    public let status:String
    public var available:Bool { status == "available" }
    public var displayTitle:String {
        let text=title.split(whereSeparator:\.isWhitespace).joined(separator:" ")
        switch text.lowercased() {
        case "full reset","full_reset":return "完全重置"
        case "":return "额度重置卡"
        default:return text
        }
    }
    public func expiryText(now:Date = Date())->String {
        guard let expiresAt else { return "到期时间未知" }
        return "\(expiresAt<=now ? "已于":"将于") \(QuotaDateText.string(expiresAt)) 到期"
    }
}
public struct ResetCards:Equatable {
    public let availableCount:Int?
    public let details:[ResetCard]?
}
public enum ResetCardsParser {
    public static func parse(_ value:Any?)->ResetCards? {
        guard let object=value as? [String:Any] else { return nil }
        var count:Int?
        if let n=object["availableCount"] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d=n.doubleValue
            if d.isFinite && d>=0 && d<1_000_000_000 && d.rounded() == d { count=Int(d) }
        }
        let details=(object["credits"] as? [[String:Any]])?.map { row->ResetCard in
            var expiry:Date?
            if let n=row["expiresAt"] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID() {
                let d=n.doubleValue
                if d.isFinite && d>0 && d<253402300800 { expiry=Date(timeIntervalSince1970:d) }
            }
            let title=(row["title"] as? String).flatMap { $0.isEmpty ? nil:$0 } ?? "额度重置卡"
            return ResetCard(title:title,expiresAt:expiry,status:row["status"] as? String ?? "unknown")
        }
        return ResetCards(availableCount:count,details:details)
    }
}
