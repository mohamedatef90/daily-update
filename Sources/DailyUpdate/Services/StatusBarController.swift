import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()

    func configure(appState: AppState) {
        self.appState = appState
        updateVisibility()

        appState.settingsStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateVisibility()
            }
            .store(in: &cancellables)

        appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    func updateVisibility() {
        guard let appState else { return }
        if appState.showMenuBarIcon {
            if statusItem == nil {
                createStatusItem()
            }
            refresh()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refresh()
    }

    func refresh() {
        guard let appState, let statusItem else { return }
        guard let button = statusItem.button else { return }

        if let image = NSImage(systemSymbolName: appState.menuBarIconName, accessibilityDescription: "Daily Update") {
            image.isTemplate = true
            button.image = image
        }

        if appState.updateAvailableCount > 0 {
            button.title = " \(appState.updateAvailableCount)"
        } else {
            button.title = ""
        }

        let menu = NSMenu()

        let header = NSMenuItem(title: appState.menuBarStatusTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let subtitle = appState.menuBarStatusSubtitle {
            let sub = NSMenuItem(title: subtitle, action: nil, keyEquivalent: "")
            sub.isEnabled = false
            menu.addItem(sub)
        }

        menu.addItem(.separator())

        menu.addItem(makeItem("Check for Updates") { [weak appState] in
            Task { await appState?.checkAll() }
        })

        menu.addItem(makeItem("Update All Available") { [weak appState] in
            Task {
                appState?.selectAllUpdates()
                await appState?.updateSelected(skipDryRun: true)
            }
        })

        menu.addItem(.separator())

        menu.addItem(makeItem("Open Daily Update") { [weak appState] in
            appState?.showMainWindow()
        })

        menu.addItem(makeItem("Add Item…") { [weak appState] in
            appState?.showMainWindow()
            appState?.showAddItem = true
        })

        menu.addItem(makeItem("Settings…") { [weak appState] in
            appState?.showMainWindow()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        })

        menu.addItem(.separator())
        menu.addItem(makeItem("Quit") {
            NSApp.terminate(nil)
        })

        statusItem.menu = menu
    }

    private func makeItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = CallbackMenuItem(title: title, callback: action)
        return item
    }
}

private final class CallbackMenuItem: NSMenuItem {
    private let callback: () -> Void

    init(title: String, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(title: title, action: #selector(performCallback), keyEquivalent: "")
        self.target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performCallback() {
        callback()
    }
}
