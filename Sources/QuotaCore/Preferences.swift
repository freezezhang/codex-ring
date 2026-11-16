import Foundation

public enum DisplayMetric: String, Codable, CaseIterable {
    case remaining, used
    public var title: String { self == .remaining ? "剩余额度" : "已用额度" }
    public var shortTitle: String { self == .remaining ? "剩余" : "已用" }
}
public enum RingSize: Int, Codable, CaseIterable {
    case avatar = 26, tiny = 32, small = 56, compact = 64, large = 76
    public var numberOnly: Bool { rawValue <= 32 }
}
public enum RefreshInterval:Int,Codable,CaseIterable { case oneMinute=60,twoMinutes=120,fiveMinutes=300
    public var title:String { "\(rawValue/60)分钟" }
}
public enum ThemePreference:String,Codable,CaseIterable {
    case system,light,dark
    public var title:String { switch self { case .system:return "跟随系统";case .light:return "浅色";case .dark:return "深色" } }
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
    /// Relative position inside Codex; independent of the free desktop position.
    public var codexAnchor:PanelPosition? = nil
    public var showWeek = true
    public var showFiveHours = false
    public var centerPeriod:QuotaPeriod = .week
    public var refreshInterval:RefreshInterval = .oneMinute
    public var theme:ThemePreference = .system
    public var bucketID: String? = nil
    public var position: PanelPosition? = nil
    public init() {}
    private enum CodingKeys:String,CodingKey { case metric,size,autoHide,animations,positionLocked,followCodex,overlayCodexUsage,codexAnchor,showWeek,showFiveHours,centerPeriod,refreshInterval,theme,bucketID,position }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        metric=(try? c.decode(DisplayMetric.self,forKey:.metric)) ?? .remaining
        size=(try? c.decode(RingSize.self,forKey:.size)) ?? .compact
        autoHide=(try? c.decode(Bool.self,forKey:.autoHide)) ?? true
        animations=(try? c.decode(Bool.self,forKey:.animations)) ?? true
        positionLocked=(try? c.decode(Bool.self,forKey:.positionLocked)) ?? false
        followCodex=(try? c.decode(Bool.self,forKey:.followCodex)) ?? false
        overlayCodexUsage=(try? c.decode(Bool.self,forKey:.overlayCodexUsage)) ?? false
        codexAnchor=try? c.decodeIfPresent(PanelPosition.self,forKey:.codexAnchor)
        showWeek=(try? c.decode(Bool.self,forKey:.showWeek)) ?? true
        showFiveHours=(try? c.decode(Bool.self,forKey:.showFiveHours)) ?? false
        if !showWeek && !showFiveHours { showWeek=true }
        centerPeriod=(try? c.decode(QuotaPeriod.self,forKey:.centerPeriod)) ?? .week
        refreshInterval=(try? c.decode(RefreshInterval.self,forKey:.refreshInterval)) ?? .oneMinute
        theme=(try? c.decode(ThemePreference.self,forKey:.theme)) ?? .system
        bucketID=try? c.decodeIfPresent(String.self,forKey:.bucketID)
        position=try? c.decodeIfPresent(PanelPosition.self,forKey:.position)
    }
}

public enum RingMenuEntry:Equatable { case refresh,settings,reset,positionLock(locked:Bool),quit }
public enum RingMenuSpec {
    public static func entries(for preferences:RingPreferences)->[RingMenuEntry] { [.refresh,.positionLock(locked:preferences.positionLocked),.reset,.settings,.quit] }
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
        centerPeriod=periods.count>1 ? preferences.centerPeriod:periods[0]
        let pool=snapshot.selectedPoolID(preferences.bucketID)
        outer=RingPresentation(display:snapshot.display(selectedID:pool,period:periods[0],now:now),metric:preferences.metric)
        inner=periods.count>1 ? RingPresentation(display:snapshot.display(selectedID:pool,period:periods[1],now:now),metric:preferences.metric):nil
    }
    public var accessibilityText:String {
        var text="\(outer.display.source == .debug ? "调试模式；":"")\(inner == nil ? "":"外圈")\(outerPeriod.title)：\(outer.accessibilityText)"
        if let inner,let innerPeriod { text += "；内圈\(innerPeriod.title)：\(inner.accessibilityText)；中心数字仅表示\(centerPeriod.title)额度。" }
        return text
    }
}
public final class PreferencesStore {
    private let defaults: UserDefaults
    private let key = "ring.preferences.v1"
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
        switch self { case .normal: return "正常"; case .yellow: return "黄色提醒"; case .orange: return "橙色提醒"; case .red: return "红色提醒" }
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
        case .loading: return "加载中"
        case .available: return metric.shortTitle
        case .stale, .expired: return "过期"
        case .connection: return "离线"
        case .timeout: return "超时"
        case .unavailable: return display.source == .disconnected ? "暂停" : "未知"
        case .protocolError: return "不可用"
        case .missingCLI: return "未连接"
        }
    }
    public var accessibilityText: String {
        return "CodexRing \(metric.title)，\(text)，\(clockwise ? "顺时针":"逆时针")，\(display.subtitle)，\(band?.accessibleName ?? "额度未知")。点击打开设置。"
    }
}
