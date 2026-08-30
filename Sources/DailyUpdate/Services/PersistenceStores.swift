import Foundation

enum UpdateHistoryStore {
    private static var fileURL: URL {
        ConfigLoader.appSupportDirectory.appendingPathComponent("history.json")
    }

    static func load() -> [UpdateHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([UpdateHistoryEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.date > $1.date }
    }

    static func append(_ entry: UpdateHistoryEntry) {
        var entries = load()
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(500))
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

enum WidgetDataStore {
    private static var fileURL: URL {
        ConfigLoader.appSupportDirectory.appendingPathComponent(WidgetSnapshot.fileName)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
