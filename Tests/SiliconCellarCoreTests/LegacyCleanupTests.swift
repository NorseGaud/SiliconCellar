import XCTest

@testable import SiliconCellarCore

final class LegacyCleanupTests: XCTestCase {
    func testLegacyPathsDoNotIncludeRecipesOrWine() {
        let support = URL(fileURLWithPath: "/tmp/SiliconCellar")
        let paths = AppPaths.legacyPaths(supportRoot: support).map(\.lastPathComponent)
        XCTAssertTrue(paths.contains("Games"))
        XCTAssertTrue(paths.contains("SteamCMD"))
        XCTAssertTrue(paths.contains("steamcmd-logged-in"))
        XCTAssertTrue(paths.contains("steam-sign-in-confirmed"))
        XCTAssertFalse(paths.contains("Recipes"))
        XCTAssertFalse(paths.contains("Wine"))
        XCTAssertFalse(paths.contains("prefix"))
    }

    func testSetupDeletesSteamCMDAndPerGamePrefixes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cellar-clean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = AppPaths.supportRoot(home: home)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Games/mdk/prefix"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("SteamCMD"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("downloads"), withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: support.appendingPathComponent("downloads/steamcmd.zip"))
        try Data("login".utf8).write(to: support.appendingPathComponent("steamcmd-logged-in"))
        try Data("ok".utf8).write(to: support.appendingPathComponent("steam-sign-in-confirmed"))
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Recipes"), withIntermediateDirectories: true)
        try Data("r".utf8).write(to: support.appendingPathComponent("Recipes/keep.json"))
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Wine/Wine Staging.app"), withIntermediateDirectories: true)
        try Data("w".utf8).write(to: support.appendingPathComponent("Wine/Wine Staging.app/keep"))

        let wine = support.appendingPathComponent("wine-bin")
        let wineserver = support.appendingPathComponent("wineserver")
        try Data().write(to: wine)
        try Data().write(to: wineserver)
        let runtime = Runtime(
            recipe: Recipe(id: "spacewar", title: "Spacewar", steamID: "480", installFolder: "Spacewar", executable: "Spacewar.exe"),
            root: support,
            wine: wine,
            wineserver: wineserver
        )
        runtime.removeLegacyData()

        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Games").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("SteamCMD").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("downloads/steamcmd.zip").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("steamcmd-logged-in").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("steam-sign-in-confirmed").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("Recipes/keep.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("Wine/Wine Staging.app/keep").path))
    }

    func testLibraryRemoveLegacyDataUsesSupportRoot() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cellar-lib-clean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = AppPaths.supportRoot(home: home)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Games/mdk"), withIntermediateDirectories: true)
        let wine = home.appendingPathComponent("wine")
        let wineserver = home.appendingPathComponent("wineserver")
        try Data().write(to: wine)
        try Data().write(to: wineserver)
        let library = Library(
            recipes: [Recipe.onboarding],
            wine: wine,
            wineserver: wineserver,
            home: home
        )
        library.removeLegacyData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Games").path))
    }
}
