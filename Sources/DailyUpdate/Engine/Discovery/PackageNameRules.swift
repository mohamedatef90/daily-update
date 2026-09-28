import Foundation

/// ADR-002 §7.4: per-ecosystem name regexes, plus the sanitizer applied to any text read from a
/// manifest (name, display name, description, source) before it reaches the UI, the log or
/// `--json`. Read-only; no I/O.
enum PackageNameRules {
    /// A name may never start with `-` (it would be read as a flag once it reaches argv), and it
    /// must not contain path separators, so it can never mean "escape the package folder".
    static func isValidGenericName(_ name: String, pattern: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("/"), !name.contains("\0") else { return false }
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    static func isValidNpmName(_ name: String) -> Bool {
        !name.hasPrefix("-") && name.range(
            of: #"^(?:@(?:[a-z0-9-~][a-z0-9-._~]*)/[a-z0-9-~][a-z0-9-._~]*|[a-z0-9-~][a-z0-9-._~]*)$"#,
            options: .regularExpression
        ) != nil
    }

    static func isValidBrewFormulaName(_ name: String) -> Bool {
        isValidGenericName(name, pattern: #"^[a-z0-9][a-z0-9+_.@-]*$"#)
    }

    /// `owner/tap/formula` — Amendment 1 F7, for formulae and casks not from the default tap.
    static func isValidTapQualifiedName(_ name: String) -> Bool {
        name.range(
            of: #"^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9+_.@-]*$"#,
            options: .regularExpression
        ) != nil
    }

    static func isValidCaskToken(_ name: String) -> Bool {
        isValidGenericName(name, pattern: #"^[a-z0-9][a-z0-9.+_-]*$"#)
    }

    /// PEP 508 names, compared after PEP 503 normalization by the caller.
    static func isValidPyPIName(_ name: String) -> Bool {
        isValidGenericName(name, pattern: #"^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$"#)
    }

    static func pep503Normalized(_ name: String) -> String {
        name.replacingOccurrences(of: #"[-_.]+"#, with: "-", options: .regularExpression).lowercased()
    }

    static func isValidCrateName(_ name: String) -> Bool {
        name.count <= 64 && isValidGenericName(name, pattern: #"^[A-Za-z0-9_-]{1,64}$"#)
    }

    static func isValidGemName(_ name: String) -> Bool {
        isValidGenericName(name, pattern: #"^[A-Za-z0-9._-]+$"#)
    }

    static func isValidPluginName(_ name: String) -> Bool {
        isValidGenericName(name, pattern: #"^[A-Za-z0-9._-]+$"#)
    }

    static func isValidSkillName(_ name: String) -> Bool {
        isValidGenericName(name, pattern: #"^[A-Za-z0-9._-]+$"#)
    }

    /// Prints only ASCII 0x20-0x7E (matching the OpenCode-tag sanitizer already used elsewhere in
    /// the engine), then truncates. Anything else (control characters, escape sequences meant to
    /// confuse a terminal or a log line) becomes `?`.
    static func sanitize(_ value: String, maxLength: Int = 200) -> String {
        let printable = value.unicodeScalars.prefix(maxLength).map { scalar -> Character in
            (0x20...0x7E).contains(scalar.value) ? Character(scalar) : "?"
        }
        let truncatedMarker = value.unicodeScalars.count > maxLength ? "…" : ""
        return String(printable) + truncatedMarker
    }
}
