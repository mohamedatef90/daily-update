import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { appState.showAddItem = true } label: {
                    Label("Add Item", systemImage: "plus")
                }

                if appState.isChecking {
                    ProgressView().controlSize(.small)
                }

                Button { Task { await appState.checkAll() } } label: {
                    Label("Check Updates", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isChecking || appState.isUpdating)
                .keyboardShortcut("r", modifiers: .command)

                Button { Task { await appState.requestUpdateSelected() } } label: {
                    Label(appState.selectedActionLabel, systemImage: "arrow.down.circle.fill")
                }
                .disabled(appState.isUpdating || appState.selectedActionableItems.isEmpty)
                .keyboardShortcut("u", modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if appState.showDashboard {
            DashboardView()
        } else if appState.showHistory {
            HistoryView()
        } else {
            ItemListView()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    private enum Tag {
        static let all = "all"
        static let dashboard = "dashboard"
        static let updates = "updates"
        static let history = "history"
    }

    var body: some View {
        List(selection: sidebarSelection) {
            Section("Overview") {
                sidebarRow(title: "Dashboard", icon: "chart.bar.fill", count: appState.updateAvailableCount, tint: .blue)
                    .tag(Tag.dashboard)
                sidebarRow(title: "All Items", icon: "square.grid.2x2", count: appState.installedItems.count)
                    .tag(Tag.all)
            }

            Section("Categories") {
                ForEach(ItemCategory.allCases) { category in
                    sidebarRow(
                        title: category.label,
                        icon: category.icon,
                        count: appState.installedItems.filter { $0.category == category }.count
                    )
                    .tag(category.rawValue)
                }
            }

            Section("Status") {
                sidebarRow(
                    title: "Updates Available",
                    icon: "exclamationmark.arrow.circlepath",
                    count: appState.updateAvailableCount,
                    tint: .orange
                )
                .tag(Tag.updates)

                sidebarRow(title: "History", icon: "clock.arrow.circlepath", count: appState.history.count)
                    .tag(Tag.history)
            }

            if let lastCheck = appState.lastCheckDate {
                Section("Last Check") {
                    Text(lastCheck, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Daily Update")
        .frame(minWidth: 220)
    }

    private var sidebarSelection: Binding<String> {
        Binding(
            get: { appState.sidebarSelectionTag },
            set: { appState.setSidebarSelection($0) }
        )
    }

    private func sidebarRow(title: String, icon: String, count: Int, tint: Color = .secondary) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                CountBadge(count: count, tint: tint)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
        }
    }
}

struct CountBadge: View {
    let count: Int
    var tint: Color = .secondary

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}
