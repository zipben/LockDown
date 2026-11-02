import Foundation

/// Minimal DNS wire-format helpers: enough to read a query's question and synthesize answers.
public enum DNSMessage {
    public static let typeA: UInt16 = 1
    public static let typeAAAA: UInt16 = 28

    public struct Question: Equatable {
        public var id: UInt16
        public var name: String
        public var qtype: UInt16
        public var qclass: UInt16
        /// Byte offset just past the question section.
        public var questionEnd: Int
    }

    public static func parseQuery(_ data: Data) -> Question? {
        let b = [UInt8](data)
        guard b.count >= 12 else { return nil }
        let flags = UInt16(b[2]) << 8 | UInt16(b[3])
        guard flags & 0x8000 == 0 else { return nil } // must be a query
        let qd = UInt16(b[4]) << 8 | UInt16(b[5])
        guard qd >= 1 else { return nil }
        var i = 12
        var labels: [String] = []
        while true {
            guard i < b.count else { return nil }
            let len = Int(b[i])
            if len == 0 { i += 1; break }
            guard len & 0xC0 == 0, i + 1 + len <= b.count, labels.count < 128 else { return nil }
            labels.append(String(decoding: b[(i + 1)..<(i + 1 + len)], as: UTF8.self))
            i += 1 + len
        }
        guard i + 4 <= b.count else { return nil }
        let qtype = UInt16(b[i]) << 8 | UInt16(b[i + 1])
        let qclass = UInt16(b[i + 2]) << 8 | UInt16(b[i + 3])
        return Question(id: UInt16(b[0]) << 8 | UInt16(b[1]), name: labels.joined(separator: ".").lowercased(),
                        qtype: qtype, qclass: qclass, questionEnd: i + 4)
    }

    /// Answer a blocked query: A -> 0.0.0.0, AAAA -> ::, anything else -> empty NOERROR.
    public static func blockedResponse(to query: Data, _ q: Question, ttl: UInt32 = 5) -> Data {
        var out = header(from: query, rcode: 0, answers: (q.qtype == typeA || q.qtype == typeAAAA) ? 1 : 0)
        out.append(contentsOf: [UInt8](query)[12..<q.questionEnd])
        if q.qtype == typeA || q.qtype == typeAAAA {
            let rdlen: UInt16 = q.qtype == typeA ? 4 : 16
            out.append(contentsOf: [0xC0, 0x0C]) // pointer to the question name
            var rr: [UInt8] = be16(q.qtype)
            rr += be16(1)
            rr += be32(ttl)
            rr += be16(rdlen)
            out.append(contentsOf: rr)
            out.append(contentsOf: [UInt8](repeating: 0, count: Int(rdlen)))
        }
        return out
    }

    /// NXDOMAIN, used to switch off browser DoH canaries and iCloud Private Relay.
    public static func nxdomain(to query: Data, _ q: Question) -> Data {
        var out = header(from: query, rcode: 3, answers: 0)
        out.append(contentsOf: [UInt8](query)[12..<q.questionEnd])
        return out
    }

    public static func servfail(to query: Data, _ q: Question) -> Data {
        var out = header(from: query, rcode: 2, answers: 0)
        out.append(contentsOf: [UInt8](query)[12..<q.questionEnd])
        return out
    }

    /// Builds a standard recursive query.
    public static func query(id: UInt16, name: String, qtype: UInt16) -> Data {
        var head: [UInt8] = be16(id)
        head += [0x01, 0x00]
        head += be16(1)
        head += [0, 0, 0, 0, 0, 0]
        var out = Data(head)
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(0)
        out.append(contentsOf: be16(qtype) + be16(1))
        return out
    }

    /// Extracts A/AAAA addresses from a response's answer section.
    public static func addresses(in response: Data) -> [String] {
        let b = [UInt8](response)
        guard b.count >= 12 else { return [] }
        let qd = Int(UInt16(b[4]) << 8 | UInt16(b[5]))
        let an = Int(UInt16(b[6]) << 8 | UInt16(b[7]))
        var i = 12
        for _ in 0..<qd {
            guard let n = skipName(b, i) else { return [] }
            i = n + 4
        }
        var result: [String] = []
        for _ in 0..<an {
            guard let n = skipName(b, i), n + 10 <= b.count else { break }
            let type = UInt16(b[n]) << 8 | UInt16(b[n + 1])
            let rdlen = Int(UInt16(b[n + 8]) << 8 | UInt16(b[n + 9]))
            let rd = n + 10
            guard rd + rdlen <= b.count else { break }
            if type == typeA, rdlen == 4 {
                result.append(b[rd..<rd + 4].map(String.init).joined(separator: "."))
            } else if type == typeAAAA, rdlen == 16 {
                var addr = in6_addr()
                withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: b[rd..<rd + 16]) }
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
                result.append(String(cString: buf))
            }
            i = rd + rdlen
        }
        return result
    }

    /// Returns a copy with the 16-bit ID replaced.
    public static func withID(_ data: Data, _ id: UInt16) -> Data {
        guard data.count >= 2 else { return data }
        var d = data
        d[d.startIndex] = UInt8(id >> 8)
        d[d.startIndex + 1] = UInt8(id & 0xFF)
        return d
    }

    public static func id(of data: Data) -> UInt16? {
        guard data.count >= 2 else { return nil }
        return UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
    }

    static func skipName(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start
        while i < b.count {
            let len = Int(b[i])
            if len == 0 { return i + 1 }
            if len & 0xC0 == 0xC0 { return i + 2 }
            i += 1 + len
        }
        return nil
    }

    static func header(from query: Data, rcode: UInt8, answers: UInt16) -> Data {
        let q = [UInt8](query)
        let rd = q[2] & 0x01
        var h: [UInt8] = [q[0], q[1], 0x80 | rd, 0x80 | rcode]
        h += be16(1)
        h += be16(answers)
        h += [0, 0, 0, 0]
        return Data(h)
    }

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}

/// Hostnames that must never resolve while web blocking is on, regardless of block lists.
public enum BypassGuards {
    /// Returning NXDOMAIN here tells Firefox to disable automatic DoH and Apple to disable iCloud Private Relay.
    public static let canaries: Set<String> = [
        "use-application-dns.net", "mask.icloud.com", "mask-h2.icloud.com", "mask-api.icloud.com",
    ]

    /// Well-known DNS-over-HTTPS endpoints. Blocking their names stops browsers' "secure DNS"
    /// from bypassing LockDown; their IPs are also firewalled on port 443.
    public static let dohHosts = DomainMatcher([
        "dns.google", "dns.google.com", "cloudflare-dns.com", "one.one.one.one", "1dot1dot1dot1.cloudflare-dns.com",
        "dns.quad9.net", "dns9.quad9.net", "dns10.quad9.net", "dns11.quad9.net",
        "doh.opendns.com", "dns.umbrella.com", "dns.nextdns.io", "doh.cleanbrowsing.org",
        "dns.adguard.com", "dns.adguard-dns.com", "dns.mullvad.net", "doh.mullvad.net", "dns.controld.com",
        "freedns.controld.com", "doh.libredns.gr", "dns.alidns.com", "doh.pub", "doh.dns.sb", "dns.twnic.tw",
    ])

    public static let dohIPs = [
        "1.1.1.1", "1.0.0.1", "1.1.1.2", "1.0.0.2", "1.1.1.3", "1.0.0.3",
        "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112", "9.9.9.10", "149.112.112.10", "9.9.9.11", "149.112.112.11",
        "208.67.222.222", "208.67.220.220", "94.140.14.14", "94.140.15.15", "76.76.2.0", "76.76.10.0",
        "45.90.28.0/24", "45.90.30.0/24", "185.228.168.168", "185.228.169.168", "194.242.2.2", "194.242.2.3",
        "2606:4700:4700::1111", "2606:4700:4700::1001", "2001:4860:4860::8888", "2001:4860:4860::8844",
        "2620:fe::fe", "2620:fe::9", "2620:119:35::35", "2620:119:53::53", "2a10:50c0::ad1:ff", "2a07:a8c0::/32",
    ]
}
