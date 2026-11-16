import XCTest
@testable import QuotaCore

final class AuthorizationHistoryTests:XCTestCase {
    func testUpdateWarningNeedsPreviouslyAuthorizedFingerprintAndCurrentDenial() throws {
        let suite="local.freeze.authorization-tests.\(UUID().uuidString)"
        let defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let store=PreferencesStore(defaults:defaults)
        XCTAssertFalse(store.observeAccessibilityTrust(false,fingerprint:"build-A"))
        XCTAssertFalse(store.observeAccessibilityTrust(true,fingerprint:"build-A"))
        XCTAssertFalse(store.observeAccessibilityTrust(false,fingerprint:"build-A"))
        let reopened=PreferencesStore(defaults:defaults)
        XCTAssertTrue(reopened.observeAccessibilityTrust(false,fingerprint:"build-B"))
        XCTAssertTrue(reopened.observeAccessibilityTrust(false,fingerprint:"build-B"))
        XCTAssertFalse(reopened.observeAccessibilityTrust(true,fingerprint:"build-B"))
        XCTAssertFalse(reopened.observeAccessibilityTrust(false,fingerprint:"build-B"))
    }
    func testUnknownSignatureDoesNotInventOrEraseAuthorizationHistory() throws {
        let suite="local.freeze.authorization-tests.\(UUID().uuidString)"
        let defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let store=PreferencesStore(defaults:defaults)
        XCTAssertFalse(store.observeAccessibilityTrust(true,fingerprint:nil))
        XCTAssertFalse(store.observeAccessibilityTrust(false,fingerprint:"build-A"))
        XCTAssertFalse(store.observeAccessibilityTrust(true,fingerprint:"build-A"))
        XCTAssertFalse(store.observeAccessibilityTrust(false,fingerprint:nil))
        XCTAssertFalse(store.observeAccessibilityTrust(true,fingerprint:""))
        XCTAssertTrue(store.observeAccessibilityTrust(false,fingerprint:"build-B"))
    }
}
