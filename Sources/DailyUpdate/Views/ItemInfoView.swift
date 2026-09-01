import SwiftUI

struct ItemInfoView: View {
    let item: UpdateItem
    var compact: Bool = false

    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
    }

    private var compactBody: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.caption.weight(.semibold))
                Text(item.category.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.displayVersion)
                    .font(.system(.caption2, design: .monospaced))
                StatusBadge(status: item.status, message: nil)
            }
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            infoRow("Name", item.name, monospaced: false, prominent: true)
            infoRow("Category", item.category.label)
            infoRow("Source", item.sourceLabel)
            infoRow("Status", item.status.label)
            infoRow("Version", item.displayVersion, monospaced: true)
            if let latest = item.latestVersion, !latest.isEmpty {
                infoRow("Latest Available", latest, monospaced: true)
            }
            infoRow("Installed", item.isInstalled ? "Yes" : "No")

            if let description = item.description, !description.isEmpty {
                infoRow("Details", description)
            }
            if let message = item.statusMessage, !message.isEmpty {
                infoRow("Message", message)
            }
            if let workingDirectory = item.workingDirectory, !workingDirectory.isEmpty {
                infoRow("Working Directory", workingDirectory, monospaced: true)
            }

            infoRow("Update Command", item.updateCommand, monospaced: true)
            if item.canInstall || !item.isInstalled {
                infoRow("Install Command", item.installCommand, monospaced: true)
            }

            if item.autoUpdate || item.isSnoozed || item.pinnedVersion != nil || item.duplicateGroupID != nil {
                Divider()
                flagsSection
            }

            Divider()
            infoRow("ID", item.id, monospaced: true)
        }
    }

    private var flagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if item.autoUpdate {
                flagRow(icon: "bolt.fill", text: "Auto-update enabled", color: .yellow)
            }
            if item.isSnoozed, let until = item.snoozedUntil {
                flagRow(icon: "moon.zzz.fill", text: "Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))", color: .purple)
            }
            if let pinned = item.pinnedVersion {
                flagRow(icon: "pin.fill", text: "Pinned to \(pinned)", color: .blue)
            }
            if item.duplicateGroupID != nil {
                flagRow(icon: "doc.on.doc", text: "Possible duplicate", color: .orange)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(prominent ? .body.weight(.medium) : (monospaced ? .system(.caption, design: .monospaced) : .caption))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func flagRow(icon: String, text: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(color)
    }
}

struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let items: [UpdateItem]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        ItemInfoView(item: item)
                        if item.id != items.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.leading, 2)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.orange)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.reason)
                        .font(.caption.weight(.medium))
                    Text(summaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(items.count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
    }

    private var summaryText: String {
        items.map(\.name).joined(separator: ", ")
    }
}
