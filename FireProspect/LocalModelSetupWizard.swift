import SwiftUI

struct LocalModelSetupWizard: View {
    enum Stage { case introduction, installing, verifying, complete, failed }
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .introduction
    @State private var progress: Double?
    @State private var errorMessage = ""
    let onCompletion: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "cpu.fill").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Set up on-device AI").font(.title.bold())
                    Text("Suggests related search terms on this Mac").foregroundStyle(.secondary)
                }
            }
            Divider()
            Group {
                switch stage {
                case .introduction: introduction
                case .installing: activity(title: "Downloading on-device AI", detail: "This stays on your Mac and does not require an account.")
                case .verifying: activity(title: "Making sure it works", detail: "Running a quick private test on this Mac…")
                case .complete: result(icon: "checkmark.circle.fill", color: .green, title: "On-device AI is ready", detail: "Related search terms stay private on this Mac.")
                case .failed: result(icon: "exclamationmark.triangle.fill", color: .orange, title: "Setup could not finish", detail: errorMessage)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                if stage != .installing && stage != .verifying { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                Spacer()
                if stage == .introduction || stage == .failed { Button(stage == .failed ? "Try Again" : "Install on-device AI") { install() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                if stage == .complete { Button("Done") { onCompletion(); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            }
        }
        .padding(28).frame(width: 580, height: 430)
        .interactiveDismissDisabled(stage == .installing || stage == .verifying)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Made for Apple silicon Macs", systemImage: "apple.logo").font(.headline)
            Text("Install a small model on this Mac to suggest related business types when you search. Nothing is sent to a cloud AI service.")
            Label("Small download", systemImage: "internaldrive")
            Label("Saved only for this app", systemImage: "folder")
            Label("No extra account needed", systemImage: "person.badge.key")
            Text("Keep FireProspect open until setup finishes.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func activity(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold()); Text(detail).foregroundStyle(.secondary)
            if let progress { ProgressView(value: progress); Text("\(Int(progress * 100))%").monospacedDigit() } else { ProgressView() }
            Text("Keep FireProspect open until setup finishes.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func result(icon: String, color: Color, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) { Image(systemName: icon).font(.system(size: 42)).foregroundStyle(color); Text(title).font(.title2.bold()); Text(detail).foregroundStyle(.secondary) }
    }

    private func install() {
        stage = .installing; progress = nil; errorMessage = ""
        Task {
            do {
                try await LocalModelService.shared.ensureInstalled { value in await MainActor.run { progress = value } }
                stage = .verifying
                try await LocalModelService.shared.verify()
                stage = .complete
            } catch { errorMessage = error.localizedDescription; stage = .failed }
        }
    }
}
