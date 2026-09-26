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

    static func pendingInApp(
        current: String?,
        latest: String?,
        message: String = "Opened app — finish the update inside the app, then run Check Updates"
    ) -> UpdateResult {
        UpdateResult(
            status: .updatePending,
            currentVersion: current,
            latestVersion: latest,
            message: message,
            canRetry: true
        )
    }

    static func failedVerification(current: String?, latest: String?, reason: String) -> UpdateResult {
        UpdateResult(
            status: .failedVerification,
            currentVersion: current,
            latestVersion: latest,
            message: reason,
            canRetry: true
        )
    }
}
