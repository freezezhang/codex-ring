import XCTest
@testable import QuotaCore

final class UsageSearchBackoffTests:XCTestCase {
    func testRepeatedFailuresBackOffAndCapAtFifteenSeconds() {
        var backoff=UsageSearchBackoff()
        var now:TimeInterval=100
        XCTAssertTrue(backoff.allowsSearch(at:now))
        for delay:TimeInterval in [1,2,4,8,15,15,15] {
            backoff.failed(at:now)
            XCTAssertFalse(backoff.allowsSearch(at:now+delay-0.01))
            now += delay
            XCTAssertTrue(backoff.allowsSearch(at:now))
        }
    }
    func testFreshWindowOrSuccessfulMatchCanResetRetryState() {
        var backoff=UsageSearchBackoff()
        backoff.failed(at:100)
        backoff.failed(at:101)
        XCTAssertFalse(backoff.allowsSearch(at:101))
        backoff=UsageSearchBackoff()
        XCTAssertTrue(backoff.allowsSearch(at:101))
        backoff.failed(at:101)
        XCTAssertTrue(backoff.allowsSearch(at:102))
    }
}
