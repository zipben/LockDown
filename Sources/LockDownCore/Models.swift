import Foundation

public struct AppRef: Codable, Hashable, Identifiable {
    public var bundleID: String
    public var name: String
    public var path: String?
    public var id: String { bundleID }

    public init(bundleID: String, name: String, path: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

/// A weekly time range. `weekday` uses Calendar numbering (1 = Sunday ... 7 = Saturday).
/// Minutes are from local midnight; `endMinute` may be 1440. Ranges never cross midnight.
public struct ScheduleRange: Codable, Hashable {
    public var weekday: Int
    public var startMinute: Int
    public var endMinute: Int

    public init(weekday: Int, startMinute: Int, endMinute: Int) {
        self.weekday = weekday
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public func contains(weekday w: Int, minute m: Int) -> Bool {
        w == weekday && m >= startMinute && m < endMinute
    }

    public func covers(_ other: ScheduleRange) -> Bool {
        weekday == other.weekday && startMinute <= other.startMinute && endMinute >= other.endMinute
    }
}

public enum BreakPolicy: Codable, Hashable {
    case none
    /// Cycle: block for `workMinutes`, then unblock for `breakMinutes`, repeating.
    case pomodoro(workMinutes: Int, breakMinutes: Int)
    /// A daily budget of unblocked minutes that can be spent on demand.
    case allowance(minutesPerDay: Int)
}

public enum LockPolicy: Codable, Hashable {
    /// Can be stopped or edited at any time.
    case none
    /// Cannot be stopped or loosened until the block ends on its own.
    case timer
    /// Unlockable by typing a freshly generated random string of `length` characters.
    case randomText(length: Int)
    /// Unlockable with a password (ideally one someone else holds). Only a salted hash is stored.
    case password(salt: String, hash: String)
    /// Unlockable only after the Mac has been restarted since the lock engaged.
    case restart

    public var label: String {
        switch self {
        case .none: return "NONE"
        case .timer: return "LOCKED IN"
        case .randomText(let n): return "RANDOM TEXT (\(n))"
        case .password: return "PASSWORD"
        case .restart: return "RESTART"
        }
    }

    /// Rank used to decide whether a lock change makes a block stricter.
    var strength: Int {
        switch self {
        case .none: return 0
        case .randomText, .password, .restart: return 1
        case .timer: return 2
        }
    }
}

public enum BlockKind: String, Codable, Hashable {
    case standard
    /// Locks the whole computer while active.
    case frozen
}

public enum FrozenMode: String, Codable, Hashable, CaseIterable {
    case lockScreen, logout, shutdown
}

/// Random Flicker: a freeze that turns itself on and off, drawing each window's length from these bounds.
public struct FlickerPolicy: Codable, Hashable {
    public var frozenMinMinutes: Int
    public var frozenMaxMinutes: Int
    public var freeMinMinutes: Int
    public var freeMaxMinutes: Int

    public init(frozenMinMinutes: Int = 10, frozenMaxMinutes: Int = 30, freeMinMinutes: Int = 30, freeMaxMinutes: Int = 90) {
        self.frozenMinMinutes = frozenMinMinutes
        self.frozenMaxMinutes = frozenMaxMinutes
        self.freeMinMinutes = freeMinMinutes
        self.freeMaxMinutes = freeMaxMinutes
    }
}

public struct Block: Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: BlockKind
    public var websites: [String]
    public var websiteExceptions: [String]
    /// Block every domain except `websiteExceptions`.
    public var blockEntireInternet: Bool
    public var apps: [AppRef]
    /// Hide apps whose frontmost window title contains one of these (case-insensitive).
    public var titleKeywords: [String]
    public var scheduleEnabled: Bool
    public var schedule: [ScheduleRange]
    /// Set on a freeze that runs by Random Flicker. Replaces the schedule, and is optional so state
    /// files from older versions still load.
    public var flicker: FlickerPolicy?
    /// Minutes after midnight when the block turns itself back on and relocks every day, undoing any
    /// unlock or stop. Standard blocks only, and optional so state files from older versions still load.
    public var reenableDailyMinute: Int?
    public var breakPolicy: BreakPolicy
    public var lock: LockPolicy
    /// When true, a locked scheduled or flickering block can't be loosened even while it isn't running.
    public var lockScheduleAlways: Bool
    public var frozenMode: FrozenMode

    public init(
        id: UUID = UUID(), name: String, kind: BlockKind = .standard,
        websites: [String] = [], websiteExceptions: [String] = [], blockEntireInternet: Bool = false,
        apps: [AppRef] = [], titleKeywords: [String] = [],
        scheduleEnabled: Bool = false, schedule: [ScheduleRange] = [], flicker: FlickerPolicy? = nil, reenableDailyMinute: Int? = nil,
        breakPolicy: BreakPolicy = .none, lock: LockPolicy = .none,
        lockScheduleAlways: Bool = false, frozenMode: FrozenMode = .lockScreen
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.websites = websites
        self.websiteExceptions = websiteExceptions
        self.blockEntireInternet = blockEntireInternet
        self.apps = apps
        self.titleKeywords = titleKeywords
        self.scheduleEnabled = scheduleEnabled
        self.schedule = schedule
        self.flicker = flicker
        self.reenableDailyMinute = reenableDailyMinute
        self.breakPolicy = breakPolicy
        self.lock = lock
        self.lockScheduleAlways = lockScheduleAlways
        self.frozenMode = frozenMode
    }

    /// Copy with the password hash removed, for sending to clients.
    public var redacted: Block {
        var b = self
        if case .password = b.lock { b.lock = .password(salt: "", hash: "") }
        return b
    }

    public var hasWebRules: Bool { blockEntireInternet || !websites.isEmpty }
}

/// A manually started run of a block.
public struct Session: Codable, Hashable {
    public var startedAt: Date
    /// nil = runs until stopped (only meaningful with an unlock method).
    public var endsAt: Date?

    public init(startedAt: Date, endsAt: Date?) {
        self.startedAt = startedAt
        self.endsAt = endsAt
    }
}

public struct GlobalSettings: Codable, Hashable {
    /// While any locked block is active, also quit these system tools.
    public var blockActivityMonitor: Bool = false
    public var blockTerminals: Bool = false
    public var blockSystemSettings: Bool = false
    /// Also firewall the IP addresses behind blocked domains (catches cached DNS and open connections;
    /// may block unrelated sites that share a CDN address).
    public var hardBlockIPs: Bool = false
    /// Upstream resolvers used after the network's own DHCP-provided servers.
    public var fallbackDNS: [String] = ["1.1.1.1", "9.9.9.9"]
    public var statsEnabled: Bool = true

    public init() {}
}

public enum StrictApps {
    public static let activityMonitor = ["com.apple.ActivityMonitor"]
    public static let terminals = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm", "com.apple.ScriptEditor2",
    ]
    public static let systemSettings = ["com.apple.systempreferences", "com.apple.Settings"]
}
