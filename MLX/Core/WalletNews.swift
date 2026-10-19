import AppKit
import Foundation
import UserNotifications

/// Wallet news as Mac notifications: money received, a deposit credited, a node recorded, a commission
/// paid, a withdrawal sent or returned. The website sends these as web push; inside the app the same
/// news comes from the ledger's public account history, checked once a minute, for the wallet open in
/// the panel (or the one this Mac works for). Off until the owner turns it on in Settings.
@MainActor
final class WalletNews: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = WalletNews()

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "walletNews")
    @Published private(set) var denied = false
    /// Tapping a notification opens the wallet.
    var onOpen: (() -> Void)?

    private let center = UNUserNotificationCenter.current()
    private var checking = false

    override init() {
        super.init()
        center.delegate = self
    }

    func setEnabled(_ on: Bool) {
        guard on else {
            enabled = false
            UserDefaults.standard.set(false, forKey: "walletNews")
            return
        }
        Task {
            let ok = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            denied = !ok
            enabled = ok
            UserDefaults.standard.set(ok, forKey: "walletNews")
        }
    }

    /// Looks for news on `account` since the last look. The first look only remembers what's there.
    func check(account: String?) async {
        guard enabled, let account, !checking else { return }
        checking = true
        defer { checking = false }
        var c = URLComponents(url: API.baseURL.appendingPathComponent("api/account/\(account)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "txs", value: "25")]
        guard let url = c.url, let got = try? await URLSession.shared.data(from: url),
              (got.1 as? HTTPURLResponse)?.statusCode == 200,
              let page = try? JSONDecoder().decode(Page.self, from: got.0) else { return }
        let key = "walletNewsSeen.\(account)"
        let seen = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let first = UserDefaults.standard.object(forKey: key) == nil
        let txs = page.txs ?? []
        UserDefaults.standard.set(Array(txs.map(\.hash).prefix(200)), forKey: key)
        if first { return }
        for t in txs.reversed() where !seen.contains(t.hash) && t.status == "success" {
            guard let n = note(t, me: account) else { continue }
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: t.hash, content: content, trigger: nil))
        }
    }

    private func note(_ t: Tx, me: String) -> (title: String, body: String)? {
        let body = t.tx.body
        let fx = t.effects ?? []
        switch body.type {
        case "deposit" where body.to == me:
            return ("Deposit arrived: \(Self.amount(body.amount, "USDC"))", "It's in your wallet as USDC.")
        case "commission" where body.to == me:
            return ("Commission paid: \(Self.amount(body.amount, "USDC"))", "USDC is in your wallet.")
        case "withdraw_settle":
            return body.outcome == "paid"
                ? ("Withdrawal sent", "USDC is on its way to your Solana address.")
                : ("Withdrawal returned", "The amount and the fee are back in your wallet.")
        case "mint_node", "buy_node", "grant_node":
            if let n = fx.first(where: { $0.kind == "mint_node" && ($0.to == nil || $0.to == me) })?.node {
                return ("Node #\(n) is yours", "It's on the network and earning MLX.")
            }
            return nil
        case "transfer" where t.tx.from != me:
            guard let e = fx.first(where: { $0.kind == "transfer" && $0.to == me }) else { return nil }
            return ("Received \(Self.amount(e.amount, e.token ?? ""))", "From \(e.from ?? t.tx.from).")
        default:
            return nil
        }
    }

    /// "12.5 USDC" from base units (6 decimals).
    static func amount(_ units: String?, _ token: String) -> String {
        let v = (Double(units ?? "0") ?? 0) / 1_000_000
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = v < 1 ? 6 : 2
        return "\(f.string(from: NSNumber(value: v)) ?? "\(v)") \(token)".trimmingCharacters(in: .whitespaces)
    }

    // banners even while the panel is open, and a tap opens the wallet
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.onOpen?() }
    }

    // MARK: wire types (only what the notes need)

    private struct Page: Decodable { let txs: [Tx]? }
    private struct Tx: Decodable {
        let hash: String
        let status: String
        let tx: Signed
        let effects: [Effect]?
    }
    private struct Signed: Decodable {
        let from: String
        let body: Body
    }
    private struct Body: Decodable {
        let type: String
        let to: String?
        let amount: String?
        let outcome: String?
    }
    private struct Effect: Decodable {
        let kind: String
        let token: String?
        let from: String?
        let to: String?
        let amount: String?
        let node: Int?
    }
}
