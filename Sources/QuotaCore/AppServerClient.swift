import Foundation

// Only the documented stdio handshake and rate-limit read are implemented.
// No credential parsing, OAuth flow, HTTP endpoint, account mutation or raw logging.
public final class AppServerClient {
    private let lock = NSLock()
    private var active: StdioSession?
    public init() {}
    public func cancel() { lock.lock(); let session = active; active = nil; lock.unlock(); session?.cancel() }
    public func fetch(executable: URL? = nil, arguments: [String]? = nil, timeout: TimeInterval = 18) -> QuotaSnapshot {
        let path = executable ?? ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }).map { URL(fileURLWithPath: $0) }
        guard let path else { return QuotaSnapshot(source: .official, fetchedAt: Date(), failure: .missingCLI) }
        let session = StdioSession(executable: path, arguments: arguments ?? ["app-server", "--stdio"])
        lock.lock(); active = session; lock.unlock()
        let result = session.run(timeout: timeout)
        lock.lock(); if active === session { active = nil }; lock.unlock()
        return result
    }
}

private final class StdioSession {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result: QuotaSnapshot?
    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Do not forward API keys or other secret-valued environment variables.
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
    }
    func finish(_ snapshot: QuotaSnapshot) {
        lock.lock(); let first = result == nil
        if first { result = snapshot }; lock.unlock()
        if first { done.signal() }
    }
    func fail(_ failure: QuotaFailure) { finish(QuotaSnapshot(source: .official, fetchedAt: Date(), failure: failure)) }
    func cancel() { fail(.unavailable); if process.isRunning { process.terminate() } }
    func send(_ object: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: object); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }
    func receive(_ object: [String: Any]) throws {
        // A request to provide external tokens is unsupported. Never answer it.
        if object["method"] as? String == "account/chatgptAuthTokens/refresh" { fail(.unavailable); return }
        guard let id = object["id"] as? Int else { return }
        if object["error"] != nil { fail(.unavailable); return }
        if id == 1, object["result"] != nil {
            try send(["method": "initialized", "params": [:]])
            try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
        } else if id == 2, let payload = object["result"] as? [String: Any] {
            finish(QuotaParser.parse(payload))
        }
    }
    func run(timeout: TimeInterval) -> QuotaSnapshot {
        lock.lock(); let alreadyCancelled = result; lock.unlock()
        if let alreadyCancelled { return alreadyCancelled }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        do {
            try process.run()
            try? output.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_quota_ring", "title": "CodexRing", "version": "0.1.0"]]])
        } catch { fail(.connection) }
        if process.isRunning {
            DispatchQueue.global(qos: .utility).async { [self] in
                var buffer = Data()
                defer { try? output.fileHandleForReading.close() }
                do {
                    while true {
                        let chunk = output.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        buffer.append(chunk)
                        guard buffer.count < 4 * 1024 * 1024 else { fail(.protocolError); return }
                        while let end = buffer.firstIndex(of: 10) {
                            let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                            guard !line.isEmpty else { continue }
                            guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { fail(.protocolError); return }
                            try receive(obj)
                            lock.lock(); let finished = result != nil; lock.unlock()
                            if finished { return }
                        }
                    }
                    fail(.connection)
                } catch { fail(.protocolError) }
            }
        } else { fail(.connection); try? output.fileHandleForReading.close() }
        if done.wait(timeout: .now() + timeout) == .timedOut { fail(.timeout) }
        lock.lock(); let final = result ?? QuotaSnapshot(source: .official, fetchedAt: Date(), failure: .timeout); lock.unlock()
        return final
    }
}
