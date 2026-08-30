import Foundation

final class SchedulerService {
    private var timer: Timer?
    private weak var appState: AppState?
    private var lastScheduledRunDay: String?

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
        guard settings.scheduledCheckEnabled else { return }

        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        guard hour == settings.scheduledCheckHour, minute == settings.scheduledCheckMinute else { return }

        let dayKey = calendar.startOfDay(for: now).description
        guard lastScheduledRunDay != dayKey else { return }
        lastScheduledRunDay = dayKey

        await appState.checkAll()
        if settings.autoUpdateScheduledItems {
            await appState.updateAutoItems()
        }
    }
}
