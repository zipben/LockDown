import Foundation

/// With "Use Tailscale DNS" on, 100.100.100.100 becomes the primary resolver and forwards to the
/// DHCP servers it remembers, not to LockDown; the firewall then drops those lookups and every
/// site fails. While web blocking is on, LockDown turns that setting off and resolves tailnet
/// names (*.ts.net) through 100.100.100.100 itself, then turns the setting back on.
final class TailscaleDNS {
    static let quad100 = "100.100.100.100"
    static let routes = ["ts.net": quad100]

    private let cli = ["/Applications/Tailscale.app/Contents/MacOS/tailscale",
                       "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                       "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// True while the setting is off because of us (persisted so a restart still restores it).
    private(set) var suspended = FileManager.default.fileExists(atPath: Paths.tailscaleRestore)

    var installed: Bool { cli != nil }

    /// The GUI app's CLI finds its local API through the logged-in user's container, so run it as
    /// the console user.
    private func tailscale(_ args: [String]) -> ShellResult? {
        guard let cli else { return nil }
        var st = stat()
        guard stat("/dev/console", &st) == 0, st.st_uid != 0,
              let pw = getpwuid(st.st_uid) else { return nil }
        let user = String(cString: pw.pointee.pw_name)
        return run("/usr/bin/sudo", ["-n", "-u", user, "-H", cli] + args, timeout: 8)
    }

    /// nil when Tailscale isn't installed, running or reachable.
    func acceptDNS() -> Bool? {
        guard let r = tailscale(["dns", "status"]), r.status == 0 else { return nil }
        if r.out.contains("Tailscale DNS: enabled") { return true }
        if r.out.contains("Tailscale DNS: disabled") { return false }
        return nil
    }

    /// Turns "Use Tailscale DNS" off if it's on. Returns true if it changed anything.
    @discardableResult
    func suspend() -> Bool {
        guard acceptDNS() == true else { return false }
        let r = tailscale(["set", "--accept-dns=false"])
        guard r?.status == 0 else {
            Log.info("couldn't turn off Tailscale DNS: \(r?.err.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no CLI")")
            return false
        }
        if !suspended {
            suspended = true
            writeAtomically(Data(), to: Paths.tailscaleRestore)
        }
        Log.info("turned off Tailscale DNS while blocking")
        return true
    }

    func resume() {
        guard suspended else { return }
        let r = tailscale(["set", "--accept-dns=true"])
        // Keep the marker if Tailscale is unreachable now so the next tick retries.
        guard r?.status == 0 else { return }
        suspended = false
        try? FileManager.default.removeItem(atPath: Paths.tailscaleRestore)
        Log.info("turned Tailscale DNS back on")
    }
}
