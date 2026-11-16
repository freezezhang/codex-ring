import Foundation
public struct QuotaCapabilities {
    private var byPool:[String:Bool]?
    public var fiveHourSupport:Bool? { support(for:nil) }
    public init() {}
    public func support(for pool:String?)->Bool? {
        guard let byPool else { return nil }
        if let pool {
            let key=pool.hasSuffix("/primary") || pool.hasSuffix("/secondary") ? pool.split(separator:"/").dropLast().joined(separator:"/"):pool
            return byPool[key]
        }
        if let codex=byPool["codex"] { return codex }
        return byPool.keys.sorted().first.flatMap { byPool[$0] } ?? false
    }
    public mutating func observe(_ snapshot:QuotaSnapshot) {
        guard snapshot.source == .official,snapshot.failure == nil,!snapshot.loading,snapshot.capabilitiesKnown else { return }
        byPool=Dictionary(grouping:snapshot.quotas,by:\.poolID).mapValues { $0.contains { $0.period == .fiveHours } }
    }
}
