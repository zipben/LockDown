import LockDownCore
import SwiftUI

enum Tab: String, CaseIterable {
    case blocks = "BLOCKS", stats = "HI-SCORES", settings = "OPTIONS"
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var tab: Tab

    init(initialTab: Tab = .blocks) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        ZStack {
            Pixel.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(tab: $tab)
                Rectangle().fill(Pixel.edge).frame(height: 3)
                if store.connected {
                    switch tab {
                    case .blocks: BlocksScreen()
                    case .stats: StatsScreen()
                    case .settings: SettingsScreen()
                    }
                } else {
                    InsertCoinScreen()
                }
            }
            Scanlines()
            if let d = store.dialog { DialogView(dialog: d) { store.dialog = nil } }
        }
        .frame(minWidth: 980, minHeight: 680)
        .preferredColorScheme(.dark)
    }
}

struct TopBar: View {
    @EnvironmentObject var store: Store
    @Binding var tab: Tab

    var body: some View {
        HStack(spacing: 16) {
            Sprites.mascot(3)
            VStack(alignment: .leading, spacing: 6) {
                Text("LOCKDOWN").font(Pixel.font(20)).foregroundStyle(Pixel.yellow)
                    .shadow(color: Pixel.red, radius: 0, x: 3, y: 3)
                StatusLine()
            }
            Spacer()
            ForEach(Tab.allCases, id: \.self) { t in
                PixelChip(label: t.rawValue, selected: tab == t, color: Pixel.cyan) { tab = t }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Pixel.panel)
    }
}

struct StatusLine: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let s = store.snapshot
        let active = s?.blocks.filter { $0.activity.enforcing }.count ?? 0
        HStack(spacing: 14) {
            if !store.connected {
                Text("DAEMON OFFLINE").font(Pixel.font(8)).foregroundStyle(Pixel.red).blinking()
            } else {
                Text("\(active) ACTIVE").font(Pixel.font(8)).foregroundStyle(active > 0 ? Pixel.green : Pixel.inkDim)
                if s?.anyLocked == true {
                    HStack(spacing: 6) {
                        Sprites.lock(1.5)
                        Text("LOCKED").font(Pixel.font(8)).foregroundStyle(Pixel.yellow)
                    }
                }
                if let h = s?.health, active > 0 {
                    let ok = h.dnsServerRunning && h.systemDNSRedirected && h.firewallLoaded
                    Text(ok ? "SHIELD UP" : "SHIELD DOWN").font(Pixel.font(8)).foregroundStyle(ok ? Pixel.cyan : Pixel.red)
                }
            }
        }
    }
}

struct DialogView: View {
    let dialog: Dialog
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(spacing: 18) {
                Text(dialog.title).font(Pixel.font(18)).foregroundStyle(dialog.color)
                Text(dialog.message).font(Pixel.font(9)).foregroundStyle(Pixel.ink)
                    .multilineTextAlignment(.center).lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                Button("CONTINUE", action: dismiss)
                    .buttonStyle(PixelButtonStyle(color: dialog.color))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(28)
            .frame(maxWidth: 460)
            .background(PixelRect(step: 6).fill(Pixel.panel))
            .overlay(PixelRect(step: 6).stroke(dialog.color, lineWidth: 3))
        }
    }
}

struct InsertCoinScreen: View {
    let command = "sudo \"/Applications/LockDown.app/Contents/Resources/install.sh\""

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Sprites.mascot(8)
            Text("INSERT COIN").font(Pixel.font(28)).foregroundStyle(Pixel.yellow).blinking(0.7)
            Text("The LockDown daemon isn't running.\nInstall it once with your admin password:")
                .font(Pixel.font(10)).foregroundStyle(Pixel.inkDim).multilineTextAlignment(.center).lineSpacing(8)
            Text(command).font(.system(size: 13, design: .monospaced)).foregroundStyle(Pixel.green)
                .textSelection(.enabled)
                .padding(12).background(Pixel.panel).overlay(Rectangle().stroke(Pixel.panelHi, lineWidth: 2))
            Button("COPY COMMAND") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(PixelButtonStyle(color: Pixel.cyan))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
