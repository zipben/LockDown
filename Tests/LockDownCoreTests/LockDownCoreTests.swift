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
