import Foundation

struct ItemPreference: Codable, Equatable {
    var autoUpdate: Bool = false
    var snoozedUntil: Date? = nil
    var pinnedVersion: String? = nil
    var permanentlyIgnored: Bool = false
}

struct UpdateHistoryEntry: Codable, Identifiable {
    let id: UUID
    let itemID: String
    let itemName: String
    let fromVersion: String?
    let toVersion: String?
    let date: Date
    let success: Bool
    let message: String?
    let command: String

    init(itemID: String, itemName: String, fromVersion: String?, toVersion: String?, success: Bool, message: String?, command: String) {
        self.id = UUID()
        self.itemID = itemID
        self.itemName = itemName
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.date = Date()
        self.success = success
        self.message = message
        self.command = command
    }
}

struct HealthIssue: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let severity: Severity

    enum Severity: String {
        case ok, warning, error
    }
}

struct DuplicateGroup: Identifiable {
    let id: String
    let itemIDs: [String]
    let reason: String
}

struct DashboardStats {
    let totalItems: Int
    let installedCount: Int
    let updatesAvailable: Int
    let snoozedCount: Int
    let autoUpdateCount: Int
    let duplicateCount: Int
    let byCategory: [(ItemCategory, Int)]
    let lastCheck: Date?
}

struct DryRunEntry: Identifiable {
    let id: String
    let name: String
    let command: String
    let action: String
    let category: ItemCategory
}

struct UpdateRunItemResult: Identifiable {
    let id: String
    let name: String
    let success: Bool
    let message: String?
}

struct UpdateRunReport: Identifiable {
    let id = UUID()
    let completedAt: Date
    let succeededCount: Int
    let failedCount: Int
    let results: [UpdateRunItemResult]

    var totalCount: Int { succeededCount + failedCount }
}

struct WidgetSnapshot: Codable {
    var updateCount: Int
    var lastCheck: Date?
    var status: String

    static let fileName = "widget-state.json"
}

enum UpdateGroupOrder {
    static let defaultOrder: [ItemCategory] = [.runtime, .app, .cli, .library, .repo]

    static func sortItems(_ items: [UpdateItem], order: [ItemCategory]) -> [UpdateItem] {
        items.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs.category) ?? order.count
            let ri = order.firstIndex(of: rhs.category) ?? order.count
            if li != ri { return li < ri }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
