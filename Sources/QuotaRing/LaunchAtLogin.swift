import ServiceManagement

enum LaunchAtLogin {
    static var enabled:Bool { SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval }
    static var statusText:String {
        switch SMAppService.mainApp.status {
        case .enabled:return "已启用"
        case .requiresApproval:return "待批准"
        // An unregistered development build can also report notFound. It does
        // not prove the bundle is outside Applications; register on user intent.
        case .notFound,.notRegistered:return "未启用"
        @unknown default:return "未知"
        }
    }
    static func setEnabled(_ enabled:Bool)->String? {
        do {
            if enabled {
                if !self.enabled { try SMAppService.mainApp.register() }
            } else if self.enabled { try SMAppService.mainApp.unregister() }
            return nil
        } catch { return "设置失败：\(error.localizedDescription)" }
    }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
