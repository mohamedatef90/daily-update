import Foundation

/// Read-only preflight for npm-owned typed updates: compares the target release's
/// `engines.node` range with the Node that actually runs the owning npm, before any mutation.
///
/// Both inputs come from npm itself as JSON (`npm view --json <pkg>@latest version engines` and
/// `npm version --json`), so nothing is scraped from human-readable output. The range grammar is
/// the node-semver subset used in `engines` fields; anything outside it is `.unevaluable` and
/// gates rather than being guessed.
enum NpmEngineCompatibility {
    enum Verdict: Equatable {
        case compatible, incompatible, unevaluable
    }

    enum Decision: Equatable {
        case compatible
        case gated(String)
    }

    enum Preflight: Equatable {
        case compatible
        case gated(String)
        case checkFailed(String)
    }

    struct PackageMetadata: Equatable {
        let version: String?
        let nodeRange: String?
    }

    // MARK: - Preflight

    static func preflight(packageManagerPath: String, package: String) async -> Preflight {
        let npm = shellQuote(packageManagerPath)
        // Run outside any project so `npm version` cannot pick up a local package.json.
        let neutralDirectory = NSTemporaryDirectory()
        let view = await ShellRunner.run(
            "\(npm) view --json \(shellQuote(package + "@latest")) version engines",
            workingDirectory: neutralDirectory,
            timeout: 30
        )
        guard view.succeeded, let metadata = parsePackageMetadata(view.stdout) else {
            let detail = firstLine(view.stderr) ?? firstLine(view.stdout) ?? "exit \(view.exitCode)"
            return .checkFailed("could not read the Node engine requirement for \(package)@latest (\(detail)); nothing was changed")
        }
        guard metadata.nodeRange != nil else { return .compatible }

        let runtime = await ShellRunner.run("\(npm) version --json", workingDirectory: neutralDirectory, timeout: 15)
        guard runtime.succeeded, let nodeVersion = parseRuntimeNodeVersion(runtime.stdout) else {
            let detail = firstLine(runtime.stderr) ?? "exit \(runtime.exitCode)"
            return .checkFailed("could not read the Node version used by \(packageManagerPath) (\(detail)); nothing was changed")
        }

        switch decision(package: package, metadata: metadata, nodeVersion: nodeVersion) {
        case .compatible: return .compatible
        case .gated(let reason): return .gated(reason)
        }
    }

    static func decision(package: String, metadata: PackageMetadata, nodeVersion: String) -> Decision {
        guard let range = metadata.nodeRange else { return .compatible }
        let target = metadata.version.map { "\(package)@\($0)" } ?? "\(package)@latest"
        let current = nodeVersion.hasPrefix("v") ? nodeVersion : "v\(nodeVersion)"
        switch evaluate(nodeVersion: nodeVersion, range: range) {
        case .compatible:
            return .compatible
        case .incompatible:
            return .gated("\(target) requires Node \(range), but this npm runs Node \(current). Update Node for this installation first; nothing was changed.")
        case .unevaluable:
            return .gated("\(target) declares Node engine range \"\(range)\", which Daily Update cannot evaluate against Node \(current). Check compatibility manually; nothing was changed.")
        }
    }

    // MARK: - npm JSON

    static func parsePackageMetadata(_ json: String) -> PackageMetadata? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let engines = object["engines"] as? [String: Any]
        let range = (engines?["node"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PackageMetadata(
            version: object["version"] as? String,
            nodeRange: range?.isEmpty == false ? range : nil
        )
    }

    static func parseRuntimeNodeVersion(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = object["node"] as? String, !node.isEmpty else { return nil }
        return node
    }

    // MARK: - Range evaluation

    static func evaluate(nodeVersion: String, range: String) -> Verdict {
        guard let partial = PartialVersion(nodeVersion),
              let major = partial.major, let minor = partial.minor, let patch = partial.patch else {
            return .unevaluable
        }
        let version = Version(major: major, minor: minor, patch: patch)
        var sawUnevaluable = false
        for alternative in range.components(separatedBy: "||") {
            guard let comparators = comparatorSet(alternative) else {
                sawUnevaluable = true
                continue
            }
            if comparators.allSatisfy({ $0.matches(version) }) { return .compatible }
        }
        return sawUnevaluable ? .unevaluable : .incompatible
    }

    private struct Version: Comparable {
        let major: Int, minor: Int, patch: Int

        static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// `20`, `20.5`, `20.x`, `v20.5.1`; nil components are wildcards. Prerelease or build
    /// identifiers are rejected so they are never compared by guesswork.
    private struct PartialVersion {
        let major: Int?, minor: Int?, patch: Int?

        init?(_ raw: String) {
            var text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
            guard !text.isEmpty, !text.contains("-"), !text.contains("+") else { return nil }
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count <= 3 else { return nil }
            var values: [Int?] = []
            var wildcardSeen = false
            for piece in pieces {
                if ["x", "X", "*"].contains(piece) {
                    wildcardSeen = true
                    values.append(nil)
                } else if let value = Int(piece), value >= 0, !wildcardSeen {
                    values.append(value)
                } else {
                    return nil
                }
            }
            while values.count < 3 { values.append(nil) }
            major = values[0]
            minor = values[1]
            patch = values[2]
        }
    }

    private struct Comparator {
        enum Operator { case less, lessOrEqual, greater, greaterOrEqual }
        let op: Operator
        let version: Version

        func matches(_ candidate: Version) -> Bool {
            switch op {
            case .less: return candidate < version
            case .lessOrEqual: return candidate <= version
            case .greater: return candidate > version
            case .greaterOrEqual: return candidate >= version
            }
        }
    }

    private static func comparatorSet(_ rawSet: String) -> [Comparator]? {
        // `>= 20.5.0` is accepted by npm; glue operators to their operand.
        let spacedOperator = try! NSRegularExpression(pattern: #"(>=|<=|>|<|=|\^|~)\s+"#)
        let trimmed = rawSet.trimmingCharacters(in: .whitespaces)
        let set = spacedOperator.stringByReplacingMatches(
            in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed), withTemplate: "$1"
        )
        if set.isEmpty { return [] }

        let tokens = set.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.count == 3, tokens[1] == "-" {
            guard let lower = PartialVersion(tokens[0]), let upper = PartialVersion(tokens[2]) else { return nil }
            return hyphenRange(lower: lower, upper: upper)
        }

        var comparators: [Comparator] = []
        for token in tokens {
            guard let expanded = expandComparator(token) else { return nil }
            comparators.append(contentsOf: expanded)
        }
        return comparators
    }

    private static func expandComparator(_ token: String) -> [Comparator]? {
        let operators = [">=", "<=", ">", "<", "=", "^", "~"]
        let op = operators.first { token.hasPrefix($0) } ?? ""
        guard let partial = PartialVersion(String(token.dropFirst(op.count))) else { return nil }
        guard let major = partial.major else {
            // `*`, `x`, `>=*`: any version. `<*` and `>*` match nothing and are not used in practice.
            return ["", "=", ">=", "<=", "^", "~"].contains(op) ? [] : nil
        }
        let minor = partial.minor ?? 0
        let patch = partial.patch ?? 0
        let floor = Version(major: major, minor: minor, patch: patch)

        func ceiling() -> Version {
            partial.minor == nil
                ? Version(major: major + 1, minor: 0, patch: 0)
                : Version(major: major, minor: minor + 1, patch: 0)
        }

        switch op {
        case "", "=":
            if partial.patch == nil { return [.init(op: .greaterOrEqual, version: floor), .init(op: .less, version: ceiling())] }
            return [.init(op: .greaterOrEqual, version: floor), .init(op: .lessOrEqual, version: floor)]
        case ">=":
            return [.init(op: .greaterOrEqual, version: floor)]
        case ">":
            if partial.patch == nil { return [.init(op: .greaterOrEqual, version: ceiling())] }
            return [.init(op: .greater, version: floor)]
        case "<":
            return [.init(op: .less, version: floor)]
        case "<=":
            if partial.patch == nil { return [.init(op: .less, version: ceiling())] }
            return [.init(op: .lessOrEqual, version: floor)]
        case "~":
            return [.init(op: .greaterOrEqual, version: floor), .init(op: .less, version: ceiling())]
        case "^":
            let upper: Version
            if major > 0 || partial.minor == nil {
                upper = Version(major: major + 1, minor: 0, patch: 0)
            } else if minor > 0 || partial.patch == nil {
                upper = Version(major: 0, minor: minor + 1, patch: 0)
            } else {
                upper = Version(major: 0, minor: 0, patch: patch + 1)
            }
            return [.init(op: .greaterOrEqual, version: floor), .init(op: .less, version: upper)]
        default:
            return nil
        }
    }

    private static func hyphenRange(lower: PartialVersion, upper: PartialVersion) -> [Comparator] {
        var result: [Comparator] = []
        if let major = lower.major {
            result.append(.init(op: .greaterOrEqual, version: Version(major: major, minor: lower.minor ?? 0, patch: lower.patch ?? 0)))
        }
        if let major = upper.major {
            if let minor = upper.minor {
                if let patch = upper.patch {
                    result.append(.init(op: .lessOrEqual, version: Version(major: major, minor: minor, patch: patch)))
                } else {
                    result.append(.init(op: .less, version: Version(major: major, minor: minor + 1, patch: 0)))
                }
            } else {
                result.append(.init(op: .less, version: Version(major: major + 1, minor: 0, patch: 0)))
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func firstLine(_ text: String) -> String? {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
