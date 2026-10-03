import XCTest

@testable import SiliconCellarCore

extension RuntimeTests {
    static let rsiRecipe: Recipe = {
        var recipe = Recipe(
            id: "star-citizen",
            title: "Star Citizen",
            steamID: nil,
            installFolder: "StarCitizen",
            executable: "StarCitizen.exe",
            executableRelativePath: "LIVE/Bin64/StarCitizen.exe"
        )
        recipe.launcher = .rsi
        recipe.rsiChannel = "LIVE"
        return recipe
    }()

    func makeRSIEnvironment() throws -> Environment {
        let env = try makeEnvironment(recipe: Self.rsiRecipe)
        env.runtime.wineServerDirectory = env.root.appendingPathComponent("wine-server")
        env.runtime.expectedRSISetupSHA256 = SteamInstaller.digest(of: env.commands.installerBytes)
        env.runtime.installPollInterval = 0
        return env
    }

    func writeRSICookies(_ env: Environment) throws {
        let cookies = env.runtime.rsiProfile.appendingPathComponent("Network/Cookies")
        try FileManager.default.createDirectory(at: cookies.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("session".utf8).write(to: cookies)
    }

    func testRSISetupInstallsThePinnedClient() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        XCTAssertTrue(env.commands.ran.contains { $0.name == "curl" && $0.arguments.contains(RSIInstaller.downloadURL) })
        let installerStart = try XCTUnwrap(env.commands.started.first { $0.1.first?.hasSuffix(RSIInstaller.launchFileName) == true })
        XCTAssertEqual(Array(installerStart.1.dropFirst()), ["/D=\(RSIInstaller.windowsInstallPath)"])
        XCTAssertEqual(
            env.commands.started.last?.1,
            [try XCTUnwrap(env.runtime.rsiClient).path, "--in-process-gpu"]
        )
        XCTAssertEqual(env.frontmost.namedWindows.first?.1, RSIInstaller.windowTitle)
        XCTAssertEqual(env.runtime.fileSnapshot().stage, .signIn)
        XCTAssertEqual(env.runtime.prefix.lastPathComponent, "prefix-rsi")
    }

    func testRSIProcessesSimulateWriteCopy() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        XCTAssertEqual(env.runtime.wineEnvironment()["WINE_SIMULATE_WRITECOPY"], "1")
    }

    func testRSISetupStopsWhenTheInstallerClosesEarly() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.commands.leaveRSIInstallerUnfinished = true
        XCTAssertThrowsError(try env.runtime.setup()) { error in
            XCTAssertEqual(
                (error as? PortError)?.message,
                "The RSI Launcher installer closed before it finished. Choose Install RSI Launcher again."
            )
        }
    }

    func testRSISetupStopsWhenTheInstallerDoesNotMatchThePin() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.runtime.expectedRSISetupSHA256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try env.runtime.setup())
        XCTAssertFalse(env.commands.started.contains { $0.1.first?.hasSuffix(RSIInstaller.fileName) == true })
    }

    func testRSIStagesFollowSignInAndInstallFiles() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        XCTAssertEqual(env.runtime.fileSnapshot().stage, .setup)
        try env.runtime.setup()
        try writeRSICookies(env)
        XCTAssertTrue(env.runtime.isSignedIn)
        XCTAssertEqual(env.runtime.fileSnapshot().stage, .install)

        let game = try XCTUnwrap(env.runtime.game)
        XCTAssertEqual(
            game.path,
            env.runtime.prefix.path + "/drive_c/Program Files/Roberts Space Industries/StarCitizen/LIVE/Bin64/StarCitizen.exe"
        )
        XCTAssertFalse(env.runtime.isGameInstalled)
        try FileManager.default.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("game".utf8).write(to: game)
        XCTAssertTrue(env.runtime.isGameInstalled)
        XCTAssertEqual(env.runtime.fileSnapshot().stage, .ready)
    }

    func testRSIInstallOpensTheLauncherAndWaits() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.commands.finishRSIInstallOnStart = true
        try env.runtime.installGame()
        XCTAssertTrue(env.runtime.isGameInstalled)
        XCTAssertEqual(env.commands.started.last?.1.last, "--in-process-gpu")
        XCTAssertTrue(env.sink.messages.contains {
            $0.contains("C:\\Program Files\\Roberts Space Industries\\StarCitizen")
        })

        env.commands.finishRSIInstallOnStart = false
        env.commands.finishRSIUninstallOnStart = true
        try env.runtime.uninstallGame()
        XCTAssertFalse(env.runtime.isGameInstalled)
    }

    func testRSIPlayAppliesTheRendererThenOpensTheLauncher() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        XCTAssertThrowsError(try env.runtime.playGame())
        env.commands.finishRSIInstallOnStart = true
        try env.runtime.installGame()
        env.commands.ran.removeAll()
        try env.runtime.playGame()
        XCTAssertTrue(env.commands.ran.contains {
            $0.arguments.first == "reg" && $0.arguments.contains { $0.contains("AppDefaults\\StarCitizen.exe\\SiliconCellar") }
        })
        XCTAssertEqual(
            env.commands.started.last?.1,
            [try XCTUnwrap(env.runtime.rsiClient).path, "--in-process-gpu"]
        )
        XCTAssertEqual(env.commands.lastStartEnvironment["WINEPREFIX"], env.runtime.prefix.path)
    }

    func testRSILogoutWithoutSessionRemovesTheCookies() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try writeRSICookies(env)
        try env.runtime.logout()
        XCTAssertFalse(env.runtime.isSignedIn)
    }

    func testRSIProcessDetection() {
        XCTAssertTrue(RSIProcess.isClientRunning(in: "C:\\Program Files\\Roberts Space Industries\\RSI Launcher\\RSI Launcher.exe\n"))
        XCTAssertFalse(RSIProcess.isClientRunning(in: "/bin/zsh -c open RSI Launcher.exe\n"))
        XCTAssertFalse(RSIProcess.isClientRunning(in: "/tmp/downloads/rsi-setup-2.17.0.exe\n"))
        XCTAssertTrue(RSIProcess.isInstallerRunning(in: "/tmp/downloads/rsi-setup-2.17.0.exe\n"))
        XCTAssertTrue(RSIProcess.isInstallerRunning(in: "/tmp/downloads/RSI Launcher-Setup-2.17.0.exe\n"))
    }
}
