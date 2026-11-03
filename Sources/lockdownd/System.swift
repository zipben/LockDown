import Foundation
import LockDownCore

enum Log {
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    static func info(_ s: String) {
        FileHandle.standardError.write(Data("\(stamp.string(from: Date())) [lockdownd] \(s)\n".utf8))
    }
}

struct ShellResult {
    var status: Int32
    var out: String
    var err: String
}

@discardableResult
func run(_ path: String, _ args: [String], input: String? = nil, timeout: TimeInterval? = nil) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    let inPipe = Pipe()
    p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
    do { try p.run() } catch { return ShellResult(status: -1, out: "", err: "\(error)") }
    if let timeout {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    }
    if let input {
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inPipe.fileHandleForWriting.close()
    }
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ShellResult(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
}

enum Paths {
    static let support = "/Library/Application Support/LockDown"
    static let state = support + "/state.json"
    static let stats = support + "/stats.json"
    static let dnsRestore = support + "/dns-restore.json"
    static let pfRules = support + "/pf.rules"
    static let tailscaleRestore = support + "/tailscale-dns-suspended"
}

func writeAtomically(_ data: Data, to path: String, mode: Int16 = 0o600) {
    let url = URL(fileURLWithPath: path)
    do {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    } catch {
        Log.info("write \(path) failed: \(error)")
    }
}

func bootSessionID() -> String {
    var size = 0
    sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0)
    return String(cString: buf)
}

/// Wall time derived from a monotonic clock that keeps counting through sleep, anchored to
/// network time when reachable. Changing the system clock doesn't move it.
final class TrustedClock {
    private let lock = NSLock()
    private var baseWall = Date()
    private var baseMono = TrustedClock.mono()

    static func mono() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return baseWall.addingTimeInterval(Double(TrustedClock.mono() - baseMono) / 1e9)
    }

    /// Re-anchors to NTP. Returns true on success.
    @discardableResult
    func syncNTP() -> Bool {
        // time.cloudflare.com anycast addresses, so no DNS lookup is needed.
        for server in ["162.159.200.1", "162.159.200.123"] {
            if let t = SNTP.query(server) {
                lock.lock()
                baseWall = t
                baseMono = TrustedClock.mono()
                lock.unlock()
                return true
            }
        }
        return false
    }
}

enum SNTP {
    static func query(_ ip: String, timeout: Int = 2) -> Date? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(123).bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        var packet = [UInt8](repeating: 0, count: 48)
        packet[0] = 0x1B // LI=0, VN=3, Mode=client
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == 48 else { return nil }
        var buf = [UInt8](repeating: 0, count: 48)
        guard recv(fd, &buf, 48, 0) == 48 else { return nil }
        let secs = buf[40..<44].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let frac = buf[44..<48].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard secs > 2_208_988_800 else { return nil }
        return Date(timeIntervalSince1970: Double(secs - 2_208_988_800) + Double(frac) / 4_294_967_296)
    }
}
