import SwiftUI

/// "MLX Node 0.9.1 is available", the release notes and an Update button. Pressing it downloads, checks, installs and
/// restarts MLX Node right here in the panel: a progress bar and a status line while it works, then the error in red
/// with Try again (and the download page as a fallback) if something goes wrong.
struct UpdateCard: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var updater: Updater
    @Environment(\.openURL) private var openURL
    let version: String
    let notes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(BrandMark.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MLX Node \(version) is available").font(.system(size: 13, weight: .semibold))
                    if !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if updater.state == .idle {
                    Button(action: start) {
                        Text("Update").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandMark.orange)
                    .controlSize(.small)
                    .transition(.opacity)
                }
            }
            if let line {
                // one view for every working step, so only the bar and the words change
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(BrandMark.orange)
                        .animation(.linear(duration: 0.15), value: fraction)
                    HStack(spacing: 6) {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Spacer(minLength: 0)
                        if spinning {
                            ProgressView().controlSize(.mini).transition(.opacity)
                        }
                    }
                    .frame(height: 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if case .failed(let message) = updater.state {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Try again", action: start).controlSize(.small)
                        Spacer(minLength: 0)
                        Button("Download in browser") { openURL(Updater.browserPage) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if case .manual(let message) = updater.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(BrandMark.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func start() {
        updater.update(to: version, size: m.latest?.size, model: m)
    }

    /// The status line while working; nil when idle, failed or handed to Finder.
    private var line: String? {
        switch updater.state {
        case .downloading(let p): return p > 0 ? "Downloading… \(Int((p * 100).rounded()))%" : "Downloading…"
        case .verifying: return "Checking signature…"
        case .installing: return "Installing…"
        case .readyToRelaunch: return "Restarting MLX Node…"
        case .idle, .failed, .manual: return nil
        }
    }

    private var fraction: Double {
        if case .downloading(let p) = updater.state { return p }
        return 1
    }

    private var spinning: Bool {
        switch updater.state {
        case .verifying, .installing, .readyToRelaunch: return true
        default: return false
        }
    }
}

/// "Updated to MLX Node 0.9.0", for a little while after the updater restarted MLX Node.
struct UpdatedRow: View {
    let version: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Updated to MLX Node \(version)").font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
