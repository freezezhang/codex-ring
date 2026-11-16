import XCTest
@testable import QuotaCore

final class CodexExecutableLocatorTests: XCTestCase {
    private func withInstallation(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func install(_ root: URL, _ path: String, script: String = "#!/bin/sh\nexit 0\n", executable: Bool = true) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
        return file
    }

    func testDesktopOnlyInstallationCanReadQuotaWithoutCLIOrNode() throws {
        try withInstallation { root in
            let app = root.appendingPathComponent("Custom Location/Renamed Codex.app")
            let executable = try install(app, "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", script: """
            #!/usr/bin/python3
            import json, sys, time
            assert sys.argv[1:] == ['app-server']
            assert json.loads(sys.stdin.readline())['method'] == 'initialize'
            print(json.dumps({'id': 1, 'result': {}}), flush=True)
            assert json.loads(sys.stdin.readline())['method'] == 'initialized'
            assert json.loads(sys.stdin.readline())['method'] == 'account/rateLimits/read'
            print(json.dumps({'id': 2, 'result': {'rateLimits': {'secondary': {'usedPercent': 31, 'windowDurationMins': 10080, 'resetsAt': time.time()+86400}}}}), flush=True)
            sys.stdin.read()

            """)
            let client = AppServerClient(resolveExecutable: {
                CodexExecutableLocator.resolve(applicationURLs: [app], cliDirectories: [])
            })
            XCTAssertEqual(CodexExecutableLocator.resolve(applicationURLs: [app], cliDirectories: []), executable)
            let snapshot = client.fetch(timeout: 5)
            XCTAssertNil(snapshot.failure)
            XCTAssertEqual(snapshot.display().remaining, 69)
        }
    }

    func testOlderDesktopLayoutsAndUserApplicationsWork() throws {
        for path in ["Contents/Resources/codex", "Contents/Resources/codex-cli/bin/codex"] {
            try withInstallation { root in
                let app = root.appendingPathComponent("Applications/Codex.app")
                let executable = try install(app, path)
                XCTAssertEqual(CodexExecutableLocator.resolve(applicationURLs: [app], cliDirectories: []), executable)
            }
        }
    }

    func testBundledNativeBinaryWinsOverStandaloneWrapper() throws {
        try withInstallation { root in
            let app = root.appendingPathComponent("ChatGPT.app")
            let native = try install(app, "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
            _ = try install(app, "Contents/Resources/codex-cli/bin/codex")
            _ = try install(root, "bin/codex")
            XCTAssertEqual(CodexExecutableLocator.resolve(applicationURLs: [app], cliDirectories: [root.appendingPathComponent("bin")]), native)
        }
    }

    func testStandaloneFallbackSkipsMissingNonExecutableAndDirectoryCandidates() throws {
        try withInstallation { root in
            let app = root.appendingPathComponent("Codex.app")
            _ = try install(app, "Contents/Resources/codex", executable: false)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("bad-bin/codex"), withIntermediateDirectories: true)
            let cli = try install(root, "homebrew/bin/codex")
            let directories = ["missing", "bad-bin", "homebrew/bin"].map { root.appendingPathComponent($0) }
            XCTAssertEqual(CodexExecutableLocator.resolve(applicationURLs: [app], cliDirectories: directories), cli)
        }
    }

    func testMissingInstallationHasExplicitFailure() {
        let client = AppServerClient(resolveExecutable: {
            CodexExecutableLocator.resolve(applicationURLs: [], cliDirectories: [])
        })
        XCTAssertEqual(client.fetch().failure, .missingCLI)
        XCTAssertNil(client.fetchAccountInfo())
    }
}
