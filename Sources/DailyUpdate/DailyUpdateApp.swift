import SwiftUI

@main
enum DailyUpdateMain {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, args.dropFirst().contains(where: { $0.hasPrefix("-") }) {
            exit(CLIRunner.runSync(arguments: args))
        }
        DailyUpdateApp.main()
    }
}

struct DailyUpdateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            mainWindow
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add to Update List…") {
                    appState.showAddItem = true
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandMenu("Updates") {
                Button("Check for Updates") {
                    Task { await appState.checkAll() }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Update Selected") {
                    Task { await appState.requestUpdateSelected() }
                }
                .keyboardShortcut("u", modifiers: [.command])

                Button("Show Dashboard") {
                    appState.setSidebarSelection("dashboard")
                    appState.showMainWindow()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .sheet(isPresented: $appState.showAddItem) {
                    AddItemView()
                        .environmentObject(appState)
                }
        }
    }

    private var mainWindow: some View {
        ContentView()
            .environmentObject(appState)
            .frame(minWidth: 960, minHeight: 600)
            .sheet(isPresented: $appState.showOnboarding) {
                OnboardingView()
                    .environmentObject(appState)
                    .interactiveDismissDisabled()
            }
            .sheet(isPresented: $appState.showAddItem) {
                AddItemView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $appState.showDryRun) {
                DryRunSheet()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $appState.showUpdateReport) {
                UpdateReportSheet()
                    .environmentObject(appState)
            }
            .onAppear {
                appDelegate.connect(appState: appState)
                appState.appDelegate = appDelegate
                hideMainWindowIfNeeded()
            }
            .task {
                await NotificationService.requestAuthorization()
                if !appState.showOnboarding {
                    await appState.runStartupFlow()
                    hideMainWindowIfNeeded()
                }
            }
    }

    private func hideMainWindowIfNeeded() {
        guard appState.menuBarOnly, appState.settingsStore.settings.hasCompletedSetup else { return }
        appDelegate.applyActivationPolicy()
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.orderOut(nil)
            }
        }
    }
}
