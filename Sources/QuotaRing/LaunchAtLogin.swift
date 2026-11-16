import ServiceManagement
import QuotaCore

enum LaunchAtLogin {
    static var enabled:Bool { SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval }
    static var statusText:String {
        switch SMAppService.mainApp.status {
        case .enabled:return L10n.string("login.enabled")
        case .requiresApproval:return L10n.string("login.requiresApproval")
        // An unregistered development build can also report notFound. It does
        // not prove the bundle is outside Applications; register on user intent.
        case .notFound,.notRegistered:return L10n.string("login.disabled")
        @unknown default:return L10n.string("login.unknown")
        }
    }
    /// Returns the system error description on failure.
    static func setEnabled(_ enabled:Bool)->String? {
        do {
            if enabled {
                if !self.enabled { try SMAppService.mainApp.register() }
            } else if self.enabled { try SMAppService.mainApp.unregister() }
            return nil
        } catch { return error.localizedDescription }
    }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
