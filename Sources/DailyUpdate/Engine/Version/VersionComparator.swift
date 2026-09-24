import Foundation

enum VersionComparator {
    enum Ordering {
        case older
        case same
        case newer
        case incomparable
    }

    static func isAtLeast(current: String?, latest: String?) -> Bool {
        guard let latest, !latest.isEmpty else { return true }
        guard let current, !current.isEmpty else { return false }
        let ordering = compare(current: current, latest: latest)
        return ordering == .same || ordering == .newer
    }

    static func isBehind(current: String?, latest: String?) -> Bool {
        guard let latest, !latest.isEmpty, let current, !current.isEmpty else { return false }
        return compare(current: current, latest: latest) == .older
    }

    static func compare(current: String, latest: String) -> Ordering {
        compare(VersionValue(token: current), VersionValue(token: latest))
    }

    static func compare(_ current: VersionValue, _ latest: VersionValue) -> Ordering {
        switch (current, latest) {
        case let (.semantic(lhs), .semantic(rhs)):
            if lhs == rhs { return .same }
            return lhs < rhs ? .older : .newer
        case let (.revision(lhs), .revision(rhs)):
            if lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) {
                return .same
            }
            return .incomparable
        case let (.opaque(lhs), .opaque(rhs)):
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame ? .same : .incomparable
        default:
            return .incomparable
        }
    }

    static func normalize(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let primary = withoutPrefix.components(separatedBy: ",").first ?? withoutPrefix
        return primary.lowercased()
    }
}
