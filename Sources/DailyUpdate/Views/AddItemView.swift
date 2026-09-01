import SwiftUI

struct AddItemView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var category: ItemCategory = .app
    @State private var description = ""

    // App-specific
    @State private var appDetectMode: AppDetectMode = .applicationFolder
    @State private var appName = ""
    @State private var detectScript = ""

    // CLI-specific
    @State private var commandName = ""
    @State private var useCLIScript = false

    // Repo-specific
    @State private var repoPath = ""

    // Common
    @State private var versionCommand = ""
    @State private var checkCommand = ""
    @State private var installCommand = ""
    @State private var updateCommand = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add to Update List")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            Form {
                Section("Basic Info") {
                    TextField("Name", text: $name)
                    Picker("Category", selection: $category) {
                        ForEach(ItemCategory.allCases) { cat in
                            Text(cat.label).tag(cat)
                        }
                    }
                    TextField("Description (optional)", text: $description)
                }

                Section("Detection") {
                    switch category {
                    case .app:
                        appDetectionFields
                    case .cli:
                        cliDetectionFields
                    case .repo:
                        repoDetectionFields
                    default:
                        genericDetectionFields
                    }
                }

                Section("Update Commands") {
                    if category != .repo {
                        TextField("Version command (optional)", text: $versionCommand)
                    }
                    TextField("Check command (optional)", text: $checkCommand)
                    TextField("Install command (optional)", text: $installCommand)
                    TextField("Update command", text: $updateCommand)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Add Item") { addItem() }
                    .disabled(!isValid)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 520)
        .onChange(of: category) { _ in resetFields() }
        .onChange(of: repoPath) { _ in autoFillRepoCommands() }
    }

    @ViewBuilder
    private var appDetectionFields: some View {
        Picker("Detect via", selection: $appDetectMode) {
            ForEach(AppDetectMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }

        switch appDetectMode {
        case .applicationFolder:
            TextField("App name (e.g. Cursor)", text: $appName)
                .onChange(of: appName) { _ in
                    if updateCommand.isEmpty {
                        updateCommand = "{UPDATE_SCRIPT} smart \(appName.lowercased()) /Applications/\(appName).app ~/Applications/\(appName).app"
                    }
                }
            Text("Looks for \(appName.isEmpty ? "AppName" : appName).app in your Applications folders.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .script:
            TextField("Detect script (exit 0 = installed)", text: $detectScript, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    @ViewBuilder
    private var cliDetectionFields: some View {
        Toggle("Use custom detect script", isOn: $useCLIScript)

        if useCLIScript {
            TextField("Detect script", text: $detectScript, axis: .vertical)
                .lineLimit(2...4)
        } else {
            TextField("Command or absolute path (e.g. codex)", text: $commandName)
                .onChange(of: commandName) { _ in
                    if versionCommand.isEmpty, !commandName.isEmpty {
                        versionCommand = "\(commandName) --version 2>/dev/null | head -1"
                    }
                }
            Text("Searches common user bin folders. Use an absolute executable path for a custom location.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var repoDetectionFields: some View {
        HStack {
            TextField("Repo path", text: $repoPath)
            Button("Browse…") {
                if let picked = FolderPicker.pickFolder(
                    message: "Select a git repository folder",
                    defaultURL: appState.settingsStore.settings.rootFolder.isEmpty
                        ? URL(fileURLWithPath: NSHomeDirectory())
                        : URL(fileURLWithPath: appState.settingsStore.settings.rootFolder)
                ) {
                    repoPath = picked
                }
            }
        }
    }

    @ViewBuilder
    private var genericDetectionFields: some View {
        TextField("Detect script (exit 0 = installed)", text: $detectScript, axis: .vertical)
            .lineLimit(2...4)
    }

    private var isValid: Bool {
        guard !name.isEmpty, !updateCommand.isEmpty else { return false }
        switch category {
        case .app:
            switch appDetectMode {
            case .applicationFolder: return !appName.isEmpty
            case .script: return !detectScript.isEmpty
            }
        case .cli:
            return useCLIScript ? !detectScript.isEmpty : !commandName.isEmpty
        case .repo:
            return !repoPath.isEmpty
        default:
            return !detectScript.isEmpty
        }
    }

    private func resetFields() {
        versionCommand = ""
        checkCommand = ""
        installCommand = ""
        updateCommand = ""
        detectScript = ""
        appName = ""
        commandName = ""
        repoPath = ""
    }

    private func autoFillRepoCommands() {
        guard category == .repo, !repoPath.isEmpty else { return }
        let path = repoPath
        versionCommand = "git -C \"\(path)\" rev-parse --short HEAD"
        checkCommand = "cd \"\(path)\" && git fetch --quiet origin 2>/dev/null; [ -n \"$(git -C \"\(path)\" rev-list HEAD..@{u} 2>/dev/null)\" ] && echo UPDATE || echo OK"
        updateCommand = "cd \"\(path)\" && git pull --ff-only"
        if name.isEmpty {
            name = URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private func addItem() {
        let config: DetectorConfig
        let appFolders = appState.settingsStore.settings.applicationFolders

        switch category {
        case .app:
            switch appDetectMode {
            case .applicationFolder:
                config = ItemBuilder.appFromFolder(
                    name: name,
                    appName: appName,
                    appFolders: appFolders,
                    checkCommand: checkCommand.nilIfEmpty,
                    installCommand: installCommand.nilIfEmpty,
                    updateCommand: updateCommand,
                    description: description.nilIfEmpty
                )
            case .script:
                config = ItemBuilder.appFromScript(
                    name: name,
                    detectScript: detectScript,
                    versionCommand: versionCommand.nilIfEmpty,
                    checkCommand: checkCommand.nilIfEmpty,
                    installCommand: installCommand.nilIfEmpty,
                    updateCommand: updateCommand,
                    description: description.nilIfEmpty
                )
            }
        case .cli:
            if useCLIScript {
                config = ItemBuilder.cliFromScript(
                    name: name,
                    detectScript: detectScript,
                    versionCommand: versionCommand.nilIfEmpty,
                    checkCommand: checkCommand.nilIfEmpty,
                    installCommand: installCommand.nilIfEmpty,
                    updateCommand: updateCommand,
                    description: description.nilIfEmpty
                )
            } else {
                config = ItemBuilder.cli(
                    name: name,
                    commandName: commandName,
                    checkCommand: checkCommand.nilIfEmpty,
                    installCommand: installCommand.nilIfEmpty,
                    updateCommand: updateCommand,
                    description: description.nilIfEmpty
                )
            }
        case .repo:
            config = ItemBuilder.repo(name: name, path: repoPath, installCommand: installCommand.nilIfEmpty, description: description.nilIfEmpty)
        default:
            config = ItemBuilder.generic(
                name: name,
                category: category,
                detectScript: detectScript,
                versionCommand: versionCommand.nilIfEmpty,
                checkCommand: checkCommand.nilIfEmpty,
                installCommand: installCommand.nilIfEmpty,
                updateCommand: updateCommand,
                description: description.nilIfEmpty
            )
        }

        appState.addCustomItem(config)
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
