import CryptoKit
import XCTest

/// The witness's Swift port of lib/chain/tlog.ts, against vectors made by the TypeScript code on mlx.app.
final class WitnessTests: XCTestCase {
    let root7 = Data(hexString: "20d6e31e3f416ff0c7e2bc29a45419c27d9a97b20e659df312d277488cd65ee6")!
    let root20 = Data(hexString: "b8ee5800e1dcc261a5a13601c5dfabe9a68cfa880e3b0c67c19846f78363a545")!
    let proof = [
            "e7ee4b16d0a6f2738b1f7c1b549981e73356f5530004a0c46969405088c4c982",
            "d6fda8ec1d07f4649995297969a82c42794b5c8a19eb46ca787cff775afd50dc",
            "e275c350e57a6762a62e9712288078f74f6f30aee1726ae1da45f6720f0a8142",
            "d89f999e35b8a70ff72ce439985842ace3cd845b930a772a5e5b235c01123316",
            "f6f5a1ad135e17a242b0be28ddff88dbfefcec6f93a717407b5f3f07ef2b8f34",
            "2e3a5668f9f841d8f4ce0b3731c9016a7efcd38cc669acda3ad3159d3e2f0d22"
    ].compactMap { Data(hexString: $0) }
    let pk = "2e8e6244518eec6de91e630a2b2f4c1a409c333a7613c857cc4e3ee5fc1bd14f"
    let note = "mlx.app/ledger/mlx-1\n20\nuO5YAOHcwmGloTYBxd+r6aaM+ogOOwxnwZhG94NjpUU=\n\n— mlx.app/ledger/mlx-1 cjR6YDw9aYLV062Oj9rlFZn9V0FC8pehfsL2MYQQDo/8HS04v784ze/0tW/Zcq+u2wizOLbmjBheKC/qvMGzlMBUjw0=\n"

    func testLeafHash() {
        XCTAssertEqual(TLog.leafHash(Data(hexString: "c02c0b965e023abee808f2b548d8d5193a8b5229be6f3121a6f16e2d41a449b3")!).hex, "e02a6a43ea6d83d2fab6f0ba16eb545dc04e93addaf9c1b7138e6e96e01ac596")
    }

    func testConsistency() {
        XCTAssertTrue(TLog.verifyConsistency(m: 7, n: 20, root1: root7, root2: root20, proof: proof))
        XCTAssertFalse(TLog.verifyConsistency(m: 7, n: 20, root1: root20, root2: root7, proof: proof))
        XCTAssertFalse(TLog.verifyConsistency(m: 8, n: 20, root1: root7, root2: root20, proof: proof))
        var bad = proof
        bad[0] = Data(repeating: 1, count: 32)
        XCTAssertFalse(TLog.verifyConsistency(m: 7, n: 20, root1: root7, root2: root20, proof: bad))
    }

    func testCheckpoint() {
        let cp = TLog.parseCheckpoint(note, sequencer: pk)
        XCTAssertEqual(cp?.size, 20)
        XCTAssertEqual(cp?.root, root20)
        XCTAssertNil(TLog.parseCheckpoint(note.replacingOccurrences(of: "\n20\n", with: "\n21\n"), sequencer: pk))
        XCTAssertNil(TLog.parseCheckpoint(note, sequencer: String(repeating: "ab", count: 32)))
        XCTAssertEqual(TLog.cosignMessage(time: 1700000000, body: cp!.body), "mlx-cosignature/v1\ntime 1700000000\nmlx.app/ledger/mlx-1\n20\nuO5YAOHcwmGloTYBxd+r6aaM+ogOOwxnwZhG94NjpUU=\n")
    }
}
