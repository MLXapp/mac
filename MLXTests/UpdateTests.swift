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
        XCTAssertEqual(UpdateKit.dmgName("0.9.0"), "MLX-Node-090.dmg")
        XCTAssertEqual(UpdateKit.dmgName("0.10.0"), "MLX-Node-0100.dmg")
    }

    // MARK: the app's file name (MLX.app → MLX Node.app, 0.9.0)

    func testOldNameMovesToNewNameInTheSameFolder() {
        let none: (String) -> Bool = { _ in false }
        XCTAssertEqual(UpdateKit.renamedPath(for: "/Applications/MLX.app", exists: none), "/Applications/MLX Node.app")
        XCTAssertEqual(UpdateKit.renamedPath(for: "/Users/a/Applications/MLX.app", exists: none), "/Users/a/Applications/MLX Node.app")
        XCTAssertEqual(UpdateKit.renamedPath(for: "/Applications/MLX.app/", exists: none), "/Applications/MLX Node.app")
        XCTAssertEqual(UpdateKit.renamedPath(for: "/Volumes/Work/Apps/MLX.app", exists: none), "/Volumes/Work/Apps/MLX Node.app")
    }

    func testNewNameAndOtherNamesStay() {
        let none: (String) -> Bool = { _ in false }
        XCTAssertNil(UpdateKit.renamedPath(for: "/Applications/MLX Node.app", exists: none))
        XCTAssertNil(UpdateKit.renamedPath(for: "/Applications/MLX 2.app", exists: none))  // a copy the owner named
        XCTAssertNil(UpdateKit.renamedPath(for: "/Applications/mlx.app", exists: none))  // only the exact old name
        XCTAssertNil(UpdateKit.renamedPath(for: "/Applications/MLX Studio.app", exists: none))
        XCTAssertNil(UpdateKit.renamedPath(for: "/private/var/folders/x/T/AppTranslocation/1234/d/MLX.app", exists: none))
    }

    func testNeverRenamesOntoSomethingThere() {
        // MLX Node.app already in Applications (dragged from the disk image): the old copy keeps its name
        XCTAssertNil(UpdateKit.renamedPath(for: "/Applications/MLX.app", exists: { $0 == "/Applications/MLX Node.app" }))
        // something with the new name elsewhere doesn't matter
        XCTAssertEqual(UpdateKit.renamedPath(for: "/Applications/MLX.app", exists: { $0 == "/Users/a/Applications/MLX Node.app" }), "/Applications/MLX Node.app")
    }

    func testRestartsFromTheNewPlaceOnlyWhenTheDiskSaysSo() {
        let old = "/Applications/MLX.app", new = "/Applications/MLX Node.app"
        // renamed: start the app from its new place
        XCTAssertEqual(UpdateKit.restartPath(old: old, new: new, exists: { $0 == new }), new)
        // not renamed (no permission, something in the way): keep running where it is
        XCTAssertNil(UpdateKit.restartPath(old: old, new: new, exists: { $0 == old }))
        XCTAssertNil(UpdateKit.restartPath(old: old, new: new, exists: { $0 == old || $0 == new }))
        // nothing to restart into
        XCTAssertNil(UpdateKit.restartPath(old: old, new: nil, exists: { _ in true }))
        XCTAssertNil(UpdateKit.restartPath(old: old, new: new, exists: { _ in false }))
        XCTAssertNil(UpdateKit.restartPath(old: old, new: old, exists: { _ in false }))
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
