import AppKit
import UserNotifications
import QuotaCore

final class QuotaNotificationController:NSObject,UNUserNotificationCenterDelegate {
    private let defaults:UserDefaults
    private var engine:QuotaAlertEngine
    private var allowed=false
    private let receiptKey="ring.alertReceipts.v1"
    private var center:UNUserNotificationCenter { .current() }
    var onStatus:((String)->Void)?
    var onCelebrate:(()->Void)?
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        let data=defaults.data(forKey:"ring.alertReceipts.v1") ?? Data()
        engine=QuotaAlertEngine(receipts:(try? JSONDecoder().decode([String:Date].self,from:data)) ?? [:])
        super.init()
    }
    func refreshStatus() {
        center.delegate=self
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.allowed=settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                let text:String
                switch settings.authorizationStatus {
                case .authorized,.provisional:text=L10n.string("permission.granted")
                case .denied:text=L10n.string("permission.denied")
                default:text=L10n.string("permission.notRequested")
                }
                self.onStatus?(text)
            }
        }
    }
    func requestPermission() {
        center.requestAuthorization(options:[.alert,.sound]) { [weak self] _,error in
            DispatchQueue.main.async {
                if error != nil { self?.onStatus?(L10n.string("permission.requestFailed")) }
                else { self?.refreshStatus() }
            }
        }
    }
    func clearBaseline() { engine.clearBaseline() }
    func observe(_ snapshot:QuotaSnapshot,preferences:RingPreferences) {
        let result=engine.evaluate(snapshot,preferences:preferences,notificationsAllowed:allowed,now:Date())
        if let data=try? JSONEncoder().encode(engine.receipts) { defaults.set(data,forKey:receiptKey) }
        for alert in result.alerts {
            let content=UNMutableNotificationContent()
            content.title=alert.title;content.body=alert.body;content.sound = .default
            center.add(UNNotificationRequest(identifier:alert.key,content:content,trigger:nil)) { [weak self] error in
                if error != nil { DispatchQueue.main.async { self?.onStatus?(L10n.string("notification.sendFailed")) } }
            }
        }
        if result.celebrate { onCelebrate?() }
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,
                                withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions)->Void) {
        completionHandler([.banner,.sound,.list])
    }
    func openSettings() {
        if let url=URL(string:"x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
