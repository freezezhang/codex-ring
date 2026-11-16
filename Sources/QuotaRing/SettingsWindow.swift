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
    @Published var notificationStatus="未申请"
    @Published var launchAtLogin=false
    @Published var loginStatus=""
    @Published var loginError:String?
    @Published var fiveHourSupport:Bool?
    @Published var overlayAccessibilityGranted=false
    @Published var overlayAuthorizationNotice:String?
    @Published var overlayStatus=""
    @Published var menuPresentation:QuotaMenuPresentation?
    @Published var menuPanelVisible=false
    @Published var debugState=QuotaDebugState() { didSet { onDebugState?(debugState) } }
    var onPreferences:((RingPreferences)->Void)?
    var onDebugState:((QuotaDebugState)->Void)?
    var onDiagnostics:(()->Void)?
    var onOpenAccessibilitySettings:(()->Void)?
    var onAbout:(()->Void)?
    var onLoginChange:((Bool)->Void)?
    var onLoginSettings:(()->Void)?
    var onNotificationSettings:(()->Void)?
    var onPreviewConfetti:(()->Void)?
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
                quotaPanelSection
                ringSection
                alertsSection
                generalSection
                quotaStatusSection
            }.formStyle(.grouped)
            HStack {
                Button("关于") { model.onAbout?() }
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
    private var quotaPanelSection:some View {
        Section("额度面板") {
            Toggle("显示用量节奏",isOn:$model.preferences.quotaPanel.showPace)
                .help("显示红／绿进度标记、超额／余量和预计耗尽时间。")
            Picker("每周工作日",selection:$model.preferences.quotaPanel.weeklySchedule) {
                ForEach(WeeklyPaceSchedule.allCases,id:\.rawValue) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
                .help("4／5／6天从周一起计算，按系统时区划分；用于本周节奏和耗尽预测。自动按完整7天计算，不显示每日刻度。5小时额度不受影响。")
            Picker("周期刻度外观",selection:$model.preferences.quotaPanel.tickStyle) {
                ForEach(QuotaTickStyle.allCases,id:\.rawValue) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
                .help("控制每周工作日及5小时额度的小时刻度。隐藏刻度不会停止节奏预测。")
            Picker("重置时间",selection:$model.preferences.quotaPanel.resetStyle) {
                ForEach(QuotaResetStyle.allCases,id:\.rawValue) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
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
            VStack(alignment:.leading,spacing:0) {
                Toggle("覆盖 Codex 额度控件",isOn:$model.preferences.overlayCodexUsage)
                    .help("自动缩为小号并覆盖头像上方的用量圆环；点击仍打开 Codex 用量菜单。关闭后恢复原来的大小和位置。")
                valueRow("需要辅助功能权限",value:model.overlayAccessibilityGranted ? "已授权":"未授权")
                    .help(model.overlayAuthorizationNotice ?? "开启覆盖功能需要辅助功能权限。授权后请重新开启覆盖。")
                    .padding(.leading,16)
                    .padding(.top,12)
                if let notice=model.overlayAuthorizationNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                        .padding(.leading,16).padding(.top,8)
                }
                Button("辅助功能设置") { model.onOpenAccessibilitySettings?() }
                    .padding(.leading,16).padding(.top,8)
                if !model.overlayStatus.isEmpty {
                    valueRow("覆盖状态",value:"暂不可用",warning:true)
                        .help(model.overlayStatus)
                        .padding(.leading,16).padding(.top,8)
                }
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
            Picker("中心数字",selection:Binding(get:{ model.preferences.automaticCenter ? "auto":model.preferences.centerPeriod.rawValue },set:{ value in
                var preferences=model.preferences
                preferences.automaticCenter=value == "auto"
                if let period=QuotaPeriod(rawValue:value) { preferences.centerPeriod=period }
                model.preferences=preferences
            })) {
                Text("本周").tag(QuotaPeriod.week.rawValue)
                Text("5小时").tag(QuotaPeriod.fiveHours.rawValue)
                Text("较低项").tag("auto")
            }.pickerStyle(.segmented)
                .help("较低项优先显示已耗尽或预计更早耗尽的额度；无法预测时显示剩余额度更低的一项。双圈和菜单栏仍分别显示两种额度。")
        } else {
            valueRow("中心数字",value:model.composition.centerPeriod == .week ? "本周额度（自动）":"5小时额度（自动）")
        }
    }
    private var alertsSection:some View {
        Section("提醒") {
            VStack(alignment:.leading,spacing:0) {
                Toggle("额度与重置卡通知",isOn:$model.preferences.alerts.enabled)
                    .help("按刷新间隔检查真实额度；同一周期、同类事件只提醒一次。预测沿用每周工作日设置。")
                valueRow("需要通知权限",value:model.notificationStatus)
                    .help("开启提醒时申请通知权限；未授权时可在系统通知设置中允许 CodexRing。")
                    .padding(.leading,16).padding(.top,12)
                Button("通知设置") { model.onNotificationSettings?() }
                    .padding(.leading,16).padding(.top,8)
            }
            if model.preferences.alerts.enabled {
                Toggle("剩余额度不足",isOn:$model.preferences.alerts.lowQuota)
                if model.preferences.alerts.lowQuota {
                    Stepper("低于 \(model.preferences.alerts.remainingThreshold)%",value:$model.preferences.alerts.remainingThreshold,in:1...99,step:1).padding(.leading,16)
                }
                Toggle("预计即将耗尽",isOn:$model.preferences.alerts.predictedExhaustion)
                if model.preferences.alerts.predictedExhaustion {
                    Picker("提前提醒",selection:$model.preferences.alerts.predictionMinutes) {
                        Text("15分钟").tag(15);Text("30分钟").tag(30);Text("1小时").tag(60);Text("2小时").tag(120)
                    }.padding(.leading,16)
                }
                Toggle("额度恢复",isOn:$model.preferences.alerts.restored)
                Toggle("重置卡即将到期",isOn:$model.preferences.alerts.resetCards)
                if model.preferences.alerts.resetCards {
                    Stepper("提前 \(model.preferences.alerts.cardDays) 天",value:$model.preferences.alerts.cardDays,in:1...30).padding(.leading,16)
                }
            }
            Toggle("额度恢复时播放彩带",isOn:$model.preferences.resetConfetti)
                .help("检测到额度重置或从耗尽恢复时播放；不会因打开应用或调试数值触发。遵守系统减少动态效果设置。")
            if model.preferences.resetConfetti {
                Button("预览彩带") { model.onPreviewConfetti?() }
                    .padding(.leading,16)
            }
        }
    }
    private var generalSection:some View {
        Section("通用") {
            VStack(alignment:.leading,spacing:0) {
                Toggle("登录时启动",isOn:Binding(get:{model.launchAtLogin},set:{model.onLoginChange?($0)}))
                valueRow("登录项状态",value:model.loginError == nil ? model.loginStatus:"设置失败")
                    .help(model.loginError ?? "与系统登录项状态同步。")
                    .padding(.leading,16).padding(.top,12)
                Button("登录项设置") { model.onLoginSettings?() }
                    .padding(.leading,16).padding(.top,8)
            }
        }
    }
    @ViewBuilder private var quotaStatusSection:some View {
        if model.display.status != .available || model.pools.count>1 {
            Section {
                if model.display.status != .available {
                    valueRow("额度状态",value:model.display.subtitle)
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
