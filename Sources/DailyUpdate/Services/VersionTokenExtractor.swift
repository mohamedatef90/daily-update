import Foundation

enum VersionTokenExtractor {
    private static let semverPattern =
        #"(?<![0-9A-Za-z])v?(\d+(?:\.\d+)+(?:[-_][0-9A-Za-z.-]+)?)"#
    private static let shaPattern = #"(?i)(?<![0-9a-f])([0-9a-f]{7,40})(?![0-9a-f])"#

    static func extract(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed

        if let semantic = firstMatch(pattern: semverPattern, in: firstLine) {
            return semantic
        }

        if let sha = firstMatch(pattern: shaPattern, in: firstLine), sha.contains(where: { $0.isLetter }) {
            return sha.lowercased()
        }

        return nil
    }

    private static func firstMatch(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              match.numberOfRanges >= 2,
              let tokenRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[tokenRange])
    }
}
