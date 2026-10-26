import SwiftUI

/// The one panel under the menu bar icon. Every screen (first-run steps, the live view, the wallet,
/// settings, connecting a wallet, the invite code, feedback) slides in here; there are no other windows.
struct PanelView: View {
    @EnvironmentObject var m: AppModel

    static let width: CGFloat = 340

    private var key: String {
        if m.screen != .home { return "\(m.screen)" }
        return m.phase != .ready || m.setupOpen ? "setup" : "home"
    }

    var body: some View {
        ZStack(alignment: .top) {
            screen
                .id(key)
                .transition(.asymmetric(
                    insertion: .move(edge: m.forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: m.forward ? .leading : .trailing).combined(with: .opacity)))
        }
        .frame(width: m.screen == .wallet ? WalletPanel.width : PanelView.width)
        .clipped()
        .animation(.smooth(duration: 0.38), value: key)
    }

    @ViewBuilder private var screen: some View {
        switch m.screen {
        case .settings: SettingsPanel()
        case .feedback: FeedbackPanel()
        case .upgrade: UpgradePanel()
        case .connect: ConnectPanel()
        case .invite: InvitePanel()
        case .wallet: WalletPanel()
        case .home:
            if m.phase != .ready || m.setupOpen { SetupPanel() } else { MenuView() }
        }
    }
}

/// Back arrow and title for screens under the main one.
struct SubHeader: View {
    @EnvironmentObject var m: AppModel
    let title: String
    var back: AppModel.Screen = .home

    var body: some View {
        HStack(spacing: 6) {
            Button {
                m.go(back)
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
        }
    }
}

/// The big button used across the panel.
struct PrimaryButton: View {
    let title: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 3)
        }
        .buttonStyle(.borderedProminent)
        .tint(BrandMark.ink)
        .controlSize(.large)
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
    }
}

/// This Mac, as a small card: name, chip, memory, macOS.
struct MacCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: SystemInfo.symbol)
                .font(.system(size: 22, weight: .regular))
                .frame(width: 44, height: 44)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(SystemInfo.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("Apple \(SystemInfo.chip) · \(SystemInfo.memoryGB) GB · \(SystemInfo.os)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
