import CryptoKit
import XCTest

final class CanonicalTests: XCTestCase {
    /// Same bytes as lib/chain/crypto.ts canonical() (reference strings made with Node).
    func testLinkMessageMatchesServer() {
        let msg = Signing.linkMessage(chain: "mlx-1", account: "alex.mlx", device: "02ab", name: "Alex\u{2019}s Mac \"Pro\"\n\t\u{01}/é", chip: "M3 Max", memoryGB: 64, os: "macOS 15.5", ts: 1_792_200_000_000)
        XCTAssertEqual(msg, #"{"account":"alex.mlx","chain":"mlx-1","chip":"M3 Max","device":"02ab","memoryGB":64,"name":"Alex’s Mac \"Pro\"\n\t\u0001/é","os":"macOS 15.5","ts":1792200000000,"type":"mlx-device-link"}"#)
    }

    func testRequestMessageMatchesServer() {
        let msg = Signing.requestMessage(chain: "mlx-1", device: "03cd", method: "post", path: "/api/worker/hello", body: Data(), ts: 1_792_200_000_123)
        XCTAssertEqual(msg, #"{"body":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","chain":"mlx-1","device":"03cd","method":"POST","path":"/api/worker/hello","ts":1792200000123,"type":"mlx-device-request"}"#)
    }

    func testCleanMatchesServerSlicing() {
        XCTAssertEqual(Signing.clean("  Studio\u{0007} in Seoul  ", max: 40), "Studio in Seoul")
        XCTAssertEqual(Signing.clean(String(repeating: "a", count: 50), max: 40).count, 40)
        XCTAssertEqual(Signing.clean("abc😀def", max: 4), "abc")  // never cuts a surrogate pair in half
    }

    func testWalletNames() {
        XCTAssertEqual(Signing.walletName(" Alex "), "alex.mlx")
        XCTAssertEqual(Signing.walletName("alex.mlx"), "alex.mlx")
        XCTAssertTrue(Signing.isWalletName("alex-2.mlx"))
        XCTAssertFalse(Signing.isWalletName("a.mlx"))
        XCTAssertFalse(Signing.isWalletName("alex"))
    }

    func testBase64URL() {
        XCTAssertEqual(Data([0xfb, 0xff, 0xfe]).base64URL, "-__-")
    }
}

final class KeyTests: XCTestCase {
    func testSoftwareKeyFormat() throws {
        let k = DeviceKey(software: P256.Signing.PrivateKey())
        XCTAssertEqual(k.publicKeyHex.count, 66)
        XCTAssertTrue(k.publicKeyHex.hasPrefix("02") || k.publicKeyHex.hasPrefix("03"))
        let sig = try k.sign("hello")
        XCTAssertEqual(sig.count, 128)
        // what the server does: P-256 verify over SHA-256 of the message, raw r||s
        let pub = try P256.Signing.PublicKey(compressedRepresentation: Data(hex: k.publicKeyHex))
        let s = try P256.Signing.ECDSASignature(rawRepresentation: Data(hex: sig))
        XCTAssertTrue(pub.isValidSignature(s, for: Data("hello".utf8)))
        XCTAssertFalse(pub.isValidSignature(s, for: Data("hellO".utf8)))
    }
}

final class PolicyTests: XCTestCase {
    let ok = Conditions(idleSeconds: 600, onAC: true, thermal: "nominal", lowPowerMode: false, hour: 3)

    func testReadyWhenIdlePluggedAndCool() {
        XCTAssertTrue(Policy.readiness(ok, Limits()).ok)
    }

    func testWaitsForIdle() {
        var c = ok
        c.idleSeconds = 30
        var idle = Limits()
        idle.idleMinutes = 3
        let r = Policy.readiness(c, idle)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.reason, "Starts after 3 min idle")
    }

    func testBatteryAndHeatAndPause() {
        var c = ok
        c.onAC = false
        XCTAssertEqual(Policy.readiness(c, Limits()).reason, "Waiting for power")
        var l = Limits()
        l.onlyOnAC = false
        XCTAssertTrue(Policy.readiness(c, l).ok)
        c = ok
        c.thermal = "serious"
        XCTAssertFalse(Policy.readiness(c, Limits()).ok)
        l = Limits()
        l.idleMinutes = 3  // pause in idle mode reads "Paused"; manual mode says "Stopped" (testManualMode)
        l.maxThermal = "serious"
        XCTAssertTrue(Policy.readiness(c, l).ok)
        l.paused = true
        XCTAssertEqual(Policy.readiness(ok, l).reason, "Paused")
    }

    func testHoursOverMidnight() {
        var l = Limits()
        l.hoursFrom = 22
        l.hoursTo = 7
        XCTAssertTrue(Policy.inHours(23, l))
        XCTAssertTrue(Policy.inHours(3, l))
        XCTAssertFalse(Policy.inHours(12, l))
        XCTAssertFalse(Policy.inHours(7, l))
    }

    func testStopsTheMomentTheOwnerIsBack() {
        var c = ok
        c.idleSeconds = 0.2
        var idle = Limits()
        idle.idleMinutes = 3
        XCTAssertEqual(Policy.mustStop(c, idle), "You're back")
        XCTAssertNil(Policy.mustStop(ok, Limits()))
    }

    func testNewInstallsStartManual() {
        XCTAssertEqual(Limits().idleMinutes, 0)
        XCTAssertTrue(Limits().manual)
    }

    func testManualMode() {
        var l = Limits()
        l.idleMinutes = 0
        var busy = ok
        busy.idleSeconds = 0.1
        // manual: works while the Mac is in use, and the owner's touch doesn't stop it
        XCTAssertTrue(Policy.readiness(busy, l).ok)
        XCTAssertNil(Policy.mustStop(busy, l))
        l.paused = true
        XCTAssertEqual(Policy.readiness(busy, l).reason, "Stopped")
        XCTAssertEqual(Policy.mustStop(busy, l), "Stopped")
    }

    func testClamp() {
        var l = Limits()
        l.idleMinutes = -5
        l.memoryPct = 99
        l.maxThermal = "critical"
        let c = l.clamped()
        XCTAssertEqual(c.idleMinutes, 0)
        XCTAssertEqual(c.memoryPct, 75)
        XCTAssertEqual(c.maxThermal, "fair")
    }
}

extension Data {
    init(hex: String) {
        var d = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            d.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self = d
    }
}
