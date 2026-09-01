import Foundation

struct UpdateResult {
    let status: ItemStatus
    let currentVersion: String?
    let latestVersion: String?
    let message: String?
    let canRetry: Bool

    var completedOrInitiated: Bool {
        status == .updated || status == .updatePending
    }

    static func success(current: String?, latest: String?, note: String? = nil) -> UpdateResult {
        UpdateResult(
            status: .updated,
            currentVersion: current,
            latestVersion: latest,
            message: note,
            canRetry: false
        )
    }

    static func failed(reason: String, current: String?, latest: String?) -> UpdateResult {
        UpdateResult(
            status: .error,
            currentVersion: current,
            latestVersion: latest,
            message: reason,
            canRetry: true
        )
    }

    static func pendingInApp(current: String?, latest: String?) -> UpdateResult {
        UpdateResult(
            status: .updatePending,
            currentVersion: current,
            latestVersion: latest,
            message: "Opened app — finish the update inside the app, then run Check Updates",
            canRetry: true
        )
    }

    static func stillBehind(current: String?, latest: String?, reason: String) -> UpdateResult {
        UpdateResult(
            status: .updateAvailable,
            currentVersion: current,
            latestVersion: latest,
            message: reason,
            canRetry: true
        )
    }
}
