import Foundation

enum UpdateCommandSemantics {
    /// First command before `||` — the action Daily Update expects to run first.
    static func primarySegment(_ command: String) -> String {
        command.components(separatedBy: "||").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? command
    }

    /// True when the primary update action is an in-app or App Store handoff.
    static func usesInAppUpdateFlow(_ command: String) -> Bool {
        let lower = command.lowercased()
        if lower.contains("if brew"), hasInAppFallback(command) {
            return false
        }

        let primary = primarySegment(command).lowercased()
        if primary.contains("open -a") || primary.contains("open \"-a") || primary.hasPrefix("open ") {
            return true
        }
        if primary.contains("macappstore://") || primary.contains("apps.apple.com") {
            return true
        }
        return false
    }

    /// True when a later branch opens the app (e.g. `brew ... || open -a App`).
    static func hasInAppFallback(_ command: String) -> Bool {
        let lower = command.lowercased()
        if lower.contains("|| open -a") || lower.contains("|| open ") {
            return true
        }
        if lower.contains("else open -a") || lower.contains("else open ") {
            return true
        }
        return false
    }
}
