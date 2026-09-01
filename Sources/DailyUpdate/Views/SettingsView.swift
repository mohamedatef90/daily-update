import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var newSubfolder = ""
    @State private var newSkipDir = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            menuBarTab
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            foldersTab
                .tabItem { Label("Folders", systemImage: "folder") }
            repoScanTab
                .tabItem { Label("Repo Scan", systemImage: "folder.badge.gearshape") }
            updateListTab
                .tabItem { Label("Update List", systemImage: "list.bullet") }
        }
        .frame(width: 540, height: 480)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section("Automatic Updates") {
                Toggle("Check for updates on app launch", isOn: Binding(
                    get: { appState.autoCheckOnLaunch },
                    set: { appState.autoCheckOnLaunch = $0 }
                ))
                Toggle("Auto-update available items on launch", isOn: Binding(
                    get: { appState.autoUpdateOnLaunch },
                    set: { appState.autoUpdateOnLaunch = $0 }
                ))
                Toggle("Check when Mac wakes up", isOn: Binding(
                    get: { appState.autoCheckOnWake },
                    set: { appState.autoCheckOnWake = $0 }
                ))
                Toggle("Rescan folders for repos on launch", isOn: Binding(
                    get: { appState.rescanReposOnLaunch },
                    set: { appState.rescanReposOnLaunch = $0 }
                ))
                Toggle("Rescan Applications for apps on launch", isOn: Binding(
                    get: { appState.rescanAppsOnLaunch },
                    set: { appState.rescanAppsOnLaunch = $0 }
                ))
                Toggle("Rescan agent skills on launch", isOn: Binding(
                    get: { appState.rescanSkillsOnLaunch },
                    set: { appState.rescanSkillsOnLaunch = $0 }
                ))
                Toggle("Show dashboard on launch", isOn: Binding(
                    get: { appState.settingsStore.settings.showDashboardOnLaunch },
                    set: {
                        appState.settingsStore.settings.showDashboardOnLaunch = $0
                        appState.settingsStore.save()
                    }
                ))
            }

            Section("Notifications & Safety") {
                Toggle("Notify when updates are found", isOn: Binding(
                    get: { appState.notificationsEnabled },
                    set: { appState.notificationsEnabled = $0 }
                ))
                Toggle("Confirm before updating (dry-run preview)", isOn: Binding(
                    get: { appState.confirmBeforeUpdate },
                    set: { appState.confirmBeforeUpdate = $0 }
                ))
                Toggle("Stash git repos before pull", isOn: Binding(
                    get: { appState.stashReposBeforeUpdate },
                    set: { appState.stashReposBeforeUpdate = $0 }
                ))
            }

            Section("Scheduled Check") {
                Toggle("Daily scheduled check", isOn: Binding(
                    get: { appState.scheduledCheckEnabled },
                    set: { appState.scheduledCheckEnabled = $0 }
                ))
                Stepper("Time: \(appState.settingsStore.settings.scheduledCheckHour):\(String(format: "%02d", appState.settingsStore.settings.scheduledCheckMinute))", value: Binding(
                    get: { appState.settingsStore.settings.scheduledCheckHour },
                    set: {
                        appState.settingsStore.settings.scheduledCheckHour = $0
                        appState.settingsStore.save()
                    }
                ), in: 0...23)
                Toggle("Auto-update items marked for auto-update", isOn: Binding(
                    get: { appState.settingsStore.settings.autoUpdateScheduledItems },
                    set: {
                        appState.settingsStore.settings.autoUpdateScheduledItems = $0
                        appState.settingsStore.save()
                    }
                ))
            }

            Section("Import / Export") {
                HStack {
                    Button("Export Config…") { exportConfig() }
                    Button("Import Config…") { importConfig() }
                }
                Text("Export includes settings, custom items, and update history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("CLI") {
                Text("DailyUpdate --check --json")
                    .font(.system(.caption, design: .monospaced))
                Text("DailyUpdate --update-all")
                    .font(.system(.caption, design: .monospaced))
                Text("DailyUpdate --health")
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .formStyle(.grouped)
    }

    private func exportConfig() {
        do {
            let url = try appState.exportConfig()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSLog("Export failed: \(error)")
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.importConfig(from: url)
        } catch {
            NSLog("Import failed: \(error)")
        }
    }

    private var menuBarTab: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { appState.showMenuBarIcon },
                    set: { appState.showMenuBarIcon = $0 }
                ))
                Toggle("Menu bar only (hide Dock icon)", isOn: Binding(
                    get: { appState.menuBarOnly },
                    set: { appState.menuBarOnly = $0 }
                ))
                Text("When menu bar only is on, the app stays in the background. Use the menu bar icon to open the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.launchAtLogin = $0 }
                ))
                if let launchAtLoginError = appState.launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Starts Daily Update when you log in to your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var foldersTab: some View {
        Form {
            Section("Root Folder") {
                HStack {
                    Text(appState.settingsStore.settings.rootFolder)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Button("Change…") {
                        if let picked = FolderPicker.pickFolder(message: "Select root folder") {
                            appState.settingsStore.settings.rootFolder = picked
                            appState.settingsStore.save()
                            appState.reloadConfigs()
                        }
                    }
                }
            }

            Section("Additional Scan Folders") {
                if appState.settingsStore.settings.additionalFolders.isEmpty {
                    Text("No additional folders")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                ForEach(appState.settingsStore.settings.additionalFolders, id: \.self) { folder in
                    HStack {
                        Text(folder).font(.caption)
                        Spacer()
                        Button(role: .destructive) {
                            appState.settingsStore.removeFolder(folder)
                            appState.reloadConfigs()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    if let picked = FolderPicker.pickFolder(message: "Add scan folder") {
                        appState.settingsStore.addFolder(picked)
                        appState.reloadConfigs()
                    }
                } label: {
                    Label("Add Folder", systemImage: "plus")
                }
            }

            Section("Applications Folders") {
                ForEach(appState.settingsStore.settings.applicationFolders, id: \.self) { folder in
                    HStack {
                        Text(folder).font(.caption)
                        Spacer()
                        Button(role: .destructive) {
                            appState.settingsStore.removeApplicationFolder(folder)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    if let picked = FolderPicker.pickFolder(message: "Add Applications folder") {
                        appState.settingsStore.addApplicationFolder(picked)
                        appState.reloadConfigs()
                    }
                } label: {
                    Label("Add Applications Folder", systemImage: "plus")
                }
            }

            Section("App Discovery") {
                Toggle("Discover apps in Applications folders", isOn: Binding(
                    get: { appState.settingsStore.settings.appDiscovery.enabled },
                    set: {
                        appState.settingsStore.settings.appDiscovery.enabled = $0
                        appState.settingsStore.save()
                        appState.reloadConfigs()
                    }
                ))
                Toggle("Developer & software tools only", isOn: Binding(
                    get: { appState.settingsStore.settings.appDiscovery.developerOnly },
                    set: {
                        appState.settingsStore.settings.appDiscovery.developerOnly = $0
                        appState.settingsStore.save()
                        appState.reloadConfigs()
                    }
                ))
                Toggle("Include Utilities subfolder", isOn: Binding(
                    get: { appState.settingsStore.settings.appDiscovery.scanUtilitiesFolder },
                    set: {
                        appState.settingsStore.settings.appDiscovery.scanUtilitiesFolder = $0
                        appState.settingsStore.save()
                        appState.reloadConfigs()
                    }
                ))
                Text("Finds IDEs, terminals, dev utilities, and other tools in your Applications folders. Uses Sparkle feeds and Homebrew cask versions when available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reset to Defaults") {
                        appState.settingsStore.resetAppDiscoverySettings()
                        appState.reloadConfigs()
                    }
                    Spacer()
                    Button("Rescan Now") {
                        appState.reloadConfigs()
                    }
                }
                Text("\(appState.discoveredAppCount) apps discovered with current rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Agent Skills Discovery") {
                Toggle("Discover agent skills and plugin repos", isOn: Binding(
                    get: { appState.settingsStore.settings.skillDiscovery.enabled },
                    set: {
                        appState.settingsStore.settings.skillDiscovery.enabled = $0
                        appState.settingsStore.save()
                        appState.reloadConfigs()
                    }
                ))
                Toggle("Include Cursor/Claude plugin caches (git)", isOn: Binding(
                    get: { appState.settingsStore.settings.skillDiscovery.scanPluginCaches },
                    set: {
                        appState.settingsStore.settings.skillDiscovery.scanPluginCaches = $0
                        appState.settingsStore.save()
                        appState.reloadConfigs()
                    }
                ))
                Text("Scans ~/.agents/skills, ~/.cursor/skills, ~/.claude/skills, and plugin caches. Git-backed plugin repos get individual update checks. Global skills installed via npx skills are tracked under Libraries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reset to Defaults") {
                        appState.settingsStore.resetSkillDiscoverySettings()
                        appState.reloadConfigs()
                    }
                    Spacer()
                    Button("Rescan Now") {
                        appState.reloadConfigs()
                    }
                }
                Text("\(appState.discoveredSkillCount) skill sources discovered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var repoScanTab: some View {
        Form {
            Section("Scan Depth") {
                Stepper(
                    "Max folder depth: \(appState.settingsStore.settings.repoScan.maxDepth)",
                    value: Binding(
                        get: { appState.settingsStore.settings.repoScan.maxDepth },
                        set: {
                            appState.settingsStore.settings.repoScan.maxDepth = max(1, min($0, 10))
                            appState.settingsStore.save()
                        }
                    ),
                    in: 1...10
                )
                Toggle("Skip hidden folders (starting with .)", isOn: Binding(
                    get: { appState.settingsStore.settings.repoScan.skipHiddenDirectories },
                    set: {
                        appState.settingsStore.settings.repoScan.skipHiddenDirectories = $0
                        appState.settingsStore.save()
                    }
                ))
            }

            Section("Root Folder Scope") {
                Toggle("Only scan named subfolders inside root", isOn: Binding(
                    get: { appState.settingsStore.settings.repoScan.limitRootToSubfolders },
                    set: {
                        appState.settingsStore.settings.repoScan.limitRootToSubfolders = $0
                        appState.settingsStore.save()
                    }
                ))
                Text("Keeps scans fast by only looking inside folders like Projects, dev, and 04_App_Coding instead of your entire home folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(appState.settingsStore.settings.repoScan.subfolders, id: \.self) { name in
                    HStack {
                        Text(name).font(.caption)
                        Spacer()
                        Button(role: .destructive) {
                            appState.settingsStore.removeRepoScanSubfolder(name)
                            appState.reloadConfigs()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("Add subfolder name", text: $newSubfolder)
                    Button("Add") {
                        appState.settingsStore.addRepoScanSubfolder(newSubfolder)
                        newSubfolder = ""
                        appState.reloadConfigs()
                    }
                    .disabled(newSubfolder.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Skip Directories") {
                Text("Folders to never enter during repo scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(appState.settingsStore.settings.repoScan.skipDirectories, id: \.self) { name in
                    HStack {
                        Text(name).font(.caption)
                        Spacer()
                        Button(role: .destructive) {
                            appState.settingsStore.removeRepoScanSkipDirectory(name)
                            appState.reloadConfigs()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("Add skip folder", text: $newSkipDir)
                    Button("Add") {
                        appState.settingsStore.addRepoScanSkipDirectory(newSkipDir)
                        newSkipDir = ""
                        appState.reloadConfigs()
                    }
                    .disabled(newSkipDir.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack {
                    Button("Reset to Defaults") {
                        appState.settingsStore.resetRepoScanSettings()
                        appState.reloadConfigs()
                    }
                    Spacer()
                    Button("Rescan Now") {
                        appState.reloadConfigs()
                    }
                }
            }

            Section("Results") {
                Text("\(appState.discoveredRepoCount) repos discovered with current rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var updateListTab: some View {
        Form {
            Section {
                Button {
                    appState.showAddItem = true
                } label: {
                    Label("Add App, CLI, or Repo", systemImage: "plus.circle.fill")
                }
            }

            Section("Your Custom Items") {
                let custom = appState.settingsStore.settings.customItems
                if custom.isEmpty {
                    Text("No custom items yet. Click above to add one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(custom) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).fontWeight(.medium)
                                Text(item.category.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                appState.removeCustomItem(id: item.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Section("Ignored Items") {
                let ignoredIDs = appState.settingsStore.settings.itemPreferences
                    .filter { $0.value.permanentlyIgnored }
                    .map(\.key)
                    .sorted()
                if ignoredIDs.isEmpty {
                    Text("No ignored items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ignoredIDs, id: \.self) { id in
                        HStack {
                            Text(appState.items.first(where: { $0.id == id })?.name ?? id)
                            Spacer()
                            Button("Restore") {
                                appState.unignoreItem(id: id)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
