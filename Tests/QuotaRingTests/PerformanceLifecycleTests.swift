import AppKit
import Combine
import XCTest
import QuotaCore
@testable import QuotaRing

private final class TestKeyStore:APIKeyStorage {
    var value:String?
    var readCount=0
    var beforeRead:(()->Void)?
    var beforeSave:(()->Void)?
    var beforeRemove:(()->Void)?
    func read()throws->String? {
        XCTAssertFalse(Thread.isMainThread)
        readCount += 1;beforeRead?();return value
    }
    func save(_ key:String)throws {
        XCTAssertFalse(Thread.isMainThread)
        beforeSave?();value=key
    }
    func remove()throws {
        XCTAssertFalse(Thread.isMainThread)
        beforeRemove?();value=nil
    }
}

final class PerformanceLifecycleTests:XCTestCase {
    private var defaults:UserDefaults!
    private var suite:String!
    override func setUp() {
        super.setUp()
        suite="CodexRing.PerformanceTests."+UUID().uuidString
        defaults=UserDefaults(suiteName:suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName:suite)
        defaults=nil;super.tearDown()
    }
    private func controller(_ store:TestKeyStore,enabled:Bool=false)->OpenAIUsageController {
        var config=OpenAIUsageConfiguration();config.enabled=enabled
        defaults.set(try! JSONEncoder().encode(config),forKey:"openAIUsageConfiguration")
        return OpenAIUsageController(defaults:defaults,keyStore:store,automaticRefresh:false)
    }
    private func pump(until condition:()->Bool,timeout:TimeInterval=3) {
        let deadline=Date().addingTimeInterval(timeout)
        while !condition(),Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition())
    }
    func testBlockedKeychainLeavesMainQueueResponsiveAndCoalescesRefreshes() {
        let store=TestKeyStore(),gate=DispatchSemaphore(value:0)
        let entered=expectation(description:"keychain read started")
        store.beforeRead={ entered.fulfill();_ = gate.wait(timeout:.now()+5) }
        let api=controller(store,enabled:true)
        defer { gate.signal() }
        api.refresh()
        wait(for:[entered],timeout:2)
        XCTAssertTrue(api.refreshing);XCTAssertTrue(api.keychainBusy)
        for _ in 0..<20 { api.refresh() }
        let heartbeat=expectation(description:"main queue remains responsive")
        DispatchQueue.main.async { heartbeat.fulfill() }
        wait(for:[heartbeat],timeout:1)
        gate.signal()
        pump { !api.keychainBusy && !api.refreshing }
        XCTAssertEqual(store.readCount,1)
        XCTAssertEqual(api.status,.configureKey)
    }
    func testDisablingDuringBlockedReadRejectsItsResult() {
        let store=TestKeyStore(),gate=DispatchSemaphore(value:0)
        store.value="synthetic-key"
        let entered=expectation(description:"read entered")
        store.beforeRead={ entered.fulfill();_ = gate.wait(timeout:.now()+5) }
        let api=controller(store,enabled:true)
        defer { gate.signal() }
        api.refresh();wait(for:[entered],timeout:2)
        api.setEnabled(false)
        gate.signal();pump { !api.keychainBusy }
        XCTAssertFalse(api.refreshing);XCTAssertFalse(api.hasConfiguredKey)
        XCTAssertNil(api.snapshot);XCTAssertEqual(store.readCount,1)
    }
    func testOfflineUsageDistinguishesMissingAndConfiguredKeys() {
        for key in [nil,"synthetic-key"] as [String?] {
            let store=TestKeyStore()
            store.value=key
            let api=controller(store,enabled:true)
            api.setNetworkOffline(true)
            pump { !api.keychainBusy && !api.refreshing }
            XCTAssertEqual(api.status,key == nil ? .configureKey:.offline)
            XCTAssertEqual(api.hasConfiguredKey,key != nil)
            XCTAssertNil(api.snapshot)
            XCTAssertNil(api.lastSuccessfulRefresh)
            XCTAssertEqual(store.readCount,1)
            if key != nil {
                api.refresh()
                XCTAssertFalse(api.keychainBusy)
                XCTAssertEqual(store.readCount,1)
            }
        }
    }
    func testSaveAndDeleteRunOffMainAndPersistOnlyAfterSuccess() {
        let store=TestKeyStore(),gate=DispatchSemaphore(value:0)
        let entered=expectation(description:"save entered")
        store.beforeSave={ entered.fulfill();_ = gate.wait(timeout:.now()+5) }
        let api=controller(store)
        var saved=false
        defer { gate.signal() }
        api.save(key:"synthetic-key",project:"proj_test",budget:"50",startDay:12) { saved=$0 }
        wait(for:[entered],timeout:2)
        XCTAssertTrue(api.keychainBusy);XCTAssertNil(api.configuration.manualBudget)
        api.save(key:"other-key",project:"",budget:"",startDay:1) { XCTAssertFalse($0) }
        gate.signal();pump { saved }
        XCTAssertEqual(api.configuration.manualBudget,50)
        XCTAssertEqual(api.configuration.cycleStartDay,12)
        XCTAssertEqual(api.configuration.projectID,"proj_test")
        XCTAssertTrue(api.hasConfiguredKey)
        api.removeKey();pump { !api.keychainBusy }
        XCTAssertNil(store.value);XCTAssertFalse(api.hasConfiguredKey)
        XCTAssertEqual(api.status,.notConfigured)
    }
    func testReadFailureClearsBusyStateAndAllowsRetry() {
        final class FailingStore:APIKeyStorage {
            struct Failure:Error {}
            func read()throws->String? { XCTAssertFalse(Thread.isMainThread);throw Failure() }
            func save(_ key:String)throws {}
            func remove()throws {}
        }
        var config=OpenAIUsageConfiguration();config.enabled=true
        defaults.set(try! JSONEncoder().encode(config),forKey:"openAIUsageConfiguration")
        let api=OpenAIUsageController(defaults:defaults,keyStore:FailingStore(),automaticRefresh:false)
        for _ in 0..<2 {
            api.refresh();pump { !api.keychainBusy && !api.refreshing }
            XCTAssertEqual(api.status,.keychainUnavailable)
        }
    }
    func testEqualPresentationUpdatesDoNotPublish() {
        let model=SettingsModel(preferences:RingPreferences(),apiUsage:controller(TestKeyStore()))
        var changes=0
        let subscription=model.objectWillChange.sink { changes += 1 }
        let snapshot=model.snapshot
        for _ in 0..<100 {
            model.update(\.snapshot,snapshot)
            model.update(\.isRefreshing,false)
            model.update(\.overlayStatus,"")
            model.update(\.fiveHourSupport,nil)
        }
        XCTAssertEqual(changes,0)
        model.update(\.isRefreshing,true)
        XCTAssertEqual(changes,1)
        withExtendedLifetime(subscription) {}
    }
    func testSettingsReleaseViewsAndKeepDraftsAcrossPageAndWindowChanges() throws {
        #if arch(x86_64)
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
            "Reopening SwiftUI settings stalls on GitHub-hosted Intel runners. Run this window test on a local Intel Mac."
        )
        #endif
        _ = NSApplication.shared
        let model=SettingsModel(preferences:RingPreferences(),apiUsage:controller(TestKeyStore()))
        let settings=RingSettingsWindow(model:model,onClose:{})
        settings.state.apiDraft.key="unsaved-synthetic-key"
        settings.state.apiDraft.project="proj_draft"
        settings.state.apiDraft.budget="123"
        settings.state.apiDraft.startDay=19
        for page in SettingsPage.allCases {
            settings.state.selected=page
            weak var host:NSView?
            autoreleasepool {
                settings.showWindow(nil)
                host=settings.window?.contentView
                XCTAssertNotNil(host)
                settings.window?.contentView?.layoutSubtreeIfNeeded()
                settings.close()
                XCTAssertNil(settings.window?.contentView)
            }
            pump { host == nil }
            XCTAssertEqual(settings.state.selected,page)
            XCTAssertEqual(settings.state.apiDraft.key,"unsaved-synthetic-key")
            XCTAssertEqual(settings.state.apiDraft.project,"proj_draft")
            XCTAssertEqual(settings.state.apiDraft.budget,"123")
            XCTAssertEqual(settings.state.apiDraft.startDay,19)
        }
    }
    func testDebugWindowReleasesItsHostingViewOnClose() {
        _ = NSApplication.shared
        let model=SettingsModel(preferences:RingPreferences(),apiUsage:controller(TestKeyStore()))
        let debug=RingDebugWindow(model:model,onClose:{})
        weak var host:NSView?
        autoreleasepool {
            debug.showWindow(nil)
            host=debug.window?.contentView
            XCTAssertNotNil(host)
            debug.close()
            XCTAssertNil(debug.window?.contentView)
        }
        pump { host == nil }
    }
}
