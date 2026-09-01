import AppKit
import SwiftUI

struct ItemListView: View {
    @EnvironmentObject var appState: AppState
    @State private var showLog = false
    @State private var infoItem: UpdateItem?

    private var displayItems: [UpdateItem] {
        appState.filteredItems
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if displayItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No Items")
                        .font(.title2.weight(.semibold))
                    Text("Run Check Updates to find installed apps, CLIs, and repos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(displayItems, selection: .constant(Set<String>())) {
                    TableColumn("") { item in
                        Toggle("", isOn: Binding(
                            get: { item.isSelected },
                            set: { _ in appState.toggleSelection(for: item.id) }
                        ))
                        .toggleStyle(.checkbox)
                        .disabled(!item.isActionable || appState.isUpdating)
                    }
                    .width(32)

                    TableColumn("Name") { item in
                        ItemNameCell(item: item, onShowInfo: { infoItem = item })
                            .contextMenu { itemContextMenu(for: item) }
                    }
                    .width(min: 180, ideal: 240)

                    TableColumn("Category") { item in
                        Label(item.category.label, systemImage: item.category.icon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .width(100)

                    TableColumn("Version") { item in
                        Text(item.displayVersion)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(item.status == .updateAvailable ? .primary : .secondary)
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn("Status") { item in
                        HStack {
                            StatusBadge(status: item.status, message: item.statusMessage)
                            if item.isUserDefined {
                                Button(role: .destructive) {
                                    appState.removeCustomItem(id: item.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .help("Remove from update list")
                            }
                        }
                    }
                    .width(min: 140, ideal: 180)
                }
            }

            if showLog {
                Divider()
                LogPanel(lines: appState.logLines)
                    .frame(height: 140)
            }
        }
        .navigationTitle(appState.listTitle)
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .popover(item: $infoItem) { item in
            ScrollView {
                ItemInfoView(item: item)
                    .padding(16)
            }
            .frame(width: 380, height: 420)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            TextField("Search…", text: $appState.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Button("Select All Updates") { appState.selectAllUpdates() }
                .disabled(appState.updateAvailableCount == 0)

            Button("Deselect All") { appState.deselectAll() }

            Spacer()

            Button { showLog.toggle() } label: {
                Label(showLog ? "Hide Log" : "Show Log", systemImage: "text.alignleft")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var bottomBar: some View {
        HStack {
            if appState.isUpdating {
                ProgressView("Running…")
                    .controlSize(.small)
            } else if appState.isChecking {
                ProgressView("Checking for updates…")
                    .controlSize(.small)
            } else {
                Text("\(appState.updateAvailableCount) updates · \(appState.selectedActionableItems.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct StatusBadge: View {
    let status: ItemStatus
    let message: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.label)
                    .font(.caption.weight(.medium))
                if let message, shouldShowMessage(for: status) {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    private func shouldShowMessage(for status: ItemStatus) -> Bool {
        switch status {
        case .error, .notInstalled, .updatePending, .updateAvailable:
            return message != nil
        default:
            return false
        }
    }

    private var color: Color {
        switch status {
        case .unknown, .checking: return .gray
        case .upToDate, .updated: return .green
        case .updateAvailable: return .orange
        case .updatePending: return .yellow
        case .notInstalled: return .secondary
        case .error: return .red
        case .updating: return .blue
        }
    }
}

struct LogPanel: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct ItemNameCell: View {
    let item: UpdateItem
    var onShowInfo: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ItemIdentityIcon(item: item)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).fontWeight(.medium)
                    if item.autoUpdate {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .help("Auto-update enabled")
                    }
                    if item.isSnoozed {
                        Image(systemName: "moon.zzz.fill")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                            .help("Snoozed")
                    }
                    if item.duplicateGroupID != nil {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Possible duplicate")
                    }
                    if item.isPinnedMismatch {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .help("Pinned version mismatch")
                    }
                    Spacer(minLength: 0)
                    Button {
                        onShowInfo?()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Item info")
                }
                HStack(spacing: 8) {
                    if let desc = item.description {
                        Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(item.sourceLabel)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }
}

struct ItemIdentityIcon: View {
    let item: UpdateItem

    var body: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.gradient)
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }

    private var appIcon: NSImage? {
        guard item.category == .app, let iconPath = item.iconPath else { return nil }
        let expandedPath = (iconPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else { return nil }
        return NSWorkspace.shared.icon(forFile: expandedPath)
    }

    private var symbol: String {
        switch item.id {
        case "codex-app", "codex-cli", "chatgpt", "chatgpt-atlas", "chatgpt-classic": return "circle.hexagongrid.fill"
        case "claude-app", "claude-code": return "text.quote"
        case "cursor", "cursor-agent": return "cursorarrow.rays"
        case "gemini-cli": return "sparkles"
        case "gh-cli": return "chevron.left.forwardslash.chevron.right"
        case "opencode": return "chevron.left.forwardslash.chevron.right"
        case "hermes-agent", "openclaw", "cline-cli", "qwen-code": return "brain.head.profile"
        case "node", "npm", "pnpm", "yarn", "bun", "corepack": return "curlybraces"
        case "python", "pip", "pip-packages": return "chevron.left.forwardslash.chevron.right"
        case "swift", "flutter", "dart", "cocoapods": return "hammer.fill"
        case "go", "rustup", "cargo": return "gearshape.2.fill"
        default: return item.category.icon
        }
    }

    private var tint: Color {
        switch item.id {
        case "codex-app", "codex-cli", "chatgpt", "chatgpt-atlas", "chatgpt-classic": return .teal
        case "claude-app", "claude-code": return .orange
        case "cursor", "cursor-agent": return .indigo
        case "gemini-cli": return .blue
        case "gh-cli": return .gray
        case "opencode": return .purple
        case "hermes-agent", "openclaw", "cline-cli", "qwen-code": return .pink
        case "node", "npm", "pnpm", "yarn", "bun", "corepack": return .green
        case "python", "pip", "pip-packages": return .yellow
        case "swift", "flutter", "dart", "cocoapods": return .red
        case "go", "rustup", "cargo": return .brown
        default:
            switch item.category {
            case .app: return .blue
            case .cli: return .indigo
            case .runtime: return .orange
            case .library: return .purple
            case .repo: return .teal
            }
        }
    }
}

extension ItemListView {
    @ViewBuilder
    func itemContextMenu(for item: UpdateItem) -> some View {
        if item.canInstall {
            Button("Install") {
                appState.deselectAll()
                appState.toggleSelection(for: item.id)
                Task { await appState.requestUpdateSelected() }
            }
            Divider()
        } else if item.canUpdate {
            Button("Update") {
                appState.deselectAll()
                appState.toggleSelection(for: item.id)
                Task { await appState.requestUpdateSelected() }
            }
            if item.canRetryUpdate {
                Button("Retry Update") {
                    Task { await appState.retryUpdate(for: item.id) }
                }
            }
            Divider()
        } else if item.canRetryUpdate {
            Button("Retry Update") {
                Task { await appState.retryUpdate(for: item.id) }
            }
            Divider()
        }
        Button("Snooze 1 day") { appState.snoozeItem(id: item.id, days: 1) }
        Button("Snooze 7 days") { appState.snoozeItem(id: item.id, days: 7) }
        Divider()
        Button(item.autoUpdate ? "Disable Auto-Update" : "Enable Auto-Update") {
            appState.setAutoUpdate(id: item.id, enabled: !item.autoUpdate)
        }
        Button("Pin Current Version") {
            appState.setPinnedVersion(id: item.id, version: item.currentVersion)
        }
        if item.pinnedVersion != nil {
            Button("Clear Pinned Version") {
                appState.setPinnedVersion(id: item.id, version: nil)
            }
        }
        Divider()
        Button("Ignore Permanently", role: .destructive) {
            appState.ignoreItem(id: item.id)
        }
    }
}
