import AppKit
import Foundation

enum CodexExecutableLocator {
    /// Prefer the desktop client's bundled native executable. Installing the
    /// desktop app does not create a CLI in Homebrew's or npm's bin directory.
    static func resolve(applicationURLs: [URL]? = nil, cliDirectories: [URL]? = nil) -> URL? {
        let applications = applicationURLs ?? installedApplications()
        let bundledPaths = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex-cli/bin/codex",
            "Contents/Resources/codex"
        ]
        let bundled = applications.flatMap { app in bundledPaths.map { app.appendingPathComponent($0) } }
        let directories = cliDirectories ?? standaloneDirectories()
        let candidates = bundled + directories.map { $0.appendingPathComponent("codex") }
        return candidates.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
        }
    }

    private static func installedApplications() -> [URL] {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .compactMap(\.bundleURL)
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        let roots = [URL(fileURLWithPath: "/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let conventional = roots.flatMap { root in
            ["Codex.app", "ChatGPT.app"].map { root.appendingPathComponent($0) }
        }
        // Running/registered apps also cover renamed or custom installations.
        return running + (registered.map { [$0] } ?? []) + conventional
    }

    private static func standaloneDirectories() -> [URL] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = ["/usr/local/bin", "/opt/homebrew/bin"] + path.split(separator: ":").map(String.init)
        // Never search relative PATH entries or the current working directory.
        return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
    }
}
