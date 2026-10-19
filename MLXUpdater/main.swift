import Foundation

/// MLX Node's installer service. It lives inside the app (Contents/XPCServices/MLXUpdater.xpc), only MLX Node can
/// reach it, and it isn't sandboxed, so it can do what the sandboxed app can't: mount the update's disk image, swap
/// the new app in where MLX Node is installed, and give an install from before 0.9.0 ("MLX.app") its new name.
/// It never downloads anything and never runs the app.
final class Service: NSObject, UpdaterProtocol {
    private let queue = DispatchQueue(label: "app.mlx.mac.updater.work")

    func prepare(_ dmg: FileHandle, target: String, withReply reply: @escaping (String?, String?, Int, String?) -> Void) {
        queue.async {
            do {
                let p = try Installer.prepare(dmg: dmg, target: target)
                reply(p.staged, p.version, 0, nil)
            } catch {
                let f = Service.failure(error)
                reply(nil, nil, f.code.rawValue, f.message)
            }
        }
    }

    func install(_ staged: String, target: String, withReply reply: @escaping (Int, String?) -> Void) {
        queue.async {
            do {
                try Installer.install(staged: staged, target: target)
                reply(0, nil)
            } catch {
                let f = Service.failure(error)
                reply(f.code.rawValue, f.message)
            }
        }
    }

    func moveToCurrentName(_ target: String, withReply reply: @escaping (String?, Int, String?) -> Void) {
        queue.async {
            do {
                let path = try Installer.moveToCurrentName(target)
                reply(path, 0, nil)
            } catch {
                let f = Service.failure(error)
                reply(nil, f.code.rawValue, f.message)
            }
        }
    }

    func discard(_ staged: String, target: String, withReply reply: @escaping () -> Void) {
        queue.async {
            Installer.discard(staged: staged, target: target)
            reply()
        }
    }

    func ping(withReply reply: @escaping (String) -> Void) {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        reply("MLXUpdater \(v) (\(Installer.isReleaseSigned ? "release" : "local build"))")
    }

    static func failure(_ e: Error) -> UpdateFailure {
        (e as? UpdateFailure) ?? UpdateFailure(.failed, e.localizedDescription)
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    /// A Developer ID build answers only a Developer ID build of MLX Node; a local ad-hoc build answers its own app.
    private let strict = Installer.isReleaseSigned

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if strict { connection.setCodeSigningRequirement(UpdateKit.appRequirement) }
        connection.exportedInterface = NSXPCInterface(with: UpdaterProtocol.self)
        connection.exportedObject = Service()
        connection.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()  // runs the service; never returns
