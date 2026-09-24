import Foundation

enum ResolvedOwner: Equatable {
    case brewFormula(String)
    case brewCask(String)
    case npm(prefix: String, package: String)
    case nativeInstaller(NativeInstallerID)
    case pipx(package: String)
    case uvTool(name: String)
    case unknown
}

enum NativeInstallerID: String, Equatable {
    case claudeCode
}

struct OwnerCandidate: Equatable {
    let commandPath: String
    let resolvedPath: String
    let owner: ResolvedOwner
}

struct OwnerResolution: Equatable {
    let commandName: String
    let active: OwnerCandidate?
    let competing: [OwnerCandidate]

    var fingerprint: String? {
        guard let active else { return nil }
        return "\(active.resolvedPath)|\(describe(active.owner))"
    }

    private func describe(_ owner: ResolvedOwner) -> String {
        switch owner {
        case .brewFormula(let formula): return "brew:\(formula)"
        case .brewCask(let token): return "cask:\(token)"
        case .npm(let prefix, let package): return "npm:\(prefix):\(package)"
        case .nativeInstaller(let id): return "native:\(id.rawValue)"
        case .pipx(let package): return "pipx:\(package)"
        case .uvTool(let name): return "uv:\(name)"
        case .unknown: return "unknown"
        }
    }
}

struct EcosystemLayout: Equatable {
    let homeDirectory: String
    let brewCellars: [String]
    let brewCaskrooms: [String]
    let claudeNativeRoot: String
    let uvToolRoots: [String]
    let pipxVenvRoots: [String]

    static func fixture(home: String) -> EcosystemLayout {
        EcosystemLayout(
            homeDirectory: home,
            brewCellars: [
                "\(home)/opt/homebrew/Cellar",
                "\(home)/usr/local/Cellar"
            ],
            brewCaskrooms: [
                "\(home)/opt/homebrew/Caskroom",
                "\(home)/usr/local/Caskroom"
            ],
            claudeNativeRoot: "\(home)/.local/share/claude/versions",
            uvToolRoots: ["\(home)/.local/share/uv/tools"],
            pipxVenvRoots: [
                "\(home)/.local/pipx/venvs",
                "\(home)/.local/share/pipx/venvs"
            ]
        )
    }

    static func live(home: String = NSHomeDirectory()) -> EcosystemLayout {
        EcosystemLayout(
            homeDirectory: home,
            brewCellars: ["/opt/homebrew/Cellar", "/usr/local/Cellar"],
            brewCaskrooms: ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"],
            claudeNativeRoot: "\(home)/.local/share/claude/versions",
            uvToolRoots: ["\(home)/.local/share/uv/tools"],
            pipxVenvRoots: ["\(home)/.local/pipx/venvs", "\(home)/.local/share/pipx/venvs"]
        )
    }
}

enum OwnerResolver {
    static func resolve(commandName: String, layout: EcosystemLayout = .live()) async -> OwnerResolution {
        let result = await ShellRunner.run("whence -ap -- \(ShellEscaping.quote(commandName))")
        let candidates = result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return resolve(commandName: commandName, candidatePaths: candidates, layout: layout)
    }

    static func resolve(
        commandName: String,
        candidatePaths: [String],
        layout: EcosystemLayout = .live()
    ) -> OwnerResolution {
        var seenResolved = Set<String>()
        var resolvedCandidates: [OwnerCandidate] = []

        for commandPath in candidatePaths {
            let expanded = (commandPath as NSString).expandingTildeInPath
            let resolvedPath = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
            guard seenResolved.insert(resolvedPath).inserted else { continue }
            let owner = classify(resolvedPath: resolvedPath, layout: layout)
            resolvedCandidates.append(OwnerCandidate(commandPath: expanded, resolvedPath: resolvedPath, owner: owner))
        }

        let active = resolvedCandidates.first
        let competing = Array(resolvedCandidates.dropFirst())
        return OwnerResolution(commandName: commandName, active: active, competing: competing)
    }

    private static func classify(resolvedPath: String, layout: EcosystemLayout) -> ResolvedOwner {
        if let formula = capture(path: resolvedPath, roots: layout.brewCellars) {
            return .brewFormula(formula)
        }
        if let cask = capture(path: resolvedPath, roots: layout.brewCaskrooms) {
            return .brewCask(cask)
        }
        if let npmOwner = npmOwner(for: resolvedPath) {
            return npmOwner
        }
        if isPath(resolvedPath, within: layout.claudeNativeRoot) {
            return .nativeInstaller(.claudeCode)
        }
        if let name = capture(path: resolvedPath, roots: layout.uvToolRoots) {
            return .uvTool(name: name)
        }
        if let package = capture(path: resolvedPath, roots: layout.pipxVenvRoots) {
            return .pipx(package: package)
        }
        return .unknown
    }

    private static func npmOwner(for path: String) -> ResolvedOwner? {
        let marker = "/lib/node_modules/"
        guard let range = path.range(of: marker) else { return nil }
        let prefix = String(path[..<range.lowerBound])
        let remainder = String(path[range.upperBound...])
        let package = remainder.components(separatedBy: "/").prefix(2).joined(separator: "/")
        guard !package.isEmpty else { return nil }
        return .npm(prefix: prefix, package: package)
    }

    private static func capture(path: String, roots: [String]) -> String? {
        for root in roots {
            let expandedRoot = (root as NSString).expandingTildeInPath
            guard isPath(path, within: expandedRoot) else { continue }
            let relative = String(path.dropFirst(expandedRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let firstComponent = relative.components(separatedBy: "/").first, !firstComponent.isEmpty else {
                continue
            }
            return firstComponent
        }
        return nil
    }

    private static func isPath(_ path: String, within root: String) -> Bool {
        let normalizedRoot = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix("\(normalizedRoot)/")
    }
}
