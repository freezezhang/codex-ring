import Foundation

/// Only failed full searches back off; an unfinished traversal keeps its progress.
/// Uses monotonic time so clock changes cannot prolong or bypass a cooldown.
public struct UsageSearchBackoff {
    private var delay:TimeInterval=1
    private var retryAt:TimeInterval=0
    public init() {}
    public func allowsSearch(at now:TimeInterval)->Bool { now>=retryAt }
    public mutating func failed(at now:TimeInterval) {
        retryAt=now+delay
        delay=min(15,delay*2)
    }
}
