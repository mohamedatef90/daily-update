import Foundation

/// M2: how discovery results are shown. Everything here is display data derived from a
/// `DiscoveryRunResult`; nothing in this file runs a command or offers an action on an install.

enum DiscoveryStatus: Equatable {
    /// The setting is Off: the app behaves exactly as before.
    case off
    case idle
    case running
    /// `rows` is the number of discovered rows merged; `issues` the number of ecosystems that were
    /// partial or failed (a non-blocking banner).
    case ready(rows: Int, issues: Int, elapsedMs: Int)
    case failed(String)

    var isRunning: Bool { self == .running }
}

struct DiscoveredInstall: Hashable, Identifiable {
    var path: String
    var version: String?
    var ecosystem: String
    var owner: String
    var id: String { path + "|" + ecosystem }
}

/// What the item info shows about one row's installs. Display only (M3 adds actions).
struct ItemDiscoveryDetails: Equatable {
    var activePath: String?
    /// The name the login PATH runs this package by (`ng` for `@angular/cli`), from the install's own bin map.
    /// A discovered row has no catalog `command`, so this is what the agent evidence probe uses.
    var primaryCommand: String?
    var ownerBadge: String
    /// Installs the login PATH shadows (R2), for example the old `/usr/local/bin/gemini`.
    var competing: [DiscoveredInstall] = []
    /// Installs in a root that is not on the login PATH (R3), listed under a version-manager row.
    var inactive: [DiscoveredInstall] = []
    /// Files the PATH runs that no enumerator owns, shadowing this package's own install.
    var shadowedByUnownedFiles: [DiscoveredInstall] = []

    var isEmpty: Bool { competing.isEmpty && inactive.isEmpty && shadowedByUnownedFiles.isEmpty }
}

struct EcosystemGroup: Identifiable, Equatable {
    var ecosystem: Ecosystem
    var count: Int
    var id: String { ecosystem.rawValue }
    var title: String { EcosystemPresentation.title(ecosystem) }
    var icon: String { EcosystemPresentation.icon(ecosystem) }
}

enum EcosystemPresentation {
    /// The sidebar order: package managers first, then version managers.
    static let sidebarOrder: [Ecosystem] = [.brew, .cask, .npm, .pnpm, .yarn, .bun, .uv, .pipx, .pip, .cargo, .gem,
                                            .nvm, .fnm, .mise, .asdf, .pyenv, .rustup]

    static func title(_ ecosystem: Ecosystem) -> String {
        switch ecosystem {
        case .brew: return "Homebrew"
        case .cask: return "Homebrew casks"
        case .npm: return "npm"
        case .pnpm: return "pnpm"
        case .yarn: return "Yarn"
        case .bun: return "Bun"
        case .uv: return "uv"
        case .pipx: return "pipx"
        case .pip: return "pip"
        case .cargo: return "Cargo"
        case .gem: return "RubyGems"
        case .nvm: return "nvm"
        case .fnm: return "fnm"
        case .mise: return "mise"
        case .asdf: return "asdf"
        case .pyenv: return "pyenv"
        case .rustup: return "rustup"
        default: return ecosystem.rawValue
        }
    }

    static func icon(_ ecosystem: Ecosystem) -> String {
        switch ecosystem {
        case .brew, .cask: return "mug"
        case .npm, .pnpm, .yarn, .bun: return "shippingbox"
        case .uv, .pipx, .pip: return "curlybraces"
        case .cargo: return "gearshape.2"
        case .gem: return "diamond"
        case .nvm, .fnm, .mise, .asdf, .pyenv, .rustup: return "square.stack.3d.up"
        default: return "questionmark.folder"
        }
    }

    /// "npm · nvm v24" for an npm package under nvm, "Homebrew" for a formula.
    static func ownerBadge(owner: ResolvedOwner, rootLabel: String?) -> String {
        let base: String
        switch owner {
        case .brewFormula: base = "Homebrew"
        case .brewCask: base = "Homebrew cask"
        case .npm: base = "npm"
        case .pnpm: base = "pnpm"
        case .yarnClassic: base = "Yarn"
        case .bun: base = "Bun"
        case .pipx: base = "pipx"
        case .uvTool: base = "uv"
        case .pipUser: base = "pip"
        case .cargo: base = "Cargo"
        case .gem: base = "RubyGems"
        case .versionManager(let kind, _): base = "\(kind)"
        case .nativeInstaller: base = "Installer"
        case .appStore: base = "App Store"
        case .sparkleApp, .selfUpdatingApp: base = "Self-updating"
        case .agentSkill, .agentPlugin: base = "Agent"
        case .system: base = "System"
        case .unknown: base = "Unknown owner"
        }
        guard let rootLabel, !rootLabel.isEmpty, !rootLabel.hasPrefix("Homebrew") else { return base }
        return "\(base) · \(rootLabel)"
    }
}

enum PathDisplay {
    /// `/Users/<name>/x` shown as `~/x`.
    static func home(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/", path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
