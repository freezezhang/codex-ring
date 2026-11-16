import Foundation
import CoreFoundation

public enum QuotaSource: String { case official, disconnected, debug }
public enum QuotaFailure: String, Error { case unavailable, connection, timeout, protocolError, missingCLI }
public enum DisplayStatus: String { case loading, available, unavailable, stale, expired, connection, timeout, protocolError, missingCLI }
public enum QuotaPeriod:String,Codable,CaseIterable { case week,fiveHours
    public var title:String { self == .week ? L10n.string("period.week.title"):L10n.string("period.fiveHours.title") }
    public var shortName:String { self == .week ? L10n.string("period.week.short"):L10n.string("period.fiveHours.short") }
    public var quotaName:String { self == .week ? L10n.string("period.week.quota"):L10n.string("period.fiveHours.quota") }
    /// A period name followed by a metric value, e.g. "Weekly 80% left".
    public func value(_ metricValue:String)->String { L10n.format("quota.periodValue",shortName,metricValue) }
}
public struct WeeklyQuota: Equatable {
    public let id: String
    public let label: String
    public let remaining: Double?
    public let resetsAt: Date?
    public let period:QuotaPeriod
    public var poolID:String {
        let parts=id.split(separator:"/")
        return parts.last == "primary" || parts.last == "secondary" ? parts.dropLast().joined(separator:"/"):id
    }
    public init(id: String, label: String, remaining: Double?, resetsAt: Date?,period:QuotaPeriod = .week) {
        self.id = id; self.label = label; self.remaining = remaining; self.resetsAt = resetsAt
        self.period=period
    }
}
public struct QuotaDisplay {
    public let status: DisplayStatus
    public let remaining: Double?
    public let quota: WeeklyQuota?
    public let fetchedAt: Date
    public let source: QuotaSource
    public var centerText: String {
        guard let remaining else { return "—" }
        let rounded = remaining.rounded()
        return abs(rounded - remaining) < 0.05 ? "\(Int(rounded))%" : String(format: "%.1f%%", remaining)
    }
    public var subtitle: String {
        if source == .disconnected { return L10n.string("status.paused") }
        if source == .debug { return L10n.string("status.debug") }
        switch status {
        case .loading: return L10n.string("status.loading")
        case .available: return L10n.string("status.available")
        case .unavailable: return L10n.string("status.unavailable")
        case .stale: return L10n.string("status.stale")
        case .expired: return L10n.string("status.expired")
        case .connection: return L10n.string("status.connection")
        case .timeout: return L10n.string("status.timeout")
        case .protocolError: return L10n.string("status.protocolError")
        case .missingCLI: return L10n.string("status.missingCLI")
        }
    }
}
public struct QuotaSnapshot:Equatable {
    public let source: QuotaSource
    public let fetchedAt: Date
    public let quotas: [WeeklyQuota]
    public let failure: QuotaFailure?
    public let loading: Bool
    public let capabilitiesKnown:Bool
    public let resetCards:ResetCards?
    public init(source: QuotaSource, fetchedAt: Date, quotas: [WeeklyQuota] = [], failure: QuotaFailure? = nil, loading: Bool = false,capabilitiesKnown:Bool? = nil,resetCards:ResetCards? = nil) {
        self.source = source; self.fetchedAt = fetchedAt; self.quotas = quotas; self.failure = failure
        self.loading = loading
        self.capabilitiesKnown=capabilitiesKnown ?? !quotas.isEmpty
        self.resetCards=resetCards
    }
    public func selectedPoolID(_ selectedID:String?)->String? {
        if let selectedID {
            return selectedID.hasSuffix("/primary") || selectedID.hasSuffix("/secondary")
                ? selectedID.split(separator:"/").dropLast().joined(separator:"/"):selectedID
        }
        return quotas.first(where:{$0.poolID == "codex"})?.poolID ?? quotas.map(\.poolID).sorted().first
    }
    public func display(selectedID: String? = nil,period:QuotaPeriod = .week, now: Date = Date()) -> QuotaDisplay {
        let candidates=quotas.filter { $0.period == period }
        let selectedPool=selectedID.map { id in id.hasSuffix("/primary") || id.hasSuffix("/secondary") ? id.split(separator:"/").dropLast().joined(separator:"/"):id }
        let quota:WeeklyQuota?
        if let selectedPool { quota=candidates.first { $0.id == selectedID || $0.poolID == selectedPool } }
        else { quota=candidates.first { $0.poolID == "codex" } ?? candidates.first }
        var status: DisplayStatus = .available
        if loading { status = .loading }
        else if let failure { status = DisplayStatus(rawValue: failure.rawValue) ?? .unavailable }
        else if source != .debug && (now.timeIntervalSince(fetchedAt) > 300 || fetchedAt.timeIntervalSince(now) > 60) { status = .stale }
        else if source != .debug, let reset = quota?.resetsAt, reset <= now { status = .expired }
        else if quota?.remaining == nil { status = .unavailable }
        return QuotaDisplay(status: status, remaining: status == .available ? quota?.remaining : nil,
                            quota: quota, fetchedAt: fetchedAt, source: source)
    }
}

public enum QuotaParser {
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
    public static func parse(_ payload: [String: Any], at now: Date = Date(), source: QuotaSource = .official) -> QuotaSnapshot {
        var buckets: [(String, [String: Any])] = []
        if let multi = payload["rateLimitsByLimitId"], !(multi is NSNull) {
            if let map = multi as? [String: Any] {
                buckets = map.keys.sorted().compactMap { key in (map[key] as? [String: Any]).map { (key, $0) } }
            }
        } else if let legacy = payload["rateLimits"] as? [String: Any] {
            buckets = [(legacy["limitId"] as? String ?? "codex", legacy)]
        }
        var rows: [WeeklyQuota] = []
        var capabilitiesKnown=false
        for (key, bucket) in buckets {
            for slot in ["primary", "secondary"] {
                guard let window=bucket[slot] as? [String:Any],let duration=number(window["windowDurationMins"]),duration>0 else { continue }
                capabilitiesKnown=true
                let period:QuotaPeriod
                if duration == 10080 { period = .week } else if duration == 300 { period = .fiveHours } else { continue }
                let used = number(window["usedPercent"])
                let remaining = used.map { min(100, max(0, 100 - $0)) }
                let epoch = number(window["resetsAt"])
                let reset = epoch.flatMap { $0 > 0 && $0 < 253402300800 ? Date(timeIntervalSince1970: $0) : nil }
                let label = (bucket["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
                rows.append(WeeklyQuota(id: "\(key)/\(slot)", label: label, remaining: remaining, resetsAt: reset,period:period))
            }
        }
        return QuotaSnapshot(source: source, fetchedAt: now, quotas: rows,capabilitiesKnown:capabilitiesKnown,resetCards:ResetCardsParser.parse(payload["rateLimitResetCredits"]))
    }
}
