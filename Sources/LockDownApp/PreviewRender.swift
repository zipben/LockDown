import AppKit
import LockDownCore
import SwiftUI

/// `LockDown --render-preview <dir>` writes PNGs of the main screens with sample data, for checking
/// layout without a running daemon or Screen Recording permission.
enum PreviewRender {
    @MainActor
    static func run(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = Date()
        var social = Block(name: "Social Media", websites: ["reddit.com", "x.com", "*tube*"], websiteExceptions: ["old.reddit.com/r/swift"],
                           apps: [AppRef(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", path: "/Applications/Slack.app")],
                           titleKeywords: ["twitch"], scheduleEnabled: true,
                           schedule: (2...6).map { ScheduleRange(weekday: $0, startMinute: 540, endMinute: 1020) },
                           breakPolicy: .pomodoro(workMinutes: 25, breakMinutes: 5), lock: .randomText(length: 60))
        social.lockScheduleAlways = true
        let games = Block(name: "Games", apps: [AppRef(bundleID: "com.valvesoftware.steam", name: "Steam")], breakPolicy: .allowance(minutesPerDay: 30), lock: .timer)
        let frozen = Block(name: "Bedtime", kind: .frozen, frozenMode: .lockScreen)
        var stats = StatsSummary()
        let keyFmt = DateFormatter(), labelFmt = DateFormatter()
        keyFmt.dateFormat = "yyyy-MM-dd"
        labelFmt.dateFormat = "MM-dd"
        stats.blockedByDay = (0..<7).map { i in
            let day = Calendar.current.date(byAdding: .day, value: i - 6, to: now)!
            return StatRow(key: keyFmt.string(from: day), label: labelFmt.string(from: day), value: [12, 30, 8, 44, 21, 5, 17][i])
        }
        stats.blockedToday = [StatRow(key: "reddit.com", label: "reddit.com", value: 14), StatRow(key: "youtube.com", label: "youtube.com", value: 3)]
        stats.appsBlockedToday = [StatRow(key: "com.valvesoftware.steam", label: "Steam", value: 2)]
        stats.appTimeToday = [StatRow(key: "com.apple.dt.Xcode", label: "Xcode", value: 9000), StatRow(key: "com.apple.Safari", label: "Safari", value: 2400)]
        var health = FilterHealth()
        health.dnsServerRunning = true
        health.systemDNSRedirected = true
        health.firewallLoaded = true
        health.upstreams = ["75.75.75.75", "1.1.1.1"]
        let snap = Snapshot(now: now, blocks: [
            BlockStatus(block: social, activity: Activity(source: .schedule, enforcing: true, endsAt: now.addingTimeInterval(5400), nextBreakAt: now.addingTimeInterval(840)), locked: true, lockReason: "", allowanceRemaining: nil),
            BlockStatus(block: games, activity: Activity(source: .timer, enforcing: false, endsAt: now.addingTimeInterval(7200), breakEndsAt: now.addingTimeInterval(300)), locked: true, lockReason: "", allowanceRemaining: 1500),
            BlockStatus(block: frozen, activity: .idle, locked: false, lockReason: "", allowanceRemaining: nil),
        ], settings: GlobalSettings(), health: health, stats: stats, anyLocked: true)

        let focus = Block(name: "Focus Time", websites: ["reddit.com", "news.ycombinator.com", "x.com", "*tube*"], websiteExceptions: ["docs.python.org"],
                          apps: [AppRef(bundleID: "com.valvesoftware.steam", name: "Steam"), AppRef(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")],
                          lock: .randomText(length: 60))
        let running = Snapshot(now: now, blocks: [
            BlockStatus(block: focus, activity: Activity(source: .timer, enforcing: true, endsAt: now.addingTimeInterval(3600)), locked: true, lockReason: "", allowanceRemaining: nil),
        ], settings: GlobalSettings(), health: health, stats: stats, anyLocked: true)

        let flicker = Block(name: "Flicker", kind: .frozen, flicker: FlickerPolicy(), lock: .randomText(length: 40), lockScheduleAlways: true)
        let flickering = Snapshot(now: now, blocks: [
            BlockStatus(block: flicker, activity: .idle, locked: true, lockReason: "", allowanceRemaining: nil),
        ], settings: GlobalSettings(), health: health, stats: stats, anyLocked: false)

        let tabs: [(String, Tab, Snapshot?)] = [("blocks", .blocks, snap), ("running", .blocks, running), ("flicker", .blocks, flickering), ("stats", .stats, snap), ("options", .settings, snap), ("insert-coin", .blocks, nil)]
        for (name, tab, s) in tabs {
            let store = Store(preview: s)
            let root = ContentView(initialTab: tab).environmentObject(store)
            save(root, size: CGSize(width: 1400, height: 1000), to: "\(dir)/\(name).png")
        }
        for (name, lock, locked, challenge) in [("frozen-unlocked", LockPolicy.none, false, nil as String?),
                                                ("frozen-random", .randomText(length: 40), true, LockEngine.randomString(40)),
                                                ("frozen-timer", .timer, true, nil)] {
            let model = FrozenModel()
            model.blockID = frozen.id
            model.blockName = "Bedtime"
            model.endsAt = now.addingTimeInterval(3723)
            model.lock = lock
            model.locked = locked
            model.challenge = challenge
            save(FrozenView(model: model), size: CGSize(width: 1100, height: 760), to: "\(dir)/\(name).png")
        }
    }

    @MainActor
    static func save<V: View>(_ view: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
