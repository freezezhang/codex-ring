import AppKit
import SwiftUI
import QuotaCore

final class SettingsModel:ObservableObject {
    @Published var preferences:RingPreferences { didSet { onPreferences?(preferences) } }
    @Published var snapshot=QuotaSnapshot(source:.official,fetchedAt:Date(),loading:true)
    @Published var source:QuotaSource = .official
    @Published var isRefreshing=false
    @Published var updatedText="—"
    @Published var diagnosticText=""
    @Published var diagnostics=false
    @Published var fiveHourSupport:Bool?
    @Published var overlayAccessibilityGranted=false
    @Published var overlayStatus=""
    @Published var menuPresentation:QuotaMenuPresentation?
    @Published var debugState=QuotaDebugState() { didSet { onDebugState?(debugState) } }
    var onPreferences:((RingPreferences)->Void)?
    var onDebugState:((QuotaDebugState)->Void)?
    var onRestore:(()->Void)?,onDiagnostics:(()->Void)?,onOpenDebug:(()->Void)?
    init(preferences:RingPreferences) { self.preferences=preferences }
    var composition:RingComposition { RingComposition(snapshot:snapshot,preferences:preferences,fiveHourSupport:fiveHourSupport) }
    var display:QuotaDisplay { composition.center.display }
    var pools:[WeeklyQuota] { Dictionary(grouping:snapshot.quotas,by:\.poolID).values.compactMap(\.first).sorted { $0.poolID<$1.poolID } }
}
final class RingSettingsWindow:NSWindowController,NSWindowDelegate {
    private let onClose:()->Void
    init(model:SettingsModel,onClose:@escaping ()->Void) {
        self.onClose=onClose
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:470,height:560),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="CodexRing";window.isReleasedWhenClosed=false
        window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary,.canJoinAllApplications,.ignoresCycle]
        super.init(window:window);window.delegate=self
        window.contentView=NSHostingView(rootView:RingSettingsView(model:model,onDone:{ [weak self] in self?.close() }));window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
    func windowWillClose(_ notification:Notification) { onClose() }
}
private struct RingSettingsView:View {
    @ObservedObject var model:SettingsModel
    let onDone:()->Void
    private var colorScheme:ColorScheme? {
        switch model.preferences.theme { case .system:return nil;case .light:return .light;case .dark:return .dark }
    }
    var body:some View {
        VStack(spacing:0) {
            Form {
                appearanceSection
                ringSection
                quotaStatusSection
                DisclosureGroup("更多") {
                    HStack(spacing:12) {
                        Button("调试") { model.onOpenDebug?() }
                        Button("归位") { model.onRestore?() }
                            .help("恢复圆圈到屏幕内")
                    }.frame(maxWidth:.infinity,alignment:.leading)
                        .padding(.top,12)
                    if model.debugState.isEnabled { Text("调试模式").font(.caption).foregroundStyle(.orange) }
                }
            }.formStyle(.grouped)
            HStack {
                Spacer();Button("完成",action:onDone).keyboardShortcut(.defaultAction)
            }
                .padding(.horizontal,20).padding(.vertical,12)
        }.frame(width:470,height:560)
            .background(Color(nsColor:.windowBackgroundColor))
            .toggleStyle(.switch)
            .preferredColorScheme(colorScheme)
    }
    private var appearanceSection:some View {
        Section("显示") {
            Picker("刷新间隔",selection:$model.preferences.refreshInterval) {
                ForEach(RefreshInterval.allCases,id:\.rawValue) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
            Toggle("菜单栏显示额度",isOn:$model.preferences.showMenuBar)
                .help("按下方勾选的本周、5小时额度显示百分比，双选时用 | 分隔；点击打开额度进度面板。")
            Picker("显示项",selection:$model.preferences.metric) {
                Text("剩余").tag(DisplayMetric.remaining);Text("已用").tag(DisplayMetric.used)
            }.pickerStyle(.segmented)
                .accessibilityHint("已用从顶部顺时针，剩余从顶部逆时针；颜色按实际已用比例的70%、80%、90%变化。")
            Picker("圆圈大小",selection:$model.preferences.size) {
                Text("小号 · 26 点").tag(RingSize.avatar);Text("紧凑 · 32 点").tag(RingSize.tiny)
                Text("中号 · 56 点").tag(RingSize.small);Text("标准 · 64 点").tag(RingSize.compact);Text("大号 · 76 点").tag(RingSize.large)
            }.pickerStyle(.menu)
                .accessibilityHint("26和32点只显示数字，表示所选百分比。无有效数据时显示横线。")
            Picker("主题",selection:$model.preferences.theme) {
                ForEach(ThemePreference.allCases,id:\.rawValue) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
        }
    }
    private var ringSection:some View {
        Section("圆环") {
            quotaControls
            Toggle("贴边自动隐藏",isOn:$model.preferences.autoHide)
                .help("自由移动时贴近屏幕边缘自动收起；跟随 Codex 窗口时保持显示在窗口内。")
            Toggle("展开与收起动画",isOn:$model.preferences.animations)
            Toggle("跟随 Codex 移动",isOn:$model.preferences.followCodex)
                .disabled(model.preferences.overlayCodexUsage)
                .help("圆圈跟随 Codex 窗口，支持普通窗口和全屏；没有 Codex 窗口时恢复自由位置。")
            Toggle("覆盖 Codex 额度控件",isOn:$model.preferences.overlayCodexUsage)
                .help("自动缩为小号并覆盖头像上方的用量圆环；点击仍打开 Codex 用量菜单。关闭后恢复原来的大小和位置。")
            if model.preferences.overlayCodexUsage && model.overlayAccessibilityGranted && !model.overlayStatus.isEmpty {
                Text(model.overlayStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var quotaControls:some View {
        Toggle("本周额度",isOn:Binding(get:{model.fiveHourSupport == false ? true:model.preferences.showWeek},set:{model.preferences.showWeek=$0}))
            .disabled(model.fiveHourSupport == false || (model.preferences.showWeek && !model.preferences.showFiveHours))
        Toggle("5小时额度",isOn:Binding(get:{model.fiveHourSupport == false ? false:model.preferences.showFiveHours},set:{model.preferences.showFiveHours=$0}))
            .disabled(model.fiveHourSupport != true || (model.preferences.showFiveHours && !model.preferences.showWeek))
            .accessibilityHint(model.fiveHourSupport == false ? "账户未提供5小时窗口。":"双圈时外圈本周、内圈5小时；中心数字可单独选择。")
        if model.composition.inner != nil {
            Picker("中心数字",selection:$model.preferences.centerPeriod) {
                Text("本周额度").tag(QuotaPeriod.week)
                Text("5小时额度").tag(QuotaPeriod.fiveHours)
            }.pickerStyle(.segmented)
                .help("只切换圆圈中心的数字来源；双圈和菜单栏仍分别显示两种额度。")
        } else {
            valueRow("中心数字",value:model.composition.centerPeriod == .week ? "本周额度（自动）":"5小时额度（自动）")
        }
    }
    @ViewBuilder private var quotaStatusSection:some View {
        if model.display.status != .available || model.pools.count>1 {
            Section {
                if model.display.status != .available {
                    Text(model.display.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if model.pools.count>1 {
                    Picker("额度池",selection:$model.preferences.bucketID) {
                        Text("自动选择").tag(Optional<String>.none)
                        ForEach(model.pools,id:\.poolID) { q in Text(q.label).tag(Optional(q.poolID)) }
                    }.pickerStyle(.menu)
                }
            }
        }
    }
    private func valueRow(_ title:String,value:String,warning:Bool=false)->some View {
        HStack(spacing:12) {
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength:8)
            Text(value).font(.callout).foregroundStyle(warning ? Color.orange:Color.secondary)
                .lineLimit(1).fixedSize(horizontal:true,vertical:false)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
