import Foundation

enum VersionComparator {
    enum Ordering {
        case older
        case same
        case newer
        case incomparable
    }

    private enum Identifier: Equatable {
        case numeric(Int)
        case alpha(String)
    }

    private enum ParsedVersion: Equatable {
        case semantic(core: [Int], prerelease: [Identifier])
        case revision(String)
        case opaque(String)
    }

    /// Returns true when `current` is greater than or equal to `latest` after normalization.
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
        let left = parse(current)
        let right = parse(latest)

        switch (left, right) {
        case let (.revision(lhs), .revision(rhs)):
            if lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) {
                return .same
            }
            return .incomparable
        case let (.semantic(lhsCore, lhsPre), .semantic(rhsCore, rhsPre)):
            let coreResult = compareCore(lhsCore, rhsCore)
            if coreResult != .same {
                return coreResult
            }
            return comparePrerelease(lhsPre, rhsPre)
        case let (.opaque(lhs), .opaque(rhs)):
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame ? .same : .incomparable
        default:
            return .incomparable
        }
    }

    static func normalize(_ version: String) -> String {
        let cleaned = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .components(separatedBy: ",").first ?? version
        return cleaned.lowercased()
    }

    private static func parse(_ version: String) -> ParsedVersion {
        let normalized = normalize(version)
        if normalized.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil,
           normalized.contains(where: \.isLetter) {
            return .revision(normalized)
        }

        let withoutBuild = normalized.components(separatedBy: "+").first ?? normalized
        if let captures = captures(pattern: #"^(\d+(?:\.\d+)*)(.*)$"#, in: withoutBuild), captures.count == 2 {
            let coreString = captures[0]
            let suffix = captures[1]
            let parts = coreString.split(separator: ".", omittingEmptySubsequences: false)
            let core = parts.compactMap { Int($0) }
            if !core.isEmpty {
                let prerelease = parsePrerelease(suffix)
                return .semantic(core: core, prerelease: prerelease)
            }
        }

        return .opaque(normalized)
    }

    private static func parsePrerelease(_ rawSuffix: String) -> [Identifier] {
        let suffix = rawSuffix.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        guard !suffix.isEmpty else { return [] }
        let pieces = suffix.replacingOccurrences(of: "_", with: ".").split(separator: ".")
        var identifiers: [Identifier] = []
        for piece in pieces {
            for chunk in splitAlphaNumeric(String(piece)) {
                if let number = Int(chunk) {
                    identifiers.append(.numeric(number))
                } else {
                    identifiers.append(.alpha(chunk))
                }
            }
        }
        return identifiers
    }

    private static func splitAlphaNumeric(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        var wasNumeric = value.first?.isNumber ?? false
        for char in value {
            if current.isEmpty {
                current.append(char)
                wasNumeric = char.isNumber
                continue
            }
            if char.isNumber == wasNumeric {
                current.append(char)
            } else {
                chunks.append(current)
                current = String(char)
                wasNumeric = char.isNumber
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func compareCore(_ lhs: [Int], _ rhs: [Int]) -> Ordering {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left == right { continue }
            return left < right ? .older : .newer
        }
        return .same
    }

    private static func comparePrerelease(_ lhs: [Identifier], _ rhs: [Identifier]) -> Ordering {
        if lhs.isEmpty, rhs.isEmpty { return .same }
        if lhs.isEmpty { return .newer } // release > prerelease
        if rhs.isEmpty { return .older }

        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            if index >= lhs.count { return .older }
            if index >= rhs.count { return .newer }
            let left = lhs[index]
            let right = rhs[index]
            switch (left, right) {
            case let (.numeric(l), .numeric(r)):
                if l == r { continue }
                return l < r ? .older : .newer
            case let (.alpha(l), .alpha(r)):
                let result = l.compare(r, options: .caseInsensitive)
                if result == .orderedSame { continue }
                return result == .orderedAscending ? .older : .newer
            case (.numeric, .alpha):
                return .older
            case (.alpha, .numeric):
                return .newer
            }
        }
        return .same
    }

    private static func captures(pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              match.numberOfRanges >= 2 else {
            return nil
        }

        var results: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let captureRange = Range(match.range(at: index), in: value) else { continue }
            results.append(String(value[captureRange]))
        }
        return results
    }
}
