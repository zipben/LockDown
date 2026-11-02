import Foundation

public enum IPC {
    public static let socketPath = "/var/run/lockdownd.sock"
    public static let version = 1
}

public enum Command: String, Codable {
    case snapshot, saveBlock, deleteBlock, startBlock, stopBlock
    case requestChallenge, solveChallenge, submitPassword
    case takeBreak, endBreak, saveSettings
    case enforcement, reportUsage, reportBlockedApp, canUninstall
}

public struct UsageReport: Codable, Hashable {
    public var bundleID: String
    public var appName: String
    public var title: String?
    public var seconds: Int

    public init(bundleID: String, appName: String, title: String?, seconds: Int) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.seconds = seconds
    }
}

public struct Request: Codable {
    public var cmd: Command
    public var blockID: UUID?
    public var block: Block?
    public var endsAt: Date?
    public var minutes: Int?
    public var text: String?
    public var settings: GlobalSettings?
    public var usage: UsageReport?

    public init(_ cmd: Command, blockID: UUID? = nil, block: Block? = nil, endsAt: Date? = nil,
                minutes: Int? = nil, text: String? = nil, settings: GlobalSettings? = nil, usage: UsageReport? = nil) {
        self.cmd = cmd
        self.blockID = blockID
        self.block = block
        self.endsAt = endsAt
        self.minutes = minutes
        self.text = text
        self.settings = settings
        self.usage = usage
    }
}

public struct BlockStatus: Codable, Hashable, Identifiable {
    public var block: Block
    public var activity: Activity
    public var locked: Bool
    public var lockReason: String
    public var allowanceRemaining: Int?
    public var id: UUID { block.id }

    public init(block: Block, activity: Activity, locked: Bool, lockReason: String, allowanceRemaining: Int?) {
        self.block = block
        self.activity = activity
        self.locked = locked
        self.lockReason = lockReason
        self.allowanceRemaining = allowanceRemaining
    }
}

public struct FilterHealth: Codable, Hashable {
    public var dnsServerRunning = false
    public var systemDNSRedirected = false
    public var firewallLoaded = false
    /// nil = not tested yet; false = a lookup through the system resolver didn't reach LockDown.
    public var systemPathOK: Bool?
    /// VPN-installed DNS servers that sit ahead of LockDown (allowed through so lookups keep working).
    public var vpnResolvers: [String] = []
    public var upstreams: [String] = []
    public var lastError: String?

    public init() {}
}

public struct StatRow: Codable, Hashable, Identifiable {
    public var key: String
    public var label: String
    public var value: Int
    public var id: String { key }

    public init(key: String, label: String, value: Int) {
        self.key = key
        self.label = label
        self.value = value
    }
}

public struct StatsSummary: Codable, Hashable {
    /// Seconds in the foreground today, by app.
    public var appTimeToday: [StatRow] = []
    /// Blocked DNS lookups today, by domain.
    public var blockedToday: [StatRow] = []
    /// Apps quit by LockDown today.
    public var appsBlockedToday: [StatRow] = []
    /// Total blocked attempts (web + apps) per day for the last 7 days, oldest first.
    public var blockedByDay: [StatRow] = []

    public init() {}
}

public struct Snapshot: Codable {
    public var now: Date
    public var blocks: [BlockStatus]
    public var settings: GlobalSettings
    public var health: FilterHealth
    public var stats: StatsSummary
    public var anyLocked: Bool

    public init(now: Date, blocks: [BlockStatus], settings: GlobalSettings, health: FilterHealth, stats: StatsSummary, anyLocked: Bool) {
        self.now = now
        self.blocks = blocks
        self.settings = settings
        self.health = health
        self.stats = stats
        self.anyLocked = anyLocked
    }
}

public struct Response: Codable {
    public var ok: Bool
    public var error: String?
    public var snapshot: Snapshot?
    public var enforcement: Enforcement?
    public var challenge: String?
    public var allowed: Bool?
    /// The daemon's tamper-resistant clock; clients should compute countdowns against this.
    public var now: Date?

    public init(ok: Bool = true, error: String? = nil, snapshot: Snapshot? = nil, enforcement: Enforcement? = nil,
                challenge: String? = nil, allowed: Bool? = nil, now: Date? = nil) {
        self.ok = ok
        self.now = now
        self.error = error
        self.snapshot = snapshot
        self.enforcement = enforcement
        self.challenge = challenge
        self.allowed = allowed
    }

    public static func fail(_ message: String) -> Response { Response(ok: false, error: message) }
}

public enum Wire {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

public enum ClientError: Error, CustomStringConvertible {
    case daemonUnavailable
    case io(String)
    case remote(String)

    public var description: String {
        switch self {
        case .daemonUnavailable: return "The LockDown daemon isn't running."
        case .io(let s): return "Daemon connection failed: \(s)"
        case .remote(let s): return s
        }
    }
}

/// Blocking client for the daemon's Unix socket. One request per connection, newline-terminated JSON.
public enum DaemonClient {
    public static func send(_ request: Request, timeout: TimeInterval = 5) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.io("socket") }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(IPC.socketPath.utf8)
            buf.copyBytes(from: bytes.prefix(buf.count - 1))
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw ClientError.daemonUnavailable }

        var payload = try Wire.encoder.encode(request)
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { throw ClientError.io("write") }

        guard let line = SocketIO.readLine(fd, limit: 8 << 20) else { throw ClientError.io("no response") }
        let response = try Wire.decoder.decode(Response.self, from: line)
        if !response.ok { throw ClientError.remote(response.error ?? "Unknown error") }
        return response
    }
}

public enum SocketIO {
    /// Reads until newline or EOF. Returns nil on error/timeout with no data.
    public static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while data.count < limit {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buf[0..<nl])
                return data
            }
            data.append(contentsOf: buf[0..<n])
        }
        return data.isEmpty ? nil : data
    }
}
