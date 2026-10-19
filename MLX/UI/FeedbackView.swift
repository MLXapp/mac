import SwiftUI

/// Send feedback, inside the panel.
struct FeedbackPanel: View {
    @EnvironmentObject var m: AppModel
    @State private var text = ""
    @State private var diagnostics = true
    @State private var state: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SubHeader(title: "Send feedback")
            Text("Anything helps: MLX Node got in your way, your Mac got warm, something was confusing.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(height: 130)
            Toggle(isOn: $diagnostics) {
                Text("Include diagnostics: app, macOS, chip, memory, temperature and recent stop times. Never prompts, outputs or files.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            if let state {
                Text(state).font(.caption).foregroundStyle(state.hasPrefix("Thanks") ? .green : .red).transition(.opacity)
            }
            PrimaryButton(title: busy ? "Sending…" : "Send", disabled: busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: send)
        }
        .padding(16)
        .animation(.smooth, value: state)
    }

    private func send() {
        busy = true
        Task {
            let e = await m.sendFeedback(text, diagnostics: diagnostics)
            busy = false
            if let e { state = e } else {
                state = "Thanks! We read every note."
                text = ""
                try? await Task.sleep(for: .seconds(1.2))
                m.go(.home)
            }
        }
    }
}
