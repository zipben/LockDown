import Foundation
import LockDownCore

final class Daemon {
    let queue = DispatchQueue(label: "lockdownd.state")
    let clock = TrustedClock()
    let bootID = bootSessionID()
    var engine = LockEngine()

    var state = EngineState()
    var stats = StatsStore.load()
    var health = FilterHealth()
    var challenges: [UUID: String] = [:]

    let dns = DNSServer()
    let firewall = Firewall()
    let systemDNS = SystemDNS()

    private var lastEnforcement = Enforcement()
    private var webActive = false
    private var ticks = 0
    private var dirty = false
    private var statsDirty = false

    // MARK: Lifecycle

    func start() {
        try? FileManager.default.createDirectory(atPath: Paths.support, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        load()
        if clock.syncNTP() { Log.info("clock anchored to NTP") } else { Log.info("NTP unavailable; using system clock") }

        dns.onBlocked = { [weak self] host in
            self?.queue.async { self?.recordBlockedDomain(host) }
        }
        do {
            try dns.start()
            health.dnsServerRunning = true
        } catch {
            health.lastError = "\(error)"
            Log.info("DNS server failed: \(error)")
        }
        refreshUpstreams()

        // A previous run may have died with DNS redirected and no active blocks; tick() fixes it either way.
        queue.async { self.tick() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { self.tick() }
        timer.resume()
        timers.append(timer)

        IPCServer(daemon: self).start()
    }

    private var timers: [DispatchSourceTimer] = []

    /// Called on SIGTERM. If a locked block is enforcing web rules, leave DNS redirected and the
    /// firewall loaded: killing the daemon then cuts DNS instead of unblocking ("fail closed").
    func shutdown() {
        queue.sync {
            persist(force: true)
            if lastEnforcement.anyLocked && lastEnforcement.hasWebRules {
                Log.info("stopping while locked: leaving DNS redirected (fail closed)")
                return
            }
            if webActive {
                systemDNS.restore()
                firewall.unload()
            }
        }
    }

    // MARK: Tick

    func tick() {
        let now = clock.now()
        ticks += 1
        let before = state.lockBoot
        engine.housekeep(&state, now: now, bootID: bootID)
        if before != state.lockBoot { dirty = true }

        let e = engine.enforcement(for: state, now: now, bootID: bootID)
        if e.web != lastEnforcement.web || e.hardBlockIPs != lastEnforcement.hardBlockIPs {
            dns.setPolicies(e.web)
            applyWeb(e)
        } else if webActive && ticks % 5 == 0 {
            watchdog()
        }
        if webActive && e.hardBlockIPs && ticks % 150 == 1 { refreshBlockedIPs(e) }
        if ticks % 15 == 0 { refreshUpstreams() }
        if ticks % 1800 == 0 { clock.syncNTP() }
        lastEnforcement = e
        persist(force: false)
    }

    private func applyWeb(_ e: Enforcement) {
        if e.hasWebRules {
            systemDNS.redirect()
            firewall.setVPNResolvers(systemDNS.unmanagedResolvers())
            if let err = firewall.load() { health.lastError = err; Log.info(err) }
            systemDNS.flushCache()
            if !webActive { Log.info("web blocking on (vpn dns \(firewall.vpnResolvers), upstreams \(health.upstreams))") }
            webActive = true
            if e.hardBlockIPs { refreshBlockedIPs(e) } else { firewall.setBlockedIPs([]) }
            selfTest()
        } else if webActive {
            Log.info("web blocking off")
            systemDNS.restore()
            firewall.unload()
            webActive = false
            health.systemPathOK = nil
        }
        updateHealth()
    }

    /// Looks up a unique name through the normal system resolver (mDNSResponder) and checks that
    /// it arrived at our DNS server. Catches resolvers we can't redirect, e.g. a VPN's own DNS.
    private func selfTest() {
        let name = "t\(UInt32.random(in: 0...UInt32.max))" + DNSServer.probeSuffix
        let dns = self.dns
        DispatchQueue.global().async {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            var res: UnsafeMutablePointer<addrinfo>?
            let started = Date()
            let rc = getaddrinfo(name, nil, &hints, &res)
            let took = Date().timeIntervalSince(started)
            if let res { freeaddrinfo(res) }
            let ok = dns.consumeProbe(name)
            self.queue.async {
                guard self.webActive else { return }
                self.health.systemPathOK = ok
                if ok {
                    if let e = self.health.lastError, e.hasPrefix("DNS self-test") || e.hasPrefix("Lookups go to") { self.health.lastError = nil }
                } else {
                    let vpn = self.firewall.vpnResolvers
                    self.health.lastError = vpn.isEmpty
                        ? "DNS self-test failed: lookups aren't reaching LockDown."
                        : "Lookups go to a VPN's DNS (\(vpn.joined(separator: ", "))) instead of LockDown, so sites aren't blocked. Turn off \"Use Tailscale DNS\" (tailscale set --accept-dns=false) or your VPN's DNS setting."
                    Log.info("self-test probe \(name) never reached the DNS server (getaddrinfo rc \(rc) after \(String(format: "%.1f", took))s, vpn dns \(vpn))")
                }
            }
        }
    }

    /// Re-asserts DNS redirection and firewall rules if something removed them.
    private func watchdog() {
        if !systemDNS.isRedirected() {
            Log.info("watchdog: DNS settings changed, re-redirecting")
            systemDNS.redirect()
        }
        firewall.setVPNResolvers(systemDNS.unmanagedResolvers())
        if !firewall.verify() {
            Log.info("watchdog: firewall rules missing, reloading")
            if let err = firewall.load() { health.lastError = err }
            if lastEnforcement.hardBlockIPs { refreshBlockedIPs(lastEnforcement) }
        }
        if ticks % 30 == 0 { selfTest() }
        updateHealth()
    }

    private func updateHealth() {
        health.systemDNSRedirected = webActive && systemDNS.isRedirected()
        health.firewallLoaded = webActive && firewall.loaded
        health.upstreams = dns.currentUpstreams
        health.vpnResolvers = webActive ? firewall.vpnResolvers : []
    }

    private func refreshUpstreams() {
        dns.setUpstreams(systemDNS.upstreams(fallback: state.settings.fallbackDNS))
        health.upstreams = dns.currentUpstreams
    }

    private func refreshBlockedIPs(_ e: Enforcement) {
        let names = Set(e.web.flatMap(\.blocked).filter { !$0.contains("*") }.flatMap { [$0, "www." + $0] })
        let dns = self.dns
        let fw = firewall
        DispatchQueue.global().async {
            var ips = Set<String>()
            for n in names {
                ips.formUnion(dns.resolve(n, qtype: DNSMessage.typeA))
                ips.formUnion(dns.resolve(n, qtype: DNSMessage.typeAAAA))
            }
            ips.remove("0.0.0.0")
            ips.remove("::")
            fw.setBlockedIPs(ips.sorted())
        }
    }

    // MARK: Persistence

    private func load() {
        if let d = FileManager.default.contents(atPath: Paths.state) {
            do { state = try Wire.decoder.decode(EngineState.self, from: d) } catch {
                Log.info("state.json unreadable (\(error)); keeping a copy and starting fresh")
                try? FileManager.default.copyItem(atPath: Paths.state, toPath: Paths.state + ".corrupt")
            }
        }
    }

    private func persist(force: Bool) {
        if dirty || force {
            if let d = try? Wire.encoder.encode(state) { writeAtomically(d, to: Paths.state) }
            dirty = false
        }
        if (statsDirty && ticks % 30 == 0) || force {
            stats.prune(keepingAfter: engine.dayKey(clock.now().addingTimeInterval(-31 * 86400)))
            stats.save()
            statsDirty = false
        }
    }

    private func recordBlockedDomain(_ host: String) {
        guard state.settings.statsEnabled else { return }
        stats.days[engine.dayKey(clock.now()), default: DayStats()].blockedDomains[StatsStore.displayDomain(host), default: 0] += 1
        statsDirty = true
    }

    // MARK: Requests (always called on `queue`)

    func handle(_ req: Request) -> Response {
        let now = clock.now()
        do {
            switch req.cmd {
            case .snapshot:
                return Response(snapshot: snapshot(now), now: now)

            case .enforcement:
                return Response(enforcement: lastEnforcement, now: now)

            case .saveBlock:
                guard let b = req.block else { return .fail("Missing block.") }
                try engine.save(b, newPassword: req.text, into: &state, now: now, bootID: bootID)
                changed()

            case .deleteBlock:
                try engine.delete(try id(req), from: &state, now: now, bootID: bootID)
                changed()

            case .startBlock:
                try engine.start(try id(req), endsAt: req.endsAt, in: &state, now: now, bootID: bootID)
                changed()

            case .stopBlock:
                try engine.stop(try id(req), in: &state, now: now, bootID: bootID)
                changed()

            case .requestChallenge:
                let bid = try id(req)
                guard let b = state.blocks.first(where: { $0.id == bid }) else { throw EngineError.notFound }
                guard case .randomText(let n) = b.lock else { throw EngineError.invalid("This block doesn't use a random-text lock.") }
                let text = LockEngine.randomString(n)
                challenges[bid] = text
                return Response(challenge: text, now: now)

            case .solveChallenge:
                let bid = try id(req)
                guard let expected = challenges[bid] else { throw EngineError.invalid("Ask for a new challenge first.") }
                guard req.text == expected else {
                    // A miss means a fresh string: no retrying a nearly-right paste.
                    challenges[bid] = nil
                    throw EngineError.locked("Wrong text. Request a new challenge and try again.")
                }
                challenges[bid] = nil
                engine.grant(bid, in: &state, now: now)
                changed()

            case .submitPassword:
                try engine.verifyPassword(try id(req), password: req.text ?? "", in: &state, now: now)
                changed()

            case .takeBreak:
                try engine.takeBreak(try id(req), minutes: req.minutes ?? 0, in: &state, now: now)
                changed()

            case .endBreak:
                engine.endBreak(try id(req), in: &state, now: now)
                changed()

            case .saveSettings:
                guard let s = req.settings else { return .fail("Missing settings.") }
                try saveSettings(s, now: now)
                changed()

            case .reportUsage:
                if let u = req.usage, state.settings.statsEnabled, (1...60).contains(u.seconds) {
                    let key = engine.dayKey(now)
                    stats.days[key, default: DayStats()].appSeconds[u.bundleID, default: 0] += u.seconds
                    stats.days[key, default: DayStats()].appNames[u.bundleID] = u.appName
                    statsDirty = true
                }
                return Response(now: now)

            case .reportBlockedApp:
                if let u = req.usage, state.settings.statsEnabled {
                    let key = engine.dayKey(now)
                    stats.days[key, default: DayStats()].blockedApps[u.bundleID, default: 0] += 1
                    stats.days[key, default: DayStats()].appNames[u.bundleID] = u.appName
                    statsDirty = true
                }
                return Response(now: now)

            case .canUninstall:
                return Response(allowed: !lastEnforcement.anyLocked && !state.blocks.contains {
                    engine.isLocked($0, in: state, now: now, bootID: bootID)
                }, now: now)
            }
            return Response(snapshot: snapshot(now), now: now)
        } catch let e as EngineError {
            return .fail(e.description)
        } catch {
            return .fail("\(error)")
        }
    }

    private func id(_ req: Request) throws -> UUID {
        guard let i = req.blockID else { throw EngineError.invalid("Missing block id.") }
        return i
    }

    /// While anything is locked, strictness settings can only be tightened.
    private func saveSettings(_ s: GlobalSettings, now: Date) throws {
        let old = state.settings
        let locked = state.blocks.contains { engine.isLocked($0, in: state, now: now, bootID: bootID) }
        if locked {
            let loosened = (old.blockActivityMonitor && !s.blockActivityMonitor)
                || (old.blockTerminals && !s.blockTerminals)
                || (old.blockSystemSettings && !s.blockSystemSettings)
                || (old.hardBlockIPs && !s.hardBlockIPs)
            if loosened { throw EngineError.locked("A block is locked. Strictness settings can only be turned up.") }
        }
        var clean = s
        clean.fallbackDNS = s.fallbackDNS.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        state.settings = clean
        refreshUpstreams()
    }

    private func changed() {
        dirty = true
        tick()
    }

    private func snapshot(_ now: Date) -> Snapshot {
        let statuses = state.blocks.map { b in
            BlockStatus(
                block: b.redacted,
                activity: engine.activity(of: b, in: state, now: now),
                locked: engine.isLocked(b, in: state, now: now, bootID: bootID),
                lockReason: engine.lockReason(b),
                allowanceRemaining: engine.allowanceRemaining(b, in: state, now: now))
        }
        let today = engine.dayKey(now)
        let lastDays = (0..<7).reversed().map { engine.dayKey(now.addingTimeInterval(-Double($0) * 86400)) }
        return Snapshot(now: now, blocks: statuses, settings: state.settings, health: health,
                        stats: stats.summary(today: today, lastDays: lastDays),
                        anyLocked: statuses.contains { $0.locked })
    }
}

/// Unix-socket server: one JSON request line in, one JSON response line out.
final class IPCServer {
    let daemon: Daemon

    init(daemon: Daemon) { self.daemon = daemon }

    func start() {
        unlink(IPC.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: Array(IPC.socketPath.utf8).prefix(buf.count - 1))
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            Log.info("IPC bind failed: \(String(cString: strerror(errno)))")
            exit(1)
        }
        chmod(IPC.socketPath, 0o666)
        listen(fd, 32)
        let t = Thread {
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { continue }
                DispatchQueue.global().async { self.serve(c) }
            }
        }
        t.name = "ipc"
        t.start()
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard let line = SocketIO.readLine(fd, limit: 4 << 20) else { return }
        let response: Response
        if let req = try? Wire.decoder.decode(Request.self, from: line) {
            response = daemon.queue.sync { daemon.handle(req) }
        } else {
            response = .fail("Malformed request.")
        }
        guard var out = try? Wire.encoder.encode(response) else { return }
        out.append(0x0A)
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { write(fd, $0.baseAddress! + sent, out.count - sent) }
            if n <= 0 { return }
            sent += n
        }
    }
}
