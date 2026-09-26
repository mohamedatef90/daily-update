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

enum GateReason: String, Codable, CaseIterable, Hashable {
    case bulk
    case remoteScript
    case privileged
    case destructive
    case needsReview
    case pinned

    var label: String {
        switch self {
        case .bulk: return "Bulk update"
        case .remoteScript: return "Remote script"
        case .privileged: return "Needs admin privileges"
        case .destructive: return "Destructive command"
        case .needsReview: return "Needs review"
        case .pinned: return "Pinned version"
        }
    }
}

enum BlockReason: String, Codable, Hashable {
    case unknownOwner
    case noStrategy
    case systemOwned
    case vendorInstaller
    case managedByVersionManager
    case bundledWith
    case needsPrivilege
    case untrustedPath
    case ownerMismatch
    case noReadOnlyLatestSource
    case unverifiedSelfUpdater
    case unsafeCheckCommand
    case manualOnly

    var label: String {
        switch self {
        case .unsafeCheckCommand: return "Unsafe check command"
        case .needsPrivilege: return "Needs administrator permissions"
        case .systemOwned: return "Managed by system"
        case .managedByVersionManager: return "Managed by version manager"
        case .bundledWith: return "Bundled with another tool"
        case .manualOnly: return "Manual update only"
        case .noReadOnlyLatestSource: return "No read-only latest source"
        case .unverifiedSelfUpdater: return "Unverified self-updater"
        case .ownerMismatch: return "Owner mismatch"
        case .untrustedPath: return "Untrusted path"
        case .vendorInstaller: return "Managed by vendor installer"
        case .noStrategy: return "No update strategy"
        case .unknownOwner: return "Unknown owner"
        }
    }
}

enum ItemStatus: String, Codable {
    case unknown
    case checking
    case checkFailed
    case upToDate
    case updateAvailable
    case gated
    case blocked
    case failedVerification
    case updatePending
    case notInstalled
    case error
    case updating
    case updated

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .checking: return "Checking…"
        case .checkFailed: return "Check failed"
        case .upToDate: return "Current"
        case .updateAvailable: return "Update available"
        case .gated: return "Needs you"
        case .blocked: return "Can't update here"
        case .failedVerification: return "Didn't update"
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
    var currentVersionRaw: String? = nil
    var currentVersion: String?
    var latestVersion: String?
    var status: ItemStatus
    var statusMessage: String?
    var gateReasons: [GateReason] = []
    var blockReason: BlockReason?
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
    var command: String? = nil
    var packages: PackageIdentifiers? = nil
    var selfUpdater: String? = nil
    var appcastURL: String? = nil
    var autoUpdates: Bool? = nil
    let versionCommand: String?
    var versionPattern: String? = nil
    let checkCommand: String?
    let installCommand: String
    let updateCommand: String
    let workingDirectory: String?
    var plannedUpdateCommandSpec: CommandSpec? = nil
    var ownerFingerprint: String? = nil
    var detectedPaths: [String] = []
    var needsReview: Bool = false
    var detectRule: DetectRule? = nil

    var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > Date()
    }

    var isPinnedMismatch: Bool {
        guard let pinnedVersion = pinnedVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pinnedVersion.isEmpty,
              let targetVersion = latestVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !targetVersion.isEmpty else {
            return false
        }
        return !GatePolicy.versionsMatch(targetVersion, pinnedVersion)
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
        isInstalled && status == .updateAvailable
    }

    var canRetryUpdate: Bool {
        isInstalled && (
            status == .error ||
            status == .updatePending ||
            status == .failedVerification ||
            (status == .updateAvailable && statusMessage != nil)
        )
    }

    var needsAdministratorPermission: Bool {
        if blockReason == .needsPrivilege { return true }
        guard status == .error, let message = statusMessage?.lowercased() else { return false }
        return message.contains("needs permission") ||
            message.contains("permission denied") ||
            message.contains("eacces") ||
            message.contains("administrator password") ||
            message.contains("sudo:")
    }

    var isBulkOperation: Bool {
        gateReasons.contains(.bulk) || ActionCommandPolicy.matchesBulkPattern(updateCommand)
    }

    var isRemoteScriptOperation: Bool {
        ActionCommandPolicy.isRemoteScriptInstaller(updateCommand) ||
            ActionCommandPolicy.isRemoteScriptInstaller(installCommand)
    }

    var commandReviewHash: String {
        GatePolicy.reviewedCommandHash(
            detectCommand: detectCommand,
            versionCommand: versionCommand,
            checkCommand: checkCommand,
            updateCommand: updateCommand,
            installCommand: installCommand,
            detectRule: detectRule, versionPattern: versionPattern, workingDirectory: workingDirectory,
            command: command, packages: packages, selfUpdater: selfUpdater,
            appcastURL: appcastURL, autoUpdates: autoUpdates
        )
    }

    var isAwaitingAutomationReview: Bool {
        source != .bundled && needsReview && gateReasons.contains(.needsReview)
    }

    var requiresCommandReview: Bool {
        needsReview || gateReasons.contains(.needsReview)
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
        hasher.combine(gateReasons)
        hasher.combine(blockReason)
        hasher.combine(currentVersion)
        hasher.combine(currentVersionRaw)
        hasher.combine(latestVersion)
        hasher.combine(statusMessage)
        hasher.combine(versionPattern)
        hasher.combine(plannedUpdateCommandSpec)
        hasher.combine(ownerFingerprint)
    }

    static func == (lhs: UpdateItem, rhs: UpdateItem) -> Bool {
        lhs.id == rhs.id &&
            lhs.isSelected == rhs.isSelected &&
            lhs.status == rhs.status &&
            lhs.statusMessage == rhs.statusMessage &&
            lhs.gateReasons == rhs.gateReasons &&
            lhs.blockReason == rhs.blockReason &&
            lhs.currentVersionRaw == rhs.currentVersionRaw &&
            lhs.currentVersion == rhs.currentVersion &&
            lhs.latestVersion == rhs.latestVersion &&
            lhs.versionPattern == rhs.versionPattern &&
            lhs.plannedUpdateCommandSpec == rhs.plannedUpdateCommandSpec &&
            lhs.ownerFingerprint == rhs.ownerFingerprint &&
            lhs.isInstalled == rhs.isInstalled &&
            lhs.autoUpdate == rhs.autoUpdate &&
            lhs.isSnoozed == rhs.isSnoozed &&
            lhs.permanentlyIgnored == rhs.permanentlyIgnored &&
            lhs.duplicateGroupID == rhs.duplicateGroupID &&
            lhs.pinnedVersion == rhs.pinnedVersion &&
            lhs.needsReview == rhs.needsReview
    }
}
