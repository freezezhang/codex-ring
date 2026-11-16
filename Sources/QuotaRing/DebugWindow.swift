import AppKit
import SwiftUI
import QuotaCore

final class RingDebugWindow:NSWindowController,NSWindowDelegate {
    private let onClose:()->Void
    init(model:SettingsModel,onClose:@escaping ()->Void) {
        self.onClose=onClose
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:440,height:450),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="CodexRing 调试";window.isReleasedWhenClosed=false
        window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary,.canJoinAllApplications,.ignoresCycle]
        super.init(window:window);window.delegate=self
        window.contentView=NSHostingView(rootView:RingDebugView(model:model,onDone:{ [weak self] in self?.close() }));window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
    func windowWillClose(_ notification:Notification) { onClose() }
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
                    Toggle("启用调试",isOn:$model.debugState.isEnabled)
                } footer: {
                    Text("调试值仅本次运行生效，关闭后恢复真实额度。")
                }
                Section("已用额度") {
                    percentageRow("1周已用",value:$model.debugState.weekUsed)
                    percentageRow("5小时已用",value:$model.debugState.fiveHoursUsed)
                }.disabled(!model.debugState.isEnabled)
                Section("显示周期") {
                    Toggle("显示1周额度",isOn:$model.preferences.showWeek)
                        .disabled(model.preferences.showWeek && !model.preferences.showFiveHours)
                    Toggle("显示5小时额度",isOn:$model.preferences.showFiveHours)
                        .disabled(model.preferences.showFiveHours && !model.preferences.showWeek)
                }.disabled(!model.debugState.isEnabled)
                DisclosureGroup("窗口信息") {
                    Toggle("显示窗口诊断信息",isOn:$model.diagnostics)
                        .onChange(of:model.diagnostics) { _ in model.onDiagnostics?() }
                    if model.diagnostics { Text(model.diagnosticText).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }.formStyle(.grouped)
            HStack { Spacer();Button("完成",action:onDone).keyboardShortcut(.defaultAction) }
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
                    .frame(width:64).accessibilityLabel("\(title)百分比")
                Text("%")
            }
            Slider(value:value,in:0...100,step:0.1).accessibilityLabel(title)
        }
    }
}
