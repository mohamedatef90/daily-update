import CryptoKit
import Foundation

enum GatePolicy {
    private static let yesEligibleReasons: Set<GateReason> = [.bulk, .needsReview, .pinned]

    static func reviewedCommandHash(updateCommand: String, installCommand: String) -> String {
        let payload = "\(updateCommand)\n--\n\(installCommand)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func updateGateReasons(for config: DetectorConfig, reviewedHash: String?) -> [GateReason] {
        let classification = CommandShapeClassifier.classify(config.updateCommand)
        var reasons: [GateReason] = []

        if classification.risks.contains(.bulk) { reasons.append(.bulk) }
        if classification.risks.contains(.remoteScript) { reasons.append(.remoteScript) }
        if classification.risks.contains(.privileged) { reasons.append(.privileged) }
        if classification.risks.contains(.destructive) { reasons.append(.destructive) }

        let requiresReview = classification.needsReview || config.needsReview == true
        if requiresReview {
            let expected = reviewedCommandHash(updateCommand: config.updateCommand, installCommand: config.installCommand ?? "")
            if reviewedHash != expected {
                reasons.append(.needsReview)
            }
        }

        var seen = Set<GateReason>()
        return reasons.filter { seen.insert($0).inserted }
    }

    static func shouldAutoSelectForUpdate(_ item: UpdateItem) -> Bool {
        item.canUpdate && !item.isBulkOperation
    }

    static func canRunScopedUpdateWithYes(_ item: UpdateItem) -> Bool {
        guard item.status == .gated else { return false }
        guard item.blockReason == nil else { return false }
        let reasons = Set(item.gateReasons)
        guard !reasons.isEmpty else { return false }
        return reasons.isSubset(of: yesEligibleReasons)
    }

    static func isUnsafeCheckPathCommand(checkCommand: String, updateCommand: String) -> Bool {
        let classification = CommandShapeClassifier.classify(checkCommand)
        if classification.risks.contains(.bulk) ||
            classification.risks.contains(.remoteScript) ||
            classification.risks.contains(.privileged) ||
            classification.risks.contains(.destructive) ||
            classification.risks.contains(.unparseable) {
            return true
        }
        if CommandShapeClassifier.containsMutatingPackageManagerVerb(checkCommand) {
            return true
        }
        return CommandShapeClassifier.checkRunsUpdate(check: checkCommand, update: updateCommand)
    }
}
