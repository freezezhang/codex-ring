import AppKit
import XCTest
@testable import QuotaRing

final class CodexApplicationRegistryTests:XCTestCase {
    func testRepeatedPollingDoesNotRediscoverApplications() {
        var lookups=0
        let current=NSRunningApplication.current
        let registry=CodexApplicationRegistry(center:NotificationCenter(),resolve:{
            lookups += 1;return [current]
        })
        registry.start();registry.start()
        for _ in 0..<1000 {
            XCTAssertTrue(registry.applications.first === current)
        }
        XCTAssertEqual(lookups,1)
    }
    func testLaunchAndExitImmediatelyUpdateCacheWithoutDuplicateChanges() {
        let center=NotificationCenter()
        var running:[NSRunningApplication]=[]
        var changes=0
        let registry=CodexApplicationRegistry(center:center,resolve:{running})
        registry.onChange={changes += 1}
        registry.start()
        XCTAssertTrue(registry.applications.isEmpty)
        running=[.current]
        center.post(name:NSWorkspace.didLaunchApplicationNotification,object:nil)
        XCTAssertEqual(registry.applications.count,1);XCTAssertEqual(changes,1)
        // Launch/exit of unrelated apps must not invalidate a working match.
        center.post(name:NSWorkspace.didLaunchApplicationNotification,object:nil)
        center.post(name:NSWorkspace.didTerminateApplicationNotification,object:nil)
        XCTAssertEqual(changes,1)
        running=[]
        center.post(name:NSWorkspace.didTerminateApplicationNotification,object:nil)
        XCTAssertTrue(registry.applications.isEmpty);XCTAssertEqual(changes,2)
    }
    func testStopUnsubscribesAndRestartTakesFreshSnapshot() {
        let center=NotificationCenter()
        var lookups=0
        var running:[NSRunningApplication]=[.current]
        let registry=CodexApplicationRegistry(center:center,resolve:{lookups += 1;return running})
        registry.start();registry.stop()
        XCTAssertTrue(registry.applications.isEmpty)
        running=[]
        center.post(name:NSWorkspace.didTerminateApplicationNotification,object:nil)
        XCTAssertEqual(lookups,1)
        registry.start()
        XCTAssertEqual(lookups,2);XCTAssertTrue(registry.applications.isEmpty)
        running=[.current]
        center.post(name:NSWorkspace.didLaunchApplicationNotification,object:nil)
        XCTAssertEqual(lookups,3);XCTAssertEqual(registry.applications.count,1)
    }
    func testObserversDoNotRetainRegistry() {
        let center=NotificationCenter()
        weak var released:CodexApplicationRegistry?
        autoreleasepool {
            let registry=CodexApplicationRegistry(center:center,resolve:{[]})
            released=registry;registry.start()
        }
        XCTAssertNil(released)
        center.post(name:NSWorkspace.didLaunchApplicationNotification,object:nil)
    }
}
