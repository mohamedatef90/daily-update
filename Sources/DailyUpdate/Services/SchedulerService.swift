import Foundation

final class SchedulerService {
    private var timer: Timer?
    private weak var appState: AppState?
    private var lastScheduledRun: Date?

    func start(appState: AppState) {
        self.appState = appState
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func tick() async {
        guard let appState else { return }
        let settings = appState.settingsStore.settings
        guard settings.scheduledCheckEnabled, !appState.isChecking, !appState.isUpdating else { return }

        let now = Date()
        let interval = TimeInterval((settings.scheduledCheckInterval ?? .hours6)
            .minutes(customMinutes: max(15, settings.scheduledCheckCustomMinutes ?? 120)) * 60)
        let latestCheck = [lastScheduledRun, appState.lastCheckDate].compactMap { $0 }.max() ?? .distantPast
        guard now.timeIntervalSince(latestCheck) >= interval else { return }
        lastScheduledRun = now

        await appState.checkAll()
        if settings.autoUpdateScheduledItems {
            await appState.updateAutoItems()
        }
    }
}
