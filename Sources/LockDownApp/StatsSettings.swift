import LockDownCore
import SwiftUI

struct StatsScreen: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let s = store.snapshot?.stats ?? StatsSummary()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Sprites.trophy(4)
                    Text("HI-SCORES").font(Pixel.font(18)).foregroundStyle(Pixel.yellow)
                }
                PixelPanel(title: "BLOCKED ATTEMPTS - LAST 7 DAYS", accent: Pixel.red) {
                    BlockedBarChart(rows: s.blockedByDay)
                }
                HStack(alignment: .top, spacing: 16) {
                    ScoreTable(title: "SITES BLOCKED TODAY", accent: Pixel.cyan, rows: s.blockedToday) { "\($0)" }
                    ScoreTable(title: "APPS QUIT TODAY", accent: Pixel.magenta, rows: s.appsBlockedToday) { "\($0)" }
                }
                ScoreTable(title: "SCREEN TIME TODAY", accent: Pixel.green, rows: s.appTimeToday) { durationString($0) }
                if store.snapshot?.settings.statsEnabled == false {
                    Text("STATS ARE OFF. TURN THEM ON IN OPTIONS.").font(Pixel.font(8)).foregroundStyle(Pixel.yellow)
                }
            }
            .padding(20)
        }
    }
}

struct ScoreTable: View {
    let title: String
    let accent: Color
    let rows: [StatRow]
    let format: (Int) -> String

    var body: some View {
        PixelPanel(title: title, accent: accent) {
            if rows.isEmpty {
                Text("NO SCORES YET").font(Pixel.font(8)).foregroundStyle(Pixel.inkMuted)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                HStack(spacing: 10) {
                    Text(String(format: "%2d.", i + 1)).foregroundStyle(i == 0 ? Pixel.yellow : Pixel.inkMuted)
                    Text(r.label.uppercased()).foregroundStyle(Pixel.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(format(r.value)).foregroundStyle(Pixel.inkDim)
                }
                .font(Pixel.font(8))
            }
        }
    }
}

/// One series, so no legend: the panel title names it. Bars are a single hue anchored to the
/// baseline; only today's and the peak value are labeled, the rest are on hover.
struct BlockedBarChart: View {
    let rows: [StatRow]
    let height: CGFloat = 120

    var body: some View {
        let peak = max(1, rows.map(\.value).max() ?? 1)
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                let isToday = i == rows.count - 1
                let labeled = isToday || (r.value == peak && r.value > 0)
                VStack(spacing: 6) {
                    Text(labeled ? "\(r.value)" : " ").font(Pixel.font(7)).foregroundStyle(Pixel.ink)
                    // Quantize to 4px steps so bars stay on the pixel grid.
                    let h = (CGFloat(r.value) / CGFloat(peak) * height / 4).rounded() * 4
                    Rectangle()
                        .fill(isToday ? Pixel.red : Pixel.red.opacity(0.55))
                        .frame(height: max(r.value > 0 ? 4 : 0, h))
                        .help("\(r.key): \(r.value) blocked")
                    Rectangle().fill(Pixel.inkMuted).frame(height: 2)
                    Text(isToday ? "TODAY" : r.label).font(Pixel.font(6)).foregroundStyle(isToday ? Pixel.ink : Pixel.inkMuted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height + 44, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rows.map { "\($0.key): \($0.value) blocked" }.joined(separator: ", "))
    }
}

struct SettingsScreen: View {
    @EnvironmentObject var store: Store
    @AppStorage(TextSize.key) private var textScale: Double = TextSize.large.rawValue
    @State private var draft: GlobalSettings?
    @State private var dnsText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Sprites.gear(4)
                    Text("OPTIONS").font(Pixel.font(18)).foregroundStyle(Pixel.yellow)
                }
                PixelPanel(title: "TEXT SIZE", accent: Pixel.yellow) {
                    HStack(spacing: 8) {
                        ForEach(TextSize.allCases, id: \.self) { t in
                            PixelChip(label: t.label, selected: abs(textScale - Double(t.rawValue)) < 0.01) { textScale = Double(t.rawValue) }
                        }
                    }
                    Text("Applies right away, including the freeze screen.").font(Pixel.font(7)).foregroundStyle(Pixel.inkMuted)
                }
                if let d = Binding($draft) {
                    PixelPanel(title: "STRICT MODE (WHILE A BLOCK IS LOCKED)", accent: Pixel.red) {
                        PixelToggle(label: "QUIT ACTIVITY MONITOR", isOn: d.blockActivityMonitor)
                        PixelToggle(label: "QUIT TERMINALS", isOn: d.blockTerminals,
                                    detail: "Terminal, iTerm, Warp, Ghostty, kitty, Alacritty, WezTerm, Script Editor. Stops sudo tricks, and your coding tools too.")
                        PixelToggle(label: "QUIT SYSTEM SETTINGS", isOn: d.blockSystemSettings,
                                    detail: "Stops you switching LockDown off in Login Items.")
                        if store.snapshot?.anyLocked == true {
                            Text("LOCKED: THESE CAN ONLY BE TURNED ON.").font(Pixel.font(7)).foregroundStyle(Pixel.yellow)
                        }
                    }
                    PixelPanel(title: "NETWORK SHIELD", accent: Pixel.cyan) {
                        PixelToggle(label: "HARD MODE: ALSO BLOCK BY IP ADDRESS", isOn: d.hardBlockIPs,
                                    detail: "Cuts open connections and cached lookups. Can also block unrelated sites that share the same servers.")
                        Text("FALLBACK DNS SERVERS (COMMA SEPARATED)").font(Pixel.font(7)).foregroundStyle(Pixel.inkDim)
                        PixelField(placeholder: "1.1.1.1, 9.9.9.9", text: $dnsText).frame(maxWidth: 380)
                    }
                    PixelPanel(title: "STATS", accent: Pixel.green) {
                        PixelToggle(label: "RECORD STATS", isOn: d.statsEnabled)
                    }
                    HStack {
                        Button("SAVE OPTIONS") {
                            var s = d.wrappedValue
                            s.fallbackDNS = dnsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            store.send(Request(.saveSettings, settings: s), success: "Options saved.")
                        }
                        .buttonStyle(PixelButtonStyle(color: Pixel.yellow))
                        .disabled(d.wrappedValue == store.snapshot?.settings && dnsText == store.snapshot?.settings.fallbackDNS.joined(separator: ", "))
                    }
                }
                HealthPanel()
                PixelPanel(title: "GAME OVER (UNINSTALL)", accent: Pixel.inkDim) {
                    Text("Uninstalling is refused while any block is locked:")
                        .font(Pixel.font(8)).foregroundStyle(Pixel.inkDim)
                    Text("sudo \"/Applications/LockDown.app/Contents/Resources/uninstall.sh\"")
                        .font(Pixel.mono(12)).foregroundStyle(Pixel.ink).textSelection(.enabled)
                }
            }
            .padding(20)
        }
        .onAppear(perform: load)
        .onChange(of: store.snapshot?.settings) { _, _ in if draft == nil { load() } }
    }

    func load() {
        guard let s = store.snapshot?.settings else { return }
        draft = s
        dnsText = s.fallbackDNS.joined(separator: ", ")
    }
}

struct HealthPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let h = store.snapshot?.health ?? FilterHealth()
        let webActive = store.snapshot?.blocks.contains { $0.activity.enforcing && $0.block.hasWebRules } ?? false
        PixelPanel(title: "SHIELD STATUS", accent: Pixel.green) {
            row("DNS BLOCKER", h.dnsServerRunning, "RUNNING", "DOWN")
            row("SYSTEM DNS -> LOCKDOWN", h.systemDNSRedirected, "YES", webActive ? "NO" : "ONLY WHILE BLOCKING")
            row("FIREWALL RULES", h.firewallLoaded, "LOADED", webActive ? "MISSING" : "ONLY WHILE BLOCKING")
            HStack {
                Text("UPSTREAM DNS").foregroundStyle(Pixel.inkDim)
                Spacer()
                Text(h.upstreams.isEmpty ? "NONE" : h.upstreams.joined(separator: " ")).foregroundStyle(Pixel.ink)
            }
            .font(Pixel.font(8))
            if let e = h.lastError {
                Text("LAST ERROR: \(e)").font(Pixel.font(7)).foregroundStyle(Pixel.red).lineSpacing(4)
            }
        }
    }

    func row(_ label: String, _ ok: Bool, _ yes: String, _ no: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Pixel.inkDim)
            Spacer()
            Text(ok ? yes : no).foregroundStyle(ok ? Pixel.green : Pixel.inkMuted)
        }
        .font(Pixel.font(8))
    }
}
