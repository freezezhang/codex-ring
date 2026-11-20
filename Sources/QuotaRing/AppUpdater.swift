import SwiftUI
import QuotaCore
#if canImport(Sparkle)
import Sparkle

final class AppUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    private var observers: [NSKeyValueObservation] = []

    init?() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return nil }

        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        let updater = controller.updater
        observers = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                self?.objectWillChange.send()
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                self?.objectWillChange.send()
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                self?.objectWillChange.send()
            }
        ]
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyInstalls: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func check() {
        controller.checkForUpdates(nil)
    }
}

struct AppUpdateSettings: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Section {
            LabeledContent(L10n.string("updates.section")) {
                Button(L10n.string("updates.check")) { updater.check() }
                    .disabled(!updater.canCheck)
            }
            Toggle(L10n.string("updates.automaticCheck"), isOn: $updater.automaticallyChecks)
            Toggle(L10n.string("updates.automaticInstall"), isOn: $updater.automaticallyInstalls)
                .disabled(!updater.automaticallyChecks)
        }
    }
}
#endif
