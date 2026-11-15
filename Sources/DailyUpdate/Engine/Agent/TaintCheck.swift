import Foundation

/// AI-1 taint check. A proposal is tainted when one of its argv tokens, URLs or domains appears in the
/// UNTRUSTED text (the item's description, the extra text the app supplied, and the free text of the
/// evidence: a package description, brew caveats, the output of `--version`) but NOT in the STRUCTURED
/// identity (the item's identity, plus the evidence's trusted facts: package name and version, bin names,
/// resolved paths, brew token and tap, bundle id and versions, the parsed version token). The agent may use
/// its own knowledge, so a token that appears nowhere is allowed; only "it appears in the untrusted text and
/// nowhere we verified" is a taint. A tainted proposal can never be an `acceptedCandidate`: it is gated.
enum TaintCheck {
    struct Finding: Equatable {
        var token: String
        var kind: String   // "url", "domain", or "token"
    }

    /// Ordinary vocabulary that is not a payload: the package managers, their verbs and common flags.
    private static let baseline: Set<String> = [
        "brew", "npm", "pnpm", "yarn", "pipx", "uv", "pip", "pip3", "cargo", "gem", "bun", "rustup", "mas", "mise",
        "corepack", "install", "update", "upgrade", "uninstall", "ls", "list", "info", "view", "outdated", "global",
        "latest", "tool", "self-update", "show", "version", "read", "-version",
    ]

    static func findings(proposal: AgentProposal, context: AgentItemContext, evidence: EvidenceBundle) -> [Finding] {
        // Untrusted: the item's description and extra text, AND everything the agent saw in the evidence.
        // Third-party free text (a package description, brew caveats, the output of `--version`) is untrusted
        // even though the engine collected it. Only the structured identity parts are trusted (below).
        let untrusted = ([context.description].compactMap { $0 } + context.extraText + [evidence.combinedText])
            .joined(separator: "\n").lowercased()
        guard !untrusted.isEmpty else { return [] }
        let trusted = trustedText(context: context, evidence: evidence).lowercased()

        var found: [Finding] = []
        var seen = Set<String>()
        let argv = (proposal.versionCommand ?? []) + (proposal.updateCommand ?? [])
        for element in argv {
            for atom in atoms(of: element) {
                let lowered = atom.lowercased()
                guard seen.insert(lowered).inserted, !isOrdinary(lowered) else { continue }
                if untrusted.contains(lowered), !trusted.contains(lowered) {
                    found.append(Finding(token: atom, kind: kind(of: lowered)))
                }
            }
        }
        return found
    }

    /// What the engine can stand behind: the item's identity and the structured identity facts of the evidence
    /// (package name and version, bin names, resolved paths, brew token and tap, bundle id and versions, the
    /// parsed version token). Not the free text of the evidence.
    private static func trustedText(context: AgentItemContext, evidence: EvidenceBundle) -> String {
        var parts: [String] = [context.id, context.name]
        parts += [context.category, context.ecosystem, context.handle, context.root, context.commandName,
                  context.packageID, context.appPath, context.status, context.observedVersion,
                  context.currentPlannedCommand].compactMap { $0 }
        for competing in context.competing {
            parts += [competing.path, competing.version, competing.ecosystem, competing.packageID].compactMap { $0 }
        }
        parts.append(evidence.trustedText)
        return parts.joined(separator: "\n")
    }

    /// Splits one argv element into the pieces that could carry a payload: words, `name=value` parts,
    /// and a package name without its `@version` suffix.
    static func atoms(of element: String) -> [String] {
        var result: [String] = []
        let separators = CharacterSet(charactersIn: " \t\n=|;&<>()\"'`,")
        for word in element.components(separatedBy: separators) where !word.isEmpty {
            // `name@version` or `name@latest` is judged by its name: the version or tag is not a payload,
            // and a poisoned text that repeats the whole string must not taint the clean package name.
            if let at = word.lastIndex(of: "@"), at != word.startIndex {
                let name = String(word[..<at])
                result.append(name.isEmpty ? word : name)
            } else {
                result.append(word)
            }
        }
        return result
    }

    private static func isOrdinary(_ atom: String) -> Bool {
        if baseline.contains(atom) { return true }
        if atom.hasPrefix("-") { return true }           // a flag name; its value is a separate atom
        if atom.count < 3 { return true }
        if atom.range(of: #"^[0-9][0-9a-z.\-+]*$"#, options: .regularExpression) != nil { return true } // a version
        return false
    }

    private static func kind(of atom: String) -> String {
        if atom.contains("://") { return "url" }
        if atom.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil { return "domain" }
        return "token"
    }
}

/// `suggestRemoval` never carries a command from the agent. The engine builds the text itself, from the
/// item's own identity, and labels it as destructive: a person copies and runs it, if they decide to.
struct RemovalSuggestion: Equatable {
    var text: String
    var copyableCommand: String?
    let gate = "destructive: needs a person; never run by the engine"

    static func make(for context: AgentItemContext) -> RemovalSuggestion {
        let fallback = RemovalSuggestion(
            text: "This looks like an accidental install. Remove it with the tool that installed it, after checking nothing uses it.",
            copyableCommand: nil)
        guard let package = context.packageID, let ecosystem = context.ecosystem else { return fallback }
        func suggestion(_ argv: [String]) -> RemovalSuggestion {
            let command = argv.map { $0.range(of: #"^[A-Za-z0-9@/._:=+-]+$"#, options: .regularExpression) != nil ? $0 : ShellEscaping.quote($0) }.joined(separator: " ")
            return RemovalSuggestion(text: "This looks like an accidental install. If you agree, you can remove it yourself with the command below.", copyableCommand: command)
        }
        switch ecosystem {
        case "npm" where PackageNameRules.isValidNpmName(package):
            let prefix = context.root.map { ["--prefix", $0] } ?? []
            return suggestion(["npm", "uninstall", "-g"] + prefix + [package])
        case "brew" where PackageNameRules.isValidBrewFormulaName(package) || PackageNameRules.isValidTapQualifiedName(package):
            return suggestion(["brew", "uninstall", package])
        case "pipx" where PackageNameRules.isValidPyPIName(package):
            return suggestion(["pipx", "uninstall", package])
        case "uv" where PackageNameRules.isValidPyPIName(package):
            return suggestion(["uv", "tool", "uninstall", package])
        case "cargo" where PackageNameRules.isValidCrateName(package):
            return suggestion(["cargo", "uninstall", package])
        case "gem" where PackageNameRules.isValidGemName(package):
            return suggestion(["gem", "uninstall", package])
        default:
            return fallback
        }
    }
}
