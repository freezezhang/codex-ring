import XCTest
import CoreGraphics
@testable import QuotaCore
final class PreferencesTests: XCTestCase {
    func presentation(used: Double, metric: DisplayMetric) -> RingPresentation {
        let s = QuotaSnapshot(source: .official, fetchedAt: Date(), quotas: [WeeklyQuota(id: "codex/primary", label: "codex", remaining: 100 - used, resetsAt: Date().addingTimeInterval(3600))])
        return RingPresentation(display: s.display(), metric: metric)
    }
    func testThresholdBoundariesInBothMetrics() {
        let cases: [(Double, UsageBand)] = [(0,.normal),(69.99,.normal),(70,.yellow),(79.99,.yellow),(80,.orange),(89.99,.orange),(90,.red),(100,.red)]
        for (used, band) in cases {
            for metric in DisplayMetric.allCases { XCTAssertEqual(presentation(used: used, metric: metric).band, band, "used=\(used), metric=\(metric)") }
        }
    }
    func testMetricSwitchChangesNumberButNotColor() {
        let remaining = presentation(used: 81, metric: .remaining)
        let used = presentation(used: 81, metric: .used)
        XCTAssertEqual(remaining.text, "19%"); XCTAssertEqual(used.text, "81%")
        XCTAssertEqual(remaining.band, used.band); XCTAssertEqual(used.band, .orange)
        XCTAssertEqual(remaining.caption, "剩余"); XCTAssertEqual(used.caption, "已用")
    }
    func testUnknownAndNetworkNeverBecomeUsedOneHundred() {
        for failure: QuotaFailure? in [nil, .connection, .timeout] {
            let s = QuotaSnapshot(source: .official, fetchedAt: Date(), failure: failure)
            for metric in DisplayMetric.allCases {
                let p = RingPresentation(display: s.display(), metric: metric)
                XCTAssertNil(p.value); XCTAssertNil(p.band); XCTAssertEqual(p.text, "—")
            }
        }
    }
    func testStaleAndResetExpiredDoNotHaveThresholdColor() {
        let q = WeeklyQuota(id: "codex", label: "codex", remaining: 2, resetsAt: Date().addingTimeInterval(-1))
        for date in [Date(), Date().addingTimeInterval(-301)] {
            let p = RingPresentation(display: QuotaSnapshot(source:.official, fetchedAt:date, quotas:[q]).display(), metric:.used)
            XCTAssertEqual(p.caption,"过期"); XCTAssertNil(p.band); XCTAssertNil(p.value)
        }
    }
    func testNonSensitivePreferencesPersistAcrossStoreInstances() throws {
        let name = "local.freeze.quota-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        var preferences = RingPreferences(); preferences.metric = .used; preferences.size = .small
        preferences.autoHide = false; preferences.animations = false; preferences.positionLocked=true; preferences.bucketID = "codex/primary";preferences.theme = .dark
        preferences.followCodex=true;preferences.overlayCodexUsage=true;preferences.codexAnchor=PanelPosition(x:0.4,y:0.8)
        preferences.position = PanelPosition(x: -400, y: 260)
        PreferencesStore(defaults:defaults).save(preferences)
        XCTAssertEqual(PreferencesStore(defaults:try XCTUnwrap(UserDefaults(suiteName:name))).load(), preferences)
    }
    func testDefaultsAndCorruptSettingsRecoverSafely() throws {
        let name = "local.freeze.quota-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName:name)); defer { defaults.removePersistentDomain(forName:name) }
        XCTAssertEqual(PreferencesStore(defaults:defaults).load().size, .compact)
        defaults.set(Data("invalid".utf8),forKey:"ring.preferences.v1")
        XCTAssertEqual(PreferencesStore(defaults:defaults).load(), RingPreferences())
    }
    func testPreferencesDoNotContainConnectionOrCredentials() throws {
        let data = try JSONEncoder().encode(RingPreferences())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(Set(json.keys), Set(["metric","size","autoHide","animations","positionLocked","followCodex","overlayCodexUsage","showMenuBar","showWeek","showFiveHours","centerPeriod","refreshInterval","theme"]))
    }
    func testSmallSizesRemainRecoverableAtEveryEdge() {
        let screen = CGRect(x: 2560, y: 100, width: 1920, height: 980)
        for size in RingSize.allCases {
            let frame = CGRect(x:3000,y:500,width:size.rawValue,height:size.rawValue)
            for edge in DockEdge.allCases {
                let hidden = Docking.hidden(frame,edge:edge,screen:screen)
                XCTAssertTrue(screen.contains(hidden))
                XCTAssertEqual(min(hidden.width,hidden.height),Docking.handle(for:CGFloat(size.rawValue)))
                XCTAssertTrue(screen.contains(Docking.revealed(frame,edge:edge,screen:screen)))
            }
        }
    }
    func testLoadingNeverShowsFabricatedPercentageOrBand() {
        let s=QuotaSnapshot(source:.official,fetchedAt:Date(),loading:true)
        for metric in DisplayMetric.allCases {
            let p=RingPresentation(display:s.display(),metric:metric)
            XCTAssertEqual(p.text,"—");XCTAssertEqual(p.caption,"加载中");XCTAssertNil(p.value);XCTAssertNil(p.band)
        }
    }
    func testAvatarAndSmallUseOnlyDynamicNumber() {
        for size in [RingSize.avatar,.tiny] {
            XCTAssertTrue(size.numberOnly)
            XCTAssertEqual(presentation(used:32,metric:.used).compactText,"32")
            XCTAssertEqual(presentation(used:32,metric:.remaining).compactText,"68")
            for (used,expected) in [(0.0,"0"),(70.0,"70"),(100.0,"100")] {
                let p=presentation(used:used,metric:.used)
                XCTAssertEqual(p.compactText,expected);XCTAssertFalse(p.compactText.contains("%"))
            }
        }
        XCTAssertFalse(RingSize.small.numberOnly)
    }
    func testCompactUnknownAndLoadingRemainExplicitlyUnknown() {
        for s in [QuotaSnapshot(source:.official,fetchedAt:Date(),failure:.connection),QuotaSnapshot(source:.official,fetchedAt:Date(),loading:true)] {
            for metric in DisplayMetric.allCases {
                let p=RingPresentation(display:s.display(),metric:metric)
                XCTAssertEqual(p.compactText,"—");XCTAssertNil(p.value);XCTAssertNil(p.band)
            }
        }
    }
    func testAvatarSizePersistsWithoutChangingExistingSizeValues() throws {
        XCTAssertEqual(RingSize.small.rawValue,56)
        let name="local.freeze.quota-tests.\(UUID().uuidString)"
        let defaults=try XCTUnwrap(UserDefaults(suiteName:name));defer { defaults.removePersistentDomain(forName:name) }
        var p=RingPreferences();p.size = .avatar;p.metric = .used
        PreferencesStore(defaults:defaults).save(p)
        XCTAssertEqual(PreferencesStore(defaults:defaults).load().size,.avatar)
        XCTAssertEqual(PreferencesStore(defaults:defaults).load().metric,.used)
    }
    func testDirectionAndArcAtZeroFullAndModeSwitch() {
        for used in [0.0,32,70,100] {
            let u=presentation(used:used,metric:.used),r=presentation(used:used,metric:.remaining)
            XCTAssertTrue(u.clockwise);XCTAssertFalse(r.clockwise)
            XCTAssertEqual(u.arcEndAngle!,90-used*3.6,accuracy:0.0001)
            XCTAssertEqual(r.arcEndAngle!,90+(100-used)*3.6,accuracy:0.0001)
            XCTAssertEqual(u.band,r.band)
        }
    }
    func testPositionLockOnlyPreventsUserMovement() {
        let initial=CGPoint(x:400,y:300),start=CGPoint(x:420,y:320),end=CGPoint(x:1000,y:800)
        XCTAssertEqual(DragMotion.origin(initial:initial,start:start,current:end,locked:true),initial)
        XCTAssertEqual(DragMotion.origin(initial:initial,start:start,current:end,locked:false),CGPoint(x:980,y:780))
        let screen=CGRect(x:0,y:0,width:1000,height:800)
        let full=CGRect(x:0,y:300,width:26,height:26)
        let hidden=Docking.hidden(full,edge:.left,screen:screen)
        XCTAssertEqual(hidden.width,8)
        let revealed=Docking.revealed(full,edge:.left,screen:screen)
        XCTAssertEqual(revealed.width,26);XCTAssertTrue(screen.contains(revealed))
    }
    func testExistingSettingsMigrateWithLockOff() throws {
        let data=Data("{\"metric\":\"used\",\"size\":56,\"autoHide\":false,\"animations\":false}".utf8)
        let p=try JSONDecoder().decode(RingPreferences.self,from:data)
        XCTAssertEqual(p.metric,.used);XCTAssertEqual(p.size,.small);XCTAssertFalse(p.positionLocked);XCTAssertFalse(p.autoHide)
        XCTAssertEqual(p.theme,.system)
        XCTAssertFalse(p.overlayCodexUsage)
    }
    func testThemeFollowsSystemOrExplicitOverride() {
        XCTAssertFalse(ThemePreference.system.isDark(systemIsDark:false))
        XCTAssertTrue(ThemePreference.system.isDark(systemIsDark:true))
        for system in [false,true] {
            XCTAssertFalse(ThemePreference.light.isDark(systemIsDark:system))
            XCTAssertTrue(ThemePreference.dark.isDark(systemIsDark:system))
        }
    }
    func testEachThemePersistsAndUnknownThemeMigratesSafely() throws {
        let name="local.freeze.quota-tests.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        for theme in ThemePreference.allCases {
            var p=RingPreferences();p.theme=theme;p.size = .avatar;p.positionLocked=true
            PreferencesStore(defaults:defaults).save(p)
            XCTAssertEqual(PreferencesStore(defaults:try XCTUnwrap(UserDefaults(suiteName:name))).load(),p)
        }
        let p=try JSONDecoder().decode(RingPreferences.self,from:Data("{\"theme\":\"invalid\",\"size\":26}".utf8))
        XCTAssertEqual(p.theme,.system);XCTAssertEqual(p.size,.avatar)
    }
}
