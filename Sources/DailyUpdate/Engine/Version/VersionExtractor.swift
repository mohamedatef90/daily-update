import Foundation

enum VersionExtractor {
    static let defaultPattern =
        #"(?<![0-9.])v?(\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]*[0-9A-Za-z]|[a-z]+[0-9]*|_\d+)?)"#
    private static let shaPattern = #"(?i)(?<![0-9a-f])([0-9a-f]{7,40})(?![0-9a-f])"#

    static func extract(from output: String, pattern: String? = nil) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed

        if let pattern, let custom = firstMatch(pattern: pattern, in: firstLine) {
            return custom
        }

        if let semantic = firstMatch(pattern: defaultPattern, in: firstLine) {
            return semantic
        }

        if let sha = firstMatch(pattern: shaPattern, in: firstLine), sha.contains(where: { $0.isLetter }) {
            return sha.lowercased()
        }

        return nil
    }

    static func validate(pattern: String) throws {
        let regex = try NSRegularExpression(pattern: pattern)
        guard regex.numberOfCaptureGroups == 1 else {
            throw PatternValidationError.singleCaptureGroupRequired
        }
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

    enum PatternValidationError: LocalizedError {
        case singleCaptureGroupRequired

        var errorDescription: String? {
            "Version pattern must include exactly one capture group."
        }
    }
}
