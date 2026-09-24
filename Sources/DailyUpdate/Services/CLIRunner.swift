import Foundation

@MainActor
protocol CLIRunnerState: AnyObject {
    var items: [UpdateItem] { get }
    var confirmBeforeUpdate: Bool { get }
    var selectedActionableItems: [UpdateItem] { get }
    func checkAll() async
    func selectAllInstallable()
    func selectAllUpdates(limitTo ids: [String]?)
    func deselectAll(limitTo ids: [String]?)
    func setSelection(for id: String, selected: Bool)
    func updateSelected(skipDryRun: Bool, explicitTargetIDs: [String]?) async
}

extension AppState: CLIRunnerState {
    func updateSelected(skipDryRun: Bool, explicitTargetIDs: [String]?) async {
        await updateSelected(skipDryRun: skipDryRun, retryItemID: nil, explicitTargetIDs: explicitTargetIDs)
    }
}

enum CLIRunner {
    private enum Command {
        case check
        case installAll
        case updateAll
        case install(itemID: String)
        case update(itemID: String)
        case health
    }

    private struct ParsedArguments {
        var command: Command?
        var json = false
        var yes = false
        var showHelp = false
    }

    private enum ParseError: Error {
        case unknownOption(String)
        case unexpectedArgument(String)
        case missingValue(String)
        case conflictingCommands

        var message: String {
            switch self {
            case .unknownOption(let option):
                return "Unknown option: \(option)"
            case .unexpectedArgument(let argument):
                return "Unexpected argument: \(argument)"
            case .missingValue(let flag):
                return "Missing value for \(flag)."
            case .conflictingCommands:
                return "Specify only one action command at a time."
            }
        }
    }

    private enum ScopedAction {
        case install
        case update

        var flagName: String {
            switch self {
            case .install:
                return "--install"
            case .update:
                return "--update"
            }
        }

        var noun: String {
            switch self {
            case .install:
                return "install"
            case .update:
                return "update"
            }
        }

        func matches(_ item: UpdateItem) -> Bool {
            switch self {
            case .install:
                return item.canInstall
            case .update:
                return item.canUpdate
            }
        }
    }

    static func isCLIInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return first.hasPrefix("-")
    }

    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        let store = UserSettingsStore()
        let state = AppState(settingsStore: store)
        return await run(arguments: arguments, state: state)
    }

    @MainActor
    static func run(
        arguments: [String],
        state: any CLIRunnerState,
        output: (String) -> Void = { print($0) }
    ) async -> Int32 {
        let args = Array(arguments.dropFirst())
        let parsed: ParsedArguments
        do {
            parsed = try parse(arguments: args)
        } catch let error as ParseError {
            output(error.message)
            printHelp(output: output)
            return 1
        } catch {
            output("Failed to parse command line arguments.")
            return 1
        }

        if parsed.showHelp {
            printHelp(output: output)
            return 0
        }

        guard let command = parsed.command else {
            printHelp(output: output)
            return 1
        }

        switch command {
        case .check:
            await state.checkAll()
            if parsed.json {
                printJSON(state, output: output)
            } else {
                printCheckResults(state, output: output)
            }
            return state.items.contains(where: { $0.status == .checkFailed }) ? 1 : 0
        case .installAll:
            await state.checkAll()
            let skipped = state.items.filter { $0.canInstall && ActionCommandPolicy.isRemoteScriptInstaller($0.installCommand) }
            for item in skipped {
                output("skipped \(item.id): remote-script install must be confirmed in the app")
            }
            state.selectAllInstallable()
            return await runSelectedActions(
                state: state,
                requireExplicitConfirmation: state.confirmBeforeUpdate,
                confirmed: parsed.yes,
                emptySelectionExitCode: skipped.isEmpty ? 0 : 2,
                output: output
            )
        case .updateAll:
            await state.checkAll()
            state.selectAllUpdates(limitTo: nil)
            return await runSelectedActions(
                state: state,
                requireExplicitConfirmation: state.confirmBeforeUpdate,
                confirmed: parsed.yes,
                failOnAnyCheckFailure: true,
                output: output
            )
        case .install(let itemID):
            await state.checkAll()
            return await runScopedAction(
                state: state,
                itemID: itemID,
                action: .install,
                confirmed: parsed.yes,
                output: output
            )
        case .update(let itemID):
            await state.checkAll()
            return await runScopedAction(
                state: state,
                itemID: itemID,
                action: .update,
                confirmed: parsed.yes,
                output: output
            )
        case .health:
            let issues = await HealthCheckService.run(settings: UserSettingsStore().settings)
            if parsed.json {
                let data = issues.map { ["title": $0.title, "detail": $0.detail, "severity": $0.severity.rawValue] }
                if let encoded = try? JSONSerialization.data(withJSONObject: data),
                   let str = String(data: encoded, encoding: .utf8) {
                    output(str)
                }
            } else {
                for issue in issues {
                    output("[\(issue.severity.rawValue.uppercased())] \(issue.title): \(issue.detail)")
                }
            }
            return 0
        }
    }

    private static func parse(arguments: [String]) throws -> ParsedArguments {
        var parsed = ParsedArguments()
        var index = 0

        func assignCommand(_ command: Command) throws {
            if parsed.command != nil {
                throw ParseError.conflictingCommands
            }
            parsed.command = command
        }

        func consumeValue(for flag: String) throws -> String {
            let nextIndex = index + 1
            guard nextIndex < arguments.count else { throw ParseError.missingValue(flag) }
            let value = arguments[nextIndex]
            guard !value.hasPrefix("-") else { throw ParseError.missingValue(flag) }
            index = nextIndex
            return value
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                parsed.showHelp = true
            case "--json":
                parsed.json = true
            case "--yes":
                parsed.yes = true
            case "--check":
                try assignCommand(.check)
            case "--health":
                try assignCommand(.health)
            case "--install-all":
                try assignCommand(.installAll)
            case "--update-all":
                try assignCommand(.updateAll)
            case "--install":
                let itemID = try consumeValue(for: "--install")
                try assignCommand(.install(itemID: itemID))
            case "--update":
                let itemID = try consumeValue(for: "--update")
                try assignCommand(.update(itemID: itemID))
            default:
                if let itemID = argument.dropPrefix("--install=") {
                    guard !itemID.isEmpty else { throw ParseError.missingValue("--install") }
                    try assignCommand(.install(itemID: String(itemID)))
                } else if let itemID = argument.dropPrefix("--update=") {
                    guard !itemID.isEmpty else { throw ParseError.missingValue("--update") }
                    try assignCommand(.update(itemID: String(itemID)))
                } else if argument.hasPrefix("-") {
                    throw ParseError.unknownOption(argument)
                } else {
                    throw ParseError.unexpectedArgument(argument)
                }
            }
            index += 1
        }

        return parsed
    }

    @MainActor
    private static func runSelectedActions(
        state: any CLIRunnerState,
        requireExplicitConfirmation: Bool,
        confirmed: Bool,
        emptySelectionExitCode: Int32 = 0,
        failOnAnyCheckFailure: Bool = false,
        output: (String) -> Void
    ) async -> Int32 {
        let remoteInstalls = state.selectedActionableItems.filter {
            $0.canInstall && ActionCommandPolicy.isRemoteScriptInstaller($0.installCommand)
        }
        for item in remoteInstalls {
            state.setSelection(for: item.id, selected: false)
            output("skipped \(item.id): remote-script install must be confirmed in the app")
        }
        let excludedIDs = Set(remoteInstalls.map(\.id))
        let entries = state.selectedActionableItems.filter { !excludedIDs.contains($0.id) }.map { item in
            DryRunEntry(
                id: item.id,
                name: item.name,
                command: item.canInstall ? item.installCommand : item.updateCommand,
                action: item.actionLabel,
                category: item.category
            )
        }
        if entries.isEmpty {
            output("No matching items found.")
            if failOnAnyCheckFailure && state.items.contains(where: { $0.status == .checkFailed }) {
                return 1
            }
            return remoteInstalls.isEmpty ? emptySelectionExitCode : 2
        }

        let requiresRiskConfirmation = entries.contains { entry in
            guard let item = state.items.first(where: { $0.id == entry.id }) else { return false }
            return item.isBulkOperation || item.isRemoteScriptOperation || item.requiresCommandReview
        }

        if requireExplicitConfirmation || requiresRiskConfirmation {
            printDryRunPlan(entries: entries, output: output)
            guard confirmed else {
                output("Confirmation required. Re-run with --yes to execute these actions.")
                return 2
            }
        }

        let targetIDs = Set(entries.map(\.id))
        await state.updateSelected(skipDryRun: true, explicitTargetIDs: nil)
        return actionExitCode(
            state: state,
            targetIDs: targetIDs,
            failOnAnyCheckFailure: failOnAnyCheckFailure
        )
    }

    @MainActor
    private static func runScopedAction(
        state: any CLIRunnerState,
        itemID: String,
        action: ScopedAction,
        confirmed: Bool,
        output: (String) -> Void
    ) async -> Int32 {
        state.deselectAll(limitTo: nil)
        guard let item = state.items.first(where: { $0.id == itemID }) else {
            output("Item ID not found: \(itemID)")
            printAvailableIDs(state: state, for: action, output: output)
            return 1
        }
        // Remote-script and unparseable updates are refused on one path, with
        // or without --yes, whatever gate or loop shape put them there.
        if action == .update, item.status == .gated || action.matches(item),
           ActionCommandPolicy.isRemoteScriptInstaller(item.updateCommand) {
            printDryRunPlan(entries: [
                DryRunEntry(
                    id: item.id,
                    name: item.name,
                    command: item.updateCommand,
                    action: item.actionLabel,
                    category: item.category
                )
            ], output: output)
            output("This update runs a remote script and must be confirmed in the app.")
            return 2
        }
        if action == .update, item.status == .gated, GatePolicy.canRunScopedUpdateWithYes(item), !confirmed {
            printDryRunPlan(entries: [
                DryRunEntry(
                    id: item.id,
                    name: item.name,
                    command: item.updateCommand,
                    action: item.actionLabel,
                    category: item.category
                )
            ], output: output)
            output("This update is gated. Re-run with --yes to execute it.")
            return 2
        }
        let isNormalAction = action.matches(item)
        let isScopedGatedUpdate = action == .update && confirmed && GatePolicy.canRunScopedUpdateWithYes(item)
        guard isNormalAction || isScopedGatedUpdate else {
            output("Item '\(itemID)' is not available for \(action.noun).")
            printAvailableIDs(state: state, for: action, output: output)
            return 1
        }

        if case .update = action, item.isBulkOperation, !confirmed {
            printDryRunPlan(entries: [
                DryRunEntry(
                    id: item.id,
                    name: item.name,
                    command: item.updateCommand,
                    action: item.actionLabel,
                    category: item.category
                )
            ], output: output)
            output("Bulk updates require --yes. Re-run with --yes to execute this action.")
            return 2
        }

        if case .install = action, ActionCommandPolicy.isRemoteScriptInstaller(item.installCommand) {
            printDryRunPlan(entries: [
                DryRunEntry(
                    id: item.id,
                    name: item.name,
                    command: item.installCommand,
                    action: item.actionLabel,
                    category: item.category
                )
            ], output: output)
            output("This install runs a remote script and must be confirmed in the app.")
            return 2
        }

        if item.requiresCommandReview, !confirmed {
            printDryRunPlan(entries: [
                DryRunEntry(
                    id: item.id,
                    name: item.name,
                    command: action == .install ? item.installCommand : item.updateCommand,
                    action: item.actionLabel,
                    category: item.category
                )
            ], output: output)
            output("This command needs review. Re-run with --yes to execute it.")
            return 2
        }

        state.setSelection(for: item.id, selected: true)
        await state.updateSelected(skipDryRun: true, explicitTargetIDs: [item.id])
        return actionExitCode(state: state, targetIDs: Set([item.id]))
    }

    @MainActor
    private static func printAvailableIDs(
        state: any CLIRunnerState,
        for action: ScopedAction,
        output: (String) -> Void
    ) {
        let ids = state.items
            .filter { action.matches($0) || (action == .update && GatePolicy.canRunScopedUpdateWithYes($0)) }
            .map(\.id)
            .sorted()
        if ids.isEmpty {
            output("No items are currently eligible for \(action.noun).")
            return
        }

        output("Available IDs for \(action.flagName):")
        for id in ids {
            output("  \(id)")
        }
    }

    private static func printDryRunPlan(entries: [DryRunEntry], output: (String) -> Void) {
        output("Dry-run plan:")
        for entry in entries {
            output("  [\(entry.action)] \(entry.name) (\(entry.id))")
            output("    \(entry.command)")
        }
    }

    @MainActor
    private static func actionExitCode(
        state: any CLIRunnerState,
        targetIDs: Set<String>,
        failOnAnyCheckFailure: Bool = false
    ) -> Int32 {
        if failOnAnyCheckFailure && state.items.contains(where: { $0.status == .checkFailed }) {
            return 1
        }
        for item in state.items where targetIDs.contains(item.id) {
            switch item.status {
            case .updated, .upToDate, .updatePending:
                continue
            default:
                return 1
            }
        }
        return 0
    }

    private static func printHelp(output: (String) -> Void = { print($0) }) {
        output("""
        Daily Update CLI

        Usage:
          DailyUpdate --check              Check for updates
          DailyUpdate --update-all         Update all available items
          DailyUpdate --update <item-id>   Update one item only
          DailyUpdate --install-all        Install all missing items
          DailyUpdate --install <item-id>  Install one item only
          DailyUpdate --yes                Confirm guarded CLI actions when required
          DailyUpdate --health             Run health checks
          DailyUpdate --json               JSON output (with --check or --health)
          DailyUpdate --help               Show this help

        Run without flags to open the GUI.
        """)
    }

    @MainActor
    private static func printCheckResults(
        _ state: any CLIRunnerState,
        output: (String) -> Void = { print($0) }
    ) {
        let updateCount = state.items.filter {
            $0.status == .updateAvailable || $0.status == .gated || $0.status == .updatePending
        }.count
        output("Daily Update — \(updateCount) update(s) available\n")
        for item in state.items {
            let status = item.status.label
            let version = item.displayVersion
            output("\(item.name) [\(item.category.label)] — \(status) (\(version))")
        }
    }

    @MainActor
    private static func printJSON(
        _ state: any CLIRunnerState,
        output: (String) -> Void = { print($0) }
    ) {
        let payload: [[String: Any]] = state.items.map { item in
            [
                "id": item.id,
                "name": item.name,
                "category": item.category.rawValue,
                "status": item.status.rawValue,
                "currentVersionRaw": item.currentVersionRaw ?? "",
                "currentVersion": item.currentVersion ?? "",
                "latestVersion": item.latestVersion ?? "",
                "gateReasons": item.gateReasons.map(\.rawValue),
                "blockReason": item.blockReason?.rawValue ?? "",
                "plannedCommand": plannedCommand(for: item)
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            output(str)
        }
    }

    private static func plannedCommand(for item: UpdateItem) -> String {
        if item.canInstall {
            return item.installCommand
        }
        if let plannedSpec = item.plannedUpdateCommandSpec {
            return plannedSpec.displayString
        }
        return item.updateCommand
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count)
    }
}
