import Foundation

enum CLIRunner {
    static func isCLIInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return first.hasPrefix("-")
    }

    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        let args = Array(arguments.dropFirst())
        let flags = Set(args.filter { $0.hasPrefix("-") })
        let json = flags.contains("--json")

        let store = UserSettingsStore()
        let state = AppState(settingsStore: store)

        if flags.contains("--help") || flags.contains("-h") {
            printHelp()
            return 0
        }

        if flags.contains("--check") {
            await state.checkAll()
            if json {
                printJSON(state)
            } else {
                printCheckResults(state)
            }
            return 0
        }

        if flags.contains("--install-all") {
            await state.checkAll()
            state.selectAllInstallable()
            await state.updateSelected(skipDryRun: true)
            return state.items.contains { $0.status == .error } ? 1 : 0
        }

        if flags.contains("--update-all") {
            await state.checkAll()
            state.selectAllUpdates()
            await state.updateSelected(skipDryRun: true)
            return state.items.contains { $0.status == .error } ? 1 : 0
        }

        if flags.contains("--install") {
            await state.checkAll()
            state.selectAllInstallable()
            await state.updateSelected(skipDryRun: true)
            return state.items.contains { $0.status == .error } ? 1 : 0
        }

        if flags.contains("--update") {
            await state.checkAll()
            state.selectAllUpdates()
            await state.updateSelected(skipDryRun: true)
            return state.items.contains { $0.status == .error } ? 1 : 0
        }

        if flags.contains("--health") {
            let issues = await HealthCheckService.run(settings: store.settings)
            if json {
                let data = issues.map { ["title": $0.title, "detail": $0.detail, "severity": $0.severity.rawValue] }
                if let encoded = try? JSONSerialization.data(withJSONObject: data),
                   let str = String(data: encoded, encoding: .utf8) {
                    print(str)
                }
            } else {
                for issue in issues {
                    print("[\(issue.severity.rawValue.uppercased())] \(issue.title): \(issue.detail)")
                }
            }
            return 0
        }

        printHelp()
        return 1
    }

    private static func printHelp() {
        print("""
        Daily Update CLI

        Usage:
          DailyUpdate --check              Check for updates
          DailyUpdate --update             Alias for --update-all
          DailyUpdate --update-all         Update all available items
          DailyUpdate --install            Alias for --install-all
          DailyUpdate --install-all        Install all missing items
          DailyUpdate --health             Run health checks
          DailyUpdate --json               JSON output (with --check or --health)
          DailyUpdate --help               Show this help

        Run without flags to open the GUI.
        """)
    }

    @MainActor
    private static func printCheckResults(_ state: AppState) {
        print("Daily Update — \(state.updateAvailableCount) update(s) available\n")
        for item in state.items {
            let status = item.status.label
            let version = item.displayVersion
            print("\(item.name) [\(item.category.label)] — \(status) (\(version))")
        }
    }

    @MainActor
    private static func printJSON(_ state: AppState) {
        let payload: [[String: Any]] = state.items.map { item in
            [
                "id": item.id,
                "name": item.name,
                "category": item.category.rawValue,
                "status": item.status.rawValue,
                "currentVersion": item.currentVersion ?? "",
                "latestVersion": item.latestVersion ?? ""
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
