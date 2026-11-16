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
    var onPreferences:((RingPreferences)->Void)?
    var onRestore:(()->Void)?,onDiagnostics:(()->Void)?
    init(preferences:RingPreferences) { self.preferences=preferences }
    var composition:RingComposition { RingComposition(snapshot:snapshot,preferences:preferences,fiveHourSupport:fiveHourSupport) }
    var display:QuotaDisplay { composition.outer.display }
    var pools:[WeeklyQuota] { Dictionary(grouping:snapshot.quotas,by:\.poolID).values.compactMap(\.first).sorted { $0.poolID<$1.poolID } }
    func resetText(_ period:QuotaPeriod)->String {
        QuotaDateText.string(snapshot.display(selectedID:preferences.bucketID,period:period).quota?.resetsAt)
    }
}
final class RingSettingsWindow:NSWindowController,NSWindowDelegate {
    private let onClose:()->Void
    init(model:SettingsModel,onClose:@escaping ()->Void) {
        self.onClose=onClose
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:470,height:650),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="CodexRing";window.isReleasedWhenClosed=false
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
                quotaSection
                cardsSection
                DisclosureGroup("更多") {
                    Button("恢复圆圈到屏幕内") { model.onRestore?() }
                    Toggle("显示窗口诊断信息",isOn:$model.diagnostics).onChange(of:model.diagnostics) { _ in model.onDiagnostics?() }
                    if model.diagnostics { Text(model.diagnosticText).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }.formStyle(.grouped)
            HStack { Spacer();Button("完成",action:onDone).keyboardShortcut(.defaultAction) }
                .padding(.horizontal,20).padding(.vertical,12)
        }.frame(width:470,height:650)
            .background(Color(nsColor:.windowBackgroundColor))
            .toggleStyle(.switch)
            .preferredColorScheme(colorScheme)
    }
    private var appearanceSection:some View {
        Section("显示") {
            Picker("刷新间隔",selection:$model.preferences.refreshInterval) {
                ForEach(RefreshInterval.allCases,id:\.rawValue) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
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
            Toggle("贴边自动隐藏",isOn:$model.preferences.autoHide)
            Toggle("展开与收起动画",isOn:$model.preferences.animations)
        }
    }
    private var quotaSection:some View {
        Section("额度") {
            Toggle("显示1周额度",isOn:Binding(get:{model.fiveHourSupport == false ? true:model.preferences.showWeek},set:{model.preferences.showWeek=$0}))
                .disabled(model.fiveHourSupport == false || (model.preferences.showWeek && !model.preferences.showFiveHours))
            Toggle("显示5小时额度",isOn:Binding(get:{model.fiveHourSupport == false ? false:model.preferences.showFiveHours},set:{model.preferences.showFiveHours=$0}))
                .disabled(model.fiveHourSupport != true || (model.preferences.showFiveHours && !model.preferences.showWeek))
                .accessibilityHint(model.fiveHourSupport == false ? "账户未提供5小时窗口。":"双环时外圈1周、内圈5小时，中心数字只表示1周。")
            valueRow("周额度重置",value:model.resetText(.week))
            if model.fiveHourSupport == true { valueRow("5小时重置",value:model.resetText(.fiveHours)) }
            valueRow("刷新时间",value:model.source == .disconnected ? "—":model.updatedText)
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
    private var cardsSection:some View {
        Section {
            if let cards=model.snapshot.resetCards {
                let available=cards.details?.filter(\.available) ?? []
                ForEach(Array(available.enumerated()),id:\.offset) { index,card in
                    valueRow(card.displayTitle,value:card.expiryText(),warning:card.expiresAt.map { $0<=Date() } == true)
                        .accessibilityElement(children:.combine)
                        .accessibilityHint("第\(index+1)张额度重置卡；日期按北京时间显示。")
                }
                if available.isEmpty || (cards.availableCount.map { $0>available.count } ?? false) {
                    valueRow("额度重置卡",value:cards.availableCount == 0 ? "暂无可用":"到期时间未知")
                }
                if Date().timeIntervalSince(model.snapshot.fetchedAt)>300 { Text("已过期").foregroundStyle(.orange) }
            } else {
                Text("—").foregroundStyle(.secondary).accessibilityLabel("重置卡信息不可用")
            }
        } header: {
            HStack {
                Text("额度重置卡");Spacer()
                Text(model.snapshot.resetCards?.availableCount.map { "\($0) 张可用" } ?? "—").foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading)
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
