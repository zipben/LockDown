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

    /// DNS to anything but LockDown is blocked, except to `<ld_vpn_dns>`: resolvers a VPN (e.g.
    /// Tailscale's 100.100.100.100) installs ahead of ours, which networksetup can't override.
    /// Blocking those broke every lookup. (Redirecting them with route-to/rdr was tried and pf
    /// dropped the packets on this macOS.)
    func rules() -> String {
        """
        table <ld_doh> const { \(BypassGuards.dohIPs.joined(separator: ", ")) }
        table <ld_blocked> persist
        table <ld_vpn_dns> persist\(vpnResolvers.isEmpty ? "" : " { " + vpnResolvers.joined(separator: ", ") + " }")
        pass quick on lo0 all
        pass out quick inet proto udp from any port \(Firewall.upstreamSourcePort) to any port 53 keep state
        pass out quick proto { tcp udp } to <ld_vpn_dns> port 53 keep state
        block return out quick proto { tcp udp } to any port { 53 853 }
        block return out quick proto { tcp udp } to <ld_doh> port 443
        block return out quick to <ld_blocked>

        """
    }

    private(set) var vpnResolvers: [String] = []

    /// Updates the allowed VPN resolvers; reloads only when the set changes.
    func setVPNResolvers(_ ips: [String]) {
        let sorted = Array(Set(ips)).sorted()
        guard sorted != vpnResolvers else { return }
        vpnResolvers = sorted
        if loaded {
            if sorted.isEmpty {
                run(pfctl, ["-a", Firewall.anchor, "-t", "ld_vpn_dns", "-T", "flush"])
            } else {
                run(pfctl, ["-a", Firewall.anchor, "-t", "ld_vpn_dns", "-T", "replace", "-f", "-"], input: sorted.joined(separator: "\n"))
            }
        }
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

    /// Non-loopback nameservers in the system's resolver list that we didn't set: resolvers a VPN
    /// network extension installed (it owns them, so networksetup can't change them).
    func unmanagedResolvers() -> [String] {
        let out = run("/usr/sbin/scutil", ["--dns"]).out
        // Only the main section; "for scoped queries" lists per-interface resolvers mDNSResponder
        // uses only for interface-bound requests.
        let main = out.components(separatedBy: "DNS configuration (for scoped queries)").first ?? out
        var ips: [String] = []
        // Each "resolver #N" block lists its nameservers, then (optionally) its interface. Only
        // resolvers bound to tunnel interfaces belong to a VPN; the rest are ones we redirect.
        for block in main.components(separatedBy: "resolver #").dropFirst() {
            let lines = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let iface = lines.first(where: { $0.hasPrefix("if_index") })?.split(separator: "(").last?.dropLast(),
                  ["utun", "ipsec", "ppp", "tun", "tap"].contains(where: { iface.hasPrefix($0) }) else { continue }
            for line in lines where line.hasPrefix("nameserver[") {
                guard let ip = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces),
                      ip != "127.0.0.1", ip != "::1" else { continue }
                ips.append(ip)
            }
        }
        return Array(Set(ips)).sorted()
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
