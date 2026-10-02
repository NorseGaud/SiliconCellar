import XCTest

@testable import SiliconCellarCore

final class GameFixesTests: XCTestCase {
    func testCabinetsReadsEmbeddedMicrosoftCabinet() {
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes.replaceSubrange(0..<8, with: [77, 83, 67, 70, 0, 0, 0, 0])
        bytes[8] = 40
        let found = GameFixes.cabinets(in: Data(bytes))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].count, 40)
    }

    func testHeroesAudioPatchRejectsUnknownFile() {
        XCTAssertEqual(GameFixes.heroesAudioCode.count, 56)
        XCTAssertThrowsError(try GameFixes.patchedHeroesAudio(Data(repeating: 1, count: 64)))
    }

    func testBundledFixHashes() throws {
        let root = try GameFixes.fixesRoot()
        let heroes = try Data(contentsOf: root.appendingPathComponent("Heroes3/xdd.dll"))
        XCTAssertEqual(SteamInstaller.digest(of: heroes), GameFixes.heroesRendererSHA)
        let proxy = try Data(contentsOf: root.appendingPathComponent("Witcher3/amd_fidelityfx_loader_dx12.dll"))
        XCTAssertEqual(SteamInstaller.digest(of: proxy), GameFixes.witcherProxySHA)
    }

    func testEldenTemplateUsesDisplaySize() throws {
        let template = try Data(contentsOf: try GameFixes.fixesRoot().appendingPathComponent("EldenRing/graphics-default.xml"))
        let data = try GameFixes.eldenGraphics(template: template, width: 1920, height: 1080)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xFE])
        let text = try XCTUnwrap(String(data: data, encoding: .utf16LittleEndian))
        XCTAssertTrue(text.contains("<Resolution-FullScreenWidth>1920</Resolution-FullScreenWidth>"))
        XCTAssertTrue(text.contains("<Resolution-FullScreenHeight>1080</Resolution-FullScreenHeight>"))
        XCTAssertTrue(text.contains("<ScreenMode>BORDERLESS</ScreenMode>"))
        XCTAssertFalse(text.contains("DISPLAY_"))
    }

    func testRedAlertInstallsDrawFiles() throws {
        let runtime = try makeRuntime(id: "red-alert2", folder: "Command & Conquer Red Alert II", executable: "Ra2.exe")
        try runtime.applyGameFixes()
        let dll = try Data(contentsOf: runtime.gameFolder.appendingPathComponent("ddraw.dll"))
        let bundled = try Data(contentsOf: try GameFixes.fixesRoot().appendingPathComponent("RedAlert2/ddraw.dll"))
        XCTAssertEqual(dll, bundled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.gameFolder.appendingPathComponent("ddraw.ini").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtime.gameFolder.appendingPathComponent("Shaders/interpolation/catmull-rom-bilinear.glsl").path
            )
        )
    }

    func testWitcherLeavesUnknownLoader() throws {
        let runtime = try makeRuntime(id: "witcher3", folder: "The Witcher 3", executable: "witcher3.exe")
        let loader = runtime.gameFolder.appendingPathComponent("amd_fidelityfx_loader_dx12.dll")
        try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("not-the-tested-loader".utf8)
        try original.write(to: loader)
        try runtime.applyGameFixes()
        XCTAssertEqual(try Data(contentsOf: loader), original)
        let backup = loader.deletingLastPathComponent().appendingPathComponent("amd_fidelityfx_loader_dx12_orig.dll")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testRedDeadSettingsUseTheDisplay() throws {
        let template = try Data(contentsOf: try GameFixes.fixesRoot().appendingPathComponent("RedDead/system-default.xml"))
        let data = try GameFixes.redDeadSettings(template: template, width: 1920, height: 1080)
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let width = try document.nodes(forXPath: "/rage__fwuiSystemSettingsCollection/video/screenWidth").first as? XMLElement
        XCTAssertEqual(width?.attribute(forName: "value")?.stringValue, "1920")
        let windowed = try document.nodes(forXPath: "/rage__fwuiSystemSettingsCollection/video/windowed").first as? XMLElement
        XCTAssertEqual(windowed?.attribute(forName: "value")?.stringValue, "0")
        let api = try document.nodes(forXPath: "/rage__fwuiSystemSettingsCollection/advancedGraphics/API").first as? XMLElement
        XCTAssertEqual(api?.stringValue, "kSettingAPI_DX12")
    }

    func testRedDeadKeepsInstalledRockstarLauncher() throws {
        let commands = ScriptedCommands()
        let runtime = try makeRuntime(id: "rdr2", folder: "Red Dead Redemption 2", executable: "RDR2.exe", commands: commands)
        let gameFolder = runtime.gameFolder
        try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        try Data().write(to: gameFolder.appendingPathComponent("PlayRDR2.exe"))
        let launcher = runtime.prefix.appendingPathComponent("drive_c/Program Files/Rockstar Games/Launcher")
        try FileManager.default.createDirectory(at: launcher, withIntermediateDirectories: true)
        try Data().write(to: launcher.appendingPathComponent("Launcher.exe"))
        try Data().write(to: launcher.appendingPathComponent("LauncherPatcher.exe"))
        try runtime.applyGameFixes()
        XCTAssertTrue(commands.calls.isEmpty)
        let settings = runtime.prefix.appendingPathComponent(
            "drive_c/users/crossover/Documents/Rockstar Games/Red Dead Redemption 2/Settings/system.xml"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path))
    }

    func testAoe3SkipsUntestedExecutable() throws {
        let commands = ScriptedCommands()
        let runtime = try makeRuntime(id: "aoe3", folder: "AoE3DE", executable: "AoE3DE_s.exe", commands: commands)
        let exe = try XCTUnwrap(runtime.game)
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("different-build".utf8).write(to: exe)
        try runtime.applyGameFixes()
        XCTAssertTrue(commands.calls.isEmpty)
        let graphics = runtime.prefix.appendingPathComponent(
            "drive_c/users/crossover/Games/Age of Empires 3 DE/Common/GraphicalProfile.xml"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: graphics.path))
    }

    private func makeRuntime(
        id: String,
        folder: String,
        executable: String,
        commands: CommandRunning = ProcessCommandRunner()
    ) throws -> Runtime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("siliconcellar-fixes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recipe = Recipe(id: id, title: id, steamID: "1", installFolder: folder, executable: executable)
        return Runtime(
            recipe: recipe,
            root: root,
            wine: URL(fileURLWithPath: "/usr/bin/true"),
            wineserver: URL(fileURLWithPath: "/usr/bin/true"),
            commands: commands
        )
    }
}
