import SwiftUI

/// Connect this Mac to a wallet: see the Mac, press Connect, finish in the wallet right here in the
/// panel (sign in or create a wallet, confirm it's you, approve), and this updates on its own.
struct ConnectBody: View {
    @EnvironmentObject var m: AppModel
    var changing = false
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            switch m.connectState {
            case .done(let account):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                    .symbolEffect(.bounce, value: account)
                Text("Connected to \(account)").font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center)
                Text("This Mac now works for \(account).").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                PrimaryButton(title: "Continue", action: onDone)
            case .waiting:
                MacCard()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your wallet").font(.system(size: 15, weight: .semibold))
                }
                .padding(.top, 2)
                Text(m.connectInBrowser ? "Sign in to your wallet in the browser (or create one), confirm it's you, then approve this Mac. This updates by itself." : "Sign in to your wallet (or create one), confirm it's you, then approve this Mac. This updates by itself.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if m.connectInBrowser {
                    PrimaryButton(title: "Open the browser again") { m.connect(inBrowser: true) }
                } else {
                    PrimaryButton(title: "Open the wallet") { m.openWallet(load: false) }
                }
                Button("Cancel") { m.cancelConnect() }.buttonStyle(.link).font(.caption)
            default:
                MacCard()
                Text(changing ? "Connect to another wallet" : "Connect your wallet")
                    .font(.system(size: 19, weight: .bold)).multilineTextAlignment(.center)
                Text(changing
                     ? "The wallet opens right here. Sign in to the wallet this Mac should work for and approve it. It moves from \(m.account ?? "the current wallet")."
                     : "Your MLX wallet opens right here. Sign in, or create a wallet in a minute, then approve this Mac. Your keys never leave your devices.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if case .failed(let why) = m.connectState {
                    Text(why).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                PrimaryButton(title: "Connect") { m.connect() }
                Button("Use my browser instead") { m.connect(inBrowser: true) }.buttonStyle(.link).font(.caption)
            }
        }
        .animation(.smooth(duration: 0.35), value: m.connectState)
    }
}

/// Settings → Change wallet.
struct ConnectPanel: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SubHeader(title: "Wallet", back: .settings)
            ConnectBody(changing: m.account != nil) { m.go(.settings) }
        }
        .padding(16)
    }
}

/// Settings → Beta invite: change or remove the code.
struct InvitePanel: View {
    @EnvironmentObject var m: AppModel
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SubHeader(title: "Beta invite", back: .settings)
            if let current = m.currentInvite {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current code").font(.caption).foregroundStyle(.secondary)
                        Text(current).font(.system(size: 15, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { m.forgetInvite() }.controlSize(.small)
                }
                .padding(12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text(m.currentInvite == nil ? "Enter your invite code to get test jobs." : "Use a different code").font(.callout).foregroundStyle(.secondary)
            TextField("MLX-XXXX-XXXX", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .onSubmit(save)
            if let error { Text(error).font(.caption).foregroundStyle(.red).transition(.opacity) }
            if saved { Label("Code saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).transition(.opacity) }
            PrimaryButton(title: busy ? "Checking…" : "Save code", disabled: busy || code.count < 8, action: save)
        }
        .padding(16)
        .animation(.smooth(duration: 0.3), value: error)
        .animation(.smooth(duration: 0.3), value: saved)
        .animation(.smooth(duration: 0.3), value: m.currentInvite)
    }

    private func save() {
        guard !busy, code.count >= 8 else { return }
        busy = true
        error = nil
        saved = false
        Task {
            let e = await m.redeem(code)
            busy = false
            if let e { error = e } else {
                saved = true
                code = ""
            }
        }
    }
}
