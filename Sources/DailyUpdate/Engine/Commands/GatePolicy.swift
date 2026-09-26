import CryptoKit
import Foundation

enum GatePolicy {
    private static let yesEligibleReasons: Set<GateReason> = [.bulk, .needsReview, .pinned]

    static func versionsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if let left = Version(lhs), let right = Version(rhs) { return left == right }
        return lhs == rhs
    }

    private struct ReviewContext: Encodable {
        let detect: DetectRule?
        let versionCommand: String?
        let versionPattern: String?
        let checkCommand: String?
        let updateCommand: String
        let installCommand: String
        let workingDirectory: String?
        let command: String?
        let packages: PackageIdentifiers?
        let selfUpdater: String?
        let appcastURL: String?
        let autoUpdates: Bool?
    }

    static func reviewedCommandHash(
        detectCommand: String? = nil, versionCommand: String? = nil,
        checkCommand: String? = nil, updateCommand: String, installCommand: String,
        detectRule: DetectRule? = nil, versionPattern: String? = nil,
        workingDirectory: String? = nil, command: String? = nil,
        packages: PackageIdentifiers? = nil, selfUpdater: String? = nil,
        appcastURL: String? = nil, autoUpdates: Bool? = nil
    ) -> String {
        let context = ReviewContext(
            detect: detectRule ?? detectCommand.map { DetectRule(type: .command, paths: nil, command: $0, appName: nil) },
            versionCommand: versionCommand, versionPattern: versionPattern, checkCommand: checkCommand,
            updateCommand: updateCommand, installCommand: installCommand, workingDirectory: workingDirectory,
            command: command, packages: packages, selfUpdater: selfUpdater, appcastURL: appcastURL, autoUpdates: autoUpdates)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // This context contains only infallibly encodable strings, booleans and enums.
        let payload = try! encoder.encode(context)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    static func reviewedCommandHash(for config: DetectorConfig) -> String {
        reviewedCommandHash(versionCommand: config.versionCommand, checkCommand: config.checkCommand,
            updateCommand: config.updateCommand, installCommand: config.installCommand ?? "",
            detectRule: config.detect, versionPattern: config.versionPattern, workingDirectory: config.workingDirectory,
            command: config.command, packages: config.packages, selfUpdater: config.selfUpdater,
            appcastURL: config.appcastURL, autoUpdates: config.autoUpdates)
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
        guard !item.isAwaitingAutomationReview else { return false }
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
