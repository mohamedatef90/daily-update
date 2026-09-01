import Foundation

enum VersionComparator {
    /// Returns true when `current` is greater than or equal to `latest` after normalization.
    static func isAtLeast(current: String?, latest: String?) -> Bool {
        guard let latest, !latest.isEmpty else { return true }
        guard let current, !current.isEmpty else { return false }
        let normalizedCurrent = normalize(current)
        let normalizedLatest = normalize(latest)
        if normalizedCurrent == normalizedLatest { return true }
        return compare(normalizedCurrent, normalizedLatest) != .orderedAscending
    }

    static func isBehind(current: String?, latest: String?) -> Bool {
        guard let latest, !latest.isEmpty, let current, !current.isEmpty else { return false }
        return !isAtLeast(current: current, latest: latest)
    }

    static func normalize(_ version: String) -> String {
        var cleaned = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "_", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        // Keep only semver-like characters so "1.2.3 (build 45)" still compares cleanly.
        cleaned = cleaned.replacingOccurrences(
            of: "[^0-9.a-z-]",
            with: "",
            options: .regularExpression
        )
        while cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "..", with: ".")
        }
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftParts = lhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let rightParts = rhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let count = max(leftParts.count, rightParts.count)

        for index in 0..<count {
            let left = partValue(index < leftParts.count ? leftParts[index] : "0")
            let right = partValue(index < rightParts.count ? rightParts[index] : "0")
            if left != right {
                return left < right ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    private static func partValue(_ part: String) -> Int {
        let digits = part.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }
}
