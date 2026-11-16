import XCTest
@testable import QuotaCore
final class AppServerClientTests: XCTestCase {
    private func withServer(_ script: String, _ body: (URL) -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fake-server.py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        body(file)
    }
    func testOnlyOfficialReadHandshakeAndAllowlistedOutput() throws {
        try withServer("""
        import json, sys, time, os
        first = json.loads(sys.stdin.readline())
        assert first['method'] == 'initialize'
        assert 'OPENAI_API_KEY' not in os.environ
        assert 'QUOTA_RING_TEST_SECRET' not in os.environ
        print(json.dumps({'id': 1, 'result': {}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'
        read = json.loads(sys.stdin.readline())
        assert read['method'] == 'account/rateLimits/read'
        print(json.dumps({'method':'fake/notification','params':{'ignored':'private-test-value'}}), flush=True)
        print(json.dumps({'id': 2, 'result': {'rateLimitsByLimitId': {'codex': {'secondary': {'usedPercent': 31, 'windowDurationMins':10080, 'resetsAt':time.time()+86400}}}, 'ignored':'private-test-value'}}), flush=True)
        sys.stdin.read()
        """) { path in
            setenv("QUOTA_RING_TEST_SECRET", "synthetic-test-only", 1)
            defer { unsetenv("QUOTA_RING_TEST_SECRET") }
            let s = AppServerClient().fetch(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 5)
            XCTAssertNil(s.failure); XCTAssertEqual(s.display().remaining, 69)
            XCTAssertFalse(String(reflecting: s).contains("private-test-value"))
        }
    }
    func testAccountPlanUsesOnlyReadAndDoesNotRetainEmailOrRefreshTokens() throws {
        try withServer("""
        import json, sys, os
        assert json.loads(sys.stdin.readline())['method'] == 'initialize'
        assert 'OPENAI_API_KEY' not in os.environ
        print(json.dumps({'id':1,'result':{}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'
        request = json.loads(sys.stdin.readline())
        assert request['method'] == 'account/read'
        assert request['params']['refreshToken'] == False
        print(json.dumps({'id':2,'result':{'account':{'type':'chatgpt','planType':'prolite','email':'private-test-value','token':'private-test-value'}}}),flush=True)
        sys.stdin.read()
        """) { path in
            let plan=AppServerClient().fetchAccountPlan(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:[path.path],timeout:5)
            XCTAssertEqual(plan,.prolite);XCTAssertEqual(plan?.expectedAPICredits,100)
            XCTAssertFalse(String(reflecting:plan).contains("private-test-value"))
        }
    }
    func testAccountInfoReadReturnsDisplayFieldsWithoutAuthenticationMaterial() throws {
        try withServer("""
        import json, sys
        assert json.loads(sys.stdin.readline())['method'] == 'initialize'
        print(json.dumps({'id':1,'result':{}}),flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'
        read=json.loads(sys.stdin.readline())
        assert read['method'] == 'account/read' and read['params']['refreshToken'] == False
        print(json.dumps({'id':2,'result':{'account':{'type':'chatgpt','email':'user@example.com','planType':'prolite','accessToken':'secret-test-token'}}}),flush=True)
        sys.stdin.read()
        """) { path in
            let info=AppServerClient().fetchAccountInfo(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:[path.path],timeout:5)
            XCTAssertEqual(info?.email,"user@example.com");XCTAssertEqual(info?.plan,.prolite)
            XCTAssertFalse(String(reflecting:info).contains("secret-test-token"))
        }
    }
    func testAccountPlanUnavailableDoesNotFallBackToPreviouslyKnownTier() throws {
        try withServer("""
        import sys, json
        sys.stdin.readline()
        print(json.dumps({'id':1,'error':{'code':401,'message':'private-test-value'}}),flush=True)
        sys.stdin.read()
        """) { path in
            let plan=AppServerClient().fetchAccountPlan(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:[path.path],timeout:5)
            XCTAssertNil(plan)
        }
    }
    func testMalformedResponseIsSanitized() throws {
        try withServer("""
        import sys
        sys.stdin.readline()
        print('private-test-value-not-json', flush=True)
        sys.stdin.read()
        """) { path in
            let s = AppServerClient().fetch(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 5)
            XCTAssertEqual(s.failure, .protocolError); XCTAssertTrue(s.quotas.isEmpty)
        }
    }
    func testServerErrorDoesNotExposeRawError() throws {
        try withServer("""
        import sys, json
        sys.stdin.readline()
        print(json.dumps({'id':1,'error':{'code':401,'message':'private-test-value'}}), flush=True)
        sys.stdin.read()
        """) { path in
            let s = AppServerClient().fetch(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 5)
            XCTAssertEqual(s.failure, .unavailable); XCTAssertFalse(String(reflecting: s).contains("private-test-value"))
        }
    }
    func testExternalCredentialRequestIsNeverAnswered() throws {
        try withServer("""
        import sys, json
        sys.stdin.readline()
        print(json.dumps({'id':'external','method':'account/chatgptAuthTokens/refresh','params':{}}), flush=True)
        assert sys.stdin.read() == ''
        """) { path in
            let s = AppServerClient().fetch(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 5)
            XCTAssertEqual(s.failure, .unavailable)
        }
    }
    func testTimeoutTerminatesUnresponsiveRequest() throws {
        try withServer("import time; time.sleep(30)\n") { path in
            let began = Date()
            let s = AppServerClient().fetch(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 0.15)
            XCTAssertEqual(s.failure, .timeout); XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        }
    }
}
