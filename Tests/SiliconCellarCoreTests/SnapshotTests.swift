import XCTest

@testable import SiliconCellarCore

final class SteamManifestTests: XCTestCase {
    let sample = """
        "AppState"
        {
        \t"appid"\t\t"480"
        \t"installdir"\t\t"Spacewar"
        \t"StateFlags"\t\t"4"
        \t"BytesDownloaded"\t\t"100"
        \t"BytesToDownload"\t\t"200"
        }
        """

    func testReadsValues() {
        XCTAssertEqual(SteamManifest.value("appid", in: sample), "480")
        XCTAssertEqual(SteamManifest.value("installdir", in: sample), "Spacewar")
        XCTAssertTrue(SteamManifest.isCompleteInstall(text: sample, steamID: "480", installFolder: "Spacewar"))
        XCTAssertFalse(SteamManifest.isCompleteInstall(text: sample, steamID: "480", installFolder: "Other"))
    }
}

final class SnapshotTests: XCTestCase {
    func testSetupWhenRuntimeMissing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = LibrarySnapshot.inspect(
            root: root,
            runtimeReady: false,
            signedIn: false,
            gameExecutable: nil,
            manifest: nil,
            steamID: "480",
            installFolder: "Spacewar",
            wineSessionLive: false
        )
        XCTAssertEqual(snapshot.stage, .setup)
    }

    func testSignInWhenRuntimeReady() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = LibrarySnapshot.inspect(
            root: root,
            runtimeReady: true,
            signedIn: false,
            gameExecutable: nil,
            manifest: nil,
            steamID: "480",
            installFolder: "Spacewar",
            wineSessionLive: false
        )
        XCTAssertEqual(snapshot.stage, .signIn)
        XCTAssertFalse(snapshot.wineSessionLive)
    }

    func testSignedInWithoutPrefixIsInstall() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = LibrarySnapshot.inspect(
            root: root,
            runtimeReady: false,
            signedIn: true,
            gameExecutable: nil,
            manifest: nil,
            steamID: "480",
            installFolder: "Spacewar",
            wineSessionLive: false
        )
        XCTAssertEqual(snapshot.stage, .install)
    }

    func testSignInReportsLiveSession() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = LibrarySnapshot.inspect(
            root: root,
            runtimeReady: true,
            signedIn: false,
            gameExecutable: nil,
            manifest: nil,
            steamID: "480",
            installFolder: "Spacewar",
            wineSessionLive: true
        )
        XCTAssertEqual(snapshot.stage, .signIn)
        XCTAssertTrue(snapshot.wineSessionLive)
    }

    func testReadyAndRunning() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("Spacewar.exe")
        try Data().write(to: game)
        let manifest = root.appendingPathComponent("steamapps/appmanifest_480.acf")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        "AppState" { "appid" "480" "installdir" "Spacewar" "StateFlags" "4" }
        """.write(to: manifest, atomically: true, encoding: .utf8)

        let ready = LibrarySnapshot.inspect(
            root: root,
            runtimeReady: true,
            signedIn: true,
            gameExecutable: game,
            manifest: manifest,
            steamID: "480",
            installFolder: "Spacewar",
            wineSessionLive: false
        )
        XCTAssertEqual(ready.stage, .ready)

        let steamOpenOnly = LibrarySnapshot.inspect(
            root: root,
            runtimeReady: true,
            signedIn: true,
            gameExecutable: game,
            manifest: manifest,
            steamID: "480",
            installFolder: "Spacewar",
            wineSessionLive: true,
            gameRunning: false
        )
        XCTAssertEqual(steamOpenOnly.stage, .ready)
        XCTAssertTrue(steamOpenOnly.wineSessionLive)
        XCTAssertFalse(steamOpenOnly.isRunning)

        let running = LibrarySnapshot.inspect(
            root: root,
            runtimeReady: true,
            signedIn: true,
            gameExecutable: game,
            manifest: manifest,
            steamID: "480",
            installFolder: "Spacewar",
            wineSessionLive: true,
            gameRunning: true
        )
        XCTAssertEqual(running.stage, .running)
        XCTAssertTrue(running.isRunning)
    }

    func testDisplayKeepsInstallPendingWhenWineIsLive() {
        let snapshot = LibrarySnapshot(stage: .install, downloadFraction: 0.2, wineSessionLive: true)
        let display = LibrarySnapshot.display(snapshot, activity: "install", busy: true)
        XCTAssertEqual(display.stage, .downloading)
        XCTAssertEqual(display.downloadFraction, 0.2)
        XCTAssertFalse(display.isInstalled)
        XCTAssertFalse(display.isRunning)
        XCTAssertTrue(display.wineSessionLive)
    }

    func testDisplayKeepsInstalledWhenInstallFinishesWhileBusy() {
        let snapshot = LibrarySnapshot(stage: .running, wineSessionLive: true)
        let display = LibrarySnapshot.display(snapshot, activity: "install", busy: true)
        XCTAssertEqual(display.stage, .running)
        XCTAssertTrue(display.isInstalled)
        XCTAssertTrue(display.wineSessionLive)
    }

    func testDisplayKeepsUninstallFromLookingLikePlay() {
        let snapshot = LibrarySnapshot(stage: .running, wineSessionLive: true)
        let display = LibrarySnapshot.display(snapshot, activity: "uninstall", busy: true)
        XCTAssertEqual(display.stage, .ready)
        XCTAssertTrue(display.isInstalled)
        XCTAssertFalse(display.isRunning)
        XCTAssertTrue(display.wineSessionLive)
    }

    func testWineDuringInstallDoesNotCountAsRunning() {
        let snapshot = LibrarySnapshot(stage: .install, wineSessionLive: true)
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertFalse(snapshot.isInstalled)
    }

    func testDownloadProgressFollowsTheFolderSteamFills() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("steamapps/appmanifest_480.acf")
        let download = root.appendingPathComponent("steamapps/downloading/480")
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 25).write(to: download.appendingPathComponent("part.bin"))
        try """
        "AppState" { "appid" "480" "installdir" "Spacewar" "StateFlags" "1026" "BytesDownloaded" "0" "BytesToDownload" "100" }
        """.write(to: manifest, atomically: true, encoding: .utf8)

        let snapshot = LibrarySnapshot.inspect(
            root: root,
            runtimeReady: true,
            signedIn: true,
            gameExecutable: root.appendingPathComponent("missing.exe"),
            manifest: manifest,
            steamID: "480",
            installFolder: "Spacewar",
            wineSessionLive: true
        )
        XCTAssertEqual(snapshot.stage, .downloading)
        XCTAssertEqual(snapshot.downloadFraction, 0.25)
    }

    func testDownloadingIsNotInstalledOrRunning() {
        let snapshot = LibrarySnapshot(stage: .downloading, downloadFraction: 0.4, wineSessionLive: true)
        XCTAssertFalse(snapshot.isInstalled)
        XCTAssertFalse(snapshot.isRunning)
    }

    func testSnapshotFlagsFollowStage() {
        let setup = LibrarySnapshot(stage: .setup)
        XCTAssertTrue(setup.needsSetup)
        XCTAssertFalse(setup.isSignedIn)
        XCTAssertFalse(setup.isInstalled)
        XCTAssertFalse(setup.isRunning)

        let ready = LibrarySnapshot(stage: .ready)
        XCTAssertTrue(ready.isSignedIn)
        XCTAssertTrue(ready.isInstalled)
        XCTAssertFalse(ready.isRunning)

        let running = LibrarySnapshot(stage: .running, wineSessionLive: true)
        XCTAssertTrue(running.isInstalled)
        XCTAssertTrue(running.isRunning)
    }

    func testConfirmedFileDoesNotCountAsSignedIn() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ok".utf8).write(to: root.appendingPathComponent("steam-sign-in-confirmed"))
        let snapshot = LibrarySnapshot.inspect(
            root: root,
            runtimeReady: true,
            signedIn: false,
            gameExecutable: nil,
            manifest: nil,
            steamID: "480",
            installFolder: "Spacewar",
            wineSessionLive: false
        )
        XCTAssertEqual(snapshot.stage, .signIn)
    }

    func testOnboardingUntilSignInIsConfirmed() {
        XCTAssertTrue(GameStage.setup.isOnboarding)
        XCTAssertTrue(GameStage.signIn.isOnboarding)
        XCTAssertFalse(GameStage.install.isOnboarding)
        XCTAssertFalse(GameStage.ready.isOnboarding)
        XCTAssertFalse(GameStage.running.isOnboarding)
        XCTAssertFalse(GameStage.downloading.isOnboarding)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mgp-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

final class HostCheckTests: XCTestCase {
    func testRejectsIntel() {
        XCTAssertThrowsError(
            try HostCheck.require(
                HostStatus(
                    architecture: "x86_64", hasRosetta: true, wine: URL(fileURLWithPath: "/tmp/wine"), wineserver: URL(fileURLWithPath: "/tmp/wineserver"))))
    }

    func testRejectsMissingRosetta() {
        XCTAssertThrowsError(
            try HostCheck.require(
                HostStatus(
                    architecture: "arm64", hasRosetta: false, wine: URL(fileURLWithPath: "/tmp/wine"), wineserver: URL(fileURLWithPath: "/tmp/wineserver"))))
    }

    func testRejectsMissingWine() {
        XCTAssertThrowsError(try HostCheck.require(HostStatus(architecture: "arm64", hasRosetta: true, wine: nil, wineserver: nil)))
    }

    func testAcceptsAppleSiliconWithWine() throws {
        let pair = try HostCheck.require(
            HostStatus(
                architecture: "arm64",
                hasRosetta: true,
                wine: URL(fileURLWithPath: "/tmp/wine"),
                wineserver: URL(fileURLWithPath: "/tmp/wineserver")
            ))
        XCTAssertEqual(pair.wine.lastPathComponent, "wine")
    }
}

final class SteamInstallerTests: XCTestCase {
    func testDigestIsStable() {
        XCTAssertEqual(SteamInstaller.digest(of: Data("abc".utf8)), SteamInstaller.digest(of: Data("abc".utf8)))
        XCTAssertNotEqual(SteamInstaller.digest(of: Data("abc".utf8)), SteamInstaller.digest(of: Data("abd".utf8)))
    }
}
