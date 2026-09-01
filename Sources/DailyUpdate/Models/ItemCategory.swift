import Foundation

enum ItemCategory: String, Codable, CaseIterable, Identifiable {
    case app
    case cli
    case runtime
    case library
    case repo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .app: return "Apps"
        case .cli: return "CLIs"
        case .runtime: return "Runtimes"
        case .library: return "Libraries"
        case .repo: return "Repos"
        }
    }

    var icon: String {
        switch self {
        case .app: return "app.fill"
        case .cli: return "terminal.fill"
        case .runtime: return "gearshape.2.fill"
        case .library: return "books.vertical.fill"
        case .repo: return "folder.fill"
        }
    }
}

enum ItemStatus: String, Codable {
    case unknown
    case checking
    case upToDate
    case updateAvailable
    case updatePending
    case notInstalled
    case error
    case updating
    case updated

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .updateAvailable: return "Update available"
        case .updatePending: return "Finish in app"
        case .notInstalled: return "Not installed"
        case .error: return "Update failed"
        case .updating: return "Updating…"
        case .updated: return "Updated"
        }
    }
}

struct UpdateItem: Identifiable, Hashable {
    let id: String
    let name: String
    let category: ItemCategory
    let description: String?
    var currentVersion: String?
    var latestVersion: String?
    var status: ItemStatus
    var statusMessage: String?
    var isInstalled: Bool
    var isSelected: Bool
    var isUserDefined: Bool
    var source: ItemSource?
    var autoUpdate: Bool = false
    var snoozedUntil: Date? = nil
    var pinnedVersion: String? = nil
    var permanentlyIgnored: Bool = false
    var duplicateGroupID: String? = nil
    let iconPath: String?
    let detectCommand: String?
    let versionCommand: String?
    let checkCommand: String?
    let installCommand: String
    let updateCommand: String
    let workingDirectory: String?

    var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > Date()
    }

    var isPinnedMismatch: Bool {
        guard let pinnedVersion, let currentVersion else { return false }
        return !currentVersion.contains(pinnedVersion) && pinnedVersion != currentVersion
    }

    var displayVersion: String {
        if let current = currentVersion, let latest = latestVersion, current != latest {
            return "\(current) → \(latest)"
        }
        return currentVersion ?? latestVersion ?? "—"
    }

    var sourceLabel: String {
        if let source { return source.label }
        if isUserDefined { return ItemSource.user.label }
        if id.hasPrefix("discovered-") { return ItemSource.discovered.label }
        return ItemSource.bundled.label
    }

    var canInstall: Bool {
        !isInstalled && !installCommand.isEmpty && status == .notInstalled
    }

    var canUpdate: Bool {
        isInstalled && (status == .updateAvailable || status == .updatePending)
    }

    var canRetryUpdate: Bool {
        isInstalled && (status == .error || status == .updatePending || (status == .updateAvailable && statusMessage != nil))
    }

    var isActionable: Bool {
        if isSnoozed || permanentlyIgnored { return false }
        if canInstall { return true }
        return canUpdate && !updateCommand.isEmpty
    }

    var actionLabel: String {
        canInstall && !canUpdate ? "Install" : "Update"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(isSelected)
        hasher.combine(status)
        hasher.combine(currentVersion)
        hasher.combine(latestVersion)
        hasher.combine(statusMessage)
    }

    static func == (lhs: UpdateItem, rhs: UpdateItem) -> Bool {
        lhs.id == rhs.id &&
            lhs.isSelected == rhs.isSelected &&
            lhs.status == rhs.status &&
            lhs.statusMessage == rhs.statusMessage &&
            lhs.currentVersion == rhs.currentVersion &&
            lhs.latestVersion == rhs.latestVersion &&
            lhs.isInstalled == rhs.isInstalled &&
            lhs.autoUpdate == rhs.autoUpdate &&
            lhs.isSnoozed == rhs.isSnoozed &&
            lhs.permanentlyIgnored == rhs.permanentlyIgnored &&
            lhs.duplicateGroupID == rhs.duplicateGroupID &&
            lhs.pinnedVersion == rhs.pinnedVersion
    }
}
