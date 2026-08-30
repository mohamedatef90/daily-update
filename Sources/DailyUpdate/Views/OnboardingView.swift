import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var step = 0
    @State private var rootFolder = UserSettings.defaultRootFolder
    @State private var additionalFolders: [String] = []
    @State private var applicationFolders = ["/Applications", "~/Applications"]
    @State private var discoveredRepos: [DetectorConfig] = []
    @State private var discoveredApps: [DetectorConfig] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch step {
                case 0: welcomeStep
                case 1: rootFolderStep
                case 2: additionalFoldersStep
                case 3: appFoldersStep
                case 4: reviewStep
                default: welcomeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)

            Divider()
            footer
        }
        .frame(width: 560, height: 520)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
            Text("Welcome to Daily Update")
                .font(.title2.weight(.semibold))
            Text("Set up your folders so the app knows where to find your stuff.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What Daily Update does")
                .font(.headline)
            Label("Finds apps, CLIs, runtimes, and git repos", systemImage: "magnifyingglass")
            Label("Checks for updates when your Mac starts or wakes", systemImage: "arrow.clockwise")
            Label("Lets you choose what to update", systemImage: "checkmark.circle")
            Text("First, tell us where your files live — usually your home folder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rootFolderStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Root Folder")
                .font(.headline)
            Text("This is usually your home folder (e.g. /Users/yourname). Daily Update will scan here for git repos and projects.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Text(rootFolder)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button("Choose…") {
                    if let picked = FolderPicker.pickFolder(
                        message: "Select your root folder",
                        defaultURL: URL(fileURLWithPath: rootFolder)
                    ) {
                        rootFolder = picked
                        scanRepos()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { scanRepos(); scanApps() }
    }

    private var additionalFoldersStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Additional Folders")
                .font(.headline)
            Text("If you install tools or repos elsewhere (external drive, /opt, etc.), add those paths here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if additionalFolders.isEmpty {
                Text("No extra folders added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(additionalFolders, id: \.self) { folder in
                    HStack {
                        Text(folder)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            additionalFolders.removeAll { $0 == folder }
                            scanRepos()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                if let picked = FolderPicker.pickFolder(message: "Select an additional folder") {
                    if picked != rootFolder, !additionalFolders.contains(picked) {
                        additionalFolders.append(picked)
                        scanRepos()
                    }
                }
            } label: {
                Label("Add Folder", systemImage: "plus.circle")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appFoldersStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Applications Folders")
                .font(.headline)
            Text("Where should Daily Update look for .app bundles? Default is /Applications and ~/Applications.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(applicationFolders, id: \.self) { folder in
                HStack {
                    Text(folder)
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    if applicationFolders.count > 1 {
                        Button(role: .destructive) {
                            applicationFolders.removeAll { $0 == folder }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                if let picked = FolderPicker.pickFolder(message: "Select an Applications folder") {
                    if !applicationFolders.contains(picked) {
                        applicationFolders.append(picked)
                    }
                }
            } label: {
                Label("Add Applications Folder", systemImage: "plus.circle")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ready to Go")
                .font(.headline)

            Group {
                LabeledContent("Root folder", value: rootFolder)
                LabeledContent("Extra folders", value: additionalFolders.isEmpty ? "None" : "\(additionalFolders.count)")
                LabeledContent("App folders", value: "\(applicationFolders.count)")
                LabeledContent("Repos found", value: "\(discoveredRepos.count)")
                LabeledContent("Apps found", value: "\(discoveredApps.count)")
            }
            .font(.subheadline)

            Text("Daily Update will check for updates automatically every time it opens.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { scanRepos(); scanApps() }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            if step < 4 {
                Button("Next") { step += 1 }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Finish Setup") { finishSetup() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(.bar)
    }

    private func scanRepos() {
        var folders = [rootFolder]
        folders.append(contentsOf: additionalFolders)
        discoveredRepos = RepoScanner.discoverRepos(
            in: folders,
            rootFolder: rootFolder,
            options: RepoScanSettings.defaults.scanOptions
        )
    }

    private func scanApps() {
        discoveredApps = AppScanner.discoverApps(
            in: applicationFolders,
            excludingPaths: [],
            excludingBundleIDs: [],
            options: AppScanOptions(developerOnly: true, scanUtilitiesFolder: true)
        )
    }

    private func finishSetup() {
        appState.settingsStore.settings.applicationFolders = applicationFolders
        appState.settingsStore.save()
        appState.completeOnboarding(rootFolder: rootFolder, additionalFolders: additionalFolders)
    }
}
