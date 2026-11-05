import AppKit
import LockDownCore
import SwiftUI
import UserNotifications

/// Runs in the user's session (launched with --agent by a LaunchAgent). Quits blocked apps,
/// hides windows with blocked titles, shows the Frozen Turkey screen, and reports usage.
@MainActor
final class Agent: NSObject, NSApplicationDelegate {
    private var enforcement = Enforcement()
    private var daemonSkew: TimeInterval = 0
    private var lastNotified: [String: Date] = [:]
    private var frozenWindows: [NSWindow] = []
    private var frozenStartedAt: Date?
    private var frozenActionTaken = false
    private var askedScreenCapture = false
    private var usageTick = 0
    private let frozenModel = FrozenModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { self?.check(app) } }
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app { self?.check(app) }
                self?.reassertFrozen()
            }
        }

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private var now: Date { Date().addingTimeInterval(daemonSkew) }

    private func poll() {
        Task.detached {
            guard let r = try? DaemonClient.send(Request(.enforcement), timeout: 3), let e = r.enforcement else { return }
            let skew = r.now?.timeIntervalSinceNow ?? 0
            await MainActor.run {
                self.enforcement = e
                self.daemonSkew = skew
                self.sweep()
            }
        }
    }

    /// Applies the current rules to everything running.
    private func sweep() {
        for app in NSWorkspace.shared.runningApplications { check(app) }
        checkTitles()
        updateFrozen()
        usageTick += 1
        if usageTick % 3 == 0 { reportUsage(seconds: 6) }
    }

    /// LockDown's own processes are never blocked.
    private func isOwn(_ bundleID: String?) -> Bool {
        bundleID == "com.lockdown.app" || bundleID == "com.lockdown.agent"
    }

    private func blockedName(_ bundleID: String) -> String? {
        if let a = enforcement.apps.first(where: { $0.bundleID == bundleID }) { return a.name }
        if enforcement.strictBundleIDs.contains(bundleID) { return "STRICT MODE" }
        return nil
    }

    private func check(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, !isOwn(id), !app.isTerminated,
              blockedName(id) != nil else { return }
        let name = app.localizedName ?? id
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if !app.isTerminated { app.forceTerminate() }
        }
        notify(key: id, title: "GAME OVER: \(name.uppercased())", body: "\(name) is blocked by LockDown.")
        let report = UsageReport(bundleID: id, appName: name, title: nil, seconds: 0)
        Task.detached { _ = try? DaemonClient.send(Request(.reportBlockedApp, usage: report)) }
    }

    /// Hides the frontmost app when its window title contains a blocked keyword. Needs Screen Recording
    /// permission to read other apps' window titles.
    private func checkTitles() {
        guard !enforcement.titleKeywords.isEmpty, let front = NSWorkspace.shared.frontmostApplication,
              !isOwn(front.bundleIdentifier) else { return }
        if !CGPreflightScreenCaptureAccess() {
            if !askedScreenCapture {
                askedScreenCapture = true
                CGRequestScreenCaptureAccess()
            }
            return
        }
        guard let title = frontWindowTitle(pid: front.processIdentifier)?.lowercased() else { return }
        if let k = enforcement.titleKeywords.first(where: { title.contains($0) }) {
            front.hide()
            notify(key: "title:" + k, title: "BLOCKED WINDOW", body: "A window matching \"\(k)\" was hidden.")
        }
    }

    private func frontWindowTitle(pid: pid_t) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    private func reportUsage(seconds: Int) {
        guard let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier else { return }
        // Skip when the screen is locked or the user is idle for more than 2 minutes.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 120 else { return }
        let r = UsageReport(bundleID: id, appName: front.localizedName ?? id, title: nil, seconds: seconds)
        Task.detached { _ = try? DaemonClient.send(Request(.reportUsage, usage: r)) }
    }

    private func notify(key: String, title: String, body: String) {
        if let last = lastNotified[key], Date().timeIntervalSince(last) < 15 { return }
        lastNotified[key] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Frozen Turkey

    private func updateFrozen() {
        guard let f = enforcement.frozen else {
            if !frozenWindows.isEmpty { unfreeze() }
            return
        }
        if frozenModel.blockID != f.blockID { frozenModel.reset() }
        frozenModel.blockID = f.blockID
        frozenModel.blockName = f.blockName
        frozenModel.endsAt = f.endsAt
        frozenModel.mode = f.mode
        frozenModel.lock = f.lock
        frozenModel.locked = f.locked
        // The measured skew wobbles with each poll; ignore that so the countdown can't jump.
        if abs(daemonSkew - frozenModel.skew) > 1 { frozenModel.skew = daemonSkew }
        if frozenWindows.isEmpty { freeze() }
        reassertFrozen()

        // Log out / shut down after a short countdown so the screen explains what's happening.
        if f.mode != .lockScreen, !frozenActionTaken, let start = frozenStartedAt, Date().timeIntervalSince(start) > 20 {
            frozenActionTaken = true
            let event = f.mode == .logout ? "«event aevtrlgo»" : "«event aevtrsdn»"
            NSAppleScript(source: "tell application \"loginwindow\" to \(event)")?.executeAndReturnError(nil)
        }
        frozenModel.actionAt = f.mode == .lockScreen ? nil : frozenStartedAt?.addingTimeInterval(20)
    }

    private func freeze() {
        frozenStartedAt = Date()
        frozenActionTaken = false
        frozenModel.send = { [weak self] req in
            Task.detached {
                let result = Result { try DaemonClient.send(req) }
                await MainActor.run {
                    switch result {
                    case .success(let r):
                        self?.frozenModel.message = nil
                        if let c = r.challenge { self?.frozenModel.challenge = c }
                    case .failure(let e):
                        self?.frozenModel.message = "\(e)"
                        if req.cmd == .solveChallenge { self?.frozenModel.challenge = nil }
                    }
                    self?.poll()
                }
            }
        }
        for screen in NSScreen.screens {
            let w = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.isOpaque = true
            w.backgroundColor = .black
            let host = NSHostingView(rootView: FrozenView(model: frozenModel))
            // The window must always match the screen. By default the hosting view resizes it to
            // fit the content, which can push everything below the bottom edge.
            host.sizingOptions = []
            w.contentView = host
            w.setFrame(screen.frame, display: true)
            w.makeKeyAndOrderFront(nil)
            frozenWindows.append(w)
        }
        reassertFrozen()
    }

    private func reassertFrozen() {
        guard !frozenWindows.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
                                     .disableSessionTermination, .disableHideApplication, .disableAppleMenu]
        for w in frozenWindows { w.orderFrontRegardless() }
    }

    private func unfreeze() {
        NSApp.presentationOptions = []
        for w in frozenWindows { w.orderOut(nil) }
        frozenWindows = []
        frozenStartedAt = nil
        frozenModel.reset()
    }
}

/// Borderless windows can't take keyboard focus by default; the freeze screen needs it for unlock text.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FrozenModel: ObservableObject {
    @Published var blockName = ""
    @Published var endsAt: Date?
    @Published var mode: FrozenMode = .lockScreen
    /// When a log out or shut down fires.
    @Published var actionAt: Date?
    @Published var blockID: UUID?
    @Published var lock: LockPolicy = .none
    @Published var locked = false
    @Published var challenge: String?
    @Published var message: String?
    @Published var skew: TimeInterval = 0
    var send: (Request) -> Void = { _ in }

    func reset() {
        challenge = nil
        message = nil
    }
}

/// Whole seconds until `end`. Keeps its own clock because every model update redraws the freeze
/// screen, and a timer created in a redrawn body starts over, so it missed ticks.
struct Countdown<Content: View>: View {
    let end: Date
    var skew: TimeInterval = 0
    @ViewBuilder let content: (Int) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            content(max(0, Int(end.timeIntervalSince(Date().addingTimeInterval(skew)).rounded(.up))))
        }
    }
}

struct FrozenView: View {
    @ObservedObject var model: FrozenModel

    var body: some View {
        ZStack {
            Pixel.bg.ignoresSafeArea()
            GeometryReader { geo in
                ScrollView {
                    content.frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollIndicators(.hidden)
            }
            Scanlines()
        }
    }

    private var content: some View {
        VStack(spacing: 30) {
            Sprites.snowflake(14)
            Text("FROZEN").font(Pixel.font(48)).foregroundStyle(Pixel.ice)
                .shadow(color: Pixel.cyan, radius: 0, x: 5, y: 5)
            Text(model.blockName.uppercased()).font(Pixel.font(14)).foregroundStyle(Pixel.inkDim)
            if let end = model.endsAt {
                Countdown(end: end, skew: model.skew) { s in
                    Text(clockString(s)).font(Pixel.font(36)).foregroundStyle(Pixel.yellow)
                }
            } else {
                Text("UNTIL UNLOCKED").font(Pixel.font(20)).foregroundStyle(Pixel.yellow)
            }
            if let at = model.actionAt {
                Countdown(end: at) { c in
                    Text(model.mode == .logout ? "LOGGING OUT IN \(c)" : "SHUTTING DOWN IN \(c)")
                        .font(Pixel.font(14)).foregroundStyle(Pixel.red)
                }
                .blinking()
            } else {
                Text("GO OUTSIDE. SEE YOU SOON.").font(Pixel.font(12)).foregroundStyle(Pixel.inkDim).blinking(0.8)
            }
            FrozenEscape(model: model)
                .padding(.top, 10)
        }
        .padding(.vertical, 24)
    }
}

/// The way out of a freeze, matching its lock: STOP when unlocked, an unlock challenge for
/// random-text and password locks, nothing for timer and restart locks.
struct FrozenEscape: View {
    @ObservedObject var model: FrozenModel
    @State private var typed = ""
    @State private var password = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 16) {
            if let id = model.blockID {
                if !model.locked {
                    Button("STOP FREEZE") { model.send(Request(.stopBlock, blockID: id)) }
                        .buttonStyle(PixelButtonStyle(color: Pixel.ice))
                } else {
                    locked(id)
                }
            }
            if let m = model.message {
                Text(m.uppercased()).font(Pixel.font(9)).foregroundStyle(Pixel.red)
                    .multilineTextAlignment(.center).frame(maxWidth: 640)
            }
        }
    }

    @ViewBuilder
    func locked(_ id: UUID) -> some View {
        switch model.lock {
        case .randomText:
            if let c = model.challenge {
                VStack(spacing: 10) {
                    Text("TYPE THIS EXACTLY:").font(Pixel.font(8)).foregroundStyle(Pixel.inkDim)
                    Text(c).font(Pixel.mono(16, weight: .bold)).foregroundStyle(Pixel.ink)
                        .frame(width: 640, alignment: .leading)
                    TextField("", text: $typed)
                        .textFieldStyle(.plain)
                        .font(Pixel.mono(16))
                        .focused($typing)
                        .onAppear { typing = true }
                        .padding(8).frame(width: 640)
                        .background(Pixel.panel).overlay(Rectangle().stroke(Pixel.panelHi, lineWidth: 2))
                        .onChange(of: typed) { old, new in
                            if new.count > old.count + 1 { typed = old; model.message = "No pasting! Type it." }
                        }
                    Button("SUBMIT (\(typed.count)/\(c.count))") {
                        model.send(Request(.solveChallenge, blockID: id, text: typed))
                        typed = ""
                    }
                    .buttonStyle(PixelButtonStyle(color: Pixel.yellow))
                    .disabled(typed.count != c.count)
                }
            } else {
                Button("UNLOCK") { model.send(Request(.requestChallenge, blockID: id)) }
                    .buttonStyle(PixelButtonStyle(color: Pixel.yellow))
            }
        case .password:
            HStack(spacing: 10) {
                PixelField(placeholder: "PASSWORD", text: $password, secure: true).frame(width: 300)
                Button("UNLOCK") {
                    model.send(Request(.submitPassword, blockID: id, text: password))
                    password = ""
                }
                .buttonStyle(PixelButtonStyle(color: Pixel.yellow))
                .disabled(password.isEmpty)
            }
        case .timer:
            Text("LOCKED IN: NO CONTINUES.").font(Pixel.font(9)).foregroundStyle(Pixel.inkMuted)
        case .restart:
            Text("RESTART YOUR MAC TO UNLOCK.").font(Pixel.font(9)).foregroundStyle(Pixel.inkMuted)
        case .none:
            EmptyView()
        }
    }
}
