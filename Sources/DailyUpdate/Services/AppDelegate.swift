import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private let statusBarController = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appState {
            statusBarController.configure(appState: appState)
        }
        applyActivationPolicy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            appState?.showMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        appState?.settingsStore.settings.menuBarOnly != true
    }

    func applyActivationPolicy() {
        guard let settings = appState?.settingsStore.settings else { return }
        if settings.menuBarOnly {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func connect(appState: AppState) {
        self.appState = appState
        statusBarController.configure(appState: appState)
        applyActivationPolicy()
    }

    func refreshStatusBar() {
        statusBarController.refresh()
    }

    func refreshStatusBarVisibility() {
        statusBarController.updateVisibility()
    }
}
