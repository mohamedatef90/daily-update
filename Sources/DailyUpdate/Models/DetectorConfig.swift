import Foundation

struct DetectorConfigFile: Codable {
    let items: [DetectorConfig]
}

struct DetectorConfig: Codable, Identifiable {
    let id: String
    let name: String
    let category: ItemCategory
    let description: String?
    var schemaVersion: Int? = nil
    var source: ItemSource?
    var command: String? = nil
    var packages: PackageIdentifiers? = nil
    var selfUpdater: String? = nil
    var appcastURL: String? = nil
    var autoUpdates: Bool? = nil
    /// D2: built fresh by `RowBuilder` every run; never loaded from settings or an import.
    var inventory: InventoryIdentity? = nil
    /// `<ecosystem>:<packageID>`, with `@<root>` appended only when two rows would otherwise
    /// share it. An alternate, more memorable ID a CLI caller can address a discovered row by.
    var handle: String? = nil
    let detect: DetectRule?
    let versionCommand: String?
    var versionPattern: String? = nil
    let checkCommand: String?
    let installCommand: String?
    let updateCommand: String
    let workingDirectory: String?
    var needsReview: Bool? = nil

    var isUserDefined: Bool {
        source == .user
    }

    var isDiscovered: Bool {
        source == .discovered
    }

    var hasTypedEngineFields: Bool {
        command != nil || packages != nil || selfUpdater != nil || appcastURL != nil || autoUpdates != nil || inventory != nil
    }

    var requiresReviewBeforeAutomation: Bool {
        needsReview == true && source != .bundled
    }

    func droppingTypedEngineFields() -> DetectorConfig {
        DetectorConfig(
            id: id,
            name: name,
            category: category,
            description: description,
            schemaVersion: schemaVersion,
            source: source,
            command: nil,
            packages: nil,
            selfUpdater: nil,
            appcastURL: nil,
            autoUpdates: nil,
            inventory: nil,
            detect: detect,
            versionCommand: versionCommand,
            versionPattern: versionPattern,
            checkCommand: checkCommand,
            installCommand: installCommand,
            updateCommand: updateCommand,
            workingDirectory: workingDirectory,
            needsReview: needsReview
        )
    }
}

struct PackageIdentifiers: Codable, Hashable {
    var brew: String?
    var brewCask: String?
    var npm: String?
    var pipx: String?
    var uv: String?
    var cargo: String?
    var gem: String?
    var masAdamID: String?

    /// §1 D6: "by package" catalog join — `packages.<eco>` compared against a discovery record's
    /// `packageID`. Ecosystems the schema has no field for yet (pnpm, yarn, bun, …) never join
    /// this way, only by command.
    func identifier(for ecosystem: Ecosystem) -> String? {
        switch ecosystem {
        case .brew: return brew
        case .cask: return brewCask
        case .npm: return npm
        case .pipx: return pipx
        case .uv: return uv
        case .cargo: return cargo
        case .gem: return gem
        case .app: return masAdamID
        default: return nil
        }
    }
}

struct DetectRule: Codable {
    let type: DetectType
    let paths: [String]?
    let command: String?
    let appName: String?
}

enum DetectType: String, Codable {
    case app
    case command
    case path
    case always
}

extension DetectorConfig {
    func toUpdateItem() -> UpdateItem {
        UpdateItem(
            id: id,
            name: name,
            category: category,
            description: description,
            currentVersion: nil,
            latestVersion: nil,
            status: .unknown,
            statusMessage: nil,
            isInstalled: false,
            isSelected: false,
            isUserDefined: isUserDefined,
            source: source,
            autoUpdate: false,
            iconPath: category == .app ? detect?.paths?.first : nil,
            detectCommand: detect?.command,
            command: command,
            packages: packages,
            selfUpdater: selfUpdater,
            appcastURL: appcastURL,
            autoUpdates: autoUpdates,
            versionCommand: versionCommand,
            versionPattern: versionPattern,
            checkCommand: checkCommand,
            installCommand: installCommand ?? InstallCommandResolver.resolve(id: id, installCommand: nil, updateCommand: updateCommand),
            updateCommand: updateCommand,
            workingDirectory: workingDirectory,
            detectedPaths: detect?.paths ?? [],
            needsReview: needsReview ?? false,
            detectRule: detect
        )
    }
}
