import Foundation

private final class CLIValueBox<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var storedValue: Value?
    private var finished = false

    func complete(with value: Value) {
        condition.lock()
        storedValue = value
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func resultIfReady() -> Value? {
        condition.lock()
        defer { condition.unlock() }
        return finished ? storedValue : nil
    }

    func wait() -> Value {
        condition.lock()
        while !finished { condition.wait() }
        let value = storedValue!
        condition.unlock()
        return value
    }
}

enum CLIRunner {
    static func isCLIInvocation(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.hasPrefix("-") }
    }

    static func run(arguments: [String]) async -> Int32 {
        let args = Array(arguments.dropFirst())
        let flags = Set(args.filter { $0.hasPrefix("-") })
        let json = flags.contains("--json")

        if flags.contains("--help") || flags.contains("-h") {
            printHelp()
            return 0
        }

        if flags.contains("--health") {
            let store = UserSettingsStore()
            let issues = await HealthCheckService.run(settings: store.settings)
            printHealth(issues, json: json)
            return issues.contains { $0.severity == .error } ? 1 : 0
        }

        if flags.contains("--audit") {
            let audits = await DeveloperCLIAuditService.auditAll()
            printAudits(audits, json: json)
            return audits.contains { $0.outcome == .checkFailed } ? 2 : 0
        }

        let store = UserSettingsStore()
        let state = await MainActor.run {
            AppState(settingsStore: store, runtimeMode: .commandLine)
        }

        if flags.contains("--check") {
            await state.checkAll()
            await MainActor.run { json ? printJSON(state) : printCheckResults(state) }
            return 0
        }

        if flags.contains("--install-all") {
            await state.checkAll()
            let targetIDs = await MainActor.run { () -> Set<String> in
                state.selectAllInstallable()
                return Set(state.selectedActionableItems.map(\.id))
            }
            guard !targetIDs.isEmpty else { return actionExitCode(attemptedCount: 0, statuses: []) }
            await state.updateSelected(skipDryRun: true)
            let statuses = await MainActor.run {
                state.items.filter { targetIDs.contains($0.id) }.map(\.status)
            }
            return actionExitCode(attemptedCount: targetIDs.count, statuses: statuses)
        }

        if flags.contains("--update-all") {
            await state.checkAll()
            let targetIDs = await MainActor.run { () -> Set<String> in
                state.selectAllUpdates()
                return Set(state.selectedActionableItems.map(\.id))
            }
            guard !targetIDs.isEmpty else { return actionExitCode(attemptedCount: 0, statuses: []) }
            await state.updateSelected(skipDryRun: true)
            let statuses = await MainActor.run {
                state.items.filter { targetIDs.contains($0.id) }.map(\.status)
            }
            return actionExitCode(attemptedCount: targetIDs.count, statuses: statuses)
        }

        if flags.contains("--install") || flags.contains("--update") {
            let installing = flags.contains("--install")
            guard let itemID = selectedItemID(arguments: args, flag: installing ? "--install" : "--update") else {
                fputs("DailyUpdate: --install and --update require an item id, e.g. --update opencode (see --check --json for ids).\n", stderr)
                return 64
            }
            await state.checkAll()
            let selected = await MainActor.run { () -> Bool in
                guard let item = state.items.first(where: { $0.id == itemID }) else { return false }
                guard installing ? item.canInstall : item.canUpdate else { return false }
                state.deselectAll()
                state.setSelection(for: item.id, isSelected: true)
                return !state.selectedActionableItems.isEmpty
            }
            guard selected else {
                let item = await MainActor.run { state.items.first(where: { $0.id == itemID }) }
                let reason = item.map { "\($0.status.label)\($0.statusMessage.map { ": \($0)" } ?? "")" } ?? "unknown item id"
                fputs("DailyUpdate: \(itemID) is not actionable (\(reason)).\n", stderr)
                return 3
            }
            await state.updateSelected(skipDryRun: true)
            // The run re-checks successful items afterwards, so read the recorded result
            // rather than the (already refreshed) live status.
            let (status, line) = await MainActor.run { () -> (ItemStatus, String) in
                let item = state.items.first(where: { $0.id == itemID })
                if let entry = state.history.first(where: { $0.itemID == itemID }) {
                    let versions = [entry.fromVersion, entry.toVersion].compactMap { $0 }.joined(separator: " → ")
                    let verdict = entry.success ? "Updated" : (item?.status.label ?? "Failed")
                    return (
                        entry.success ? .updated : (item?.status ?? .error),
                        "\(itemID): \(verdict) \(versions)\(entry.message.map { " — \($0)" } ?? "")"
                    )
                }
                return (item?.status ?? .error, "\(itemID): \(item?.status.label ?? "Error")")
            }
            print(line)
            return actionExitCode(attemptedCount: 1, statuses: [status])
        }

        printHelp()
        return 1
    }

    /// The value following `flag`, e.g. `--update opencode` → "opencode". Flags never count as values.
    static func selectedItemID(arguments: [String], flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("-") ? nil : value
    }

    static func actionExitCode(attemptedCount: Int, statuses: [ItemStatus]) -> Int32 {
        guard attemptedCount > 0 else { return 3 }
        guard statuses.count == attemptedCount else { return 1 }
        let successful: Set<ItemStatus> = [.updated, .upToDate]
        return statuses.allSatisfy(successful.contains) ? 0 : 1
    }

    static func runSync(arguments: [String]) -> Int32 {
        let flags = Set(arguments.dropFirst().filter { $0.hasPrefix("-") })
        if flags.contains("--help") || flags.contains("-h") {
            printHelp()
            return 0
        }

        return blockingWait { await run(arguments: arguments) }
    }

    /// Bridges the synchronous executable entry point to async work without
    /// blocking MainActor jobs needed by check/update flows.
    static func blockingWait<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) -> Value {
        let box = CLIValueBox<Value>()
        Task.detached { box.complete(with: await operation()) }

        guard Thread.isMainThread else { return box.wait() }
        while let value = box.resultIfReady() {
            return value
        }
        while true {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            if let value = box.resultIfReady() { return value }
        }
    }

    private static func printHelp() {
        print("""
        Daily Update CLI

        Usage:
          DailyUpdate --audit [--json]      Audit supported developer/AI CLIs (read-only)
          DailyUpdate --check [--json]      Check configured items (read-only)
          DailyUpdate --health [--json]     Run health checks
          DailyUpdate --update-all          Update safe, verified items one at a time
          DailyUpdate --install-all         Install safe, verified items one at a time
          DailyUpdate --update <id>         Update one item by id (ids: --check --json)
          DailyUpdate --install <id>        Install one item by id
          DailyUpdate --help                Show this help

        Safety: risky, ambiguous, bulk, privileged, login, service, local/workspace,
        major, and large pre-1.0 actions are Gated or Blocked. Exit code 0 from an
        updater is not success until path, version, help, fresh-shell, and latest
        checks pass. Run without flags to open the GUI.
        """)
    }

    private static func printHealth(_ issues: [HealthIssue], json: Bool) {
        if json {
            let data = issues.map { ["title": $0.title, "detail": $0.detail, "severity": $0.severity.rawValue] }
            printJSONObject(data)
        } else if issues.isEmpty {
            print("[OK] No health issues found")
        } else {
            for issue in issues { print("[\(issue.severity.rawValue.uppercased())] \(issue.title): \(issue.detail)") }
        }
    }

    private static func printAudits(_ audits: [DeveloperCLIAudit], json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(audits), let string = String(data: data, encoding: .utf8) { print(string) }
            return
        }
        for audit in audits {
            print("\(audit.name): \(audit.outcome.rawValue)")
            print("  active: \(audit.activeBinaryPath ?? "not found")")
            print("  version: \(audit.currentVersion ?? "unknown") → \(audit.latestVersion ?? "unknown")")
            print("  owner: \(audit.installOwner.rawValue)/\(audit.installMethod.rawValue); risk: \(audit.risk.rawValue)")
            if !audit.shadowedPaths.isEmpty { print("  shadowed: \(audit.shadowedPaths.joined(separator: ", "))") }
            print("  \(audit.statusMessage)")
        }
    }

    @MainActor
    private static func printCheckResults(_ state: AppState) {
        print("Daily Update — \(state.updateAvailableCount) update(s) available\n")
        for item in state.items {
            print("\(item.name) [\(item.category.label)] — \(item.status.label) (\(item.displayVersion))\(item.statusMessage.map { ": \($0)" } ?? "")")
        }
    }

    @MainActor
    private static func printJSON(_ state: AppState) {
        let payload: [[String: Any]] = state.items.map { item in
            ["id": item.id, "name": item.name, "category": item.category.rawValue,
             "status": item.status.rawValue, "message": item.statusMessage ?? "",
             "currentVersion": item.currentVersion ?? "", "latestVersion": item.latestVersion ?? ""]
        }
        printJSONObject(payload)
    }

    private static func printJSONObject(_ object: Any) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) { print(string) }
    }
}
