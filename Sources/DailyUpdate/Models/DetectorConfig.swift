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
    let detect: DetectRule?
    let versionCommand: String?
    let checkCommand: String?
    let installCommand: String?
    let updateCommand: String
    let workingDirectory: String?

    var isUserDefined: Bool {
        source == .user
    }

    var isDiscovered: Bool {
        source == .discovered
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
            detectCommand: detect?.command,
            versionCommand: versionCommand,
            checkCommand: checkCommand,
            installCommand: installCommand ?? InstallCommandResolver.resolve(id: id, installCommand: nil, updateCommand: updateCommand),
            updateCommand: updateCommand,
            workingDirectory: workingDirectory
        )
    }
}
