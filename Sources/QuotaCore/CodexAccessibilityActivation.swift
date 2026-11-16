import Foundation

/// OS authorization and Chromium/Electron renderer accessibility are separate. Only
/// an authorized, explicitly enabled overlay should invoke this initializer.
/// Retry after a renderer restart or a temporary AX failure without writing on
/// every window-monitor tick. Never turn accessibility off for other clients.
public struct CodexAccessibilityActivation {
    public enum Result:Equatable {
        case alreadyEnabled(String),enabled(String),unavailable
    }
    private static let attributes=["AXEnhancedUserInterface","AXManualAccessibility"]
    private var checkedAt:[Int32:TimeInterval]=[:]
    public init() {}
    public mutating func prepare(processID:Int32,now:TimeInterval,
                                 isEnabled:(String)->Bool?,enable:(String)->Bool)->Result? {
        if let last=checkedAt[processID],now-last<5 { return nil }
        if checkedAt.count>=32 { checkedAt.removeAll() }
        checkedAt[processID]=now
        for attribute in Self.attributes where isEnabled(attribute) == true {
            return .alreadyEnabled(attribute)
        }
        for attribute in Self.attributes where enable(attribute) {
            return .enabled(attribute)
        }
        return .unavailable
    }
}
