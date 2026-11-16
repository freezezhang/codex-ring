import XCTest
@testable import QuotaCore

final class CodexAccessibilityActivationTests:XCTestCase {
    func testChromiumOnlyBuildUsesEnhancedInterfaceWithoutElectronAttribute() {
        var activation=CodexAccessibilityActivation()
        var enabled=false,requests:[String]=[]
        for time in [0.0,0.2,1,5,10] {
            _=activation.prepare(processID:1,now:time,isEnabled:{ name in
                name == "AXEnhancedUserInterface" ? enabled:nil
            },enable:{ name in
                requests.append(name)
                guard name == "AXEnhancedUserInterface" else { XCTFail("Chromium has no Electron flag");return false }
                enabled=true;return true
            })
            XCTAssertTrue(enabled)
        }
        XCTAssertEqual(requests,["AXEnhancedUserInterface"])
    }
    func testElectronFallbackWhenChromiumAttributeIsUnsupported() {
        var activation=CodexAccessibilityActivation()
        var requests:[String]=[]
        let result=activation.prepare(processID:1,now:0,isEnabled:{_ in false},enable:{ name in
            requests.append(name);return name == "AXManualAccessibility"
        })
        XCTAssertEqual(result,.enabled("AXManualAccessibility"))
        XCTAssertEqual(requests,["AXEnhancedUserInterface","AXManualAccessibility"])
    }
    func testExistingAccessibilityClientIsLeftEnabled() {
        var activation=CodexAccessibilityActivation()
        let result=activation.prepare(processID:1,now:0,isEnabled:{$0 == "AXManualAccessibility"},
                                      enable:{_ in XCTFail("Already enabled");return false})
        XCTAssertEqual(result,.alreadyEnabled("AXManualAccessibility"))
    }
    func testUnavailableRendererRetriesAfterBackoffAndNewProcessDoesNotWait() {
        var activation=CodexAccessibilityActivation()
        var requests:[Int32]=[]
        func attempt(_ pid:Int32,_ time:TimeInterval)->CodexAccessibilityActivation.Result? {
            activation.prepare(processID:pid,now:time,isEnabled:{_ in nil},enable:{_ in requests.append(pid);return false})
        }
        XCTAssertEqual(attempt(1,0),.unavailable)
        XCTAssertNil(attempt(1,0.2));XCTAssertNil(attempt(1,4.9))
        XCTAssertEqual(requests,[1,1])
        XCTAssertEqual(attempt(2,4.9),.unavailable);XCTAssertEqual(attempt(1,5),.unavailable)
        XCTAssertEqual(requests,[1,1,2,2,1,1])
    }
    func testRendererDisablingAccessibilityIsRecovered() {
        var activation=CodexAccessibilityActivation()
        var enabled=true
        _=activation.prepare(processID:1,now:0,isEnabled:{_ in enabled},enable:{_ in enabled=true;return true})
        enabled=false
        _=activation.prepare(processID:1,now:5,isEnabled:{_ in enabled},enable:{_ in enabled=true;return true})
        XCTAssertTrue(enabled)
    }
    func testDelayedRendererActivationIsRecognizedEvenWhenSetterReportsFailure() {
        var activation=CodexAccessibilityActivation()
        var enabled=false,requests=0
        let first=activation.prepare(processID:1,now:0,isEnabled:{_ in false},enable:{_ in
            requests += 1;return false
        })
        XCTAssertEqual(first,.unavailable)
        enabled=true
        let next=activation.prepare(processID:1,now:5,isEnabled:{ name in
            name == "AXEnhancedUserInterface" ? enabled:nil
        },enable:{_ in requests += 1;return false})
        XCTAssertEqual(next,.alreadyEnabled("AXEnhancedUserInterface"))
        XCTAssertEqual(requests,2)
    }
}
