import AppKit
import SwiftUI
import QuotaCore

final class RingDebugWindow:NSWindowController,NSWindowDelegate {
    private let onClose:()->Void
    private let model:SettingsModel
    init(model:SettingsModel,onClose:@escaping ()->Void) {
        self.onClose=onClose;self.model=model
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:440,height:450),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary,.canJoinAllApplications,.ignoresCycle]
        super.init(window:window);window.delegate=self
        applyLanguage()
        window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
    func applyLanguage() { window?.title=L10n.string("debug.windowTitle") }
    override func showWindow(_ sender:Any?) {
        if !(window?.contentView is NSHostingView<RingDebugView>) {
            window?.contentView=NSHostingView(rootView:RingDebugView(model:model,onDone:{ [weak self] in self?.close() }))
        }
        super.showWindow(sender)
    }
    func windowWillClose(_ notification:Notification) { window?.contentView=nil;onClose() }
}

private struct RingDebugView:View {
    @ObservedObject var model:SettingsModel
    let onDone:()->Void
    private var colorScheme:ColorScheme? {
        switch model.preferences.theme { case .system:return nil;case .light:return .light;case .dark:return .dark }
    }
    var body:some View {
        VStack(spacing:0) {
            Form {
                Section {
                    Toggle(L10n.string("debug.enable"),isOn:$model.debugState.isEnabled)
                        .help(L10n.string("debug.enable.help"))
                }
                Section(L10n.string("debug.used.section")) {
                    percentageRow(L10n.string("debug.used.week"),value:$model.debugState.weekUsed)
                    percentageRow(L10n.string("debug.used.fiveHours"),value:$model.debugState.fiveHoursUsed)
                }.disabled(!model.debugState.isEnabled)
                Section(L10n.string("debug.periods.section")) {
                    Toggle(L10n.string("debug.periods.week"),isOn:$model.preferences.showWeek)
                        .disabled(model.preferences.showWeek && !model.preferences.showFiveHours)
                    Toggle(L10n.string("debug.periods.fiveHours"),isOn:$model.preferences.showFiveHours)
                        .disabled(model.preferences.showFiveHours && !model.preferences.showWeek)
                }.disabled(!model.debugState.isEnabled)
                DisclosureGroup(L10n.string("debug.window.section")) {
                    Toggle(L10n.string("debug.window.diagnostics"),isOn:$model.diagnostics)
                        .padding(.leading,16)
                        .padding(.top,12)
                        .onChange(of:model.diagnostics) { _ in model.onDiagnostics?() }
                    if model.diagnostics {
                        Text(model.diagnosticText).font(.system(.body,design:.monospaced)).textSelection(.enabled).padding(.leading,16)
                    }
                }
            }.formStyle(.grouped)
            HStack { Spacer();Button(L10n.string("common.done"),action:onDone).keyboardShortcut(.defaultAction) }
                .padding(.horizontal,20).padding(.vertical,12)
        }.frame(width:440,height:450)
            .background(Color(nsColor:.windowBackgroundColor))
            .toggleStyle(.switch).preferredColorScheme(colorScheme)
    }
    private func percentageRow(_ title:String,value:Binding<Double>)->some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text(title);Spacer()
                TextField(title,value:value,format:.number.precision(.fractionLength(0...1)))
                    .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .frame(width:64).accessibilityLabel(L10n.format("debug.percentage.a11y",title))
                Text("%")
            }
            Slider(value:value,in:0...100,step:1).accessibilityLabel(title)
        }
    }
}
