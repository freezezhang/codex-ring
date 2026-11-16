import Foundation

/// Plan identifiers are supplied by Codex account/read. Allowances describe the
/// full-cycle subscription benefit, not a verified grant or account balance.
public enum CodexAccountPlan:String,Equatable {
    case free,go,plus,pro,prolite,promax,team,business
    case businessPremium="self_serve_business_prolite"
    public var title:String {
        switch self {
        case .free:return "Free"
        case .go:return "Go"
        case .plus:return "Plus"
        case .prolite:return "Pro 5x"
        case .pro:return "Pro $200"
        case .promax:return "Pro $500"
        case .team,.business:return "Business"
        case .businessPremium:return "Business Premium"
        }
    }
    public var expectedAPICredits:Double? {
        switch self {
        case .prolite:return 100
        case .pro:return 200
        case .promax:return 500
        // Business requires the number of paid seats and billing cadence. The
        // plan name alone cannot establish a workspace's total allowance.
        default:return nil
        }
    }
    public static func parse(_ payload:[String:Any])->Self? {
        guard let account=payload["account"] as? [String:Any],account["type"] as? String == "chatgpt",
              let raw=account["planType"] as? String else { return nil }
        return Self(rawValue:raw.lowercased())
    }
}

/// Only display metadata is retained; account IDs and authentication material are discarded.
public struct CodexAccountInfo:Equatable {
    public let email:String?
    public let plan:CodexAccountPlan?
    public static func parse(_ payload:[String:Any])->Self? {
        guard let account=payload["account"] as? [String:Any],account["type"] as? String == "chatgpt" else { return nil }
        let raw=(account["email"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines)
        let email=raw.flatMap { value->String? in
            guard !value.isEmpty,value.count<=320,!value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { return nil }
            return value
        }
        return Self(email:email,plan:CodexAccountPlan.parse(payload))
    }
}
