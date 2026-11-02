import Foundation

/// Matches hostnames against block-list entries. Matching is domain-level: an entry like
/// `https://www.reddit.com/r/foo` is reduced to `www.reddit.com`.
///
/// Entry forms:
/// - `example.com`      matches example.com and every subdomain
/// - `*.example.com`    same as above
/// - `*tube*`           glob over the whole hostname (`*` = any run of characters)
public struct DomainMatcher {
    enum Pattern: Hashable {
        case suffix(String)
        case glob(NSRegularExpression)
    }

    let patterns: [Pattern]

    public init(_ entries: [String]) {
        patterns = entries.compactMap(DomainMatcher.pattern(for:))
    }

    public var isEmpty: Bool { patterns.isEmpty }

    public func matches(_ host: String) -> Bool {
        let h = DomainMatcher.normalizeHost(host)
        guard !h.isEmpty else { return false }
        for p in patterns {
            switch p {
            case .suffix(let d):
                if h == d || h.hasSuffix("." + d) { return true }
            case .glob(let re):
                if re.firstMatch(in: h, range: NSRange(h.startIndex..., in: h)) != nil { return true }
            }
        }
        return false
    }

    /// Lowercases and strips a trailing dot.
    public static func normalizeHost(_ host: String) -> String {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// Reduces a user-entered entry (possibly a URL) to a hostname pattern. Returns nil for junk.
    public static func normalizeEntry(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty || s.hasPrefix("#") { return nil }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.lastIndex(of: ":"), s[s.index(after: colon)...].allSatisfy(\.isNumber) {
            s = String(s[..<colon])
        }
        while s.hasSuffix(".") { s.removeLast() }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.*_")
        guard !s.isEmpty, s.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return s
    }

    /// True when an entry carried a URL path that domain-level blocking will ignore.
    public static func entryHasPath(_ raw: String) -> Bool {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        guard let slash = s.firstIndex(of: "/") else { return false }
        return s.index(after: slash) < s.endIndex
    }

    static func pattern(for raw: String) -> Pattern? {
        guard var e = normalizeEntry(raw) else { return nil }
        if e.hasPrefix("*.") { e.removeFirst(2) }
        if !e.contains("*") { return e.isEmpty ? nil : .suffix(e) }
        let escaped = e.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*")
        guard let re = try? NSRegularExpression(pattern: "^" + escaped + "$") else { return nil }
        return .glob(re)
    }
}

/// The resolved web policy for all active blocks at a moment.
public struct WebPolicy: Codable, Hashable {
    public var blocked: [String]
    public var exceptions: [String]
    public var blockAll: Bool

    public init(blocked: [String] = [], exceptions: [String] = [], blockAll: Bool = false) {
        self.blocked = blocked
        self.exceptions = exceptions
        self.blockAll = blockAll
    }

    public var isEmpty: Bool { !blockAll && blocked.isEmpty }
}

public struct CompiledWebPolicy {
    let blocked: DomainMatcher
    let exceptions: DomainMatcher
    let blockAll: Bool

    public init(_ p: WebPolicy) {
        blocked = DomainMatcher(p.blocked)
        exceptions = DomainMatcher(p.exceptions)
        blockAll = p.blockAll
    }

    public func isBlocked(_ host: String) -> Bool {
        if exceptions.matches(host) { return false }
        return blockAll || blocked.matches(host)
    }
}
