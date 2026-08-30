import SwiftUI

struct UpdateCheckLoadingView: View {
    let checkedItemCount: Int
    let totalItemCount: Int
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            isAnimating = true
                        }
                    }

                VStack(spacing: 6) {
                    Text("Checking for updates")
                        .font(.title2.weight(.semibold))
                    Text("Finding installed apps, CLIs, libraries, and repos…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if totalItemCount > 0 {
                    ProgressView(value: Double(checkedItemCount), total: Double(totalItemCount))
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                    Text("Checked \(checkedItemCount) of \(totalItemCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.regular)
                }
            }
            .frame(width: 390)
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Checking for updates")
        .accessibilityValue(totalItemCount > 0 ? "Checked \(checkedItemCount) of \(totalItemCount) items" : "Starting update check")
    }
}
