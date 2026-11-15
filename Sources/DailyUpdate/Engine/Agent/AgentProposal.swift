import Foundation

// ADR-003 spike: "the model proposes, the engine executes". An agent returns DATA only. This file
// defines that data and the strict parser that turns raw agent output into it. Nothing here runs a
// command. Anything the parser rejects is discarded, never repaired.

enum ProposalOwnerKind: String, Codable, CaseIterable {
    case brewFormula, brewCask, npm, pnpm, yarn, pipx, uvTool, pip, cargo, gem
    case nativeInstaller, appBundle, system, manual, unknown
}

/// Where the latest version can be read from. These mirror what `StrategyPlanner` already knows how
/// to ask for (brew info, the npm registry, a GitHub release); `none` means "no latest source".
enum ProposalLatestSource: String, Codable, CaseIterable {
    case brewInfo, npmRegistry, githubRelease, pypi, selfReported, none
}

enum ProposalVerifyRule: String, Codable, CaseIterable {
    case versionMatchesLatest, versionChanged, exitZero, none
}

/// What the agent thinks should happen. Only `update` may carry a command. `suggestRemoval` never does:
/// the app builds the removal text itself and shows it gated as destructive.
enum ProposalRecommendation: String, Codable, CaseIterable {
    case update, ignore, suggestRemoval, investigate
}

enum ProposalEvidenceAction: String, Codable, CaseIterable {
    case ran, read
}

struct ProposalEvidence: Codable, Equatable {
    let action: ProposalEvidenceAction
    let target: String
    let finding: String
}

struct AgentProposal: Codable, Equatable {
    let ownerKind: ProposalOwnerKind
    /// argv array: executable first. Never a shell string. Nil means "no version reader is proposed" (the
    /// evidence does not show one). Allowed with `investigate`, `suggestRemoval` or `ignore`, never with
    /// `update`, so an agent never has to invent a placeholder command.
    let versionCommand: [String]?
    /// Regular expression with exactly one capture group that extracts the version. Not evaluated when
    /// `versionCommand` is nil.
    let versionPattern: String
    let latestSource: ProposalLatestSource
    /// argv array, or nil when the agent found no safe, ordinary update command.
    let updateCommand: [String]?
    let verify: ProposalVerifyRule
    let confidence: Double
    let evidence: [ProposalEvidence]
    let notes: String
    let recommendation: ProposalRecommendation
    let recommendationReason: String
}

enum ProposalSchemaError: Error, Equatable, CustomStringConvertible {
    case notJSON
    case notAnObject
    case missingKey(String)
    case unexpectedKey(String)
    case wrongType(String)
    case badEnum(key: String, value: String)
    case outOfRange(String)
    case tooLong(String)
    case badCharacters(String)
    case badPattern(String)
    case badCombination(String)

    var description: String {
        switch self {
        case .notJSON: return "output is not JSON"
        case .notAnObject: return "output is not a JSON object"
        case .missingKey(let key): return "missing key \(key)"
        case .unexpectedKey(let key): return "unexpected key \(key)"
        case .wrongType(let key): return "wrong type for \(key)"
        case .badEnum(let key, let value): return "\(key) has a value outside the enum: \(value.prefix(40))"
        case .outOfRange(let key): return "\(key) is out of range"
        case .tooLong(let key): return "\(key) is too long"
        case .badCharacters(let key): return "\(key) contains control characters"
        case .badPattern(let reason): return "versionPattern rejected: \(reason)"
        case .badCombination(let reason): return reason
        }
    }
}

enum ProposalSchema {
    static let maxArgvCount = 16
    static let maxArgLength = 512
    static let maxEvidenceCount = 12
    static let maxTextLength = 2000
    static let maxPatternLength = 200
    static let maxReasonLength = 500

    /// The JSON Schema handed to `codex exec --output-schema`. Codex's structured output needs every
    /// property listed in `required` and `additionalProperties: false`. The same rules are enforced
    /// again by `ProposalParser`, because the engine never trusts the CLI to have enforced them.
    /// `docs/agent-spike/proposal.schema.json` must stay byte-identical to this (a test checks it).
    static let json = """
    {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "title": "DailyUpdateAgentProposal",
      "type": "object",
      "additionalProperties": false,
      "required": ["ownerKind", "versionCommand", "versionPattern", "latestSource", "updateCommand", "verify", "confidence", "evidence", "notes", "recommendation", "recommendationReason"],
      "properties": {
        "ownerKind": {
          "type": "string",
          "enum": ["brewFormula", "brewCask", "npm", "pnpm", "yarn", "pipx", "uvTool", "pip", "cargo", "gem", "nativeInstaller", "appBundle", "system", "manual", "unknown"]
        },
        "versionCommand": {
          "type": ["array", "null"],
          "minItems": 1,
          "maxItems": 16,
          "items": { "type": "string", "maxLength": 512 }
        },
        "versionPattern": { "type": "string", "maxLength": 200 },
        "latestSource": {
          "type": "string",
          "enum": ["brewInfo", "npmRegistry", "githubRelease", "pypi", "selfReported", "none"]
        },
        "updateCommand": {
          "type": ["array", "null"],
          "minItems": 1,
          "maxItems": 16,
          "items": { "type": "string", "maxLength": 512 }
        },
        "verify": {
          "type": "string",
          "enum": ["versionMatchesLatest", "versionChanged", "exitZero", "none"]
        },
        "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
        "evidence": {
          "type": "array",
          "maxItems": 12,
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["action", "target", "finding"],
            "properties": {
              "action": { "type": "string", "enum": ["ran", "read"] },
              "target": { "type": "string", "maxLength": 512 },
              "finding": { "type": "string", "maxLength": 2000 }
            }
          }
        },
        "notes": { "type": "string", "maxLength": 2000 },
        "recommendation": {
          "type": "string",
          "enum": ["update", "ignore", "suggestRemoval", "investigate"]
        },
        "recommendationReason": { "type": "string", "maxLength": 500 }
      }
    }
    """
}

enum ProposalParser {
    private static let topLevelKeys: Set<String> = [
        "ownerKind", "versionCommand", "versionPattern", "latestSource", "updateCommand",
        "verify", "confidence", "evidence", "notes", "recommendation", "recommendationReason",
    ]
    private static let evidenceKeys: Set<String> = ["action", "target", "finding"]

    static func parse(_ data: Data) throws -> AgentProposal {
        guard !data.isEmpty, data.count <= 64 * 1024,
              let any = try? JSONSerialization.jsonObject(with: data) else { throw ProposalSchemaError.notJSON }
        guard let object = any as? [String: Any] else { throw ProposalSchemaError.notAnObject }
        for key in object.keys where !topLevelKeys.contains(key) { throw ProposalSchemaError.unexpectedKey(key) }
        for key in topLevelKeys where object[key] == nil { throw ProposalSchemaError.missingKey(key) }

        let owner: ProposalOwnerKind = try enumValue(object["ownerKind"], key: "ownerKind")
        let latest: ProposalLatestSource = try enumValue(object["latestSource"], key: "latestSource")
        let verify: ProposalVerifyRule = try enumValue(object["verify"], key: "verify")
        let versionCommand = try argv(object["versionCommand"], key: "versionCommand", nullable: true)
        let updateCommand = try argv(object["updateCommand"], key: "updateCommand", nullable: true)
        let pattern = try text(object["versionPattern"], key: "versionPattern", max: ProposalSchema.maxPatternLength)
        // With no version command there is nothing to extract a version from, so the pattern is not run.
        if versionCommand != nil { try checkPattern(pattern) }
        let notes = try text(object["notes"], key: "notes", max: ProposalSchema.maxTextLength)
        let recommendation: ProposalRecommendation = try enumValue(object["recommendation"], key: "recommendation")
        let reason = try text(object["recommendationReason"], key: "recommendationReason", max: ProposalSchema.maxReasonLength)
        // Only `update` may carry a command. In particular `suggestRemoval` carries none at all.
        if recommendation != .update, updateCommand != nil {
            throw ProposalSchemaError.badCombination("updateCommand is only allowed with recommendation update")
        }
        // No version reader is fine when nothing will be updated (`investigate`, `suggestRemoval`, `ignore`);
        // an `update` needs one, because the engine verifies an update by reading the version.
        if versionCommand == nil, recommendation == .update {
            throw ProposalSchemaError.badCombination("versionCommand may be null only with recommendation investigate, suggestRemoval or ignore")
        }

        guard let confidenceNumber = object["confidence"] as? NSNumber,
              CFGetTypeID(confidenceNumber) != CFBooleanGetTypeID() else { throw ProposalSchemaError.wrongType("confidence") }
        let confidence = confidenceNumber.doubleValue
        guard confidence.isFinite, confidence >= 0, confidence <= 1 else { throw ProposalSchemaError.outOfRange("confidence") }

        guard let rawEvidence = object["evidence"] as? [Any] else { throw ProposalSchemaError.wrongType("evidence") }
        guard rawEvidence.count <= ProposalSchema.maxEvidenceCount else { throw ProposalSchemaError.tooLong("evidence") }
        var evidence: [ProposalEvidence] = []
        for item in rawEvidence {
            guard let entry = item as? [String: Any] else { throw ProposalSchemaError.wrongType("evidence[]") }
            for key in entry.keys where !evidenceKeys.contains(key) { throw ProposalSchemaError.unexpectedKey("evidence." + key) }
            for key in evidenceKeys where entry[key] == nil { throw ProposalSchemaError.missingKey("evidence." + key) }
            let action: ProposalEvidenceAction = try enumValue(entry["action"], key: "evidence.action")
            evidence.append(ProposalEvidence(
                action: action,
                target: try text(entry["target"], key: "evidence.target", max: ProposalSchema.maxArgLength),
                finding: try text(entry["finding"], key: "evidence.finding", max: ProposalSchema.maxTextLength)))
        }

        return AgentProposal(
            ownerKind: owner, versionCommand: versionCommand, versionPattern: pattern, latestSource: latest,
            updateCommand: updateCommand, verify: verify, confidence: confidence, evidence: evidence, notes: notes,
            recommendation: recommendation, recommendationReason: reason)
    }

    private static func enumValue<T: RawRepresentable>(_ value: Any?, key: String) throws -> T where T.RawValue == String {
        guard let string = value as? String else { throw ProposalSchemaError.wrongType(key) }
        guard let result = T(rawValue: string) else { throw ProposalSchemaError.badEnum(key: key, value: string) }
        return result
    }

    private static func hasControlCharacters(_ value: String, allowNewlines: Bool) -> Bool {
        value.unicodeScalars.contains { scalar in
            if scalar.value == 0 { return true }
            if allowNewlines, scalar == "\n" || scalar == "\t" { return false }
            return scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    private static func text(_ value: Any?, key: String, max: Int) throws -> String {
        guard let string = value as? String else { throw ProposalSchemaError.wrongType(key) }
        guard string.count <= max else { throw ProposalSchemaError.tooLong(key) }
        guard !hasControlCharacters(string, allowNewlines: true) else { throw ProposalSchemaError.badCharacters(key) }
        return string
    }

    /// An argv array. Elements are single strings with no control characters at all (no newline, so
    /// an element can never smuggle a second command line into a log or a shell).
    private static func argv(_ value: Any?, key: String, nullable: Bool) throws -> [String]? {
        if value is NSNull {
            guard nullable else { throw ProposalSchemaError.wrongType(key) }
            return nil
        }
        guard let array = value as? [Any] else { throw ProposalSchemaError.wrongType(key) }
        guard !array.isEmpty else { throw ProposalSchemaError.outOfRange(key) }
        guard array.count <= ProposalSchema.maxArgvCount else { throw ProposalSchemaError.tooLong(key) }
        var result: [String] = []
        for element in array {
            guard let string = element as? String else { throw ProposalSchemaError.wrongType(key) }
            guard !string.isEmpty || !result.isEmpty else { throw ProposalSchemaError.outOfRange(key) }
            guard string.count <= ProposalSchema.maxArgLength else { throw ProposalSchemaError.tooLong(key) }
            guard !hasControlCharacters(string, allowNewlines: false) else { throw ProposalSchemaError.badCharacters(key) }
            result.append(string)
        }
        guard !result[0].isEmpty else { throw ProposalSchemaError.outOfRange(key) }
        return result
    }

    /// The pattern must compile, have exactly one capture group, no back-references and no nested
    /// quantifier (the classic catastrophic-backtracking shape). The engine, not the agent, runs it.
    private static func checkPattern(_ pattern: String) throws {
        guard !pattern.isEmpty else { throw ProposalSchemaError.badPattern("empty") }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { throw ProposalSchemaError.badPattern("does not compile") }
        guard regex.numberOfCaptureGroups == 1 else { throw ProposalSchemaError.badPattern("needs exactly one capture group") }
        if pattern.range(of: #"\\[1-9]"#, options: .regularExpression) != nil {
            throw ProposalSchemaError.badPattern("back-reference")
        }
        if hasCatastrophicGroup(pattern) {
            throw ProposalSchemaError.badPattern("nested quantifier")
        }
    }

    /// True when a quantified group can match the same text in many ways: its body starts with an
    /// atom that is itself repeated (`(a+)+`, `(\w+\s?)+`, `(.*)*`), or it has a top-level alternation
    /// (`(a|aa)+`). A group that needs a literal between repeats, like `(?:\.\d+)+`, is fine: that is
    /// the normal shape of a version pattern. Groups are matched by a real parenthesis scan.
    static func hasCatastrophicGroup(_ pattern: String) -> Bool {
        let chars = Array(pattern)
        var openers: [Int] = []
        var index = 0
        var inClass = false
        while index < chars.count {
            let character = chars[index]
            if character == "\\" { index += 2; continue }
            if inClass { if character == "]" { inClass = false }; index += 1; continue }
            if character == "[" { inClass = true; index += 1; continue }
            if character == "(" { openers.append(index) }
            if character == ")", let open = openers.popLast() {
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                if let next, next == "+" || next == "*" || next == "{" {
                    if bodyIsAmbiguous(Array(chars[(open + 1)..<index])) { return true }
                }
            }
            index += 1
        }
        return false
    }

    private static func bodyIsAmbiguous(_ rawBody: [Character]) -> Bool {
        var body = rawBody
        if body.starts(with: ["?", ":"]) { body.removeFirst(2) }
        // Strip nested groups and classes so only this group's own top level remains.
        var flat: [Character] = []
        var depth = 0
        var inClass = false
        var index = 0
        while index < body.count {
            let character = body[index]
            if character == "\\" {
                if depth == 0 { flat.append(contentsOf: body[index..<min(index + 2, body.count)]) }
                index += 2
                continue
            }
            if inClass { if character == "]" { inClass = false }; index += 1; continue }
            if character == "[" { inClass = true; if depth == 0 { flat.append("c") }; index += 1; continue }
            if character == "(" { depth += 1; if depth == 1 { flat.append("g") }; index += 1; continue }
            if character == ")" { depth -= 1; index += 1; continue }
            if depth == 0 { flat.append(character) }
            index += 1
        }
        if flat.contains("|") { return true }
        // Starts with one atom (escape, class, group, or a plain character) that is repeated.
        var position = 0
        if flat.first == "\\", flat.count >= 2 { position = 2 } else if !flat.isEmpty { position = 1 }
        return position > 0 && position < flat.count && (flat[position] == "+" || flat[position] == "*")
    }
}
