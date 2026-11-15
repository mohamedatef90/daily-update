import Foundation

/// What an update run actually ended as. Only `updated` is a success: the item was changed and the new
/// version was verified. `handedOff` means the app's own updater was opened and nothing is installed yet.
enum ActionOutcomeKind: String, Codable {
    case updated
    case handedOff
    case failedVerification
    case failed
    /// Not run: it changed since the user confirmed, or its command was no longer produced by the planner.
    case skipped
}

/// One item's result of one run, for the CLI and the history. `from` and `to` are the versions seen.
struct ActionOutcome: Equatable {
    var itemID: String
    var name: String
    var kind: ActionOutcomeKind
    var from: String?
    var to: String?
    var message: String?
    var command: String
    var installing: Bool = false

    var isSuccess: Bool { kind == .updated }
}

struct UpdateResult {
    let status: ItemStatus
    let currentVersion: String?
    let latestVersion: String?
    let message: String?
    let canRetry: Bool

    /// True for an item the engine changed OR an updater it opened. Not the same as a success: see `outcomeKind`.
    var completedOrInitiated: Bool {
        status == .updated || status == .updatePending
    }

    var outcomeKind: ActionOutcomeKind {
        switch status {
        case .updated: return .updated
        case .updatePending: return .handedOff
        case .failedVerification: return .failedVerification
        default: return .failed
        }
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
