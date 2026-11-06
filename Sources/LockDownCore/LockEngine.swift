import CommonCrypto
import Foundation

/// Everything the daemon persists.
public struct EngineState: Codable {
    public var blocks: [Block] = []
    public var sessions: [UUID: Session] = [:]
    /// Active breaks (pomodoro rests are computed, so this is allowance breaks only): block -> end.
    public var breaks: [UUID: Date] = [:]
    /// "yyyy-MM-dd|<uuid>" -> allowance seconds spent that day.
    public var allowanceUsed: [String: Int] = [:]
    /// Boot session recorded when a restart-lock engaged.
    public var lockBoot: [UUID: String] = [:]
    /// Temporary unlocks granted after solving a challenge: block -> valid until.
    public var grants: [UUID: Date] = [:]
    /// Scheduled runs stopped early: block -> skip the schedule until this time (the window's end).
    public var skips: [UUID: Date] = [:]
    /// Consecutive restarts during a running freeze, for the emergency escape.
    public var freezeRestarts: FreezeRestarts?
    /// The current window of each flickering block.
    public var flickerPhases: [UUID: FlickerPhase] = [:]
    /// When each block's daily re-enable was last checked, so a time missed while asleep still fires.
    public var reenableChecked: [UUID: Date] = [:]
    public var settings = GlobalSettings()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case blocks, sessions, breaks, allowanceUsed, lockBoot, grants, skips, freezeRestarts, flickerPhases, reenableChecked, settings
    }

    /// Tolerates missing keys so state files from older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocks = try c.decodeIfPresent([Block].self, forKey: .blocks) ?? []
        sessions = try c.decodeIfPresent([UUID: Session].self, forKey: .sessions) ?? [:]
        breaks = try c.decodeIfPresent([UUID: Date].self, forKey: .breaks) ?? [:]
        allowanceUsed = try c.decodeIfPresent([String: Int].self, forKey: .allowanceUsed) ?? [:]
        lockBoot = try c.decodeIfPresent([UUID: String].self, forKey: .lockBoot) ?? [:]
        grants = try c.decodeIfPresent([UUID: Date].self, forKey: .grants) ?? [:]
        skips = try c.decodeIfPresent([UUID: Date].self, forKey: .skips) ?? [:]
        freezeRestarts = try c.decodeIfPresent(FreezeRestarts.self, forKey: .freezeRestarts)
        flickerPhases = try c.decodeIfPresent([UUID: FlickerPhase].self, forKey: .flickerPhases) ?? [:]
        reenableChecked = try c.decodeIfPresent([UUID: Date].self, forKey: .reenableChecked) ?? [:]
        settings = try c.decodeIfPresent(GlobalSettings.self, forKey: .settings) ?? GlobalSettings()
    }
}

public struct FreezeRestarts: Codable, Equatable {
    public var bootID: String
    public var at: Date
    public var count: Int
}

public struct FlickerPhase: Codable, Equatable {
    public var frozen: Bool
    public var startedAt: Date
    public var endsAt: Date
}

/// What a block is doing right now.
public struct Activity: Codable, Hashable {
    public enum Source: String, Codable { case none, timer, schedule, flicker }
    public var source: Source
    /// True while the block's rules are being enforced (running and not on a break).
    public var enforcing: Bool
    /// When the current run (timer or contiguous schedule window) ends; nil if open-ended.
    public var endsAt: Date?
    public var breakEndsAt: Date?
    public var nextBreakAt: Date?

    public static let idle = Activity(source: .none, enforcing: false)

    public init(source: Source, enforcing: Bool, endsAt: Date? = nil, breakEndsAt: Date? = nil, nextBreakAt: Date? = nil) {
        self.source = source
        self.enforcing = enforcing
        self.endsAt = endsAt
        self.breakEndsAt = breakEndsAt
        self.nextBreakAt = nextBreakAt
    }

    public var running: Bool { source != .none }
}

public struct FrozenEnforcement: Codable, Hashable {
    public var blockID: UUID
    public var blockName: String
    public var mode: FrozenMode
    public var endsAt: Date?
    /// The block's lock with any password hash removed; the freeze screen offers the matching way out.
    public var lock: LockPolicy
    public var locked: Bool
}

/// The rules every enforcer (DNS, pf, agent) should apply right now.
public struct Enforcement: Codable, Hashable {
    public var web: [WebPolicy] = []
    public var apps: [AppRef] = []
    public var titleKeywords: [String] = []
    public var frozen: FrozenEnforcement?
    /// System tools to quit because a locked block is active and strict settings ask for it.
    public var strictBundleIDs: [String] = []
    public var anyLocked = false
    public var hardBlockIPs = false

    public init() {}

    public var hasWebRules: Bool { web.contains { !$0.isEmpty } }
}

public enum EngineError: Error, CustomStringConvertible, Equatable {
    case notFound
    case locked(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .notFound: return "Block not found."
        case .locked(let s): return s
        case .invalid(let s): return s
        }
    }
}

public struct LockEngine {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: Activity

    public func activity(of block: Block, in state: EngineState, now: Date) -> Activity {
        var source = Activity.Source.none
        var start: Date?
        var end: Date?

        if let s = state.sessions[block.id], s.endsAt.map({ now < $0 }) ?? true, s.startedAt <= now {
            source = .timer
            start = s.startedAt
            end = s.endsAt
        }
        let skipped = state.skips[block.id].map { now < $0 } ?? false
        if block.scheduleEnabled, !skipped, let window = scheduleWindow(block.schedule, at: now) {
            if source == .none {
                source = .schedule
                start = window.start
                end = window.end
            } else if let e = end {
                end = max(e, window.end)
            }
        }
        if block.flicker != nil, let phase = state.flickerPhases[block.id], phase.frozen, now < phase.endsAt {
            if source == .none {
                source = .flicker
                start = phase.startedAt
                end = phase.endsAt
            } else if let e = end {
                end = max(e, phase.endsAt)
            }
        }
        guard source != .none, let runStart = start else { return .idle }

        if let b = state.breaks[block.id], b > now {
            return Activity(source: source, enforcing: false, endsAt: end, breakEndsAt: end.map { min($0, b) } ?? b)
        }
        if case let .pomodoro(work, rest) = block.breakPolicy, work > 0, rest > 0 {
            let cycle = Double(work + rest) * 60
            let pos = now.timeIntervalSince(runStart).truncatingRemainder(dividingBy: cycle)
            let cycleStart = now.addingTimeInterval(-pos)
            let restStart = cycleStart.addingTimeInterval(Double(work) * 60)
            if now >= restStart {
                let restEnd = cycleStart.addingTimeInterval(cycle)
                return Activity(source: source, enforcing: false, endsAt: end, breakEndsAt: end.map { min($0, restEnd) } ?? restEnd)
            }
            return Activity(source: source, enforcing: true, endsAt: end, nextBreakAt: restStart)
        }
        return Activity(source: source, enforcing: true, endsAt: end)
    }

    /// Call on every tick. Starts the next flicker window for any block whose window has ended, with
    /// a new length drawn from its bounds. A new flicker starts free, so saving it can't lock you out
    /// straight away. Returns true if anything changed.
    public func advanceFlicker<R: RandomNumberGenerator>(_ state: inout EngineState, now: Date, using rng: inout R) -> Bool {
        var changed = false
        for block in state.blocks {
            guard let policy = block.flicker else {
                if state.flickerPhases.removeValue(forKey: block.id) != nil { changed = true }
                continue
            }
            let current = state.flickerPhases[block.id]
            if let current, now < current.endsAt { continue }
            let frozen = current.map { !$0.frozen } ?? false
            let (low, high) = frozen ? (policy.frozenMinMinutes, policy.frozenMaxMinutes) : (policy.freeMinMinutes, policy.freeMaxMinutes)
            let seconds = Int.random(in: (low * 60)...(max(low, high) * 60), using: &rng)
            state.flickerPhases[block.id] = FlickerPhase(frozen: frozen, startedAt: now, endsAt: now.addingTimeInterval(Double(seconds)))
            changed = true
        }
        return changed
    }

    public func advanceFlicker(_ state: inout EngineState, now: Date) -> Bool {
        var rng = SystemRandomNumberGenerator()
        return advanceFlicker(&state, now: now, using: &rng)
    }

    /// Call on every tick. When a block's daily re-enable time has passed, relocks it and turns it back
    /// on until it's next unlocked. A scheduled block keeps to its hours, so it only gets skipped hours
    /// back. Returns the blocks it re-enabled.
    public func applyDailyReenable(_ state: inout EngineState, now: Date) -> [Block] {
        var reenabled: [Block] = []
        for block in state.blocks {
            guard let minute = block.reenableDailyMinute else {
                state.reenableChecked[block.id] = nil
                continue
            }
            guard let last = state.reenableChecked[block.id] else {
                state.reenableChecked[block.id] = now
                continue
            }
            var due = date(on: now, minute: minute)
            if due > now { due = date(on: calendar.date(byAdding: .day, value: -1, to: due) ?? due, minute: minute) }
            guard last < due else { continue }
            state.reenableChecked[block.id] = now
            state.grants[block.id] = nil
            state.skips[block.id] = nil
            state.lockBoot[block.id] = nil
            if !block.scheduleEnabled {
                state.sessions[block.id] = Session(startedAt: state.sessions[block.id]?.startedAt ?? now, endsAt: nil)
            }
            reenabled.append(block)
        }
        return reenabled
    }

    /// The contiguous scheduled window containing `date`, following ranges across midnight.
    public func scheduleWindow(_ ranges: [ScheduleRange], at date: Date) -> (start: Date, end: Date)? {
        guard rangeContaining(ranges, date) != nil else { return nil }
        var end = date
        for _ in 0..<(7 * 48) {
            guard let r = rangeContaining(ranges, end) else { break }
            end = self.date(on: end, minute: r.endMinute)
        }
        var start = date
        for _ in 0..<(7 * 48) {
            guard let r = rangeContaining(ranges, start) else { break }
            let s = self.date(on: start, minute: r.startMinute)
            start = s
            let probe = s.addingTimeInterval(-1)
            if rangeContaining(ranges, probe) == nil { break }
            start = probe
        }
        return (start, end)
    }

    /// When the next contiguous window begins, strictly after `date`. nil for an empty schedule.
    public func nextScheduleStart(_ ranges: [ScheduleRange], after date: Date) -> Date? {
        let midnight = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: midnight) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            for r in ranges.filter({ $0.weekday == weekday }).sorted(by: { $0.startMinute < $1.startMinute }) {
                let start = self.date(on: day, minute: r.startMinute)
                if start > date, rangeContaining(ranges, start.addingTimeInterval(-1)) == nil { return start }
            }
        }
        return nil
    }

    func rangeContaining(_ ranges: [ScheduleRange], _ date: Date) -> ScheduleRange? {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return ranges.first { $0.contains(weekday: c.weekday ?? 1, minute: minute) }
    }

    func date(on day: Date, minute: Int) -> Date {
        let midnight = calendar.startOfDay(for: day)
        if minute >= 1440 {
            return calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(86400)
        }
        return calendar.date(byAdding: .minute, value: minute, to: midnight) ?? midnight
    }

    // MARK: Locks

    public func isLocked(_ block: Block, in state: EngineState, now: Date, bootID: String) -> Bool {
        if block.lock == .none { return false }
        if let g = state.grants[block.id], g > now { return false }
        let running = activity(of: block, in: state, now: now).running
        guard running || locksBetweenRuns(block) else { return false }
        if case .restart = block.lock, let b = state.lockBoot[block.id], b != bootID { return false }
        return true
    }

    func locksBetweenRuns(_ block: Block) -> Bool {
        block.lockScheduleAlways && (block.flicker != nil || block.reenableDailyMinute != nil || (block.scheduleEnabled && !block.schedule.isEmpty))
    }

    public func lockReason(_ block: Block) -> String {
        switch block.lock {
        case .none: return ""
        case .timer: return "Locked until the block ends."
        case .randomText(let n): return "Type \(n) random characters to unlock."
        case .password: return "Enter the password to unlock."
        case .restart: return "Restart your Mac to unlock."
        }
    }

    /// Records restart-lock boot sessions and clears stale state. Call on every tick.
    public func housekeep(_ state: inout EngineState, now: Date, bootID: String) {
        for block in state.blocks {
            let act = activity(of: block, in: state, now: now)
            if case .restart = block.lock, act.running || locksBetweenRuns(block) {
                if state.lockBoot[block.id] == nil { state.lockBoot[block.id] = bootID }
            } else {
                state.lockBoot[block.id] = nil
            }
        }
        state.sessions = state.sessions.filter { $0.value.endsAt.map { $0 > now } ?? true }
        state.breaks = state.breaks.filter { $0.value > now }
        state.grants = state.grants.filter { $0.value > now }
        state.skips = state.skips.filter { $0.value > now }
        let today = dayKey(now)
        let weekAgo = dayKey(now.addingTimeInterval(-7 * 86400))
        state.allowanceUsed = state.allowanceUsed.filter { String($0.key.prefix(10)) >= weekAgo || $0.key.hasPrefix(today) }
    }

    /// True if `new` is at least as strict as `old`: a locked block may only change this way.
    public func isStricter(_ new: Block, than old: Block) -> Bool {
        func norm(_ a: [String]) -> Set<String> { Set(a.compactMap(DomainMatcher.normalizeEntry)) }
        func lower(_ a: [String]) -> Set<String> { Set(a.map { $0.lowercased() }) }

        guard new.kind == old.kind, new.frozenMode == old.frozenMode else { return false }
        guard norm(new.websites).isSuperset(of: norm(old.websites)) else { return false }
        guard norm(new.websiteExceptions).isSubset(of: norm(old.websiteExceptions)) else { return false }
        if old.blockEntireInternet && !new.blockEntireInternet { return false }
        guard Set(new.apps.map(\.bundleID)).isSuperset(of: old.apps.map(\.bundleID)) else { return false }
        guard lower(new.titleKeywords).isSuperset(of: lower(old.titleKeywords)) else { return false }
        if old.scheduleEnabled {
            guard new.scheduleEnabled else { return false }
            for r in old.schedule where !new.schedule.contains(where: { $0.covers(r) }) { return false }
        }
        if let o = old.flicker {
            guard let n = new.flicker,
                  n.frozenMinMinutes >= o.frozenMinMinutes, n.frozenMaxMinutes >= o.frozenMaxMinutes,
                  n.freeMinMinutes <= o.freeMinMinutes, n.freeMaxMinutes <= o.freeMaxMinutes else { return false }
        }
        if let o = old.reenableDailyMinute, new.reenableDailyMinute != o { return false }
        switch (old.breakPolicy, new.breakPolicy) {
        case (_, .none): break
        case (.none, _): return false
        case let (.pomodoro(ow, ob), .pomodoro(nw, nb)): if nw < ow || nb > ob { return false }
        case let (.allowance(o), .allowance(n)): if n > o { return false }
        default: return false
        }
        if new.lock != old.lock && new.lock.strength <= old.lock.strength { return false }
        if old.lockScheduleAlways && !new.lockScheduleAlways { return false }
        return true
    }

    // MARK: Mutations

    public func save(_ incoming: Block, newPassword: String?, into state: inout EngineState, now: Date, bootID: String) throws {
        var block = incoming
        block.websites = block.websites.compactMap(DomainMatcher.normalizeEntry)
        block.websiteExceptions = block.websiteExceptions.compactMap(DomainMatcher.normalizeEntry)
        block.titleKeywords = block.titleKeywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        block.name = block.name.trimmingCharacters(in: .whitespaces)
        if block.name.isEmpty { block.name = "UNTITLED" }
        if case .randomText(let n) = block.lock, !(1...500).contains(n) {
            throw EngineError.invalid("Random text length must be 1-500.")
        }
        if case let .pomodoro(w, b) = block.breakPolicy, w < 1 || b < 1 {
            throw EngineError.invalid("Pomodoro minutes must be at least 1.")
        }

        if block.kind != .frozen { block.flicker = nil }
        if let f = block.flicker {
            block.scheduleEnabled = false
            guard f.frozenMinMinutes >= 1, f.freeMinMinutes >= 1 else {
                throw EngineError.invalid("Flicker windows must be at least 1 minute.")
            }
            guard f.frozenMinMinutes <= f.frozenMaxMinutes, f.freeMinMinutes <= f.freeMaxMinutes else {
                throw EngineError.invalid("A flicker window's lower bound can't be above its upper bound.")
            }
        }

        if block.kind == .frozen { block.reenableDailyMinute = nil }
        if let m = block.reenableDailyMinute {
            guard (0..<1440).contains(m) else { throw EngineError.invalid("Re-enable time must be within the day.") }
            if block.lock == .timer {
                throw EngineError.invalid("Re-enable daily needs a lock you can unlock. Locked in has no unlock.")
            }
        }

        let existing = state.blocks.firstIndex { $0.id == block.id }
        if case .password = block.lock {
            if let pw = newPassword, !pw.isEmpty {
                let salt = LockEngine.randomString(16, charset: Array("abcdef0123456789"))
                block.lock = .password(salt: salt, hash: LockEngine.hash(pw, salt: salt))
            } else if let i = existing, case .password = state.blocks[i].lock {
                block.lock = state.blocks[i].lock
            } else {
                throw EngineError.invalid("Set a password for the password lock.")
            }
        }

        let oldReenable = existing.flatMap { state.blocks[$0].reenableDailyMinute }
        if let i = existing {
            let old = state.blocks[i]
            if isLocked(old, in: state, now: now, bootID: bootID) && !isStricter(block, than: old) {
                throw EngineError.locked("\(old.name) is locked. You can only make it stricter. \(lockReason(old))")
            }
            state.blocks[i] = block
        } else {
            state.blocks.append(block)
        }
        // A new time counts from now, so it can't fire for a time that's already gone by today.
        if oldReenable != block.reenableDailyMinute { state.reenableChecked[block.id] = nil }
        // New bounds apply from the next window, but the current one mustn't outlast them.
        if let f = block.flicker, let phase = state.flickerPhases[block.id] {
            let limit = now.addingTimeInterval(Double(phase.frozen ? f.frozenMaxMinutes : f.freeMaxMinutes) * 60)
            if phase.endsAt > limit { state.flickerPhases[block.id]?.endsAt = limit }
        }
    }

    public func delete(_ id: UUID, from state: inout EngineState, now: Date, bootID: String) throws {
        guard let i = state.blocks.firstIndex(where: { $0.id == id }) else { throw EngineError.notFound }
        let b = state.blocks[i]
        if isLocked(b, in: state, now: now, bootID: bootID) {
            throw EngineError.locked("\(b.name) is locked and can't be deleted. \(lockReason(b))")
        }
        state.blocks.remove(at: i)
        state.sessions[id] = nil
        state.breaks[id] = nil
        state.grants[id] = nil
        state.lockBoot[id] = nil
        state.flickerPhases[id] = nil
        state.reenableChecked[id] = nil
    }

    /// Starts (or extends) a timed run. `endsAt` nil = until stopped.
    public func start(_ id: UUID, endsAt: Date?, in state: inout EngineState, now: Date, bootID: String) throws {
        guard let b = state.blocks.first(where: { $0.id == id }) else { throw EngineError.notFound }
        if let e = endsAt, e <= now { throw EngineError.invalid("End time must be in the future.") }
        if endsAt == nil, b.lock == .timer {
            throw EngineError.invalid("A locked-in block needs an end time.")
        }
        if b.flicker != nil, state.sessions[id] == nil {
            throw EngineError.invalid("\(b.name) runs on Random Flicker. Switch it to manual to start it yourself.")
        }
        if b.scheduleEnabled, state.sessions[id] == nil {
            throw EngineError.invalid("\(b.name) runs on its schedule. Switch it to manual to start it yourself.")
        }
        if let current = state.sessions[id], isLocked(b, in: state, now: now, bootID: bootID) {
            // Locked runs can only be extended.
            switch (current.endsAt, endsAt) {
            case (nil, _): return
            case let (c?, n?) where n < c:
                throw EngineError.locked("\(b.name) is locked. You can extend it but not shorten it.")
            default: break
            }
            state.sessions[id]?.endsAt = endsAt
            return
        }
        state.sessions[id] = Session(startedAt: state.sessions[id]?.startedAt ?? now, endsAt: endsAt)
        state.breaks[id] = nil
        state.skips[id] = nil
    }

    public func stop(_ id: UUID, in state: inout EngineState, now: Date, bootID: String) throws {
        guard let b = state.blocks.first(where: { $0.id == id }) else { throw EngineError.notFound }
        if isLocked(b, in: state, now: now, bootID: bootID) {
            throw EngineError.locked("\(b.name) is locked. \(lockReason(b))")
        }
        endRun(b, in: &state, now: now)
    }

    private func endRun(_ b: Block, in state: inout EngineState, now: Date) {
        state.sessions[b.id] = nil
        state.breaks[b.id] = nil
        // Stopping during a scheduled window skips the rest of that window.
        if b.scheduleEnabled, let window = scheduleWindow(b.schedule, at: now) {
            state.skips[b.id] = window.end
        }
        // Stopping during a flicker freeze ends that freeze. The next tick starts a free window.
        if b.flicker != nil, state.flickerPhases[b.id]?.frozen == true {
            state.flickerPhases[b.id]?.endsAt = now
        }
    }

    /// Restarts in a row that end a running freeze, whatever its lock. A freeze survives reboots,
    /// so without this a broken freeze screen could only be escaped through Safe Mode.
    public static let freezeEscapeRestarts = 3
    /// A restart only continues the chain if it comes within this long of the previous boot.
    public static let freezeRestartWindow: TimeInterval = 600

    /// Call on every tick. Counts a new boot during a running freeze and, on the last restart,
    /// ends every running freeze. Returns the blocks it ended.
    public func escapeFreezeAfterRestarts(_ state: inout EngineState, now: Date, bootID: String) -> [Block] {
        let frozen = state.blocks.filter { $0.kind == .frozen && activity(of: $0, in: state, now: now).running }
        guard !frozen.isEmpty else {
            state.freezeRestarts = nil
            return []
        }
        guard let last = state.freezeRestarts else {
            state.freezeRestarts = FreezeRestarts(bootID: bootID, at: now, count: 0)
            return []
        }
        guard last.bootID != bootID else { return [] }
        let count = now.timeIntervalSince(last.at) <= Self.freezeRestartWindow ? last.count + 1 : 1
        guard count >= Self.freezeEscapeRestarts else {
            state.freezeRestarts = FreezeRestarts(bootID: bootID, at: now, count: count)
            return []
        }
        state.freezeRestarts = nil
        for b in frozen { endRun(b, in: &state, now: now) }
        // Flicker would freeze again within minutes, so the escape turns it off altogether.
        for i in state.blocks.indices where frozen.contains(where: { $0.id == state.blocks[i].id }) {
            state.blocks[i].flicker = nil
        }
        return frozen
    }

    public func allowanceRemaining(_ block: Block, in state: EngineState, now: Date) -> Int? {
        guard case .allowance(let perDay) = block.breakPolicy else { return nil }
        let used = state.allowanceUsed[dayKey(now) + "|" + block.id.uuidString] ?? 0
        return max(0, perDay * 60 - used)
    }

    public func takeBreak(_ id: UUID, minutes: Int, in state: inout EngineState, now: Date) throws {
        guard let b = state.blocks.first(where: { $0.id == id }) else { throw EngineError.notFound }
        guard let remaining = allowanceRemaining(b, in: state, now: now) else {
            throw EngineError.invalid("\(b.name) has no allowance.")
        }
        guard minutes > 0 else { throw EngineError.invalid("Pick at least one minute.") }
        guard activity(of: b, in: state, now: now).enforcing else {
            throw EngineError.invalid("\(b.name) isn't blocking right now.")
        }
        guard minutes * 60 <= remaining else {
            throw EngineError.invalid("Only \(remaining / 60) allowance minutes left today.")
        }
        state.breaks[id] = now.addingTimeInterval(Double(minutes) * 60)
        state.allowanceUsed[dayKey(now) + "|" + id.uuidString, default: 0] += minutes * 60
    }

    /// Ends an allowance break early and refunds the unused whole minutes.
    public func endBreak(_ id: UUID, in state: inout EngineState, now: Date) {
        guard let end = state.breaks[id] else { return }
        let unused = Int(end.timeIntervalSince(now)) / 60 * 60
        state.breaks[id] = nil
        let key = dayKey(now) + "|" + id.uuidString
        if let used = state.allowanceUsed[key] { state.allowanceUsed[key] = max(0, used - unused) }
    }

    // MARK: Unlocking

    public func verifyPassword(_ id: UUID, password: String, in state: inout EngineState, now: Date) throws {
        guard let b = state.blocks.first(where: { $0.id == id }) else { throw EngineError.notFound }
        guard case let .password(salt, hash) = b.lock else { throw EngineError.invalid("Not a password lock.") }
        guard LockEngine.hash(password, salt: salt) == hash else { throw EngineError.locked("Wrong password.") }
        state.grants[id] = now.addingTimeInterval(LockEngine.grantSeconds)
    }

    public func grant(_ id: UUID, in state: inout EngineState, now: Date) {
        state.grants[id] = now.addingTimeInterval(LockEngine.grantSeconds)
    }

    /// How long a solved challenge keeps a block unlocked.
    public static let grantSeconds: TimeInterval = 180

    // MARK: Enforcement

    public func enforcement(for state: EngineState, now: Date, bootID: String) -> Enforcement {
        var e = Enforcement()
        var apps: [String: AppRef] = [:]
        var keywords = Set<String>()
        e.hardBlockIPs = state.settings.hardBlockIPs
        for b in state.blocks {
            let act = activity(of: b, in: state, now: now)
            if isLocked(b, in: state, now: now, bootID: bootID) && act.running { e.anyLocked = true }
            guard act.enforcing else { continue }
            if b.kind == .frozen {
                // The longest-running frozen block wins (nil end = open-ended).
                let later: Bool
                switch (e.frozen?.endsAt, act.endsAt) {
                case let (cur?, new?): later = new > cur
                case (.some, nil): later = true
                default: later = e.frozen == nil
                }
                if later {
                    e.frozen = FrozenEnforcement(blockID: b.id, blockName: b.name, mode: b.frozenMode, endsAt: act.endsAt,
                                                 lock: b.redacted.lock, locked: isLocked(b, in: state, now: now, bootID: bootID))
                }
                continue
            }
            if b.hasWebRules {
                e.web.append(WebPolicy(blocked: b.websites, exceptions: b.websiteExceptions, blockAll: b.blockEntireInternet))
            }
            for a in b.apps { apps[a.bundleID] = a }
            for k in b.titleKeywords { keywords.insert(k.lowercased()) }
        }
        e.apps = apps.values.sorted { $0.name < $1.name }
        e.titleKeywords = keywords.sorted()
        if e.anyLocked {
            let s = state.settings
            if s.blockActivityMonitor { e.strictBundleIDs += StrictApps.activityMonitor }
            if s.blockTerminals { e.strictBundleIDs += StrictApps.terminals }
            if s.blockSystemSettings { e.strictBundleIDs += StrictApps.systemSettings }
        }
        return e
    }

    // MARK: Helpers

    public func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static let challengeCharset = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%&*?")

    public static func randomString(_ n: Int, charset: [Character] = challengeCharset) -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in charset.randomElement(using: &g)! })
    }

    public static func hash(_ password: String, salt: String) -> String {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8).map { Int8(bitPattern: $0) }
        let s = Array(salt.utf8)
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, s, s.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 100_000, &out, out.count)
        return out.map { String(format: "%02x", $0) }.joined()
    }
}
