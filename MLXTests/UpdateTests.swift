import XCTest

final class UpdateTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(UpdateKit.isNewer("0.8.2", than: "0.8.1"))
        XCTAssertTrue(UpdateKit.isNewer("0.8.10", than: "0.8.9"))  // numbers, not text
        XCTAssertTrue(UpdateKit.isNewer("0.9", than: "0.8.12"))
        XCTAssertTrue(UpdateKit.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertTrue(UpdateKit.isNewer("0.8.2.1", than: "0.8.2"))
        XCTAssertFalse(UpdateKit.isNewer("0.8.1", than: "0.8.1"))
        XCTAssertFalse(UpdateKit.isNewer("0.9", than: "0.9.0"))  // same version, written shorter
        XCTAssertFalse(UpdateKit.isNewer("0.9.0", than: "0.9"))
        XCTAssertFalse(UpdateKit.isNewer("0.8.1", than: "0.8.2"))
        XCTAssertFalse(UpdateKit.isNewer("0.8.9", than: "0.8.10"))
        XCTAssertFalse(UpdateKit.isNewer("", than: "0.8.1"))
        XCTAssertFalse(UpdateKit.isNewer("garbage", than: "0.0.1"))
        XCTAssertTrue(UpdateKit.isNewer(" 0.8.3-beta ", than: "0.8.2"))  // suffixes are ignored
        XCTAssertEqual(UpdateKit.versionParts("0.8.10"), [0, 8, 10])
    }

    func testDmgName() {
        XCTAssertEqual(UpdateKit.dmgName("0.8.2"), "MLX-082.dmg")
        XCTAssertEqual(UpdateKit.dmgName("0.10.0"), "MLX-0100.dmg")
    }

    /// Trimmed output of `hdiutil attach -nobrowse -noverify -noautoopen -readonly -plist` for a UDZO image.
    static let attachPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>system-entities</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>content-hint</key>
        \t\t\t<string>GUID_partition_scheme</string>
        \t\t\t<key>dev-entry</key>
        \t\t\t<string>/dev/disk7</string>
        \t\t\t<key>potentially-mountable</key>
        \t\t\t<false/>
        \t\t\t<key>unmapped-content-hint</key>
        \t\t\t<string>GUID_partition_scheme</string>
        \t\t</dict>
        \t\t<dict>
        \t\t\t<key>content-hint</key>
        \t\t\t<string>Apple_HFS</string>
        \t\t\t<key>dev-entry</key>
        \t\t\t<string>/dev/disk7s1</string>
        \t\t\t<key>mount-point</key>
        \t\t\t<string>/Volumes/MLX 1</string>
        \t\t\t<key>potentially-mountable</key>
        \t\t\t<true/>
        \t\t\t<key>volume-kind</key>
        \t\t\t<string>hfs</string>
        \t\t</dict>
        \t</array>
        </dict>
        </plist>
        """

    func testMountPointFromHdiutilPlist() {
        XCTAssertEqual(UpdateKit.mountPoints(hdiutilPlist: Data(Self.attachPlist.utf8)), ["/Volumes/MLX 1"])
    }

    func testMountPointWithTextBeforeThePlist() {
        let out = "Checksumming whole disk (Apple_HFS : 0)…\n" + Self.attachPlist
        XCTAssertEqual(UpdateKit.mountPoints(hdiutilPlist: Data(out.utf8)), ["/Volumes/MLX 1"])
    }

    func testMountPointFromBadOutput() {
        XCTAssertEqual(UpdateKit.mountPoints(hdiutilPlist: Data()), [])
        XCTAssertEqual(UpdateKit.mountPoints(hdiutilPlist: Data("hdiutil: attach failed - image not recognized".utf8)), [])
        let noMount = Self.attachPlist.replacingOccurrences(of: "<key>mount-point</key>", with: "<key>other</key>")
        XCTAssertEqual(UpdateKit.mountPoints(hdiutilPlist: Data(noMount.utf8)), [])
    }

    func testRequirementNamesTeamAndApp() {
        XCTAssertTrue(UpdateKit.appRequirement.contains(#"identifier "app.mlx.mac""#))
        XCTAssertTrue(UpdateKit.appRequirement.contains(#"certificate leaf[subject.OU] = "CCKXS9W488""#))
        XCTAssertTrue(UpdateKit.appRequirement.hasPrefix("anchor apple generic"))
    }
}
