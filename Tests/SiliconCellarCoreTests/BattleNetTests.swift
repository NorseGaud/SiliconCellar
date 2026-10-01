import XCTest

@testable import SiliconCellarCore

extension RuntimeTests {
    static let battleNetRecipe: Recipe = {
        var recipe = Recipe(
            id: "d2r",
            title: "Diablo II: Resurrected",
            steamID: nil,
            installFolder: "Diablo II Resurrected",
            executable: "D2R.exe"
        )
        recipe.launcher = .battleNet
        recipe.battleNetProductCode = "OSI"
        return recipe
    }()

    func makeBattleNetEnvironment() throws -> Environment {
        let env = try makeEnvironment(recipe: Self.battleNetRecipe)
        env.runtime.wineServerDirectory = env.root.appendingPathComponent("wine-server")
        env.runtime.expectedBattleNetSetupSHA256 = SteamInstaller.digest(of: env.commands.installerBytes)
        env.runtime.installPollInterval = 0
        return env
    }

    func writeBattleNetConfig(_ env: Environment, _ json: String) throws {
        let config = env.runtime.battleNetConfig
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: config)
    }

    func battleNetClientSetting(_ env: Environment, _ key: String) throws -> String? {
        let data = try Data(contentsOf: env.runtime.battleNetConfig)
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (config["Client"] as? [String: Any])?[key] as? String
    }

    func testBattleNetSetupInstallsThePinnedClient() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        XCTAssertTrue(env.commands.ran.contains { $0.name == "curl" && $0.arguments.contains(BattleNetInstaller.downloadURL) })
        let installerStart = try XCTUnwrap(env.commands.started.first { $0.1.first?.hasSuffix("Battle.net-Setup.exe") == true })
        XCTAssertEqual(Array(installerStart.1.dropFirst()), ["--lang=enUS", "--installpath=C:\\Program Files (x86)\\Battle.net"])
        XCTAssertEqual(env.commands.started.last?.1, [try XCTUnwrap(env.runtime.battleNetClient).path, "--in-process-gpu"])
        XCTAssertEqual(try battleNetClientSetting(env, "HardwareAcceleration"), "false")
        XCTAssertEqual(env.runtime.fileSnapshot().stage, .signIn)
    }

    func testOnlyBattleNetProcessesSimulateWriteCopy() throws {
        let battleNetEnv = try makeBattleNetEnvironment()
        let steamEnv = try makeEnvironment()
        defer {
            try? FileManager.default.removeItem(at: battleNetEnv.root)
            try? FileManager.default.removeItem(at: steamEnv.root)
        }
        XCTAssertEqual(battleNetEnv.runtime.wineEnvironment()["WINE_SIMULATE_WRITECOPY"], "1")
        XCTAssertNil(steamEnv.runtime.wineEnvironment()["WINE_SIMULATE_WRITECOPY"])
    }

    func testBattleNetSetupStopsWhenTheInstallerDoesNotMatchThePin() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.runtime.expectedBattleNetSetupSHA256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try env.runtime.setup())
        XCTAssertFalse(env.commands.started.contains { $0.1.first?.hasSuffix("Battle.net-Setup.exe") == true })
    }

    func testBattleNetConfigMergeKeepsOtherSettings() throws {
        let original = #"{"Client":{"SavedAccountNames":"player@example.com","HardwareAcceleration":"true"},"Games":{"osi":{"Resumable":"true"}}}"#
        let merged = try BattleNetConfig.disablingHardwareAcceleration(Data(original.utf8))
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let client = try XCTUnwrap(config["Client"] as? [String: Any])
        XCTAssertEqual(client["HardwareAcceleration"] as? String, "false")
        XCTAssertEqual(client["SavedAccountNames"] as? String, "player@example.com")
        XCTAssertEqual((config["Games"] as? [String: Any])?["osi"] as? [String: String], ["Resumable": "true"])
        XCTAssertTrue(BattleNetConfig.isSignedIn(merged))

        let cleared = try BattleNetConfig.removingSavedAccountNames(merged)
        XCTAssertFalse(BattleNetConfig.isSignedIn(cleared))
        XCTAssertTrue(BattleNetConfig.isSignedIn(try BattleNetConfig.disablingHardwareAcceleration(merged)))
        XCTAssertFalse(BattleNetConfig.isSignedIn(try BattleNetConfig.disablingHardwareAcceleration(nil)))
    }

    func testBattleNetStagesFollowSignInAndInstallFiles() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        XCTAssertEqual(env.runtime.fileSnapshot().stage, .setup)
        try env.runtime.setup()
        try writeBattleNetConfig(env, #"{"Client":{"SavedAccountNames":"player@example.com"}}"#)
        XCTAssertTrue(env.runtime.isSignedIn)
        XCTAssertEqual(env.runtime.fileSnapshot().stage, .install)

        let game = try XCTUnwrap(env.runtime.game)
        XCTAssertEqual(game.path, env.runtime.prefix.path + "/drive_c/Program Files (x86)/Diablo II Resurrected/D2R.exe")
        try FileManager.default.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: game)
        XCTAssertFalse(env.runtime.isGameInstalled)
        try Data().write(to: game.deletingLastPathComponent().appendingPathComponent(".build.info"))
        XCTAssertTrue(env.runtime.isGameInstalled)
        XCTAssertEqual(env.runtime.fileSnapshot().stage, .ready)
    }

    func testBattleNetInstallOpensTheGamePageAndWaits() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.commands.finishBattleNetInstallOnStart = true
        try env.runtime.installGame()
        XCTAssertTrue(env.runtime.isGameInstalled)
        XCTAssertEqual(env.commands.started.last?.1.last, "--exec=launch OSI")

        env.commands.finishBattleNetInstallOnStart = false
        env.commands.finishBattleNetUninstallOnStart = true
        try env.runtime.uninstallGame()
        XCTAssertFalse(env.runtime.isGameInstalled)
    }

    func testBattleNetPlayAppliesTheRendererThenLaunchesThroughBattleNet() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        XCTAssertThrowsError(try env.runtime.playGame())
        env.commands.finishBattleNetInstallOnStart = true
        try env.runtime.installGame()
        env.commands.ran.removeAll()
        try env.runtime.playGame()
        XCTAssertTrue(env.commands.ran.contains { $0.arguments.first == "reg" && $0.arguments.contains { $0.contains("AppDefaults\\D2R.exe\\SiliconCellar") } })
        XCTAssertEqual(
            env.commands.started.last?.1,
            [try XCTUnwrap(env.runtime.battleNetClient).path, "--in-process-gpu", "--exec=launch OSI"]
        )
        XCTAssertEqual(env.commands.lastStartEnvironment["WINEPREFIX"], env.runtime.prefix.path)
    }

    func testBattleNetLogoutWithoutSessionForgetsTheAccount() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try writeBattleNetConfig(env, #"{"Client":{"SavedAccountNames":"player@example.com","HardwareAcceleration":"false"}}"#)
        try env.runtime.logout()
        XCTAssertFalse(env.runtime.isSignedIn)
        XCTAssertEqual(try battleNetClientSetting(env, "HardwareAcceleration"), "false")
    }

    func testBattleNetProcessDetection() {
        XCTAssertTrue(BattleNetProcess.isClientRunning(in: "C:\\Program Files (x86)\\Battle.net\\Battle.net.exe --from-launcher\n"))
        XCTAssertFalse(BattleNetProcess.isClientRunning(in: "/bin/zsh -c open Battle.net.exe\n"))
        XCTAssertFalse(BattleNetProcess.isClientRunning(in: "/tmp/downloads/Battle.net-Setup.exe --lang=enUS\n"))
        XCTAssertTrue(BattleNetProcess.isInstallerRunning(in: "/tmp/downloads/Battle.net-Setup.exe --lang=enUS\n"))
    }

    /// A runtime for another recipe that shares the root, the Engine and the fake commands of `env`.
    func makeSiblingRuntime(_ env: Environment, recipe: Recipe) -> Runtime {
        let sibling = Runtime(
            recipe: recipe,
            root: env.root,
            wine: env.runtime.wine,
            wineserver: env.runtime.wineserver,
            commands: env.commands,
            sink: env.sink
        )
        sibling.wineServerDirectory = env.runtime.wineServerDirectory
        return sibling
    }

    func startFakeWineServer(_ env: Environment, prefix: URL) throws {
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let socket = try XCTUnwrap(WineServerSocket.url(prefix: prefix, in: env.runtime.wineServerDirectory))
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: socket)
        env.commands.live = true
    }

    func testEachLauncherHasItsOwnPrefixAndReadyMarker() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let steamRuntime = makeSiblingRuntime(env, recipe: Recipe.onboarding)
        XCTAssertEqual(steamRuntime.prefix.lastPathComponent, "prefix")
        XCTAssertEqual(steamRuntime.readyMarker.lastPathComponent, "runtime-ready")
        XCTAssertEqual(env.runtime.prefix.lastPathComponent, "prefix-battlenet")
        XCTAssertEqual(env.runtime.readyMarker.lastPathComponent, "runtime-ready-battlenet")
        XCTAssertEqual(env.runtime.wineEnvironment()["WINEPREFIX"], env.runtime.prefix.path)
    }

    func testWineServerSocketFollowsPrefixDeviceAndInode() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try FileManager.default.createDirectory(at: env.runtime.prefix, withIntermediateDirectories: true)
        var status = stat()
        XCTAssertEqual(stat(env.runtime.prefix.path, &status), 0)
        let socket = try XCTUnwrap(WineServerSocket.url(prefix: env.runtime.prefix, in: URL(fileURLWithPath: "/tmp/.wine-501")))
        XCTAssertEqual(
            socket.path,
            "/tmp/.wine-501/server-\(String(UInt64(status.st_dev), radix: 16))-\(String(UInt64(status.st_ino), radix: 16))/socket"
        )
        XCTAssertNil(WineServerSocket.url(prefix: env.root.appendingPathComponent("missing"), in: env.runtime.wineServerDirectory))
    }

    func testSessionIsLiveOnlyForTheLauncherThatRuns() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let steamRuntime = makeSiblingRuntime(env, recipe: Recipe.onboarding)
        try startFakeWineServer(env, prefix: steamRuntime.prefix)
        XCTAssertTrue(steamRuntime.isSessionLive)
        XCTAssertFalse(env.runtime.isSessionLive)
    }

    func testSteamAndBattleNetCanRunAtTheSameTime() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let steamRuntime = makeSiblingRuntime(env, recipe: Recipe.onboarding)
        try startFakeWineServer(env, prefix: steamRuntime.prefix)
        try startFakeWineServer(env, prefix: env.runtime.prefix)
        XCTAssertTrue(steamRuntime.isSessionLive)
        XCTAssertTrue(env.runtime.isSessionLive)
    }

    func testEachLauncherHasItsOwnOperationLock() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let steamLock = try SessionLock(root: env.root, launcher: .steam)
        XCTAssertThrowsError(try SessionLock(root: env.root, launcher: .steam))
        XCTAssertNoThrow(try SessionLock(root: env.root, launcher: .battleNet))
        withExtendedLifetime(steamLock) {}
    }

    func testStopSessionStopsOnlyTheLauncherOfThatGame() throws {
        let env = try makeBattleNetEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let library = Library(
            recipes: [Recipe.onboarding, Self.battleNetRecipe],
            wine: env.runtime.wine,
            wineserver: env.runtime.wineserver,
            dataRootOverride: env.root,
            commands: env.commands,
            sink: env.sink
        )
        for recipe in library.recipes {
            try FileManager.default.createDirectory(at: library.runtime(for: recipe).prefix, withIntermediateDirectories: true)
        }
        try library.stopSession(gameID: Self.battleNetRecipe.id)
        let kills = env.commands.ran.filter { $0.name == "wineserver" && $0.arguments == ["-k"] }
        XCTAssertEqual(kills.map(\.prefix), [env.runtime.prefix.path])
    }
}
