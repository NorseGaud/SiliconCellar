import XCTest

@testable import SiliconCellarCore

final class EngineTests: XCTestCase {
    func testFindWinePrefersEnvOverride() {
        let files = MemoryFiles()
        let override = "/tmp/custom-wine"
        files.paths.insert(override)
        setenv("SILICONCELLAR_WINE", override, 1)
        defer { unsetenv("SILICONCELLAR_WINE") }
        let locator = EngineLocator(commands: ScriptedCommands(), files: files)
        XCTAssertEqual(locator.findWine()?.path, override)
    }

    func testFindWinePrefersBundledEngineOverApplicationSupport() {
        let files = MemoryFiles()
        let bundle = URL(fileURLWithPath: "/tmp/SiliconCellar.app")
        let bundled = AppPaths.bundledWineBinary(bundle: bundle)
        files.paths.insert(bundled.path)
        files.paths.insert(AppPaths.wineBinary().path)
        let locator = EngineLocator(
            commands: ScriptedCommands(),
            files: files,
            bundleURL: bundle
        )
        XCTAssertEqual(locator.findWine()?.path, bundled.path)
    }

    func testFindWineFallsBackToApplicationSupportStaging() {
        let files = MemoryFiles()
        files.paths.insert(AppPaths.wineBinary().path)
        let locator = EngineLocator(
            commands: ScriptedCommands(),
            files: files,
            bundleURL: URL(fileURLWithPath: "/tmp/missing.app")
        )
        XCTAssertEqual(locator.findWine()?.path, AppPaths.wineBinary().path)
    }

    func testFindWineIgnoresGPTKPaths() {
        let files = MemoryFiles()
        files.paths.insert("/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64")
        files.paths.insert("/opt/homebrew/opt/game-porting-toolkit/bin/wine64")
        files.paths.insert("/opt/homebrew/bin/brew")
        let locator = EngineLocator(commands: ScriptedCommands(), files: files)
        XCTAssertNil(locator.findWine())
    }
}
