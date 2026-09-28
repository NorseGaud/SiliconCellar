import XCTest

@testable import SiliconCellarCore

final class GPTKCleanupTests: XCTestCase {
    func testRemovesGPTKAppWhenPresent() throws {
        let files = MemoryFiles()
        let app = URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app")
        files.paths.insert(app.path)
        let commands = ScriptedCommands()
        let cleanup = GPTKCleanup(commands: commands, files: files)
        var lines: [String] = []
        try cleanup.removeLeftovers { lines.append($0) }
        XCTAssertFalse(files.fileExists(app))
        XCTAssertTrue(lines.contains(where: { $0.localizedCaseInsensitiveContains("game porting") }))
    }

    func testUninstallsCaskWhenBrewPresent() throws {
        let files = MemoryFiles()
        files.paths.insert("/opt/homebrew/bin/brew")
        let commands = ScriptedCommands()
        commands.outcomes = [
            .success("Uninstalling Cask game-porting-toolkit"),
            .success("Uninstalling Cask game-porting-toolkit"),
        ]
        let cleanup = GPTKCleanup(commands: commands, files: files)
        try cleanup.removeLeftovers { _ in }
        XCTAssertTrue(
            commands.calls.contains(where: {
                $0.contains("uninstall") && $0.contains("--cask") && $0.contains("game-porting-toolkit")
            })
        )
    }

    func testSucceedsWhenNothingToRemove() throws {
        let cleanup = GPTKCleanup(commands: ScriptedCommands(), files: MemoryFiles())
        try cleanup.removeLeftovers { _ in }
    }
}
