import CryptoKit
import Foundation

enum GatePolicy {
    private static let yesEligibleReasons: Set<GateReason> = [.bulk, .needsReview, .pinned]

    static func versionsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if let left = Version(lhs), let right = Version(rhs) { return left == right }
        return lhs == rhs
    }

    static func reviewedCommandHash(
        detectCommand: String?,
        versionCommand: String?,
        checkCommand: String?,
        updateCommand: String,
        installCommand: String
    ) -> String {
        let payload = [
            "detect:\(detectCommand ?? "")",
            "version:\(versionCommand ?? "")",
            "check:\(checkCommand ?? "")",
            "update:\(updateCommand)",
            "install:\(installCommand)",
        ].joined(separator: "\n--\n")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func reviewedCommandHash(updateCommand: String, installCommand: String) -> String {
        reviewedCommandHash(
            detectCommand: nil,
            versionCommand: nil,
            checkCommand: nil,
            updateCommand: updateCommand,
            installCommand: installCommand
        )
    }

    static func reviewedCommandHash(for config: DetectorConfig) -> String {
        reviewedCommandHash(
            detectCommand: config.detect?.command,
            versionCommand: config.versionCommand,
            checkCommand: config.checkCommand,
            updateCommand: config.updateCommand,
            installCommand: config.installCommand ?? ""
        )
    }

    static func isReviewSatisfied(for config: DetectorConfig, reviewedHash: String?) -> Bool {
        guard config.requiresReviewBeforeAutomation else { return true }
        guard let reviewedHash else { return false }
        return reviewedHash == reviewedCommandHash(for: config)
    }

    static func updateGateReasons(
        for config: DetectorConfig,
        reviewedHash: String?,
        commandOverride: String? = nil
    ) -> [GateReason] {
        let command = commandOverride ?? config.updateCommand
        let classification = CommandShapeClassifier.classify(command)
        var reasons: [GateReason] = []

        if classification.risks.contains(.bulk) { reasons.append(.bulk) }
        if classification.risks.contains(.remoteScript) { reasons.append(.remoteScript) }
        if classification.risks.contains(.privileged) { reasons.append(.privileged) }
        if classification.risks.contains(.destructive) { reasons.append(.destructive) }

        let requiresReview = classification.needsReview || config.needsReview == true
        if requiresReview {
            let expected = reviewedCommandHash(for: config)
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
