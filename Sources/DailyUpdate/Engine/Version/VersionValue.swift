import Foundation

enum VersionValue: Hashable {
    case semantic(Version)
    case revision(String)
    case opaque(String)

    init(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Version(trimmed) {
            self = .semantic(parsed)
            return
        }

        let normalized = trimmed.lowercased()
        if normalized.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil,
           normalized.contains(where: \.isLetter) {
            self = .revision(normalized)
            return
        }

        self = .opaque(trimmed)
    }
}
