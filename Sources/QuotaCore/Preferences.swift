import Foundation

public enum DisplayMetric: String, Codable, CaseIterable {
    case remaining, used
    public var title: String { self == .remaining ? L10n.string("metric.remaining.title") : L10n.string("metric.used.title") }
    public var shortTitle: String { self == .remaining ? L10n.string("metric.remaining.short") : L10n.string("metric.used.short") }
    /// A percentage labelled with this metric, e.g. "80% left".
    public func value(_ text:String)->String { L10n.format(self == .remaining ? "metric.remaining.value":"metric.used.value",text) }
    /// The tooltip form; Chinese omits the space.
    public func compactValue(_ text:String)->String { L10n.format(self == .remaining ? "metric.remaining.compactValue":"metric.used.compactValue",text) }
}
public enum RingSize: Int, Codable, CaseIterable {
    case avatar = 26, tiny = 32, small = 56, compact = 64, large = 76
    public var numberOnly: Bool { rawValue <= 32 }
}
public enum RefreshInterval:Int,Codable,CaseIterable { case oneMinute=60,twoMinutes=120,fiveMinutes=300
    public var title:String { L10n.format("unit.minutes",rawValue/60) }
}
public enum ThemePreference:String,Codable,CaseIterable {
    case system,light,dark
    public var title:String {
        switch self { case .system:return L10n.string("theme.system");case .light:return L10n.string("theme.light");case .dark:return L10n.string("theme.dark") }
    }
    public func isDark(systemIsDark:Bool)->Bool { self == .system ? systemIsDark:self == .dark }
}
public struct PanelPosition: Codable, Equatable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct RingPreferences: Codable, Equatable {
    public var metric: DisplayMetric = .remaining
    public var size: RingSize = .compact
    public var autoHide = true
    public var animations = true
    public var positionLocked = false
    public var followCodex = false
    public var overlayCodexUsage = false
    public var showMenuBar = true
    public var quotaPanel=QuotaPanelPreferences()
    public var alerts=QuotaAlertPreferences()
    public var resetConfetti=false
    public var automaticCenter=false
    /// Relative position inside Codex; independent of the free desktop position.
    public var codexAnchor:PanelPosition? = nil
    public var showWeek = true
    public var showFiveHours = false
    public var centerPeriod:QuotaPeriod = .week
    public var refreshInterval:RefreshInterval = .oneMinute
    public var theme:ThemePreference = .system
    public var bucketID: String? = nil
    public var position: PanelPosition? = nil
    /// A registered `AppLanguage.code`; `nil` follows the system languages.
    public var languageCode: String? = nil
    /// Overlay locking is derived; preserve the user's normal-mode preference.
    public var effectivePositionLocked:Bool { positionLocked || overlayCodexUsage }
    public var canTogglePositionLock:Bool { !overlayCodexUsage }
    public mutating func togglePositionLock() {
        guard canTogglePositionLock else { return }
        positionLocked.toggle()
    }
    public mutating func reconcileOverlayPermission(granted:Bool) {
        if !granted { overlayCodexUsage=false }
    }
    public init() {}
    private enum CodingKeys:String,CodingKey { case alerts,resetConfetti,automaticCenter,metric,size,autoHide,animations,positionLocked,followCodex,overlayCodexUsage,showMenuBar,quotaPanel,codexAnchor,showWeek,showFiveHours,centerPeriod,refreshInterval,theme,bucketID,position,languageCode }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        metric=(try? c.decode(DisplayMetric.self,forKey:.metric)) ?? .remaining
        size=(try? c.decode(RingSize.self,forKey:.size)) ?? .compact
        autoHide=(try? c.decode(Bool.self,forKey:.autoHide)) ?? true
        animations=(try? c.decode(Bool.self,forKey:.animations)) ?? true
        positionLocked=(try? c.decode(Bool.self,forKey:.positionLocked)) ?? false
        followCodex=(try? c.decode(Bool.self,forKey:.followCodex)) ?? false
        overlayCodexUsage=(try? c.decode(Bool.self,forKey:.overlayCodexUsage)) ?? false
        showMenuBar=(try? c.decode(Bool.self,forKey:.showMenuBar)) ?? true
        quotaPanel=(try? c.decode(QuotaPanelPreferences.self,forKey:.quotaPanel)) ?? QuotaPanelPreferences()
        alerts=(try? c.decode(QuotaAlertPreferences.self,forKey:.alerts)) ?? QuotaAlertPreferences()
        alerts.normalize()
        resetConfetti=(try? c.decode(Bool.self,forKey:.resetConfetti)) ?? false
        automaticCenter=(try? c.decode(Bool.self,forKey:.automaticCenter)) ?? false
        codexAnchor=try? c.decodeIfPresent(PanelPosition.self,forKey:.codexAnchor)
        showWeek=(try? c.decode(Bool.self,forKey:.showWeek)) ?? true
        showFiveHours=(try? c.decode(Bool.self,forKey:.showFiveHours)) ?? false
        if !showWeek && !showFiveHours { showWeek=true }
        centerPeriod=(try? c.decode(QuotaPeriod.self,forKey:.centerPeriod)) ?? .week
        refreshInterval=(try? c.decode(RefreshInterval.self,forKey:.refreshInterval)) ?? .oneMinute
        theme=(try? c.decode(ThemePreference.self,forKey:.theme)) ?? .system
        bucketID=try? c.decodeIfPresent(String.self,forKey:.bucketID)
        position=try? c.decodeIfPresent(PanelPosition.self,forKey:.position)
        languageCode=try? c.decodeIfPresent(String.self,forKey:.languageCode)
    }
}

public enum RingMenuEntry:Equatable { case refresh,settings,reset,positionLock(locked:Bool),quit }
public enum RingMenuSpec {
    public static func entries(for preferences:RingPreferences)->[RingMenuEntry] { [.refresh,.positionLock(locked:preferences.effectivePositionLocked),.reset,.settings,.quit] }
}
public struct RingComposition {
    public let outer:RingPresentation
    public let inner:RingPresentation?
    public let outerPeriod:QuotaPeriod
    public let innerPeriod:QuotaPeriod?
    public let centerPeriod:QuotaPeriod
    public var center:RingPresentation {
        if let inner,innerPeriod == centerPeriod { return inner }
        return outer
    }
    public init(snapshot:QuotaSnapshot,preferences:RingPreferences,fiveHourSupport:Bool?,now:Date = Date()) {
        let periods:[QuotaPeriod]
        if fiveHourSupport != true { periods = [.week] }
        else if preferences.showWeek && preferences.showFiveHours { periods = [.week,.fiveHours] }
        else if preferences.showFiveHours { periods = [.fiveHours] }
        else { periods = [.week] }
        outerPeriod=periods[0];innerPeriod=periods.count>1 ? periods[1]:nil
        centerPeriod=periods.count>1
            ? (preferences.automaticCenter ? AutomaticQuotaSelection.select(snapshot:snapshot,preferences:preferences,periods:periods,now:now) ?? preferences.centerPeriod:preferences.centerPeriod)
            : periods[0]
        let pool=snapshot.selectedPoolID(preferences.bucketID)
        outer=RingPresentation(display:snapshot.display(selectedID:pool,period:periods[0],now:now),metric:preferences.metric)
        inner=periods.count>1 ? RingPresentation(display:snapshot.display(selectedID:pool,period:periods[1],now:now),metric:preferences.metric):nil
    }
    public var accessibilityText:String {
        var text=(outer.display.source == .debug ? L10n.string("a11y.debugPrefix"):"")
            + L10n.format(inner == nil ? "a11y.ring.single":"a11y.ring.outer",outerPeriod.title,outer.accessibilityText)
        if let inner,let innerPeriod {
            text += L10n.format("a11y.ring.inner",innerPeriod.title,inner.accessibilityText)
            text += L10n.format("a11y.ring.center",centerPeriod.title)
        }
        return text
    }
}
public final class PreferencesStore {
    private let defaults: UserDefaults
    private let key = "ring.preferences.v1"
    private let authorizedFingerprintKey="ring.accessibility.authorizedFingerprint.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> RingPreferences {
        guard let data = defaults.data(forKey: key), var preferences = try? JSONDecoder().decode(RingPreferences.self, from: data) else { return RingPreferences() }
        if let position = preferences.position, !position.x.isFinite || !position.y.isFinite { preferences.position = nil }
        return preferences
    }
    public func save(_ preferences: RingPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
        // Flush these small non-sensitive preferences before a user-requested restart.
        defaults.synchronize()
    }
    /// Evidence from this app's own successful authorization, not the system's
    /// private permission database. Missing history must never imply an update.
    public func observeAccessibilityTrust(_ trusted:Bool,fingerprint:String?)->Bool {
        guard let fingerprint,!fingerprint.isEmpty else { return false }
        let previous=defaults.string(forKey:authorizedFingerprintKey)
        if trusted {
            if previous != fingerprint {
                defaults.set(fingerprint,forKey:authorizedFingerprintKey)
                defaults.synchronize()
            }
            return false
        }
        return previous.map { $0 != fingerprint } ?? false
    }
}

public enum UsageBand: String, CaseIterable {
    case normal, yellow, orange, red
    public init(used: Double) {
        if used >= 90 { self = .red }
        else if used >= 80 { self = .orange }
        else if used >= 70 { self = .yellow }
        else { self = .normal }
    }
    public var hex: UInt32 {
        switch self { case .normal: return 0x69B5F6; case .yellow: return 0xF2CE58; case .orange: return 0xF4A24D; case .red: return 0xF2727D }
    }
    public var accessibleName: String {
        switch self {
        case .normal: return L10n.string("band.normal")
        case .yellow: return L10n.string("band.yellow")
        case .orange: return L10n.string("band.orange")
        case .red: return L10n.string("band.red")
        }
    }
}
public struct RingPresentation {
    public let display: QuotaDisplay
    public let metric: DisplayMetric
    public init(display: QuotaDisplay, metric: DisplayMetric) { self.display = display; self.metric = metric }
    public var used: Double? { display.remaining.map { 100 - $0 } }
    public var value: Double? { metric == .remaining ? display.remaining : used }
    public var band: UsageBand? { used.map(UsageBand.init(used:)) }
    public var text: String {
        guard let value else { return "—" }
        return abs(value.rounded() - value) < 0.05 ? "\(Int(value.rounded()))%" : String(format: "%.1f%%", value)
    }
    public var compactText: String { value.map { String(Int($0.rounded())) } ?? "—" }
    public var clockwise:Bool { metric == .used }
    public var arcEndAngle:Double? { value.map { 90 + (clockwise ? -1:1) * 3.6 * $0 } }
    public var caption: String {
        switch display.status {
        case .loading: return L10n.string("caption.loading")
        case .available: return metric.shortTitle
        case .stale, .expired: return L10n.string("caption.stale")
        case .connection: return L10n.string("caption.offline")
        case .timeout: return L10n.string("caption.timeout")
        case .unavailable: return display.source == .disconnected ? L10n.string("caption.paused") : L10n.string("caption.unknown")
        case .protocolError: return L10n.string("caption.unavailable")
        case .missingCLI: return L10n.string("caption.notConnected")
        }
    }
    public var accessibilityText: String {
        L10n.format("a11y.ring.presentation",metric.title,text,
                    clockwise ? L10n.string("a11y.clockwise"):L10n.string("a11y.counterclockwise"),
                    display.subtitle,band?.accessibleName ?? L10n.string("band.unknown"))
    }
}
