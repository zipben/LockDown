import Foundation
import LockDownCore

/// Loads LockDown's rules into a pf sub-anchor of `com.apple/*`, which the stock /etc/pf.conf
/// already evaluates, so pf.conf itself is never edited.
final class Firewall {
    static let anchor = "com.apple/250.LockDown"
    /// The daemon's upstream DNS socket binds this privileged source port; only root can, so
    /// it's the one DNS flow allowed out.
    static let upstreamSourcePort: UInt16 = 707

    private let pfctl = "/sbin/pfctl"
    private var token: String?
    private(set) var loaded = false

    /// IPv4 DNS sent to any other server (VPN resolvers like Tailscale's 100.100.100.100, routers,
    /// hard-coded public DNS) is routed onto lo0 and redirected into LockDown's server, so it's
    /// filtered instead of dropped. Dropping it broke every lookup whenever a VPN owned the primary
    /// resolver. Replies are un-translated by pf state, so clients see their original server answer.
    func rules() -> String {
        """
        table <ld_doh> const { \(BypassGuards.dohIPs.joined(separator: ", ")) }
        table <ld_blocked> persist
        rdr pass on lo0 inet proto { udp tcp } from any to ! 127.0.0.1 port 53 -> 127.0.0.1 port 53
        pass quick on lo0 all
        pass out quick inet proto udp from any port \(Firewall.upstreamSourcePort) to any port 53 keep state
        pass out quick on ! lo0 route-to lo0 inet proto { udp tcp } from any to any port 53 keep state
        block return out quick proto { tcp udp } to any port { 53 853 }
        block drop in quick on ! lo0 proto { udp tcp } to any port 53
        block return out quick proto { tcp udp } to <ld_doh> port 443
        block return out quick to <ld_blocked>

        """
    }

    func load() -> String? {
        writeAtomically(Data(rules().utf8), to: Paths.pfRules, mode: 0o644)
        let r = run(pfctl, ["-a", Firewall.anchor, "-f", Paths.pfRules])
        guard r.status == 0 else { return "pfctl load failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))" }
        if token == nil {
            // -E takes a reference on pf being enabled and prints a token used to release it.
            let e = run(pfctl, ["-E"])
            let text = e.out + e.err
            if let line = text.split(separator: "\n").first(where: { $0.contains("Token") }),
               let t = line.split(separator: ":").last {
                token = t.trimmingCharacters(in: .whitespaces)
            }
        }
        loaded = true
        return nil
    }

    func unload() {
        run(pfctl, ["-a", Firewall.anchor, "-F", "all"])
        if let t = token { run(pfctl, ["-X", t]) }
        token = nil
        loaded = false
    }

    /// True if our rules are present and pf is enabled.
    func verify() -> Bool {
        let rules = run(pfctl, ["-a", Firewall.anchor, "-s", "rules"])
        let info = run(pfctl, ["-s", "info"])
        return rules.out.contains("port = 53") && (info.out + info.err).contains("Status: Enabled")
    }

    func setBlockedIPs(_ ips: [String]) {
        if ips.isEmpty {
            run(pfctl, ["-a", Firewall.anchor, "-t", "ld_blocked", "-T", "flush"])
            return
        }
        run(pfctl, ["-a", Firewall.anchor, "-t", "ld_blocked", "-T", "replace", "-f", "-"], input: ips.joined(separator: "\n"))
        // Drop already-open connections to those hosts.
        for ip in ips {
            run(pfctl, ["-k", ip.contains(":") ? "::/0" : "0.0.0.0/0", "-k", ip])
        }
    }
}

/// Points every network service's DNS at 127.0.0.1 and restores the originals afterwards.
final class SystemDNS {
    private let networksetup = "/usr/sbin/networksetup"
    /// service -> original manual servers ([] = DHCP/automatic).
    private(set) var originals: [String: [String]] = [:]
    /// Services that refuse manual DNS (some VPN services); skipped by the watchdog.
    private var unmanageable = Set<String>()

    init() {
        if let d = FileManager.default.contents(atPath: Paths.dnsRestore),
           let o = try? JSONDecoder().decode([String: [String]].self, from: d) {
            originals = o
        }
    }

    func services() -> [String] {
        run(networksetup, ["-listallnetworkservices"]).out
            .split(separator: "\n").dropFirst()
            .map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    func servers(for service: String) -> [String] {
        let out = run(networksetup, ["-getdnsservers", service]).out
        if out.contains("aren't any") { return [] }
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Redirects every service; returns true if anything had to change.
    @discardableResult
    func redirect() -> Bool {
        var changed = false
        for s in services() where !unmanageable.contains(s) {
            let current = servers(for: s)
            if current == ["127.0.0.1"] { continue }
            if originals[s] == nil { originals[s] = current }
            run(networksetup, ["-setdnsservers", s, "127.0.0.1"])
            if servers(for: s) != ["127.0.0.1"] {
                Log.info("service \(s) won't accept manual DNS; skipping it")
                unmanageable.insert(s)
                originals[s] = nil
                continue
            }
            changed = true
        }
        if changed {
            saveOriginals()
            flushCache()
        }
        return changed
    }

    func isRedirected() -> Bool {
        services().filter { !unmanageable.contains($0) }.allSatisfy { servers(for: $0) == ["127.0.0.1"] }
    }

    func restore() {
        for s in services() {
            guard servers(for: s) == ["127.0.0.1"] else { continue }
            let o = (originals[s] ?? []).filter { $0 != "127.0.0.1" }
            run(networksetup, ["-setdnsservers", s] + (o.isEmpty ? ["Empty"] : o))
        }
        originals = [:]
        saveOriginals()
        flushCache()
    }

    func flushCache() {
        run("/usr/bin/dscacheutil", ["-flushcache"])
        run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    /// Resolvers to forward to: DHCP-provided servers, then the user's original manual servers, then fallbacks.
    func upstreams(fallback: [String]) -> [String] {
        var result: [String] = []
        let ports = run(networksetup, ["-listallhardwareports"]).out
        let devices = ports.split(separator: "\n").compactMap { line -> String? in
            line.hasPrefix("Device: ") ? String(line.dropFirst(8)) : nil
        }
        for dev in devices {
            let r = run("/usr/sbin/ipconfig", ["getoption", dev, "domain_name_server"])
            let ip = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.status == 0, !ip.isEmpty { result.append(ip) }
        }
        result += originals.values.flatMap { $0 }
        result += fallback
        var seen = Set<String>()
        return result.filter { isIPv4($0) && $0 != "127.0.0.1" && seen.insert($0).inserted }
    }

    private func isIPv4(_ s: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1
    }

    private func saveOriginals() {
        if let d = try? JSONEncoder().encode(originals) { writeAtomically(d, to: Paths.dnsRestore) }
    }
}
