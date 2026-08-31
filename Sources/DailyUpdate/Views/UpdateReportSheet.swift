import SwiftUI

struct UpdateReportSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: report.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(report.failedCount == 0 ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.failedCount == 0 ? "Updates complete" : "Updates finished with issues")
                        .font(.title3.weight(.semibold))
                    Text(report.completedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                summary(value: report.totalCount, label: "Processed", color: .blue)
                summary(value: report.succeededCount, label: "Updated", color: .green)
                summary(value: report.failedCount, label: "Failed", color: .red)
            }

            if !report.results.isEmpty {
                List(report.results) { result in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.success ? .green : .red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.name).fontWeight(.medium)
                            Text(result.success ? "Updated successfully" : "Reason: \(result.message ?? "Update failed")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if !result.success {
                            Button("Retry") {
                                dismiss()
                                Task { await appState.retryUpdate(id: result.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 150, maxHeight: 280)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var report: UpdateRunReport {
        appState.updateReport ?? UpdateRunReport(
            completedAt: Date(),
            succeededCount: 0,
            failedCount: 0,
            results: []
        )
    }

    private func summary(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.title2.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
