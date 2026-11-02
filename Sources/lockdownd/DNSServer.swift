import Foundation
import LockDownCore

/// A small DNS server on 127.0.0.1:53. Blocked names get 0.0.0.0 / ::; everything else is
/// forwarded over UDP from a privileged source port (see `Firewall.upstreamSourcePort`).
final class DNSServer {
    struct Pending {
        var deadline: Date
        var reply: (Data) -> Void
        var query: Data
        var question: DNSMessage.Question
    }

    private let policyLock = NSLock()
    private var policies: [CompiledWebPolicy] = []
    private var upstreams: [String] = []

    private let pendingLock = NSLock()
    private var pending: [UInt16: Pending] = [:]

    private var udpFD: Int32 = -1
    private var tcpFD: Int32 = -1
    private var upstreamFD: Int32 = -1
    private(set) var running = false

    /// Called (off the main state queue) with each blocked hostname.
    var onBlocked: ((String) -> Void)?

    func setPolicies(_ p: [WebPolicy]) {
        policyLock.lock()
        policies = p.map(CompiledWebPolicy.init)
        policyLock.unlock()
    }

    func setUpstreams(_ u: [String]) {
        policyLock.lock()
        upstreams = Array(u.prefix(3))
        policyLock.unlock()
    }

    var currentUpstreams: [String] {
        policyLock.lock()
        defer { policyLock.unlock() }
        return upstreams
    }

    func start() throws {
        udpFD = try bindSocket(type: SOCK_DGRAM, address: "127.0.0.1", port: 53)
        tcpFD = try bindSocket(type: SOCK_STREAM, address: "127.0.0.1", port: 53)
        listen(tcpFD, 64)
        upstreamFD = try bindSocket(type: SOCK_DGRAM, address: "0.0.0.0", port: Firewall.upstreamSourcePort)
        running = true
        thread("dns-udp") { self.udpLoop() }
        thread("dns-tcp") { self.tcpLoop() }
        thread("dns-upstream") { self.upstreamLoop() }
        thread("dns-sweep") { self.sweepLoop() }
    }

    // MARK: Decision

    enum Verdict { case blocked, nxdomain, forward }

    func verdict(for name: String) -> Verdict {
        if BypassGuards.canaries.contains(name) { return .nxdomain }
        policyLock.lock()
        let p = policies
        policyLock.unlock()
        // With no active web blocks, answer normally (DNS is only redirected while blocking anyway).
        guard !p.isEmpty else { return .forward }
        if BypassGuards.dohHosts.matches(name) { return .blocked }
        return p.contains { $0.isBlocked(name) } ? .blocked : .forward
    }

    func handle(_ query: Data, reply: @escaping (Data) -> Void) {
        guard let q = DNSMessage.parseQuery(query) else { return }
        switch verdict(for: q.name) {
        case .nxdomain:
            reply(DNSMessage.nxdomain(to: query, q))
        case .blocked:
            reply(DNSMessage.blockedResponse(to: query, q))
            if q.qtype == DNSMessage.typeA { onBlocked?(q.name) }
        case .forward:
            forward(query, q, reply: reply)
        }
    }

    // MARK: Forwarding

    func forward(_ query: Data, _ q: DNSMessage.Question, reply: @escaping (Data) -> Void) {
        let targets = currentUpstreams
        guard !targets.isEmpty else {
            reply(DNSMessage.servfail(to: query, q))
            return
        }
        pendingLock.lock()
        var id = UInt16.random(in: 0...UInt16.max)
        while pending[id] != nil { id &+= 1 }
        pending[id] = Pending(deadline: Date().addingTimeInterval(3), reply: reply, query: query, question: q)
        pendingLock.unlock()

        let out = DNSMessage.withID(query, id)
        // Query up to two resolvers at once; the first answer wins.
        for ip in targets.prefix(2) { sendUpstream(out, to: ip) }
    }

    /// Resolves a name through the upstreams (bypassing our own block list). Used for IP hard-blocking.
    func resolve(_ name: String, qtype: UInt16, timeout: TimeInterval = 3) -> [String] {
        let sem = DispatchSemaphore(value: 0)
        var result: [String] = []
        let query = DNSMessage.query(id: 0, name: name, qtype: qtype)
        guard let q = DNSMessage.parseQuery(query) else { return [] }
        forward(query, q) { data in
            result = DNSMessage.addresses(in: data)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return result
    }

    private func sendUpstream(_ data: Data, to ip: String) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
        data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(upstreamFD, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func upstreamLoop() {
        var buf = [UInt8](repeating: 0, count: 65535)
        while true {
            let n = recv(upstreamFD, &buf, buf.count, 0)
            guard n > 0 else { continue }
            let data = Data(buf[0..<n])
            guard let id = DNSMessage.id(of: data) else { continue }
            pendingLock.lock()
            let p = pending.removeValue(forKey: id)
            pendingLock.unlock()
            guard let p else { continue } // late duplicate from the second resolver
            p.reply(DNSMessage.withID(data, p.question.id))
        }
    }

    private func sweepLoop() {
        while true {
            Thread.sleep(forTimeInterval: 1)
            let now = Date()
            pendingLock.lock()
            let expired = pending.filter { $0.value.deadline < now }
            for k in expired.keys { pending[k] = nil }
            pendingLock.unlock()
            for p in expired.values { p.reply(DNSMessage.servfail(to: p.query, p.question)) }
        }
    }

    // MARK: Listeners

    private func udpLoop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var from = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udpFD, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let query = Data(buf[0..<n])
            let client = from
            let clientLen = len
            let fd = udpFD
            handle(query) { response in
                var to = client
                response.withUnsafeBytes { r in
                    withUnsafePointer(to: &to) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(fd, r.baseAddress, r.count, 0, $0, clientLen)
                        }
                    }
                }
            }
        }
    }

    private func tcpLoop() {
        while true {
            let c = accept(tcpFD, nil, nil)
            guard c >= 0 else { continue }
            DispatchQueue.global().async { self.serveTCP(c) }
        }
    }

    private func serveTCP(_ fd: Int32) {
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        while let msg = readExactlyPrefixed(fd) {
            let sem = DispatchSemaphore(value: 0)
            var answer: Data?
            handle(msg) { answer = $0; sem.signal() }
            guard sem.wait(timeout: .now() + 4) == .success, let a = answer else { return }
            var framed = Data([UInt8(a.count >> 8), UInt8(a.count & 0xFF)])
            framed.append(a)
            let ok = framed.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == framed.count
            if !ok { return }
        }
    }

    private func readExactlyPrefixed(_ fd: Int32) -> Data? {
        guard let lenBytes = readExactly(fd, 2) else { return nil }
        let len = Int(lenBytes[0]) << 8 | Int(lenBytes[1])
        guard len > 0 else { return nil }
        return readExactly(fd, len).map { Data($0) }
    }

    private func readExactly(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
            if r <= 0 { return nil }
            got += r
        }
        return buf
    }

    private func bindSocket(type: Int32, address: String, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { throw DNSError.socket("socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw DNSError.socket("bind \(address):\(port): \(msg)")
        }
        return fd
    }

    private func thread(_ name: String, _ body: @escaping () -> Void) {
        let t = Thread(block: body)
        t.name = name
        t.start()
    }
}

enum DNSError: Error, CustomStringConvertible {
    case socket(String)
    var description: String {
        switch self { case .socket(let s): return s }
    }
}
