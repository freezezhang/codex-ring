import AppKit
import SwiftUI
import QuotaCore

final class SettingsModel:ObservableObject {
    let apiUsage=OpenAIUsageController()
    @Published var preferences:RingPreferences { didSet { onPreferences?(preferences) } }
    @Published var snapshot=QuotaSnapshot(source:.official,fetchedAt:Date(),loading:true)
    @Published var source:QuotaSource = .official
    @Published var isRefreshing=false
    @Published var updatedText="—"
    @Published var diagnosticText=""
    @Published var diagnostics=false
    @Published var notificationStatus=L10n.string("permission.notRequested")
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
    var onOpenDebug:(()->Void)?
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
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:620),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.titlebarAppearsTransparent=true
        window.contentMinSize=NSSize(width:720,height:520)
        window.setFrameAutosaveName("CodexRingSidebarSettings")
        window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary,.canJoinAllApplications,.ignoresCycle]
        super.init(window:window);window.delegate=self
        applyLanguage()
        window.contentView=NSHostingView(rootView:RingSettingsView(model:model,onDone:{ [weak self] in self?.close() }));window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
    func applyLanguage() { window?.title=L10n.string("settings.windowTitle") }
    func windowWillClose(_ notification:Notification) { onClose() }
}
private enum SettingsPage:String,CaseIterable,Identifiable {
    case general,appearance,ring,panel,api,alerts,about
    var id:String { rawValue }
    var title:String {
        switch self {
        case .general:return L10n.string("settings.page.general")
        case .appearance:return L10n.string("settings.page.appearance")
        case .ring:return L10n.string("settings.page.ring")
        case .panel:return L10n.string("settings.page.subscription")
        case .api:return L10n.string("settings.page.api")
        case .alerts:return L10n.string("settings.page.alerts")
        case .about:return L10n.string("settings.page.about")
        }
    }
    var icon:String {
        switch self {
        case .general:return "gearshape.fill"
        case .appearance:return "display"
        case .ring:return "circle.dashed"
        case .panel:return "chart.bar.fill"
        case .api:return "network"
        case .alerts:return "bell.badge.fill"
        case .about:return "info.circle.fill"
        }
    }
    var color:Color {
        switch self {
        case .general:return .gray
        case .appearance:return .blue
        case .ring:return .cyan
        case .panel:return .green
        case .api:return .purple
        case .alerts:return .orange
        case .about:return .indigo
        }
    }
}

// Native picker items are cached by SwiftUI. Recreate only the pickers when
// the language changes, preserving the page selection and unsaved API fields.
private struct RingSettingsView:View {
    @ObservedObject var model:SettingsModel
    let onDone:()->Void
    @State private var selected:SettingsPage? = .general
    private var colorScheme:ColorScheme? {
        switch model.preferences.theme { case .system:return nil;case .light:return .light;case .dark:return .dark }
    }
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:12) {
                List(SettingsPage.allCases,selection:$selected) { page in
                    HStack(spacing:10) {
                        Image(systemName:page.icon).font(.system(size:13,weight:.semibold))
                            .foregroundStyle(.white).frame(width:26,height:26)
                            .background(page.color,in:RoundedRectangle(cornerRadius:6))
                        Text(page.title).font(.system(size:13,weight:.medium)).foregroundStyle(.primary)
                    }.padding(.vertical,4).tag(page)
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    .accessibilityLabel(L10n.string("settings.sidebar.a11y"))
            }.frame(width:184).background(Color.primary.opacity(0.025))
            Divider()
            VStack(alignment:.leading,spacing:0) {
                Text((selected ?? .general).title).font(.system(size:22,weight:.semibold))
                    .padding(.horizontal,24).padding(.top,22).padding(.bottom,12)
                // Keep panes alive so switching categories preserves unsaved API fields.
                ZStack {
                    ForEach(SettingsPage.allCases) { page in
                        settingsPane(page)
                            .frame(maxWidth:.infinity,maxHeight:.infinity)
                            .opacity(selected == page ? 1:0)
                            .allowsHitTesting(selected == page)
                            .disabled(selected != page)
                            .accessibilityHidden(selected != page)
                            .zIndex(selected == page ? 1:0)
                    }
                }
                Divider()
                HStack {
                    Spacer()
                    Button(L10n.string("common.done"),action:onDone).keyboardShortcut(.defaultAction)
                }.padding(.horizontal,24).padding(.vertical,14)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(minWidth:720,minHeight:520)
            .background(Color(nsColor:.windowBackgroundColor))
            .toggleStyle(.switch)
            .preferredColorScheme(colorScheme)
            .environment(\.locale,Locale(identifier:L10n.language.code))
            .onChange(of:selected) { value in if value == nil { selected = .general } }
    }
    @ViewBuilder private func settingsPane(_ page:SettingsPage)->some View {
        if page == .about {
            VStack(spacing:16) {
                Image(nsImage:NSApp.applicationIconImage).resizable().scaledToFit()
                    .frame(width:88,height:88).contentShape(Rectangle())
                    .onTapGesture(count:5) { model.onOpenDebug?() }
                    .accessibilityLabel(L10n.string("about.icon.a11y"))
                Text("CodexRing").font(.system(size:26,weight:.semibold))
                Text(RingAboutWindow.versionText)
                    .font(.body).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            Form {
                switch page {
                case .general:
                    generalSection
                    languageSection
                    Section(L10n.string("settings.refresh.section")) {
                        Picker(L10n.string("settings.refresh.interval"),selection:$model.preferences.refreshInterval) {
                            ForEach(RefreshInterval.allCases,id:\.rawValue) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu).id("refresh-interval."+L10n.language.code)
                    }
                    quotaStatusSection
                case .appearance:appearanceSection
                case .ring:ringSection
                case .panel:
                    quotaPanelSection
                    quotaStatusSection
                case .api:OpenAIUsageSettings(controller:model.apiUsage)
                case .alerts:alertsSection
                case .about:EmptyView()
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
    private var languageSection:some View {
        Section(L10n.string("settings.language.section")) {
            Picker(L10n.string("settings.language.picker"),selection:$model.preferences.languageCode) {
                Text(L10n.string("settings.language.system")).tag(Optional<String>.none)
                ForEach(AppLanguage.supported) { language in Text(language.displayName).tag(Optional(language.code)) }
            }.pickerStyle(.menu).id("interface-language."+L10n.language.code)
                .help(L10n.string("settings.language.help"))
        }
    }
    private var appearanceSection:some View {
        Section(L10n.string("settings.appearance.section")) {
            Toggle(L10n.string("settings.menuBar.toggle"),isOn:$model.preferences.showMenuBar)
                .help(L10n.string("settings.menuBar.help"))
            Picker(L10n.string("settings.metric.picker"),selection:$model.preferences.metric) {
                Text(L10n.string("settings.metric.remaining")).tag(DisplayMetric.remaining)
                Text(L10n.string("settings.metric.used")).tag(DisplayMetric.used)
            }.pickerStyle(.segmented).id("display-metric."+L10n.language.code)
                .accessibilityHint(L10n.string("settings.metric.hint"))
            Picker(L10n.string("settings.theme.picker"),selection:$model.preferences.theme) {
                ForEach(ThemePreference.allCases,id:\.rawValue) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).id("theme."+L10n.language.code)
        }
    }
    private var quotaPanelSection:some View {
        Section(L10n.string("settings.panel.section")) {
            Toggle(L10n.string("settings.panel.pace"),isOn:$model.preferences.quotaPanel.showPace)
                .help(L10n.string("settings.panel.pace.help"))
            Picker(L10n.string("settings.panel.workDays"),selection:$model.preferences.quotaPanel.weeklySchedule) {
                ForEach(WeeklyPaceSchedule.allCases,id:\.rawValue) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).id("workdays."+L10n.language.code)
                .help(L10n.string("settings.panel.workDays.help"))
            Picker(L10n.string("settings.panel.ticks"),selection:$model.preferences.quotaPanel.tickStyle) {
                ForEach(QuotaTickStyle.allCases,id:\.rawValue) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).id("tick-style."+L10n.language.code)
                .help(L10n.string("settings.panel.ticks.help"))
            Picker(L10n.string("settings.panel.resetStyle"),selection:$model.preferences.quotaPanel.resetStyle) {
                ForEach(QuotaResetStyle.allCases,id:\.rawValue) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).id("reset-style."+L10n.language.code)
        }
    }
    private var ringSection:some View {
        Section(L10n.string("settings.ring.section")) {
            quotaControls
            Picker(L10n.string("settings.ring.size"),selection:$model.preferences.size) {
                Text(L10n.string("settings.ring.size.avatar")).tag(RingSize.avatar);Text(L10n.string("settings.ring.size.tiny")).tag(RingSize.tiny)
                Text(L10n.string("settings.ring.size.small")).tag(RingSize.small);Text(L10n.string("settings.ring.size.compact")).tag(RingSize.compact)
                Text(L10n.string("settings.ring.size.large")).tag(RingSize.large)
            }.pickerStyle(.menu).id("ring-size."+L10n.language.code)
                .accessibilityHint(L10n.string("settings.ring.size.hint"))
            Toggle(L10n.string("settings.ring.autoHide"),isOn:$model.preferences.autoHide)
                .help(L10n.string("settings.ring.autoHide.help"))
            Toggle(L10n.string("settings.ring.animations"),isOn:$model.preferences.animations)
            Toggle(L10n.string("settings.ring.follow"),isOn:$model.preferences.followCodex)
                .disabled(model.preferences.overlayCodexUsage)
                .help(L10n.string("settings.ring.follow.help"))
            VStack(alignment:.leading,spacing:0) {
                Toggle(L10n.string("settings.ring.overlay"),isOn:$model.preferences.overlayCodexUsage)
                    .help(L10n.string("settings.ring.overlay.help"))
                valueRow(L10n.string("settings.ring.overlay.permission"),
                         value:model.overlayAccessibilityGranted ? L10n.string("permission.granted"):L10n.string("permission.denied"))
                    .help(model.overlayAuthorizationNotice ?? L10n.string("settings.ring.overlay.permission.help"))
                    .padding(.leading,16)
                    .padding(.top,12)
                if let notice=model.overlayAuthorizationNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                        .padding(.leading,16).padding(.top,8)
                }
                Button(L10n.string("settings.ring.overlay.accessibilitySettings")) { model.onOpenAccessibilitySettings?() }
                    .padding(.leading,16).padding(.top,8)
                if !model.overlayStatus.isEmpty {
                    valueRow(L10n.string("settings.ring.overlay.status"),value:L10n.string("settings.ring.overlay.unavailable"),warning:true)
                        .help(model.overlayStatus)
                        .padding(.leading,16).padding(.top,8)
                }
            }
        }
    }
    @ViewBuilder private var quotaControls:some View {
        Toggle(QuotaPeriod.week.quotaName,isOn:Binding(get:{model.fiveHourSupport == false ? true:model.preferences.showWeek},set:{model.preferences.showWeek=$0}))
            .disabled(model.fiveHourSupport == false || (model.preferences.showWeek && !model.preferences.showFiveHours))
        Toggle(QuotaPeriod.fiveHours.quotaName,isOn:Binding(get:{model.fiveHourSupport == false ? false:model.preferences.showFiveHours},set:{model.preferences.showFiveHours=$0}))
            .disabled(model.fiveHourSupport != true || (model.preferences.showFiveHours && !model.preferences.showWeek))
            .accessibilityHint(model.fiveHourSupport == false ? L10n.string("settings.ring.fiveHours.missing"):L10n.string("settings.ring.fiveHours.hint"))
        if model.composition.inner != nil {
            Picker(L10n.string("settings.ring.center"),selection:Binding(get:{ model.preferences.automaticCenter ? "auto":model.preferences.centerPeriod.rawValue },set:{ value in
                var preferences=model.preferences
                preferences.automaticCenter=value == "auto"
                if let period=QuotaPeriod(rawValue:value) { preferences.centerPeriod=period }
                model.preferences=preferences
            })) {
                Text(QuotaPeriod.week.shortName).tag(QuotaPeriod.week.rawValue)
                Text(QuotaPeriod.fiveHours.shortName).tag(QuotaPeriod.fiveHours.rawValue)
                Text(L10n.string("settings.ring.center.lower")).tag("auto")
            }.pickerStyle(.segmented).id("center-number."+L10n.language.code)
                .help(L10n.string("settings.ring.center.help"))
        } else {
            valueRow(L10n.string("settings.ring.center"),value:L10n.format("settings.ring.center.automatic",model.composition.centerPeriod.quotaName))
        }
    }
    private var alertsSection:some View {
        Section(L10n.string("settings.alerts.section")) {
            VStack(alignment:.leading,spacing:0) {
                Toggle(L10n.string("settings.alerts.toggle"),isOn:$model.preferences.alerts.enabled)
                    .help(L10n.string("settings.alerts.toggle.help"))
                valueRow(L10n.string("settings.alerts.permission"),value:model.notificationStatus)
                    .help(L10n.string("settings.alerts.permission.help"))
                    .padding(.leading,16).padding(.top,12)
                Button(L10n.string("settings.alerts.notificationSettings")) { model.onNotificationSettings?() }
                    .padding(.leading,16).padding(.top,8)
            }
            if model.preferences.alerts.enabled {
                Toggle(L10n.string("settings.alerts.low"),isOn:$model.preferences.alerts.lowQuota)
                if model.preferences.alerts.lowQuota {
                    Stepper(L10n.format("settings.alerts.low.threshold",model.preferences.alerts.remainingThreshold),value:$model.preferences.alerts.remainingThreshold,in:1...99,step:1).padding(.leading,16)
                }
                Toggle(L10n.string("settings.alerts.prediction"),isOn:$model.preferences.alerts.predictedExhaustion)
                if model.preferences.alerts.predictedExhaustion {
                    Picker(L10n.string("settings.alerts.prediction.lead"),selection:$model.preferences.alerts.predictionMinutes) {
                        Text(L10n.format("unit.minutes",15)).tag(15);Text(L10n.format("unit.minutes",30)).tag(30)
                        Text(L10n.format("unit.hours",1)).tag(60);Text(L10n.format("unit.hours",2)).tag(120)
                    }.id("alert-lead."+L10n.language.code).padding(.leading,16)
                }
                Toggle(L10n.string("settings.alerts.restored"),isOn:$model.preferences.alerts.restored)
                Toggle(L10n.string("alert.card.title"),isOn:$model.preferences.alerts.resetCards)
                if model.preferences.alerts.resetCards {
                    Stepper(L10n.format("settings.alerts.card.days",model.preferences.alerts.cardDays),value:$model.preferences.alerts.cardDays,in:1...30).padding(.leading,16)
                }
            }
            Toggle(L10n.string("settings.alerts.confetti"),isOn:$model.preferences.resetConfetti)
                .help(L10n.string("settings.alerts.confetti.help"))
            if model.preferences.resetConfetti {
                Button(L10n.string("settings.alerts.confetti.preview")) { model.onPreviewConfetti?() }
                    .padding(.leading,16)
            }
        }
    }
    private var generalSection:some View {
        Section(L10n.string("settings.startup.section")) {
            VStack(alignment:.leading,spacing:0) {
                Toggle(L10n.string("settings.startup.launchAtLogin"),isOn:Binding(get:{model.launchAtLogin},set:{model.onLoginChange?($0)}))
                valueRow(L10n.string("settings.startup.status"),value:model.loginError == nil ? model.loginStatus:L10n.string("settings.startup.failed"))
                    .help(model.loginError.map { L10n.format("settings.startup.failed.detail",$0) } ?? L10n.string("settings.startup.status.help"))
                    .padding(.leading,16).padding(.top,12)
                Button(L10n.string("settings.startup.loginItems")) { model.onLoginSettings?() }
                    .padding(.leading,16).padding(.top,8)
            }
        }
    }
    @ViewBuilder private var quotaStatusSection:some View {
        if model.display.status != .available || model.pools.count>1 {
            Section {
                if model.display.status != .available {
                    valueRow(L10n.string("settings.quota.status"),value:model.display.subtitle)
                }
                if model.pools.count>1 {
                    Picker(L10n.string("settings.quota.pool"),selection:$model.preferences.bucketID) {
                        Text(L10n.string("settings.quota.pool.automatic")).tag(Optional<String>.none)
                        ForEach(model.pools,id:\.poolID) { q in Text(q.label).tag(Optional(q.poolID)) }
                    }.pickerStyle(.menu).id("quota-pool."+L10n.language.code)
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
