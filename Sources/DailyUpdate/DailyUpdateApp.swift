import SwiftUI

@main
enum DailyUpdateMain {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, args.dropFirst().contains(where: { $0.hasPrefix("-") }) {
            Task { @MainActor in
                exit(await CLIRunner.run(arguments: args))
            }
            dispatchMain()
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
            .confirmationDialog(
                "Administrator Permission Needed",
                isPresented: isShowingAdministratorPermissionRequest,
                titleVisibility: .visible
            ) {
                Button("Authenticate and Retry") {
                    guard let item = appState.administratorPermissionItem else { return }
                    Task { await appState.retryUpdateWithAdministratorPermission(for: item.id) }
                }
                Button("Not Now", role: .cancel) {
                    appState.dismissAdministratorPermissionRequest()
                }
            } message: {
                Text(administratorPermissionMessage)
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

    private var isShowingAdministratorPermissionRequest: Binding<Bool> {
        Binding(
            get: { appState.administratorPermissionItem != nil },
            set: { if !$0 { appState.dismissAdministratorPermissionRequest() } }
        )
    }

    private var administratorPermissionMessage: String {
        guard let item = appState.administratorPermissionItem else { return "" }
        return "\(item.name) needs permission to modify installed files. Daily Update will open the native macOS authentication dialog. Use Touch ID when your Mac offers it, or enter an administrator password."
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
