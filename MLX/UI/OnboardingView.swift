import SwiftUI

/// First run, inside the panel: what MLX does, the invite code, connecting a wallet, limits and a
/// speed test. Each step slides in; the dots show where you are.
struct SetupPanel: View {
    @EnvironmentObject var m: AppModel
    typealias Step = AppModel.SetupStep
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    /// Back to the step the Mac still needs, if something was undone (invite removed, wallet unlinked).
    private var step: Step {
        if case .failed = m.phase { return m.setupStep }
        if m.phase == .needsLink, m.setupStep.rawValue > Step.connect.rawValue { return .connect }
        return m.setupStep
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Emblem(size: 22)
                (Text("ML") + Text("X").foregroundColor(Color.primary.opacity(0.7))).font(.system(size: 14, weight: .bold))
                Spacer()
                if step != .welcome, step != .done {
                    Text("Set up").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)
            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: m.forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: m.forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity)
            .clipped()
            dots.padding(.top, 16)
        }
        .padding(18)
        .animation(.smooth(duration: 0.3), value: error)
        .animation(.smooth(duration: 0.3), value: busy)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            page(title: "Your Mac, part of a supercomputer.", text: "MLX Node runs AI work while your Mac is idle and plugged in, earns MLX for it, and stops the moment you need it. It never reads your files, photos or messages.") {
                Emblem(size: 64).padding(.vertical, 6)
            } actions: {
                PrimaryButton(title: "Get started") { m.setupGo(.connect) }
            }
        case .invite:
            page(title: "Enter your invite code.", text: "It's in your invite email and on your invite page. One code works on up to five Macs.") {
                TextField("MLX-XXXX-XXXX", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .onSubmit(redeem)
            } actions: {
                PrimaryButton(title: busy ? "Checking…" : "Continue", disabled: busy || code.count < 8, action: redeem)
                Link("No code yet? Join the beta", destination: URL(string: "https://mlx.app/download#beta")!).font(.caption)
            }
        case .connect:
            ConnectBody(onDone: { m.setupGo(.limits) })
        case .limits:
            page(title: "You're in charge.", text: "MLX Node works only when all of these are true. Change them any time in Settings.") {
                LimitsForm()
            } actions: {
                PrimaryButton(title: "Continue") { m.setupGo(.measure) }
            }
        case .measure:
            page(title: "Measure this Mac.", text: "A short run on a small model (about 300 MB, downloaded once) to see how fast your Mac is.") {
                if case .calibrating(let p) = m.activity {
                    ProgressView(value: p).tint(BrandMark.orange).transition(.opacity)
                } else if let c = m.calibration {
                    Text("\(Int(c.tokPerSec.rounded())) tokens per second")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(BrandMark.gradient)
                        .transition(.scale.combined(with: .opacity))
                }
            } actions: {
                if m.calibration == nil {
                    PrimaryButton(title: busy ? "Measuring…" : "Run the test", disabled: busy, action: measure)
                    Button("Skip for now") { m.setupGo(.done) }.buttonStyle(.link).font(.caption)
                } else {
                    PrimaryButton(title: "Continue") { m.setupGo(.done) }
                }
            }
        case .done:
            page(title: "All set.", text: "MLX Node lives in your menu bar. Leave your Mac idle and plugged in, and it earns MLX, paid every hour and locked for 30 days (3 to 20 with a dedicated seat). A dedicated seat matched to your Mac multiplies it: 20× with Core, 80× with Pro, 320× with Ultra.") {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: step)
            } actions: {
                PrimaryButton(title: "Done") { m.finishSetup() }
            }
        }
    }

    private func page<A: View, B: View>(title: String, text: String, @ViewBuilder hero: () -> A, @ViewBuilder actions: () -> B) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 10) { hero() }
            Text(title).font(.system(size: 19, weight: .bold)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).transition(.opacity)
            }
            VStack(spacing: 8) { actions() }.padding(.top, 4)
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.filter { $0 != .invite }, id: \.self) { s in
                Capsule()
                    .fill(s == step ? AnyShapeStyle(BrandMark.gradient) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                    .frame(width: s == step ? 18 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.4), value: step)
    }

    private func redeem() {
        guard !busy, code.count >= 8 else { return }
        busy = true
        error = nil
        Task {
            let e = await m.redeem(code)
            busy = false
            if let e { error = e } else { m.setupGo(m.phase == .ready ? .limits : .connect) }
        }
    }

    private func measure() {
        busy = true
        error = nil
        Task {
            let e = await m.calibrate()
            busy = false
            if let e { error = e }
        }
    }
}
