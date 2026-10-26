import XCTest

/// MLX Node opened from its disk image installs itself (0.9.8): when that applies, where it goes, never a downgrade.
final class DiskInstallTests: XCTestCase {
    typealias Plan = UpdateKit.DiskInstallPlan
    let home = "/Users/a"

    // MARK: running from the disk image

    func testDiskImageIsAReadOnlyVolume() {
        XCTAssertTrue(UpdateKit.isOnDiskImage(path: "/Volumes/MLX Node/MLX Node.app", original: nil, readOnly: true))
        XCTAssertTrue(UpdateKit.isOnDiskImage(path: "/Volumes/MLX Node 1/MLX Node.app", original: nil, readOnly: true))
        // can't tell: under /Volumes counts as the disk image
        XCTAssertTrue(UpdateKit.isOnDiskImage(path: "/Volumes/MLX Node/MLX Node.app", original: nil, readOnly: nil))
        // an Applications folder on a writable external drive runs as usual
        XCTAssertFalse(UpdateKit.isOnDiskImage(path: "/Volumes/Work/Applications/MLX Node.app", original: nil, readOnly: false))
    }

    func testInstalledCopiesRunAsUsual() {
        XCTAssertFalse(UpdateKit.isOnDiskImage(path: "/Applications/MLX Node.app", original: nil, readOnly: false))
        XCTAssertFalse(UpdateKit.isOnDiskImage(path: "/Users/a/Applications/MLX Node.app", original: nil, readOnly: false))
        XCTAssertFalse(UpdateKit.isOnDiskImage(path: "/Users/a/Downloads/MLX Node.app", original: nil, readOnly: nil))
        // the sealed system volume is read-only but isn't a disk image
        XCTAssertFalse(UpdateKit.isOnDiskImage(path: "/Applications/MLX Node.app", original: nil, readOnly: true))
        XCTAssertFalse(UpdateKit.isOnDiskImage(path: "/Volumes/", original: nil, readOnly: true))
        XCTAssertFalse(UpdateKit.isOnDiskImage(path: "/private/Volumes/x/MLX Node.app", original: nil, readOnly: true))
    }

    func testTranslocatedCopyCountsByWhereItCameFrom() {
        let t = "/private/var/folders/xy/abc/T/AppTranslocation/6B1F-22/d/MLX Node.app"
        XCTAssertTrue(UpdateKit.isOnDiskImage(path: t, original: "/Volumes/MLX Node/MLX Node.app", readOnly: true))
        XCTAssertTrue(UpdateKit.isOnDiskImage(path: t, original: "/Volumes/MLX Node/MLX Node.app", readOnly: nil))
        // the nullfs fallback names the folder the app sits in
        XCTAssertTrue(UpdateKit.isOnDiskImage(path: t, original: "/Volumes/MLX Node", readOnly: nil))
        XCTAssertFalse(UpdateKit.isOnDiskImage(path: t, original: "/Users/a/Downloads/MLX Node.app", readOnly: nil))
        XCTAssertFalse(UpdateKit.isOnDiskImage(path: t, original: "/Volumes/Work/MLX Node.app", readOnly: false))
        // translocated but nobody can say from where: run as usual
        XCTAssertFalse(UpdateKit.isOnDiskImage(path: t, original: nil, readOnly: nil))
    }

    func testTranslocationIsSeenInThePath() {
        XCTAssertTrue(Translocation.isTranslocated("/private/var/folders/xy/abc/T/AppTranslocation/6B1F-22/d/MLX Node.app"))
        XCTAssertFalse(Translocation.isTranslocated("/Applications/MLX Node.app"))
        // not translocated: its own path, and no original to look up
        XCTAssertEqual(Translocation.realPath(of: URL(fileURLWithPath: "/Applications/MLX Node.app")), "/Applications/MLX Node.app")
        XCTAssertNil(Translocation.originalPath(of: URL(fileURLWithPath: "/Applications/MLX Node.app")))
    }

    func testOnlyADiskImageVolumeIsEjected() {
        XCTAssertTrue(UpdateKit.isEjectableVolume("/Volumes/MLX Node", readOnly: true))
        XCTAssertTrue(UpdateKit.isEjectableVolume("/Volumes/MLX Node 1/", readOnly: true))
        XCTAssertFalse(UpdateKit.isEjectableVolume("/Volumes/MLX Node", readOnly: false))
        XCTAssertFalse(UpdateKit.isEjectableVolume("/Volumes/MLX Node", readOnly: nil))
        XCTAssertFalse(UpdateKit.isEjectableVolume("/", readOnly: true))
        XCTAssertFalse(UpdateKit.isEjectableVolume("/Volumes", readOnly: true))
        XCTAssertFalse(UpdateKit.isEjectableVolume("/Volumes/", readOnly: true))
        XCTAssertFalse(UpdateKit.isEjectableVolume("/Volumes/MLX Node/inner", readOnly: true))
        XCTAssertFalse(UpdateKit.isEjectableVolume("/Volumes/..", readOnly: true))
        XCTAssertFalse(UpdateKit.isEjectableVolume("/System/Volumes/Data", readOnly: true))
    }

    // MARK: where it goes

    func testFolders() {
        XCTAssertEqual(UpdateKit.installFolders(home: home), ["/Applications", "/Users/a/Applications"])
    }

    func testFreshInstallGoesToApplications() {
        let p = UpdateKit.diskInstallPlan(version: "0.9.8", home: home, installed: { _ in nil }, writable: { _ in true })
        XCTAssertEqual(p, Plan(kind: .fresh, path: "/Applications/MLX Node.app", old: nil, previous: nil))
    }

    func testFreshInstallGoesToHomeApplicationsWhenApplicationsIsLocked() {
        let p = UpdateKit.diskInstallPlan(version: "0.9.8", home: home, installed: { _ in nil }, writable: { $0 != "/Applications" })
        XCTAssertEqual(p, Plan(kind: .fresh, path: "/Users/a/Applications/MLX Node.app", old: nil, previous: nil))
        // ~/Applications may not exist yet (so not writable): still the place, the installer makes it
        let q = UpdateKit.diskInstallPlan(version: "0.9.8", home: home, installed: { _ in nil }, writable: { _ in false })
        XCTAssertEqual(q.path, "/Users/a/Applications/MLX Node.app")
    }

    // MARK: never a downgrade

    func testSameVersionInstalledIsOpened() {
        let p = UpdateKit.diskInstallPlan(version: "0.9.8", home: home,
                                          installed: { $0 == "/Applications/MLX Node.app" ? "0.9.8" : nil }, writable: { _ in true })
        XCTAssertEqual(p, Plan(kind: .open, path: "/Applications/MLX Node.app", old: nil, previous: "0.9.8"))
    }

    func testNewerVersionInstalledIsOpenedEvenWhereItCantBeWritten() {
        let p = UpdateKit.diskInstallPlan(version: "0.9.8", home: home,
                                          installed: { $0 == "/Applications/MLX Node.app" ? "0.10.1" : nil }, writable: { _ in false })
        XCTAssertEqual(p, Plan(kind: .open, path: "/Applications/MLX Node.app", old: nil, previous: "0.10.1"))
        let q = UpdateKit.diskInstallPlan(version: "0.9.8", home: home,
                                          installed: { $0 == "/Users/a/Applications/MLX Node.app" ? "0.9.9" : nil }, writable: { _ in true })
        XCTAssertEqual(q, Plan(kind: .open, path: "/Users/a/Applications/MLX Node.app", old: nil, previous: "0.9.9"))
    }

    func testNewerLegacyCopyIsOpenedToo() {
        // never happens in practice (MLX.app is from before 0.9.0), but a newer one must never be replaced
        let p = UpdateKit.diskInstallPlan(version: "0.9.8", home: home,
                                          installed: { $0 == "/Applications/MLX.app" ? "1.0.0" : nil }, writable: { _ in true })
        XCTAssertEqual(p.kind, .open)
        XCTAssertEqual(p.path, "/Applications/MLX.app")
    }

    func testOlderVersionIsReplacedInPlace() {
        let p = UpdateKit.diskInstallPlan(version: "0.9.8", home: home,
                                          installed: { $0 == "/Applications/MLX Node.app" ? "0.9.6" : nil }, writable: { _ in true })
        XCTAssertEqual(p, Plan(kind: .replace, path: "/Applications/MLX Node.app", old: "/Applications/MLX Node.app", previous: "0.9.6"))
        // numbers, not text
        let q = UpdateKit.diskInstallPlan(version: "0.10.0", home: home,
                                          installed: { $0 == "/Applications/MLX Node.app" ? "0.9.10" : nil }, writable: { _ in true })
        XCTAssertEqual(q.kind, .replace)
    }

    func testOldMLXAppIsReplacedUnderTheNewName() {
        let p = UpdateKit.diskInstallPlan(version: "0.9.8", home: home,
                                          installed: { $0 == "/Applications/MLX.app" ? "0.8.4" : nil }, writable: { _ in true })
        XCTAssertEqual(p, Plan(kind: .replace, path: "/Applications/MLX Node.app", old: "/Applications/MLX.app", previous: "0.8.4"))
    }

    func testCurrentNameWinsOverLegacyInTheSameFolder() {
        let versions = ["/Applications/MLX Node.app": "0.9.2", "/Applications/MLX.app": "0.8.4"]
        let p = UpdateKit.diskInstallPlan(version: "0.9.8", home: home, installed: { versions[$0] }, writable: { _ in true })
        XCTAssertEqual(p, Plan(kind: .replace, path: "/Applications/MLX Node.app", old: "/Applications/MLX Node.app", previous: "0.9.2"))
    }

    func testOlderCopyInHomeApplicationsIsReplacedThere() {
        let p = UpdateKit.diskInstallPlan(version: "0.9.8", home: home,
                                          installed: { $0 == "/Users/a/Applications/MLX Node.app" ? "0.9.0" : nil }, writable: { _ in true })
        XCTAssertEqual(p, Plan(kind: .replace, path: "/Users/a/Applications/MLX Node.app", old: "/Users/a/Applications/MLX Node.app", previous: "0.9.0"))
    }

    func testOlderCopyWhereItCantBeWrittenGetsAFreshCopyBeside() {
        // an older MLX Node in a locked /Applications: a fresh copy in ~/Applications, the old one isn't touched
        let p = UpdateKit.diskInstallPlan(version: "0.9.8", home: home,
                                          installed: { $0 == "/Applications/MLX Node.app" ? "0.9.6" : nil }, writable: { $0 != "/Applications" })
        XCTAssertEqual(p, Plan(kind: .fresh, path: "/Users/a/Applications/MLX Node.app", old: nil, previous: nil))
    }

    func testNewerAnywhereWinsOverOlderElsewhere() {
        // older in /Applications, newer in ~/Applications: open the newer one, replace nothing
        let versions = ["/Applications/MLX Node.app": "0.9.6", "/Users/a/Applications/MLX Node.app": "0.9.9"]
        let p = UpdateKit.diskInstallPlan(version: "0.9.8", home: home, installed: { versions[$0] }, writable: { _ in true })
        XCTAssertEqual(p, Plan(kind: .open, path: "/Users/a/Applications/MLX Node.app", old: nil, previous: "0.9.9"))
    }
}
