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

    func writeRSISignIn(_ env: Environment) throws {
        let store = env.runtime.rsiProfile.appendingPathComponent(RSILauncherStore.fileName)
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try XCTUnwrap(
            RSILauncherStore.encrypted([
                "identity": ["username": "pilot"],
                "session": ["value": "session-token"],
            ]))
        try data.write(to: store)
    }

    func testRSISetupInstallsThePinnedClient() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        XCTAssertTrue(env.commands.ran.contains { $0.name == "curl" && $0.arguments.contains(RSIInstaller.downloadURL) })
        let installerStart = try XCTUnwrap(env.commands.started.first { $0.1.first?.hasSuffix(RSIInstaller.launchFileName) == true })
        XCTAssertEqual(Array(installerStart.1.dropFirst()), ["/D=\(RSIInstaller.windowsInstallPath)"])
        XCTAssertTrue(
            env.commands.ran.contains {
                $0.arguments.contains("Debugger") && $0.arguments.contains(#"C:\windows\system32\cmd.exe /c exit"#)
            })
        let dotNetRegistry = try String(contentsOf: env.runtime.downloads.appendingPathComponent("dotnet-products.reg"))
        XCTAssertTrue(dotNetRegistry.contains("0D741DA1E0EBC6D3CA11466FCD14361F"))
        XCTAssertTrue(dotNetRegistry.contains("NDP\\v4\\Full"))
        XCTAssertTrue(dotNetRegistry.contains("4.8.04084"))
        XCTAssertTrue(env.commands.ran.contains { $0.arguments.first == "reg" && $0.arguments.contains("import") })
        XCTAssertTrue(env.sink.messages.contains("The RSI Launcher does not need the .NET Framework download. Setup skips it."))
        XCTAssertEqual(
            env.commands.started.last?.1,
            [try XCTUnwrap(env.runtime.rsiClient).path] + Runtime.rsiChromiumSwitches
        )
        XCTAssertEqual(env.frontmost.namedWindows.first?.1, RSIInstaller.windowTitle)
        XCTAssertEqual(env.runtime.fileSnapshot().stage, .signIn)
        XCTAssertEqual(env.runtime.prefix.lastPathComponent, "prefix-rsi")
    }

    func testRSISetupHidesTheWinePowerShellStub() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let stubs = ["system32", "syswow64"].map {
            env.runtime.prefix.appendingPathComponent("drive_c/windows/\($0)/WindowsPowerShell/v1.0/powershell.exe")
        }
        for stub in stubs {
            try FileManager.default.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("stub".utf8).write(to: stub)
        }
        try env.runtime.setup()
        XCTAssertEqual(env.commands.powershellStubVisibleAtRSIInstallStart, false)
        for stub in stubs {
            XCTAssertEqual(try String(contentsOf: stub, encoding: .utf8), "stub")
            let parked = stub.deletingLastPathComponent().appendingPathComponent("powershell.exe.siliconcellar")
            XCTAssertFalse(FileManager.default.fileExists(atPath: parked.path))
        }
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
        try writeRSISignIn(env)
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

    func testRSIOpenCreatesTheChannelFolder() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        let channel = env.runtime.prefix.appendingPathComponent(
            "drive_c/Program Files/Roberts Space Industries/StarCitizen/LIVE"
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: channel.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(
            env.sink.messages.contains {
                $0.contains("C:\\Program Files\\Roberts Space Industries\\StarCitizen\\LIVE")
            })
    }

    func testRSICancelInstallLeavesTheLauncherRunning() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let library = makeLibrary(env, recipes: [Self.rsiRecipe])
        let waiting = library.runtime(for: Self.rsiRecipe)
        XCTAssertNoThrow(try waiting.pauseBetweenPolls(0))
        try library.cancelInstallWait(gameID: Self.rsiRecipe.id)
        XCTAssertThrowsError(try waiting.pauseBetweenPolls(0)) { XCTAssertTrue($0 is LauncherStopped) }
        XCTAssertFalse(env.commands.ran.contains { $0.name == "wineserver" && $0.arguments == ["-k"] })
    }

    func testRSIInstallOpensTheLauncherAndWaits() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.commands.finishRSIInstallOnStart = true
        try env.runtime.installGame()
        XCTAssertTrue(env.runtime.isGameInstalled)
        XCTAssertEqual(env.commands.started.last?.1.last, "--in-process-gpu")
        XCTAssertTrue(
            env.sink.messages.contains {
                $0.contains(
                    RSIInstaller.manualInstallInstructions(
                        gameTitle: Self.rsiRecipe.title,
                        installFolder: Self.rsiRecipe.installFolder,
                        channel: Self.rsiRecipe.rsiChannel
                    ))
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
        XCTAssertTrue(
            env.commands.ran.contains {
                $0.arguments.first == "reg" && $0.arguments.contains { $0.contains("AppDefaults\\StarCitizen.exe\\SiliconCellar") }
            })
        XCTAssertEqual(
            env.commands.started.last?.1,
            [try XCTUnwrap(env.runtime.rsiClient).path] + Runtime.rsiChromiumSwitches
        )
        XCTAssertEqual(env.commands.lastStartEnvironment["WINEPREFIX"], env.runtime.prefix.path)
    }

    func testRSILogoutClearsTheSavedSignIn() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try writeRSISignIn(env)
        XCTAssertTrue(env.runtime.isSignedIn)
        try env.runtime.logout()
        XCTAssertFalse(env.runtime.isSignedIn)
    }

    func testRSICookieFileIsNotASignIn() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let cookies = env.runtime.rsiProfile.appendingPathComponent("Network/Cookies")
        try FileManager.default.createDirectory(at: cookies.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Rsi-Token".utf8).write(to: cookies)
        XCTAssertFalse(env.runtime.isSignedIn)
        XCTAssertEqual(env.runtime.fileSnapshot().stage, .setup)
    }

    func testRSILauncherStoreSignIn() throws {
        let signedIn = Data(
            base64Encoded:
                "JzS2JVmv/fY14kmIgbJEDDrRlbXq7QoOFnXjZ9H024G6MYdGs6J+C3j8cZbdGWV/gBiasDfax0NiHt0g+FR1FRibrZN5s7DJ4Zo7Asw8l4Z502E+U5k7w/Oaaij56AzKtlA7V29gwt9qQLTkOaHCCNbx8lXGgsms8bTNKqyNSc1K"
        )!
        XCTAssertTrue(RSILauncherStore.isSignedIn(signedIn))
        let signedOut = Data(
            base64Encoded:
                "TWh6PuX1OX2SSx9FQ3SuqzqKwVmQl+5MbNIsxXqYUpPNXRja+rUfbE3LW796XPV19+sd91hsES8hfHHKsAGJ1ghZFC3sAa7vYe9sKU4botDotb2Yl81PVqXKdguzkLDAVQ==")!
        XCTAssertFalse(RSILauncherStore.isSignedIn(signedOut))
        let emptySession = Data(base64Encoded: "yWcIUrwND5AT7avyJdoa1zo8cJLAQgKOkebntRRjMrblFLWXN50cdHl0blrg8udgZx25mFEICRjBbb+CZka5Q8CYGexu008vb0+jhKIb3eN8")!
        XCTAssertFalse(RSILauncherStore.isSignedIn(emptySession))
        let roundTrip = try XCTUnwrap(
            RSILauncherStore.encrypted([
                "identity": ["username": "pilot"],
                "session": ["value": "session-token"],
            ]))
        XCTAssertTrue(RSILauncherStore.isSignedIn(roundTrip))
        let cleared = try XCTUnwrap(RSILauncherStore.clearingSignIn(roundTrip))
        XCTAssertFalse(RSILauncherStore.isSignedIn(cleared))
    }

    func testRSIUninstallRemovesTheLauncherAndKeepsTheGame() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeRSISignIn(env)
        let game = try XCTUnwrap(env.runtime.game)
        try FileManager.default.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("game".utf8).write(to: game)
        try env.runtime.uninstallLauncher()
        XCTAssertNil(env.runtime.rsiClient)
        XCTAssertFalse(env.runtime.isSignedIn)
        XCTAssertTrue(env.runtime.isGameInstalled)
        XCTAssertFalse(env.runtime.fileSnapshot().launcherClientInstalled)
        XCTAssertEqual(env.runtime.fileSnapshot().stage, .ready)
        XCTAssertTrue(env.commands.ran.contains { $0.name == "wineserver" && $0.arguments == ["-k"] })
        XCTAssertTrue(env.sink.messages.contains("The RSI Launcher is uninstalled. The game files stay."))
    }

    func testRSIProcessDetection() {
        XCTAssertTrue(RSIProcess.isClientRunning(in: "C:\\Program Files\\Roberts Space Industries\\RSI Launcher\\RSI Launcher.exe\n"))
        XCTAssertFalse(RSIProcess.isClientRunning(in: "/bin/zsh -c open RSI Launcher.exe\n"))
        XCTAssertFalse(RSIProcess.isClientRunning(in: "/tmp/downloads/rsi-setup-2.17.0.exe\n"))
        XCTAssertTrue(RSIProcess.isInstallerRunning(in: "/tmp/downloads/rsi-setup-2.17.0.exe\n"))
        XCTAssertTrue(RSIProcess.isInstallerRunning(in: "/tmp/downloads/RSI Launcher-Setup-2.17.0.exe\n"))
        XCTAssertTrue(RSIProcess.isInstallerRunning(in: "winedbg --auto 12 34\n"))
        XCTAssertFalse(RSIProcess.isInstallerRunning(in: "/bin/ps\n"))
        XCTAssertFalse(
            RSIProcess.clientDrawsInProcess(
                in: "C:\\Program Files\\Roberts Space Industries\\RSI Launcher\\RSI Launcher.exe\n"
            ))
        XCTAssertFalse(
            RSIProcess.clientDrawsInProcess(
                in: "RSI Launcher.exe --type=gpu-process --in-process-gpu\n"
            ))
        XCTAssertTrue(
            RSIProcess.clientDrawsInProcess(
                in: "C:\\Program Files\\Roberts Space Industries\\RSI Launcher\\RSI Launcher.exe --in-process-gpu\n"
            ))
    }

    func testRSIOpenRestartsWhenTheWindowCannotDraw() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.commands.finishRSIInstallOnStart = true
        try env.runtime.setup()
        env.commands.live = true
        env.commands.wineserverPath = env.runtime.wineserver.path
        env.commands.liveProcessLines = [
            #"C:\Program Files\Roberts Space Industries\RSI Launcher\RSI Launcher.exe"#
        ]
        let startsBefore = env.commands.started.count
        try env.runtime.openRSI()
        XCTAssertTrue(env.commands.ran.contains { $0.name == "wineserver" && $0.arguments == ["-k"] })
        XCTAssertEqual(env.commands.started.count, startsBefore + 1)
        XCTAssertEqual(env.commands.started.last?.1.last, "--in-process-gpu")
        XCTAssertTrue(env.sink.messages.contains("The RSI Launcher window did not open. Starting it again."))
    }

    func testRSIOpenKeepsALauncherThatDrawsInProcess() throws {
        let env = try makeRSIEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.commands.finishRSIInstallOnStart = true
        try env.runtime.setup()
        env.commands.live = true
        env.commands.wineserverPath = env.runtime.wineserver.path
        env.commands.liveProcessLines = [
            #"C:\Program Files\Roberts Space Industries\RSI Launcher\RSI Launcher.exe --in-process-gpu"#
        ]
        let startsBefore = env.commands.started.count
        try env.runtime.openRSI()
        XCTAssertEqual(env.commands.started.count, startsBefore)
        XCTAssertFalse(env.sink.messages.contains("The RSI Launcher window did not open. Starting it again."))
    }

    func testDownloadProgressLineShowsMegabytes() {
        XCTAssertNil(DownloadProgressText.line(label: "Downloading…", size: 1_000_000, totalBytes: RSIInstaller.byteCount))
        XCTAssertEqual(
            DownloadProgressText.line(label: "Downloading…", size: 80_000_000, totalBytes: RSIInstaller.byteCount),
            "Downloading… 80 MB of 343 MB (23%)"
        )
    }
}
