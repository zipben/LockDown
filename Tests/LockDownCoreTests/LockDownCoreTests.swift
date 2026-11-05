import XCTest
@testable import LockDownCore

final class DomainMatcherTests: XCTestCase {
    func testSuffixMatchesSubdomains() {
        let m = DomainMatcher(["reddit.com"])
        XCTAssertTrue(m.matches("reddit.com"))
        XCTAssertTrue(m.matches("old.reddit.com."))
        XCTAssertFalse(m.matches("notreddit.com"))
    }

    func testURLEntriesReduceToHost() {
        XCTAssertEqual(DomainMatcher.normalizeEntry("https://www.YouTube.com:443/shorts?x=1"), "www.youtube.com")
        XCTAssertTrue(DomainMatcher.entryHasPath("youtube.com/shorts"))
        XCTAssertFalse(DomainMatcher.entryHasPath("youtube.com/"))
        XCTAssertNil(DomainMatcher.normalizeEntry("  # comment"))
    }

    func testGlob() {
        let m = DomainMatcher(["*tube*", "*.example.org"])
        XCTAssertTrue(m.matches("www.youtube.com"))
        XCTAssertTrue(m.matches("a.example.org"))
        XCTAssertTrue(m.matches("example.org"))
        XCTAssertFalse(m.matches("google.com"))
    }

    func testExceptionsAndBlockAll() {
        let p = CompiledWebPolicy(WebPolicy(blocked: [], exceptions: ["github.com"], blockAll: true))
        XCTAssertFalse(p.isBlocked("api.github.com"))
        XCTAssertTrue(p.isBlocked("news.ycombinator.com"))
    }
}

final class RunModeTests: XCTestCase {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    var e: LockEngine {
        var e = LockEngine()
        e.calendar = cal
        return e
    }
    /// 2026-11-04 is a Wednesday (weekday 4).
    func wed(_ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: h, minute: m))!
    }

    func testScheduledBlockCantBeStartedByHand() throws {
        let b = Block(name: "S", websites: ["x.com"], scheduleEnabled: true,
                      schedule: [ScheduleRange(weekday: 4, startMinute: 960, endMinute: 990)])
        var s = EngineState()
        s.blocks = [b]
        XCTAssertThrowsError(try e.start(b.id, endsAt: wed(15), in: &s, now: wed(14), bootID: "A"))
        XCTAssertFalse(e.activity(of: b, in: s, now: wed(14)).running)
        XCTAssertTrue(e.activity(of: b, in: s, now: wed(16)).enforcing)
    }

    func testNextScheduleStart() {
        let r = [ScheduleRange(weekday: 4, startMinute: 960, endMinute: 990), ScheduleRange(weekday: 2, startMinute: 0, endMinute: 30)]
        XCTAssertEqual(e.nextScheduleStart(r, after: wed(15, 56)), wed(16))
        // During or just after today's window, the next one is Monday's.
        let monday = cal.date(byAdding: .day, value: 5, to: wed(0))!
        XCTAssertEqual(e.nextScheduleStart(r, after: wed(16, 10)), monday)
        XCTAssertNil(e.nextScheduleStart([], after: wed(16)))
    }

    func testNextScheduleStartSkipsContinuationPastMidnight() {
        let r = [ScheduleRange(weekday: 4, startMinute: 1320, endMinute: 1440), ScheduleRange(weekday: 5, startMinute: 0, endMinute: 420)]
        let next = e.nextScheduleStart(r, after: wed(23))
        XCTAssertEqual(next, cal.date(byAdding: .day, value: 7, to: wed(22)))
    }
}

final class FreezeEscapeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let e = LockEngine()

    /// A random-text freeze running for a day, first seen on boot "A".
    func frozen() throws -> (Block, EngineState) {
        var b = Block(name: "F", kind: .frozen)
        b.lock = .randomText(length: 5)
        var s = EngineState()
        s.blocks = [b]
        try e.start(b.id, endsAt: t0.addingTimeInterval(86400), in: &s, now: t0, bootID: "A")
        XCTAssertTrue(e.escapeFreezeAfterRestarts(&s, now: t0, bootID: "A").isEmpty)
        return (b, s)
    }

    func testThirdRestartInARowEndsFreeze() throws {
        let (b, initial) = try frozen()
        var s = initial
        XCTAssertTrue(e.escapeFreezeAfterRestarts(&s, now: t0 + 120, bootID: "B").isEmpty)
        XCTAssertTrue(e.escapeFreezeAfterRestarts(&s, now: t0 + 240, bootID: "C").isEmpty)
        XCTAssertNotNil(e.enforcement(for: s, now: t0 + 240, bootID: "C").frozen)
        XCTAssertEqual(e.escapeFreezeAfterRestarts(&s, now: t0 + 360, bootID: "D").map(\.id), [b.id])
        XCTAssertNil(e.enforcement(for: s, now: t0 + 360, bootID: "D").frozen)
        XCTAssertNil(s.freezeRestarts)
    }

    func testSameBootDoesNotCount() throws {
        var (_, s) = try frozen()
        for i in 1...10 { XCTAssertTrue(e.escapeFreezeAfterRestarts(&s, now: t0 + Double(i), bootID: "A").isEmpty) }
        XCTAssertEqual(s.freezeRestarts?.count, 0)
    }

    func testLongGapRestartsTheCountAtOne() throws {
        var (_, s) = try frozen()
        _ = e.escapeFreezeAfterRestarts(&s, now: t0 + 120, bootID: "B")
        _ = e.escapeFreezeAfterRestarts(&s, now: t0 + 240, bootID: "C")
        XCTAssertTrue(e.escapeFreezeAfterRestarts(&s, now: t0 + 3600, bootID: "D").isEmpty)
        XCTAssertEqual(s.freezeRestarts?.count, 1)
        XCTAssertNotNil(e.enforcement(for: s, now: t0 + 3600, bootID: "D").frozen)
    }

    func testFreezeRunningLongBeforeFirstRestartStillCounts() throws {
        var (_, s) = try frozen()
        _ = e.escapeFreezeAfterRestarts(&s, now: t0 + 7200, bootID: "B")
        _ = e.escapeFreezeAfterRestarts(&s, now: t0 + 7320, bootID: "C")
        XCTAssertFalse(e.escapeFreezeAfterRestarts(&s, now: t0 + 7440, bootID: "D").isEmpty)
    }

    func testOtherBlocksKeepRunning() throws {
        var (_, s) = try frozen()
        var web = Block(name: "W", websites: ["x.com"])
        web.lock = .randomText(length: 5)
        s.blocks.append(web)
        try e.start(web.id, endsAt: t0.addingTimeInterval(86400), in: &s, now: t0, bootID: "A")
        for (i, boot) in ["B", "C", "D"].enumerated() {
            _ = e.escapeFreezeAfterRestarts(&s, now: t0 + Double(i + 1) * 120, bootID: boot)
        }
        XCTAssertTrue(e.activity(of: web, in: s, now: t0 + 400).enforcing)
        XCTAssertTrue(e.isLocked(web, in: s, now: t0 + 400, bootID: "D"))
    }

    func testNoFreezeNothingCounted() {
        var s = EngineState()
        s.blocks = [Block(name: "W", websites: ["x.com"])]
        XCTAssertTrue(e.escapeFreezeAfterRestarts(&s, now: t0, bootID: "A").isEmpty)
        XCTAssertNil(s.freezeRestarts)
    }
}

final class LockEngineTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // 2026-11-02 is a Monday (weekday 2).
    func at(_ h: Int, _ m: Int = 0, day: Int = 2) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    func testTimerSessionAndExpiry() throws {
        let e = LockEngine(calendar: cal)
        var s = EngineState()
        let b = Block(name: "X", websites: ["x.com"], lock: .timer)
        s.blocks = [b]
        try e.start(b.id, endsAt: at(10), in: &s, now: at(9), bootID: "A")
        XCTAssertTrue(e.activity(of: b, in: s, now: at(9, 30)).enforcing)
        XCTAssertTrue(e.isLocked(b, in: s, now: at(9, 30), bootID: "A"))
        XCTAssertThrowsError(try e.stop(b.id, in: &s, now: at(9, 30), bootID: "A"))
        XCTAssertThrowsError(try e.start(b.id, endsAt: at(9, 45), in: &s, now: at(9, 30), bootID: "A"), "can't shorten")
        try e.start(b.id, endsAt: at(11), in: &s, now: at(9, 30), bootID: "A") // extend is fine
        XCTAssertFalse(e.activity(of: b, in: s, now: at(11, 1)).running)
        XCTAssertFalse(e.isLocked(b, in: s, now: at(11, 1), bootID: "A"))
    }

    func testScheduleWindowAcrossMidnight() {
        let e = LockEngine(calendar: cal)
        // Monday 22:00-24:00 and Tuesday 00:00-02:00
        let ranges = [ScheduleRange(weekday: 2, startMinute: 1320, endMinute: 1440),
                      ScheduleRange(weekday: 3, startMinute: 0, endMinute: 120)]
        let w = e.scheduleWindow(ranges, at: at(23))
        XCTAssertEqual(w?.start, at(22))
        XCTAssertEqual(w?.end, at(2, day: 3))
        XCTAssertNil(e.scheduleWindow(ranges, at: at(21)))
    }

    func testPomodoroPhases() throws {
        let e = LockEngine(calendar: cal)
        var s = EngineState()
        let b = Block(name: "P", websites: ["x.com"], breakPolicy: .pomodoro(workMinutes: 25, breakMinutes: 5))
        s.blocks = [b]
        try e.start(b.id, endsAt: at(12), in: &s, now: at(9), bootID: "A")
        XCTAssertTrue(e.activity(of: b, in: s, now: at(9, 10)).enforcing)
        let rest = e.activity(of: b, in: s, now: at(9, 27))
        XCTAssertFalse(rest.enforcing)
        XCTAssertEqual(rest.breakEndsAt, at(9, 30))
        XCTAssertTrue(e.activity(of: b, in: s, now: at(9, 31)).enforcing)
    }

    func testLockedEditsMustBeStricter() throws {
        let e = LockEngine(calendar: cal)
        var s = EngineState()
        var b = Block(name: "L", websites: ["x.com"], apps: [AppRef(bundleID: "a", name: "A")], lock: .timer)
        s.blocks = [b]
        try e.start(b.id, endsAt: at(10), in: &s, now: at(9), bootID: "A")

        var looser = b
        looser.websites = []
        XCTAssertThrowsError(try e.save(looser, newPassword: nil, into: &s, now: at(9, 1), bootID: "A"))

        var weakerLock = b
        weakerLock.lock = .randomText(length: 10)
        XCTAssertThrowsError(try e.save(weakerLock, newPassword: nil, into: &s, now: at(9, 1), bootID: "A"))

        b.websites.append("y.com")
        XCTAssertNoThrow(try e.save(b, newPassword: nil, into: &s, now: at(9, 1), bootID: "A"))
        XCTAssertThrowsError(try e.delete(b.id, from: &s, now: at(9, 1), bootID: "A"))
    }

    func testRandomTextGrantUnlocks() throws {
        let e = LockEngine(calendar: cal)
        var s = EngineState()
        let b = Block(name: "R", websites: ["x.com"], lock: .randomText(length: 20))
        s.blocks = [b]
        try e.start(b.id, endsAt: nil, in: &s, now: at(9), bootID: "A")
        XCTAssertTrue(e.isLocked(b, in: s, now: at(9, 1), bootID: "A"))
        e.grant(b.id, in: &s, now: at(9, 1))
        XCTAssertFalse(e.isLocked(b, in: s, now: at(9, 2), bootID: "A"))
        XCTAssertTrue(e.isLocked(b, in: s, now: at(9, 10), bootID: "A"), "grant expires")
    }

    func testRestartLock() throws {
        let e = LockEngine(calendar: cal)
        var s = EngineState()
        let b = Block(name: "B", websites: ["x.com"], lock: .restart)
        s.blocks = [b]
        try e.start(b.id, endsAt: at(18), in: &s, now: at(9), bootID: "boot1")
        e.housekeep(&s, now: at(9), bootID: "boot1")
        XCTAssertTrue(e.isLocked(b, in: s, now: at(9, 5), bootID: "boot1"))
        XCTAssertFalse(e.isLocked(b, in: s, now: at(9, 5), bootID: "boot2"))
    }

    func testPasswordLock() throws {
        let e = LockEngine(calendar: cal)
        var s = EngineState()
        let b = Block(name: "PW", websites: ["x.com"], lock: .password(salt: "", hash: ""))
        try e.save(b, newPassword: "hunter2", into: &s, now: at(8), bootID: "A")
        guard case let .password(salt, hash) = s.blocks[0].lock else { return XCTFail() }
        XCTAssertFalse(salt.isEmpty)
        XCTAssertNotEqual(hash, "hunter2")
        // Re-saving the redacted copy keeps the stored hash.
        try e.save(s.blocks[0].redacted, newPassword: nil, into: &s, now: at(8), bootID: "A")
        XCTAssertEqual(s.blocks[0].lock, .password(salt: salt, hash: hash))

        try e.start(b.id, endsAt: at(12), in: &s, now: at(9), bootID: "A")
        XCTAssertThrowsError(try e.verifyPassword(b.id, password: "nope", in: &s, now: at(9)))
        XCTAssertNoThrow(try e.verifyPassword(b.id, password: "hunter2", in: &s, now: at(9)))
        XCTAssertNoThrow(try e.stop(b.id, in: &s, now: at(9, 1), bootID: "A"))
    }

    func testAllowanceBreaks() throws {
        let e = LockEngine(calendar: cal)
        var s = EngineState()
        let b = Block(name: "A", websites: ["x.com"], breakPolicy: .allowance(minutesPerDay: 15), lock: .timer)
        s.blocks = [b]
        try e.start(b.id, endsAt: at(17), in: &s, now: at(9), bootID: "A")
        try e.takeBreak(b.id, minutes: 10, in: &s, now: at(10))
        XCTAssertFalse(e.activity(of: b, in: s, now: at(10, 5)).enforcing)
        XCTAssertEqual(e.allowanceRemaining(b, in: s, now: at(10, 5)), 5 * 60)
        XCTAssertThrowsError(try e.takeBreak(b.id, minutes: 10, in: &s, now: at(11)))
        e.housekeep(&s, now: at(11), bootID: "A")
        XCTAssertTrue(e.activity(of: b, in: s, now: at(11)).enforcing)
    }

    func testLockScheduleAlwaysGuardsOutsideHours() throws {
        let e = LockEngine(calendar: cal)
        var s = EngineState()
        let b = Block(name: "S", websites: ["x.com"], scheduleEnabled: true,
                      schedule: [ScheduleRange(weekday: 2, startMinute: 540, endMinute: 1020)],
                      lock: .randomText(length: 5), lockScheduleAlways: true)
        s.blocks = [b]
        XCTAssertTrue(e.isLocked(b, in: s, now: at(20), bootID: "A"))
        var shorter = b
        shorter.schedule = [ScheduleRange(weekday: 2, startMinute: 600, endMinute: 1020)]
        XCTAssertThrowsError(try e.save(shorter, newPassword: nil, into: &s, now: at(20), bootID: "A"))
    }

    func testStoppingScheduledRunSkipsRestOfWindow() throws {
        let e = LockEngine(calendar: cal)
        var s = EngineState()
        let b = Block(name: "Night", kind: .frozen, scheduleEnabled: true,
                      schedule: [ScheduleRange(weekday: 2, startMinute: 1260, endMinute: 1380)])
        s.blocks = [b]
        XCTAssertTrue(e.activity(of: b, in: s, now: at(21, 30)).enforcing)
        XCTAssertEqual(e.enforcement(for: s, now: at(21, 30), bootID: "A").frozen?.locked, false)
        try e.stop(b.id, in: &s, now: at(21, 30), bootID: "A")
        XCTAssertFalse(e.activity(of: b, in: s, now: at(21, 31)).running)
        XCTAssertNil(e.enforcement(for: s, now: at(21, 31), bootID: "A").frozen)
        e.housekeep(&s, now: at(23, 1), bootID: "A")
        XCTAssertTrue(s.skips.isEmpty, "skip expires with the window")
    }

    func testOldStateFileWithoutSkipsDecodes() throws {
        let json = #"{"blocks":[],"sessions":[],"breaks":[],"allowanceUsed":{},"lockBoot":[],"grants":[],"settings":{"blockActivityMonitor":false,"blockTerminals":false,"blockSystemSettings":false,"hardBlockIPs":false,"fallbackDNS":["1.1.1.1"],"statsEnabled":true}}"#
        let s = try Wire.decoder.decode(EngineState.self, from: Data(json.utf8))
        XCTAssertTrue(s.skips.isEmpty)
        XCTAssertEqual(s.settings.fallbackDNS, ["1.1.1.1"])
    }

    func testEnforcementMergesAndStrictApps() throws {
        let e = LockEngine(calendar: cal)
        var s = EngineState()
        s.settings.blockActivityMonitor = true
        let a = Block(name: "A", websites: ["x.com"], apps: [AppRef(bundleID: "com.x", name: "X")], lock: .timer)
        let f = Block(name: "F", kind: .frozen)
        s.blocks = [a, f]
        try e.start(a.id, endsAt: at(10), in: &s, now: at(9), bootID: "A")
        try e.start(f.id, endsAt: at(9, 30), in: &s, now: at(9), bootID: "A")
        let enf = e.enforcement(for: s, now: at(9, 5), bootID: "A")
        XCTAssertEqual(enf.web.count, 1)
        XCTAssertEqual(enf.apps.map(\.bundleID), ["com.x"])
        XCTAssertEqual(enf.frozen?.blockName, "F")
        XCTAssertTrue(enf.strictBundleIDs.contains("com.apple.ActivityMonitor"))
    }
}

final class DNSMessageTests: XCTestCase {
    func testRoundTripBlockedAnswer() {
        let q = DNSMessage.query(id: 0xBEEF, name: "www.Reddit.com", qtype: DNSMessage.typeA)
        let parsed = DNSMessage.parseQuery(q)
        XCTAssertEqual(parsed?.name, "www.reddit.com")
        XCTAssertEqual(parsed?.id, 0xBEEF)
        let r = DNSMessage.blockedResponse(to: q, parsed!)
        XCTAssertEqual(DNSMessage.id(of: r), 0xBEEF)
        XCTAssertEqual(DNSMessage.addresses(in: r), ["0.0.0.0"])

        let q6 = DNSMessage.query(id: 1, name: "x.com", qtype: DNSMessage.typeAAAA)
        let r6 = DNSMessage.blockedResponse(to: q6, DNSMessage.parseQuery(q6)!)
        XCTAssertEqual(DNSMessage.addresses(in: r6), ["::"])
    }

    func testNXDomainAndIDRewrite() {
        let q = DNSMessage.query(id: 7, name: "use-application-dns.net", qtype: DNSMessage.typeA)
        let r = DNSMessage.nxdomain(to: q, DNSMessage.parseQuery(q)!)
        XCTAssertEqual(r[3] & 0x0F, 3)
        XCTAssertEqual(DNSMessage.id(of: DNSMessage.withID(r, 99)), 99)
        XCTAssertNil(DNSMessage.parseQuery(r), "responses aren't queries")
    }
}

final class FlickerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let e = LockEngine()
    let policy = FlickerPolicy(frozenMinMinutes: 10, frozenMaxMinutes: 20, freeMinMinutes: 30, freeMaxMinutes: 60)

    func flickering(lock: LockPolicy = .none, always: Bool = false) -> (Block, EngineState) {
        let b = Block(name: "F", kind: .frozen, flicker: policy, lock: lock, lockScheduleAlways: always)
        var s = EngineState()
        s.blocks = [b]
        return (b, s)
    }

    func testStartsFreeThenAlternatesWithinBoundsDrawingNewLengths() {
        let (b, initial) = flickering()
        var s = initial
        var now = t0
        XCTAssertTrue(e.advanceFlicker(&s, now: now))
        var expectFrozen = false
        var frozenLengths = Set<TimeInterval>(), freeLengths = Set<TimeInterval>()
        for _ in 0..<400 {
            let p = s.flickerPhases[b.id]!
            XCTAssertEqual(p.frozen, expectFrozen)
            let length = p.endsAt.timeIntervalSince(p.startedAt)
            if p.frozen {
                XCTAssertTrue((600...1200).contains(length))
                frozenLengths.insert(length)
            } else {
                XCTAssertTrue((1800...3600).contains(length))
                freeLengths.insert(length)
            }
            let mid = p.startedAt.addingTimeInterval(length / 2)
            XCTAssertFalse(e.advanceFlicker(&s, now: mid))
            XCTAssertEqual(e.activity(of: b, in: s, now: mid).source, p.frozen ? .flicker : .none)
            XCTAssertEqual(e.enforcement(for: s, now: mid, bootID: "A").frozen != nil, p.frozen)
            now = p.endsAt
            XCTAssertTrue(e.advanceFlicker(&s, now: now))
            expectFrozen.toggle()
        }
        XCTAssertGreaterThan(frozenLengths.count, 50)
        XCTAssertGreaterThan(freeLengths.count, 50)
    }

    func testEqualBoundsGiveThatExactLength() {
        let (b, initial) = flickering()
        var s = initial
        s.blocks[0].flicker = FlickerPolicy(frozenMinMinutes: 7, frozenMaxMinutes: 7, freeMinMinutes: 3, freeMaxMinutes: 3)
        _ = e.advanceFlicker(&s, now: t0)
        XCTAssertEqual(s.flickerPhases[b.id]?.endsAt, t0 + 180)
        _ = e.advanceFlicker(&s, now: t0 + 180)
        XCTAssertEqual(s.flickerPhases[b.id]?.endsAt, t0 + 180 + 420)
    }

    func testWakingAfterALongSleepDrawsFromNow() {
        let (b, initial) = flickering()
        var s = initial
        _ = e.advanceFlicker(&s, now: t0)
        let later = t0 + 86400
        XCTAssertTrue(e.advanceFlicker(&s, now: later))
        let p = s.flickerPhases[b.id]!
        XCTAssertEqual(p.startedAt, later)
        XCTAssertTrue(p.frozen)
        XCTAssertGreaterThanOrEqual(p.endsAt, later + 600)
    }

    func testStateSurvivesRoundTrip() throws {
        let (b, initial) = flickering()
        var s = initial
        _ = e.advanceFlicker(&s, now: t0)
        let decoded = try JSONDecoder().decode(EngineState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded.flickerPhases[b.id], s.flickerPhases[b.id])
        XCTAssertEqual(decoded.blocks.first?.flicker, policy)
    }

    func testStateFromBeforeFlickerStillLoads() throws {
        let id = UUID()
        let old = """
        {"blocks":[{"id":"\(id.uuidString)","name":"Old","kind":"frozen","websites":[],"websiteExceptions":[],
        "blockEntireInternet":false,"apps":[],"titleKeywords":[],"scheduleEnabled":false,"schedule":[],
        "breakPolicy":{"none":{}},"lock":{"none":{}},"lockScheduleAlways":false,"frozenMode":"lockScreen"}]}
        """
        let s = try JSONDecoder().decode(EngineState.self, from: Data(old.utf8))
        XCTAssertEqual(s.blocks.first?.name, "Old")
        XCTAssertNil(s.blocks.first?.flicker)
        XCTAssertTrue(s.flickerPhases.isEmpty)
    }

    func testSaveRejectsBadBoundsAndKeepsModesExclusive() throws {
        var s = EngineState()
        var bad = Block(name: "B", kind: .frozen, flicker: FlickerPolicy(frozenMinMinutes: 20, frozenMaxMinutes: 10))
        XCTAssertThrowsError(try e.save(bad, newPassword: nil, into: &s, now: t0, bootID: "A"))
        bad.flicker = FlickerPolicy(frozenMinMinutes: 0)
        XCTAssertThrowsError(try e.save(bad, newPassword: nil, into: &s, now: t0, bootID: "A"))
        let both = Block(name: "C", kind: .frozen, scheduleEnabled: true, flicker: policy)
        try e.save(both, newPassword: nil, into: &s, now: t0, bootID: "A")
        XCTAssertFalse(s.blocks[0].scheduleEnabled)
        let standard = Block(name: "D", flicker: policy)
        try e.save(standard, newPassword: nil, into: &s, now: t0, bootID: "A")
        XCTAssertNil(s.blocks[1].flicker)
    }

    func testCantBeStartedByHand() {
        let (b, initial) = flickering()
        var s = initial
        XCTAssertThrowsError(try e.start(b.id, endsAt: t0 + 60, in: &s, now: t0, bootID: "A"))
    }

    func testStopEndsThisFreezeButFlickerStaysOn() throws {
        let (b, initial) = flickering()
        var s = initial
        s.flickerPhases[b.id] = FlickerPhase(frozen: true, startedAt: t0, endsAt: t0 + 900)
        try e.stop(b.id, in: &s, now: t0 + 60, bootID: "A")
        XCTAssertFalse(e.activity(of: b, in: s, now: t0 + 60).running)
        XCTAssertTrue(e.advanceFlicker(&s, now: t0 + 62))
        XCTAssertEqual(s.flickerPhases[b.id]?.frozen, false)
        XCTAssertNotNil(s.blocks[0].flicker)
    }

    func testLockedFreezeCantBeStoppedOrLoosened() throws {
        var (b, s) = flickering(lock: .randomText(length: 5))
        s.flickerPhases[b.id] = FlickerPhase(frozen: true, startedAt: t0, endsAt: t0 + 900)
        XCTAssertThrowsError(try e.stop(b.id, in: &s, now: t0 + 60, bootID: "A"))
        var off = b
        off.flicker = nil
        XCTAssertThrowsError(try e.save(off, newPassword: nil, into: &s, now: t0 + 60, bootID: "A"))
        for looser in [FlickerPolicy(frozenMinMinutes: 5, frozenMaxMinutes: 20, freeMinMinutes: 30, freeMaxMinutes: 60),
                       FlickerPolicy(frozenMinMinutes: 10, frozenMaxMinutes: 15, freeMinMinutes: 30, freeMaxMinutes: 60),
                       FlickerPolicy(frozenMinMinutes: 10, frozenMaxMinutes: 20, freeMinMinutes: 40, freeMaxMinutes: 60),
                       FlickerPolicy(frozenMinMinutes: 10, frozenMaxMinutes: 20, freeMinMinutes: 30, freeMaxMinutes: 90)] {
            b.flicker = looser
            XCTAssertThrowsError(try e.save(b, newPassword: nil, into: &s, now: t0 + 60, bootID: "A"))
        }
        b.flicker = FlickerPolicy(frozenMinMinutes: 15, frozenMaxMinutes: 25, freeMinMinutes: 20, freeMaxMinutes: 40)
        XCTAssertNoThrow(try e.save(b, newPassword: nil, into: &s, now: t0 + 60, bootID: "A"))
        XCTAssertEqual(s.flickerPhases[b.id]?.endsAt, t0 + 900)
    }

    func testBetweenFreezesLockOnlyHoldsWithTheOption() throws {
        let (plain, initial) = flickering(lock: .randomText(length: 5))
        var s = initial
        _ = e.advanceFlicker(&s, now: t0)
        XCTAssertFalse(e.isLocked(plain, in: s, now: t0 + 1, bootID: "A"))
        let (guarded, initial2) = flickering(lock: .randomText(length: 5), always: true)
        s = initial2
        _ = e.advanceFlicker(&s, now: t0)
        XCTAssertTrue(e.isLocked(guarded, in: s, now: t0 + 1, bootID: "A"))
        var off = guarded
        off.flicker = nil
        XCTAssertThrowsError(try e.save(off, newPassword: nil, into: &s, now: t0 + 1, bootID: "A"))
    }

    func testTurningOffRemovesThePhase() throws {
        var (b, s) = flickering()
        _ = e.advanceFlicker(&s, now: t0)
        b.flicker = nil
        try e.save(b, newPassword: nil, into: &s, now: t0 + 1, bootID: "A")
        XCTAssertTrue(e.advanceFlicker(&s, now: t0 + 2))
        XCTAssertNil(s.flickerPhases[b.id])
    }

    func testNewBoundsShortenAWindowThatWouldOutlastThem() throws {
        var (b, s) = flickering()
        s.flickerPhases[b.id] = FlickerPhase(frozen: false, startedAt: t0, endsAt: t0 + 3600)
        b.flicker = FlickerPolicy(frozenMinMinutes: 10, frozenMaxMinutes: 20, freeMinMinutes: 1, freeMaxMinutes: 2)
        try e.save(b, newPassword: nil, into: &s, now: t0 + 10, bootID: "A")
        XCTAssertEqual(s.flickerPhases[b.id]?.endsAt, t0 + 130)
    }

    func testDeleteClearsThePhase() throws {
        let (b, initial) = flickering()
        var s = initial
        _ = e.advanceFlicker(&s, now: t0)
        try e.delete(b.id, from: &s, now: t0 + 1, bootID: "A")
        XCTAssertNil(s.flickerPhases[b.id])
    }

    func testEmergencyEscapeTurnsFlickerOff() {
        let (b, initial) = flickering(lock: .timer, always: true)
        var s = initial
        s.flickerPhases[b.id] = FlickerPhase(frozen: true, startedAt: t0, endsAt: t0 + 86400)
        _ = e.escapeFreezeAfterRestarts(&s, now: t0, bootID: "A")
        _ = e.escapeFreezeAfterRestarts(&s, now: t0 + 120, bootID: "B")
        _ = e.escapeFreezeAfterRestarts(&s, now: t0 + 240, bootID: "C")
        XCTAssertEqual(e.escapeFreezeAfterRestarts(&s, now: t0 + 360, bootID: "D").map(\.id), [b.id])
        XCTAssertNil(s.blocks[0].flicker)
        XCTAssertNil(e.enforcement(for: s, now: t0 + 360, bootID: "D").frozen)
        XCTAssertFalse(e.isLocked(s.blocks[0], in: s, now: t0 + 360, bootID: "D"))
        _ = e.advanceFlicker(&s, now: t0 + 362)
        XCTAssertNil(s.flickerPhases[b.id])
    }
}
