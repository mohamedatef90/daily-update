import Foundation

enum BulkUpdatePolicy {
    private static let bulkItemIDs: Set<String> = [
        "brew",
        "global-npm",
        "global-pnpm",
        "global-yarn",
        "pip-packages",
        "gem"
    ]

    static func isBulkOperation(itemID: String) -> Bool {
        bulkItemIDs.contains(itemID)
    }

    static func shouldAutoSelectForUpdate(_ item: UpdateItem) -> Bool {
        item.canUpdate && !isBulkOperation(itemID: item.id)
    }
}
