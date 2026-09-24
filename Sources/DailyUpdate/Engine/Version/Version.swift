import Foundation

struct Version: Hashable, Comparable, CustomStringConvertible {
    enum Identifier: Hashable, Comparable {
        case numeric(Int)
        case alpha(String)

        static func < (lhs: Identifier, rhs: Identifier) -> Bool {
            switch (lhs, rhs) {
            case let (.numeric(l), .numeric(r)):
                return l < r
            case let (.alpha(l), .alpha(r)):
                return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
            case (.numeric, .alpha):
                return true
            case (.alpha, .numeric):
                return false
            }
        }
    }

    let core: [Int]
    let prerelease: [Identifier]
    let post: Int?
    let raw: String

    var description: String {
        raw
    }

    init?(_ token: String) {
        let normalized = Version.normalize(token)
        guard !normalized.isEmpty else { return nil }

        let dateNormalized = Version.normalizeDateToken(normalized)
        let parts = Version.extractCoreAndSuffix(from: dateNormalized)
        guard let core = parts.core else { return nil }

        self.core = core
        self.prerelease = Version.extractPrerelease(from: parts.suffix)
        self.post = Version.extractPostRevision(from: parts.suffix)
        self.raw = normalized
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let maxCoreCount = max(lhs.core.count, rhs.core.count)
        for index in 0..<maxCoreCount {
            let left = index < lhs.core.count ? lhs.core[index] : 0
            let right = index < rhs.core.count ? rhs.core[index] : 0
            if left != right {
                return left < right
            }
        }

        if lhs.prerelease.isEmpty, !rhs.prerelease.isEmpty { return false }
        if !lhs.prerelease.isEmpty, rhs.prerelease.isEmpty { return true }
        if lhs.prerelease != rhs.prerelease {
            let sharedCount = min(lhs.prerelease.count, rhs.prerelease.count)
            for index in 0..<sharedCount where lhs.prerelease[index] != rhs.prerelease[index] {
                return lhs.prerelease[index] < rhs.prerelease[index]
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }

        switch (lhs.post, rhs.post) {
        case let (left?, right?):
            return left < right
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        default:
            return false
        }
    }

    private static func normalize(_ token: String) -> String {
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        if let commaIndex = value.firstIndex(of: ",") {
            value = String(value[..<commaIndex])
        }
        if let plusIndex = value.firstIndex(of: "+") {
            value = String(value[..<plusIndex])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeDateToken(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"^(\d{4})-(\d{1,2})-(\d{1,2})$"#) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              match.numberOfRanges >= 4,
              let yearRange = Range(match.range(at: 1), in: value),
              let monthRange = Range(match.range(at: 2), in: value),
              let dayRange = Range(match.range(at: 3), in: value) else {
            return value
        }
        return "\(value[yearRange]).\(value[monthRange]).\(value[dayRange])"
    }

    private static func extractCoreAndSuffix(from token: String) -> (core: [Int]?, suffix: String) {
        let pattern = #"^(\d+(?:\.\d+)*)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (nil, token)
        }
        let fullRange = NSRange(token.startIndex..<token.endIndex, in: token)
        guard let match = regex.firstMatch(in: token, range: fullRange),
              match.numberOfRanges >= 3,
              let coreRange = Range(match.range(at: 1), in: token),
              let suffixRange = Range(match.range(at: 2), in: token) else {
            return (nil, token)
        }

        let coreParts = token[coreRange].split(separator: ".")
        let core = coreParts.compactMap { Int($0) }
        guard !core.isEmpty else {
            return (nil, String(token[suffixRange]))
        }
        return (core, String(token[suffixRange]))
    }

    private static func extractPostRevision(from suffix: String) -> Int? {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let postPatterns = [#"(?:^|[._-])post(\d+)$"#, #"_(\d+)$"#, #"-([0-9]+)-g[0-9a-f]{7,40}$"#]
        for pattern in postPatterns {
            if let value = capturedInt(pattern: pattern, in: trimmed) {
                return value
            }
        }
        return nil
    }

    private static func extractPrerelease(from suffix: String) -> [Identifier] {
        guard !suffix.isEmpty else { return [] }
        var value = suffix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        guard !value.isEmpty else { return [] }

        value = value.replacingOccurrences(of: "_", with: ".")
        if let postRange = value.range(of: #"(?:^|[.-])post\d+$"#, options: .regularExpression) {
            value.removeSubrange(postRange)
        } else if let gitDescribeRange = value.range(of: #"-\d+-g[0-9a-f]{7,40}$"#, options: [.regularExpression, .caseInsensitive]) {
            value.removeSubrange(gitDescribeRange)
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        guard !value.isEmpty else { return [] }

        var identifiers: [Identifier] = []
        for part in value.split(separator: ".") {
            for segment in splitAlphaNumeric(String(part)) where !segment.isEmpty {
                if let number = Int(segment) {
                    identifiers.append(.numeric(number))
                } else {
                    identifiers.append(.alpha(segment.lowercased()))
                }
            }
        }
        return identifiers
    }

    private static func splitAlphaNumeric(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        var segments: [String] = []
        var current = ""
        var wasDigit = value.first?.isNumber ?? false

        for char in value {
            if current.isEmpty {
                current = String(char)
                wasDigit = char.isNumber
                continue
            }

            if char.isNumber == wasDigit {
                current.append(char)
            } else {
                segments.append(current)
                current = String(char)
                wasDigit = char.isNumber
            }
        }

        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    private static func capturedInt(pattern: String, in value: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return Int(value[captureRange])
    }
}
