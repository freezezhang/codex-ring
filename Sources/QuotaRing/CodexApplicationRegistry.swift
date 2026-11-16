import AppKit

/// Keep application discovery out of the 5 Hz window-position polling loop.
/// Subscribe before the initial lookup, then reconcile on launch/exit events.
/// Window geometry and hidden state are still checked at the original cadence.
final class CodexApplicationRegistry {
    private(set) var applications:[NSRunningApplication]=[]
    var onChange:(()->Void)?
    private let center:NotificationCenter
    private let resolve:()->[NSRunningApplication]
    private var observers:[NSObjectProtocol]=[]

    init(bundleIdentifier:String = "com.openai.codex",
         center:NotificationCenter = NSWorkspace.shared.notificationCenter,
         resolve:(()->[NSRunningApplication])? = nil) {
        self.center=center
        // Keep the workspace's live application list as the source of truth;
        // bundle-ID lookup can miss apps not yet indexed by Launch Services.
        self.resolve=resolve ?? { NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier } }
    }
    func start() {
        guard observers.isEmpty else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                guard let self,!self.observers.isEmpty else { return }
                self.refresh()
            })
        }
        applications=resolve()
    }
    func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll();applications.removeAll()
    }
    deinit { stop() }
    private func refresh() {
        let next=resolve()
        guard Set(next.map(\.processIdentifier)) != Set(applications.map(\.processIdentifier)) else { return }
        applications=next
        onChange?()
    }
}
