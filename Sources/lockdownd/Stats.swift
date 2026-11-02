import Foundation
import LockDownCore

struct DayStats: Codable {
    var appSeconds: [String: Int] = [:]
    var appNames: [String: String] = [:]
    var blockedDomains: [String: Int] = [:]
    var blockedApps: [String: Int] = [:]
}

struct StatsStore: Codable {
    var days: [String: DayStats] = [:]

    static func load() -> StatsStore {
        guard let d = FileManager.default.contents(atPath: Paths.stats),
              let s = try? Wire.decoder.decode(StatsStore.self, from: d) else { return StatsStore() }
        return s
    }

    func save() {
        if let d = try? Wire.encoder.encode(self) { writeAtomically(d, to: Paths.stats, mode: 0o644) }
    }

    mutating func prune(keepingAfter cutoff: String) {
        days = days.filter { $0.key >= cutoff }
    }

    /// Collapses a hostname to its registrable-ish domain for nicer stats ("www.m.youtube.com" -> "youtube.com").
    static func displayDomain(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        let secondLevel = ["co", "com", "org", "net", "ac", "gov", "edu"]
        let take = parts.count >= 3 && secondLevel.contains(String(parts[parts.count - 2])) && parts.last!.count == 2 ? 3 : 2
        return parts.suffix(take).joined(separator: ".")
    }

    func summary(today: String, lastDays: [String]) -> StatsSummary {
        var s = StatsSummary()
        let d = days[today] ?? DayStats()
        s.appTimeToday = d.appSeconds.sorted { $0.value > $1.value }.prefix(15)
            .map { StatRow(key: $0.key, label: d.appNames[$0.key] ?? $0.key, value: $0.value) }
        s.blockedToday = d.blockedDomains.sorted { $0.value > $1.value }.prefix(15)
            .map { StatRow(key: $0.key, label: $0.key, value: $0.value) }
        s.appsBlockedToday = d.blockedApps.sorted { $0.value > $1.value }.prefix(15)
            .map { StatRow(key: $0.key, label: d.appNames[$0.key] ?? $0.key, value: $0.value) }
        s.blockedByDay = lastDays.map { day in
            let x = days[day] ?? DayStats()
            return StatRow(key: day, label: String(day.suffix(5)), value: x.blockedDomains.values.reduce(0, +) + x.blockedApps.values.reduce(0, +))
        }
        return s
    }
}
