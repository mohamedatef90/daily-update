import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState

    private var stats: DashboardStats { appState.dashboardStats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryCards
                categorySection
                if !appState.duplicateGroups.isEmpty {
                    duplicatesSection
                }
                healthSection
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
        .task { await appState.runHealthCheck() }
    }

    private var summaryCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
            StatCard(title: "Total Items", value: "\(stats.totalItems)", icon: "square.grid.2x2", tint: .blue)
            StatCard(title: "Installed", value: "\(stats.installedCount)", icon: "checkmark.circle", tint: .green)
            StatCard(title: "Updates", value: "\(stats.updatesAvailable)", icon: "exclamationmark.arrow.circlepath", tint: .orange)
            StatCard(title: "Snoozed", value: "\(stats.snoozedCount)", icon: "moon.zzz", tint: .purple)
            StatCard(title: "Auto-Update", value: "\(stats.autoUpdateCount)", icon: "bolt.circle", tint: .yellow)
            StatCard(title: "Repos Found", value: "\(appState.discoveredRepoCount)", icon: "folder", tint: .secondary)
            StatCard(title: "Apps Found", value: "\(appState.discoveredAppCount)", icon: "app.badge", tint: .secondary)
            StatCard(title: "Skills Found", value: "\(appState.discoveredSkillCount)", icon: "brain", tint: .secondary)
        }
    }

    private var categorySection: some View {
        GroupBox("By Category") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(stats.byCategory, id: \.0) { category, count in
                    HStack {
                        Label(category.label, systemImage: category.icon)
                        Spacer()
                        Text("\(count)")
                            .foregroundStyle(.secondary)
                    }
                }
                if let last = stats.lastCheck {
                    Divider()
                    Text("Last check: \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private var duplicatesSection: some View {
        GroupBox("Possible Duplicates") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Only one preferred entry from each duplicate group is updated. Custom items take priority, followed by built-in and discovered items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(appState.duplicateGroups) { group in
                    DuplicateGroupRow(
                        group: group,
                        items: appState.items(for: group)
                    )
                }
            }
            .padding(4)
        }
    }

    private var healthSection: some View {
        GroupBox("Health Check") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(appState.healthIssues) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: issue.severity))
                            .foregroundStyle(color(for: issue.severity))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).font(.caption.weight(.medium))
                            Text(issue.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Run Health Check") {
                    Task { await appState.runHealthCheck() }
                }
                .font(.caption)
            }
            .padding(4)
        }
    }

    private func icon(for severity: HealthIssue.Severity) -> String {
        switch severity {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func color(for severity: HealthIssue.Severity) -> Color {
        switch severity {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Spacer()
            }
            Text(value)
                .font(.title.weight(.bold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct HistoryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Update History")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Clear") { appState.clearHistory() }
                    .disabled(appState.history.isEmpty)
            }
            .padding()

            if appState.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No updates yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(appState.history) {
                    TableColumn("When") { entry in
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                    }
                    .width(min: 140, ideal: 160)

                    TableColumn("Item") { entry in
                        Text(entry.itemName).fontWeight(.medium)
                    }

                    TableColumn("Version") { entry in
                        Text("\(entry.fromVersion ?? "—") → \(entry.toVersion ?? "—")")
                            .font(.system(.caption, design: .monospaced))
                    }

                    TableColumn("Result") { entry in
                        Label(entry.success ? "Success" : "Failed", systemImage: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(entry.success ? .green : .red)
                            .font(.caption)
                    }
                    .width(90)
                }
            }
        }
        .navigationTitle("History")
    }
}

struct DryRunSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var confirmTitle: String {
        let actions = Set(appState.dryRunEntries.map(\.action))
        if actions == ["Install"] { return "Confirm Installs" }
        if actions == ["Update"] { return "Confirm Updates" }
        return "Confirm Actions"
    }

    private var runButtonTitle: String {
        let actions = Set(appState.dryRunEntries.map(\.action))
        if actions == ["Install"] { return "Run Installs" }
        if actions == ["Update"] { return "Run Updates" }
        return "Run Selected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(confirmTitle)
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Text("These commands will run:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            List(appState.dryRunEntries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.name).fontWeight(.medium)
                        Spacer()
                        Text(entry.action)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Text(entry.command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button(runButtonTitle) {
                    dismiss()
                    appState.shouldSkipDryRun = true
                    Task { await appState.updateSelected(skipDryRun: true) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 420)
    }
}
