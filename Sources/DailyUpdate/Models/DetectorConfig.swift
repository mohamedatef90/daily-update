import Foundation

struct DetectorConfigFile: Codable {
    let items: [DetectorConfig]
}

struct DetectorConfig: Codable, Identifiable {
    let id: String
    let name: String
    let category: ItemCategory
    let description: String?
    var source: ItemSource?
    var command: String? = nil
    var packages: PackageIdentifiers? = nil
    var selfUpdater: String? = nil
    var appcastURL: String? = nil
    var autoUpdates: Bool? = nil
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
            needsReview: needsReview ?? false
        )
    }
}
