import Foundation

// Only the documented stdio handshake, rate-limit read and account read are implemented.
// No credential parsing, OAuth flow, HTTP endpoint, account mutation or raw logging.
public final class AppServerClient {
    private let lock = NSLock()
    private var active: StdioSession?
    private let resolveExecutable: () -> URL?
    public convenience init() { self.init(resolveExecutable: { CodexExecutableLocator.resolve() }) }
    init(resolveExecutable: @escaping () -> URL?) { self.resolveExecutable = resolveExecutable }
    public func cancel() { lock.lock(); let session = active; active = nil; lock.unlock(); session?.cancel() }
    public func fetch(executable: URL? = nil, arguments: [String]? = nil, timeout: TimeInterval = 18) -> QuotaSnapshot {
        run(executable:executable,arguments:arguments,timeout:timeout,accountOnly:false).0
    }
    public func fetchAccountPlan(executable:URL?=nil,arguments:[String]?=nil,timeout:TimeInterval=12)->CodexAccountPlan? {
        fetchAccountInfo(executable:executable,arguments:arguments,timeout:timeout)?.plan
    }
    public func fetchAccountInfo(executable:URL?=nil,arguments:[String]?=nil,timeout:TimeInterval=12)->CodexAccountInfo? {
        run(executable:executable,arguments:arguments,timeout:timeout,accountOnly:true).1
    }
    private func run(executable:URL?,arguments:[String]?,timeout:TimeInterval,accountOnly:Bool)->(QuotaSnapshot,CodexAccountInfo?) {
        let path = executable ?? resolveExecutable()
        guard let path else { return (QuotaSnapshot(source: .official, fetchedAt: Date(), failure: .missingCLI),nil) }
        // Stdio is the documented default, including versions without --stdio.
        let session = StdioSession(executable: path, arguments: arguments ?? ["app-server"],accountOnly:accountOnly)
        lock.lock(); active = session; lock.unlock()
        let result = session.run(timeout: timeout)
        lock.lock(); if active === session { active = nil }; lock.unlock()
        return (result,result.failure == nil ? session.accountInfo:nil)
    }
}

private final class StdioSession {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result: QuotaSnapshot?
    private(set) var accountInfo:CodexAccountInfo?
    let accountOnly:Bool
    init(executable: URL, arguments: [String],accountOnly:Bool=false) {
        self.accountOnly=accountOnly
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
            if accountOnly { try send(["id":2,"method":"account/read","params":["refreshToken":false]]) }
            else { try send(["id": 2, "method": "account/rateLimits/read", "params": [:]]) }
        } else if id == 2, let payload = object["result"] as? [String: Any] {
            if accountOnly {
                accountInfo=CodexAccountInfo.parse(payload)
                finish(QuotaSnapshot(source:.official,fetchedAt:Date()))
            } else { finish(QuotaParser.parse(payload)) }
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
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            let params:[String:Any] = ["clientInfo": ["name": "codex_quota_ring", "title": "CodexRing", "version": version]]
            try send(["id": 1, "method": "initialize", "params": params])
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
