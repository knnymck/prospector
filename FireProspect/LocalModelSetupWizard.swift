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
                    Text("Set up local AI").font(.title.bold())
                    Text("Gemma 3 1B • MLX for Apple Silicon").foregroundStyle(.secondary)
                }
            }
            Divider()
            Group {
                switch stage {
                case .introduction: introduction
                case .installing: activity(title: "Downloading and loading Gemma 3 1B", detail: "MLX is downloading the public 4-bit model from Hugging Face. No account or access token is required.")
                case .verifying: activity(title: "Verifying local inference", detail: "Running a private test prompt on this Mac…")
                case .complete: result(icon: "checkmark.circle.fill", color: .green, title: "Gemma 3 1B is ready", detail: "FireProspect now runs the model locally with native MLX. Prompts do not leave your Mac.")
                case .failed: result(icon: "exclamationmark.triangle.fill", color: .orange, title: "Setup could not finish", detail: errorMessage)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                if stage != .installing && stage != .verifying { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                Spacer()
                if stage == .introduction || stage == .failed { Button(stage == .failed ? "Try Again" : "Install Gemma 3 1B") { install() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                if stage == .complete { Button("Done") { onCompletion(); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            }
        }
        .padding(28).frame(width: 580, height: 430)
        .interactiveDismissDisabled(stage == .installing || stage == .verifying)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Optimized for M-series Macs", systemImage: "apple.logo").font(.headline)
            Text("FireProspect uses Apple's MLX framework—not Ollama—to run a 4-bit Gemma checkpoint efficiently in unified memory.")
            Label("Compact 1B model download", systemImage: "internaldrive")
            Label("Saved in this app's model cache", systemImage: "folder")
            Label("No Hugging Face token required", systemImage: "person.badge.key")
            Text("An existing Python Hugging Face cache may be stored outside this app's sandbox. FireProspect manages its own verified copy so setup remains reliable.").font(.callout).foregroundStyle(.secondary)
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
