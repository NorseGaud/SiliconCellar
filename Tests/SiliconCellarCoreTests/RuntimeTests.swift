import XCTest

@testable import SiliconCellarCore

final class FakeCommands: CommandRunning, @unchecked Sendable {
    var live = false
    /// Path included in fake `ps` output when `live` is true (session detection).
    var wineserverPath = ""
    var started: [(URL, [String])] = []
    var files: FileSystem = FoundationFileSystem()
    var installerBytes = Data("unused".utf8)
    var steamSetupBytes = Data("fake-steam-setup".utf8)
    var lastWineArguments: [String] = []
    var lastStartEnvironment: [String: String] = [:]
    var ran: [(name: String, arguments: [String], prefix: String?)] = []
    var finishSteamInstallOnStart = false
    var finishSteamUninstallOnStart = false
    var installSeed = InstallSeed.standard
    var steamClient: FakeSteamClient?

    enum InstallSeed {
        case standard
        case none
        case steamRoot
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        workingDirectory: URL?
    ) throws -> String {
        ran.append((executable.lastPathComponent, arguments, environment["WINEPREFIX"]))
        if executable.path == "/bin/ps" || executable.lastPathComponent == "ps" {
            if live, !wineserverPath.isEmpty {
                return "\(wineserverPath)\n/bin/ps\n"
            }
            return "/bin/ps\n"
        }
        if executable.lastPathComponent == "wineserver", arguments == ["-w"] {
            if live { throw TimeoutError() }
            return ""
        }
        if arguments == ["wineboot", "--init"], let prefix = environment["WINEPREFIX"] {
            let system = URL(fileURLWithPath: prefix).appendingPathComponent("system.reg")
            try files.write(Data("WINE REG\n".utf8), to: system)
            let users = URL(fileURLWithPath: prefix).appendingPathComponent("drive_c/users/player/Desktop")
            try FileManager.default.createDirectory(at: users.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: users, withDestinationURL: URL(fileURLWithPath: "/tmp"))
            return ""
        }
        if arguments.first == "winecfg" { return "" }
        if executable.lastPathComponent == "curl" {
            guard let outputIndex = arguments.firstIndex(of: "--output"), arguments.count > outputIndex + 1 else {
                throw PortError("curl missing --output")
            }
            let payload = arguments.contains(SteamInstaller.downloadURL) ? steamSetupBytes : installerBytes
            try payload.write(to: URL(fileURLWithPath: arguments[outputIndex + 1]))
            return ""
        }
        if arguments.contains(where: { $0.hasSuffix("SteamSetup.exe") }) {
            guard let prefix = environment["WINEPREFIX"] else { throw PortError("Steam setup missing WINEPREFIX") }
            let exe = URL(fileURLWithPath: prefix).appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
            try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("steam".utf8).write(to: exe)
            return ""
        }
        if executable.lastPathComponent == "wineserver" { return "" }
        return ""
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        log: URL
    ) throws {
        started.append((executable, arguments))
        lastWineArguments = arguments
        lastStartEnvironment = environment
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: log)
        if let steam = arguments.first(where: { $0.lowercased().hasSuffix("steam.exe") }) {
            try Data("ui".utf8).write(to: URL(fileURLWithPath: steam).deletingLastPathComponent().appendingPathComponent("steamui.dll"))
        }
        if finishSteamInstallOnStart, arguments.contains(where: { $0.hasPrefix("steam://install/") }), let prefix = environment["WINEPREFIX"] {
            switch installSeed {
            case .standard:
                try seedInstalledGame(prefix: URL(fileURLWithPath: prefix))
            case .steamRoot:
                try seedMisplacedGame(prefix: URL(fileURLWithPath: prefix))
            case .none:
                break
            }
        }
        if finishSteamUninstallOnStart, arguments.contains(where: { $0.hasPrefix("steam://uninstall/") }), let prefix = environment["WINEPREFIX"] {
            try removeInstalledGame(prefix: URL(fileURLWithPath: prefix))
        }
        if arguments.contains(where: { $0.lowercased().hasSuffix("steam.exe") })
            || arguments.contains("explorer")
        {
            steamClient?.running = true
        }
    }

    private func seedInstalledGame(prefix: URL) throws {
        let library = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let game = library.appendingPathComponent("steamapps/common/Spacewar/Spacewar.exe")
        try FileManager.default.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: game)
        let manifest = library.appendingPathComponent("steamapps/appmanifest_480.acf")
        try """
        "AppState" { "appid" "480" "installdir" "Spacewar" "StateFlags" "4" }
        """.write(to: manifest, atomically: true, encoding: .utf8)
    }

    private func seedMisplacedGame(prefix: URL) throws {
        let library = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: library.appendingPathComponent("Spacewar.exe"))
        try Data("data".utf8).write(to: library.appendingPathComponent("DATA.BIN"))
        let manifest = library.appendingPathComponent("steamapps/appmanifest_480.acf")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        "AppState" { "appid" "480" "installdir" "Spacewar" "StateFlags" "4" }
        """.write(to: manifest, atomically: true, encoding: .utf8)
    }

    private func removeInstalledGame(prefix: URL) throws {
        let library = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let common = library.appendingPathComponent("steamapps/common/Spacewar")
        let manifest = library.appendingPathComponent("steamapps/appmanifest_480.acf")
        if FileManager.default.fileExists(atPath: common.path) {
            try FileManager.default.removeItem(at: common)
        }
        if FileManager.default.fileExists(atPath: manifest.path) {
            try FileManager.default.removeItem(at: manifest)
        }
    }
}

final class FakeSteamClient: SteamClientInspecting, @unchecked Sendable {
    var running = false
    /// When true, always report Steam as not running (simulates hung/failed ps detection).
    var ignoreStarts = false
    func isRunning(prefix: URL) -> Bool { ignoreStarts ? false : running }
}

final class FakeHungPSCommands: CommandRunning, @unchecked Sendable {
    var ran: [(URL, [String])] = []

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        workingDirectory: URL?
    ) throws -> String {
        ran.append((executable, arguments))
        Thread.sleep(forTimeInterval: timeout + 0.02)
        throw TimeoutError()
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        log: URL
    ) throws {}
}

final class RuntimeTests: XCTestCase {
    func testPrepareWritesReadyMarker() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.runtime.readyMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.runtime.prefix.appendingPathComponent("system.reg").path))
        let desktop = env.runtime.prefix.appendingPathComponent("drive_c/users/player/Desktop")
        XCTAssertFalse((try? desktop.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
    }

    func testSignedInReadsLoginUsers() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        XCTAssertFalse(env.runtime.isSignedIn)
        let config = env.runtime.steamLibrary.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        "users" { "1" { "MostRecent" "1" "Timestamp" "1" } }
        """.write(to: config.appendingPathComponent("loginusers.vdf"), atomically: true, encoding: .utf8)
        XCTAssertTrue(env.runtime.isSignedIn)
    }

    func testOpenSteamBringsWineToFront() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        env.frontmost.activated.removeAll()
        env.frontmost.steamUIActivated.removeAll()
        try env.runtime.openSteam(play: false)
        XCTAssertEqual(env.frontmost.activated.first, env.runtime.wine)
        let pollDeadline = Date().addingTimeInterval(1)
        while env.frontmost.steamUIActivated.isEmpty, Date() < pollDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(env.frontmost.steamUIActivated.map(\.0), [env.runtime.wine])
    }

    func testWineHostFindsStagingAppBundle() {
        let wine = URL(fileURLWithPath: "/tmp/Wine Staging.app/Contents/Resources/wine/bin/wine")
        XCTAssertEqual(WineHost.applicationBundle(containing: wine)?.path, "/tmp/Wine Staging.app")
    }

    func testWineTerminalClosesOnlyWinehelpTabs() {
        XCTAssertTrue(WineTerminal.shouldClose(history: "setenv PATH \"...\" ; winehelp --clear"))
        XCTAssertFalse(WineTerminal.shouldClose(history: "git status"))
        XCTAssertTrue(WineTerminal.closeScript.contains("winehelp --clear"))
        XCTAssertTrue(WineTerminal.closeScript.contains("exists process \"Terminal\""))
        XCTAssertTrue(WineTerminal.closeScript.contains("quit"))
    }

    func testWineHostActivatesUnixWineNotStagingApp() {
        let wine = URL(fileURLWithPath: "/tmp/Wine Staging.app/Contents/Resources/wine/bin/wine")
        let unix = URL(fileURLWithPath: "/tmp/Wine Staging.app/Contents/Resources/wine/lib/wine/x86_64-unix/wine")
        let launcher = URL(fileURLWithPath: "/tmp/Wine Staging.app/Contents/MacOS/wine")
        let staging = URL(fileURLWithPath: "/tmp/Wine Staging.app")
        let running = [
            WineHost.RunningApp(executable: launcher, bundle: staging),
            WineHost.RunningApp(executable: unix, bundle: unix),
        ]
        let chosen = WineHost.appsToActivate(wineExecutable: wine, running: running)
        XCTAssertEqual(chosen, [running[1]])
    }

    func testOpenSteamRelaunchesBareSteamWhenSessionAlreadyLive() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        env.commands.live = true
        env.commands.started.removeAll()
        try env.runtime.openSteam(play: false)
        XCTAssertTrue(
            env.commands.started.contains(where: { _, arguments in
                arguments.contains(where: { $0.lowercased().hasSuffix("steam.exe") })
                    && !arguments.contains("explorer")
                    && !arguments.contains(where: { $0.hasPrefix("/desktop=") })
            }))
    }

    func testSetupLaunchesBareSteam() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        XCTAssertTrue(
            env.commands.started.contains(where: { _, arguments in
                arguments.contains(where: { $0.lowercased().hasSuffix("steam.exe") })
                    && !arguments.contains("explorer")
                    && !arguments.contains(where: { $0.hasPrefix("/desktop=") })
            }))
    }

    func testSetupInstallsSteamClientAndRemovesSteamCMD() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try FileManager.default.createDirectory(at: env.root.appendingPathComponent("SteamCMD"), withIntermediateDirectories: true)
        try env.runtime.setup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.runtime.steamUI.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.runtime.readyMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.root.appendingPathComponent("SteamCMD").path))
        XCTAssertFalse(env.sink.messages.contains(where: { $0.contains("SteamCMD") }))
    }

    func testLibraryUsesOneSharedPrefix() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cellar-share-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let wine = home.appendingPathComponent("wine")
        let wineserver = home.appendingPathComponent("wineserver")
        try Data().write(to: wine)
        try Data().write(to: wineserver)
        let first = Recipe(id: "spacewar", title: "Spacewar", steamID: "480", installFolder: "Spacewar", executable: "Spacewar.exe")
        let second = Recipe(id: "mdk", title: "MDK", steamID: "38450", installFolder: "MDK", executable: "MDKD3D.EXE")
        let library = Library(recipes: [first, second], wine: wine, wineserver: wineserver, home: home)
        XCTAssertEqual(library.runtime(for: first).root, AppPaths.supportRoot(home: home))
        XCTAssertEqual(library.runtime(for: second).root, library.runtime(for: first).root)
        XCTAssertEqual(library.runtime(for: first).prefix, library.runtime(for: second).prefix)
    }

    func testLogoutClearsLoginUsers() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try writeSignedIn(env)
        XCTAssertTrue(env.runtime.isSignedIn)
        try env.runtime.logout()
        XCTAssertFalse(env.runtime.isSignedIn)
        XCTAssertTrue(env.sink.messages.contains(where: { $0.contains("Local Steam sign-in is cleared") }))
    }

    func testInstallStartsSteamURI() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeSignedIn(env)
        env.commands.finishSteamInstallOnStart = true
        env.runtime.installPollInterval = 0
        env.commands.started.removeAll()
        try env.runtime.installGame()
        XCTAssertTrue(
            env.commands.started.contains(where: { _, arguments in
                arguments.contains("steam://install/480")
            }))
        XCTAssertFalse(env.commands.lastWineArguments.contains(where: { $0.contains("steamcmd") }))
        try env.runtime.validateGameInstallation()
    }

    func testInstallStartsDesktopWhenWineserverIsLiveWithoutSteam() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeSignedIn(env)
        env.commands.live = true
        env.steamClient.running = false
        env.commands.finishSteamInstallOnStart = true
        env.runtime.installPollInterval = 0
        env.commands.started.removeAll()
        try env.runtime.installGame()
        XCTAssertTrue(
            env.commands.started.contains(where: { _, arguments in
                arguments.contains(where: { $0.lowercased().hasSuffix("steam.exe") })
                    && !arguments.contains(where: { $0.hasPrefix("steam://") })
                    && !arguments.contains("explorer")
            }))
        XCTAssertTrue(
            env.commands.started.contains(where: { _, arguments in
                arguments.contains("steam://install/480") && !arguments.contains("explorer")
            }))
    }

    func testInstallOpensSteamThenSendsURI() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeSignedIn(env)
        env.steamClient.running = false
        env.commands.finishSteamInstallOnStart = true
        env.runtime.installPollInterval = 0
        env.commands.started.removeAll()
        try env.runtime.installGame()
        XCTAssertEqual(env.commands.started.count, 2)
        let steam = env.commands.started[0].1
        XCTAssertFalse(steam.contains("explorer"))
        XCTAssertFalse(steam.contains(where: { $0.hasPrefix("/desktop=") }))
        XCTAssertTrue(steam.contains(where: { $0.lowercased().hasSuffix("steam.exe") }))
        XCTAssertTrue(steam.contains("-cef-disable-gpu"))
        XCTAssertFalse(steam.contains(where: { $0.hasPrefix("steam://") }))
        let request = env.commands.started[1].1
        XCTAssertFalse(request.contains("explorer"))
        XCTAssertTrue(request.contains("steam://install/480"))
    }

    func testInstallWaitsForSteamClientBeforeURI() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeSignedIn(env)
        env.commands.finishSteamInstallOnStart = true
        env.runtime.installPollInterval = 0
        // Force a fresh Steam start so we can assert wait-before-URI order.
        env.steamClient.running = false
        env.commands.live = false
        env.commands.started.removeAll()
        env.frontmost.activated.removeAll()
        env.frontmost.steamUIActivated.removeAll()
        try env.runtime.installGame()
        let steamIndex = try XCTUnwrap(
            env.commands.started.firstIndex(where: { _, arguments in
                arguments.contains(where: { $0.lowercased().hasSuffix("steam.exe") })
                    && !arguments.contains(where: { $0.hasPrefix("steam://") })
            })
        )
        let uriIndex = try XCTUnwrap(
            env.commands.started.firstIndex(where: { _, arguments in
                arguments.contains("steam://install/480")
            })
        )
        // Desktop Steam must start before the install URI, or Steam drops the request.
        XCTAssertLessThan(steamIndex, uriIndex)
        XCTAssertTrue(env.sink.messages.contains(where: { $0.contains("Install requested") }))
        XCTAssertEqual(env.frontmost.activated.first, env.runtime.wine)
        let pollDeadline = Date().addingTimeInterval(1)
        while env.frontmost.steamUIActivated.isEmpty, Date() < pollDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(env.frontmost.steamUIActivated.map(\.0), [env.runtime.wine])
        XCTAssertEqual(env.frontmost.steamUIActivated.map(\.1), [30])
    }

    func testInstallFailsWhenSteamNeverOpens() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeSignedIn(env)
        env.steamClient.ignoreStarts = true
        env.commands.live = false
        env.runtime.steamClientWait = 0
        env.commands.finishSteamInstallOnStart = true
        XCTAssertThrowsError(try env.runtime.installGame()) { error in
            let message = (error as? PortError)?.message ?? ""
            XCTAssertTrue(message.contains("Steam did not open"), message)
        }
        XCTAssertFalse(
            env.commands.started.contains(where: { _, arguments in
                arguments.contains(where: { $0.hasPrefix("steam://install/") })
            })
        )
    }

    func testInstallFailsWhenSteamExitsBeforeFiles() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeSignedIn(env)
        env.commands.finishSteamInstallOnStart = false
        env.commands.live = false
        env.runtime.installPollInterval = 0
        env.runtime.installTimeout = 0
        XCTAssertThrowsError(try env.runtime.installGame())
    }

    func testUninstallStartsSteamURIAndRemovesFiles() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeSignedIn(env)
        env.commands.finishSteamInstallOnStart = true
        env.runtime.installPollInterval = 0
        try env.runtime.installGame()
        env.commands.finishSteamUninstallOnStart = true
        env.runtime.installPollInterval = 0
        try env.runtime.uninstallGame()
        XCTAssertTrue(
            env.commands.started.contains(where: { _, arguments in
                arguments.contains("steam://uninstall/480")
            }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.runtime.game!.path))
    }

    func testInstallRepairsSteamRootLayout() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeSignedIn(env)
        env.commands.installSeed = .steamRoot
        env.commands.finishSteamInstallOnStart = true
        env.runtime.installPollInterval = 0
        try env.runtime.installGame()
        let game = try XCTUnwrap(env.runtime.game)
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: env.runtime.steamLibrary.appendingPathComponent("steamapps/common/Spacewar/DATA.BIN").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: env.runtime.steamLibrary.appendingPathComponent("Spacewar.exe").path)
        )
        XCTAssertEqual(env.runtime.snapshot().stage, .ready)
    }

    func testManifestFindsGameFolderCopy() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let nested = env.runtime.steamLibrary
            .appendingPathComponent("steamapps/common/Spacewar/steamapps/appmanifest_480.acf")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        "AppState" { "appid" "480" "installdir" "Spacewar" "StateFlags" "4" }
        """.write(to: nested, atomically: true, encoding: .utf8)
        XCTAssertEqual(env.runtime.manifest, nested)
    }

    func testPlayLaunchesThroughSteam() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try signInAndInstall(env)
        try env.runtime.playGame()
        let arguments = try XCTUnwrap(env.commands.started.last?.1)
        XCTAssertFalse(arguments.contains("explorer"))
        XCTAssertTrue(arguments.contains(where: { $0.hasSuffix("steam.exe") }))
        XCTAssertTrue(arguments.contains("-applaunch"))
        XCTAssertTrue(arguments.contains("480"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(env.runtime.steam).path))
        XCTAssertGreaterThanOrEqual(env.commands.started.count, 2)
        let bootstrap = env.commands.started[0].1
        XCTAssertTrue(bootstrap.contains(where: { $0.lowercased().hasSuffix("steam.exe") }))
        XCTAssertFalse(bootstrap.contains("explorer"))
        XCTAssertFalse(bootstrap.contains("-applaunch"))
        XCTAssertFalse(env.commands.lastStartEnvironment["ROSETTA_ADVERTISE_AVX"] == "1")
        XCTAssertFalse(arguments.contains("-cef-single-process"))
        XCTAssertFalse(arguments.contains("-cef-force-32bit"))
        XCTAssertTrue(arguments.contains("-cef-disable-gpu"))
        XCTAssertTrue(arguments.contains("-nofriendsui"))
    }

    func testPlayDirectLaunchStartsGameExecutable() throws {
        let recipe = Recipe(
            id: "mdk",
            title: "MDK",
            steamID: "38450",
            installFolder: "MDK",
            executable: "MDK3DFX.EXE",
            quarantineFiles: ["ddraw.dll"],
            directLaunch: true,
            wineD3DRenderer: "gl",
            wineVirtualDesktop: "display"
        )
        let env = try makeEnvironment(recipe: recipe)
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeSignedIn(env)
        let gameDir = env.runtime.steamLibrary.appendingPathComponent("steamapps/common/MDK")
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: gameDir.appendingPathComponent("MDK3DFX.EXE"))
        try Data("compat".utf8).write(to: gameDir.appendingPathComponent("ddraw.dll"))
        try """
        "AppState" { "appid" "38450" "installdir" "MDK" "StateFlags" "4" }
        """.write(
            to: env.runtime.steamLibrary.appendingPathComponent("steamapps/appmanifest_38450.acf"),
            atomically: true,
            encoding: .utf8
        )
        env.steamClient.running = true
        env.commands.started.removeAll()
        env.commands.ran.removeAll()
        try env.runtime.playGame()
        let arguments = try XCTUnwrap(env.commands.started.last?.1)
        XCTAssertEqual(arguments.first, "explorer")
        XCTAssertTrue(arguments.contains("/desktop=mdk,2560x1440"))
        XCTAssertTrue(arguments.contains(where: { $0.hasSuffix("MDK3DFX.EXE") }))
        XCTAssertEqual(env.frontmost.gameWindows.first?.1, "MDK")
        XCTAssertFalse(arguments.contains("-applaunch"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("ddraw.dll").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: gameDir.appendingPathComponent("ddraw.dll" + Recipe.quarantineSuffix).path
            )
        )
        XCTAssertTrue(env.sink.messages.contains(where: { $0.contains("ddraw.dll") }))
        XCTAssertTrue(
            env.commands.ran.contains(where: {
                $0.name == "wine" && $0.arguments.contains("reg") && $0.arguments.contains("gl")
            })
        )
    }

    func testSteamClientProcessIgnoresServiceAndHelper() {
        XCTAssertTrue(SteamClientProcess.isSteamClient(#"C:\Program Files (x86)\Steam\steam.exe"#))
        XCTAssertTrue(
            SteamClientProcess.isSteamClient(
                "/Users/x/Library/Application Support/SiliconCellar/prefix/drive_c/Program Files (x86)/Steam/steam.exe -nofriendsui"
            )
        )
        XCTAssertFalse(SteamClientProcess.isSteamClient("steamservice.exe /RunAsService"))
        XCTAssertFalse(SteamClientProcess.isSteamClient("steamwebhelper.exe --no-sandbox"))
        XCTAssertFalse(SteamClientProcess.isSteamClient("explorer.exe /desktop"))
        XCTAssertFalse(
            SteamClientProcess.isSteamClient(
                #"zsh -c '… Steam/steam.exe … steamwebhelper …'"#
            )
        )
        XCTAssertFalse(
            SteamClientProcess.isSteamClient(
                "steampath=C:\\Program Files (x86)\\Steam\\steam.exe -launcher=0"
            )
        )
    }

    func testSteamClientProcessDetectsRunningFromProcessList() {
        let prefix = URL(fileURLWithPath: "/Users/x/Library/Application Support/SiliconCellar/prefix")
        let list = """
            /bin/zsh
            \(prefix.path)/drive_c/Program Files (x86)/Steam/steam.exe -nofriendsui
            C:\\Program Files (x86)\\Steam\\bin\\cef\\steamwebhelper.exe --type=gpu
            """
        XCTAssertTrue(SteamClientProcess.isRunning(in: list, prefix: prefix))
        XCTAssertTrue(SteamClientProcess.isFullyRunning(in: list, prefix: prefix))
        XCTAssertFalse(SteamClientProcess.isRunning(in: "steamwebhelper.exe\n/bin/ps", prefix: prefix))
        XCTAssertFalse(
            SteamClientProcess.isFullyRunning(
                in: "\(prefix.path)/drive_c/Program Files (x86)/Steam/steam.exe -nofriendsui\n/bin/ps",
                prefix: prefix
            )
        )
        // Dying Wine orphans often show Windows-only paths with no Silicon Cellar prefix.
        XCTAssertFalse(
            SteamClientProcess.isRunning(
                in: #"C:\Program Files (x86)\Steam\steam.exe -nofriendsui -nochatui"# + "\n/bin/ps",
                prefix: prefix
            )
        )
    }

    func testGameProcessDetectsExecutableWithoutMatchingSteam() {
        let list = """
            /Users/x/.../Steam/steam.exe -nofriendsui
            C:\\Program Files (x86)\\Steam\\steamapps\\common\\MDK\\MDKD3D.EXE
            steamwebhelper.exe --type=gpu
            """
        XCTAssertTrue(GameProcess.isRunning(executable: "MDKD3D.EXE", in: list))
        XCTAssertFalse(GameProcess.isRunning(executable: "MDKD3D.EXE", in: "steam.exe\nsteamwebhelper.exe"))
    }

    func testProcessSteamClientInspectorTimesOutHungPs() throws {
        let runner = FakeHungPSCommands()
        let inspector = ProcessSteamClientInspector(commands: runner, timeout: 0.05)
        let began = Date()
        XCTAssertFalse(inspector.isRunning(prefix: URL(fileURLWithPath: "/tmp/prefix")))
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0)
        XCTAssertEqual(runner.ran.count, 1)
    }

    func testCommandRunnerDrainsLargeStdoutBeforeExit() throws {
        let runner = ProcessCommandRunner()
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "print('x' * 200000, end='')"],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 5,
            workingDirectory: nil
        )
        XCTAssertEqual(output.count, 200_000)
    }

    func testCommandRunnerRepeatedShortRunsComplete() throws {
        let runner = ProcessCommandRunner()
        for _ in 0..<50 {
            let output = try runner.run(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["ok"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 2,
                workingDirectory: nil
            )
            XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        }
    }

    func testCommandRunnerTimeoutCleansUp() throws {
        let runner = ProcessCommandRunner()
        let began = Date()
        XCTAssertThrowsError(
            try runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 0.15,
                workingDirectory: nil
            )
        ) { error in
            XCTAssertTrue(error is TimeoutError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 3.0)
    }

    func testCommandRunnerTimeoutDoesNotLeakPipes() throws {
        let before = try Self.openPipeFileDescriptorCount()
        let runner = ProcessCommandRunner()
        for _ in 0..<40 {
            XCTAssertThrowsError(
                try runner.run(
                    executable: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["60"],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: 0.05,
                    workingDirectory: nil
                )
            ) { error in
                XCTAssertTrue(error is TimeoutError)
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
        let after = try Self.openPipeFileDescriptorCount()
        XCTAssertLessThan(
            after - before,
            30,
            "PIPE fds leaked: before=\(before) after=\(after)"
        )
    }

    private static func openPipeFileDescriptorCount() throws -> Int {
        let runner = ProcessCommandRunner()
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-p", String(ProcessInfo.processInfo.processIdentifier), "-F", "t"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin"],
            timeout: 5,
            workingDirectory: nil
        )
        return output.split(whereSeparator: \.isNewline).filter { $0 == "tPIPE" }.count
    }

    func testPlayClearsSteamHTMLCache() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try signInAndInstall(env)
        env.steamClient.running = false
        let cache = env.runtime.prefix.appendingPathComponent("drive_c/users/player/AppData/Local/Steam/htmlcache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: cache.appendingPathComponent("Index"))
        try env.runtime.playGame()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testPlayWrapsSteamWebHelper() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try signInAndInstall(env)
        env.runtime.steamWebHelperWrapper = Data("SCWRAP1-test".utf8)
        let cefLegacy = env.runtime.steamLibrary.appendingPathComponent("bin/cef/cef.win64")
        let cefCurrent = env.runtime.steamLibrary.appendingPathComponent("bin/cef/cef.win7x64")
        for cef in [cefLegacy, cefCurrent] {
            try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true)
            try Data("valve-helper".utf8).write(to: cef.appendingPathComponent("steamwebhelper.exe"))
        }
        try env.runtime.playGame()
        for cef in [cefLegacy, cefCurrent] {
            XCTAssertEqual(try Data(contentsOf: cef.appendingPathComponent("steamwebhelper-valve.exe")), Data("valve-helper".utf8))
            XCTAssertEqual(try Data(contentsOf: cef.appendingPathComponent("steamwebhelper.exe")), Data("SCWRAP1-test".utf8))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: env.runtime.steamLibrary.appendingPathComponent("steam.cfg").path
            ),
            "Do not inhibit the Steam bootstrapper; Client version 0 leaves the UI broken."
        )
        XCTAssertTrue(env.commands.lastStartEnvironment["WINEDLLOVERRIDES"]?.contains("winedbg.exe=d") == true)
    }

    /// Regression: Steam updates can replace a wrapped helper with a new unmarked Valve binary
    /// (seen with cef.win64). Re-wrap must restore SCWRAP1 or the login UI stays black.
    func testEnsureSteamWebHelperWrapperRewrapsAfterSteamUpdate() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        env.runtime.steamWebHelperWrapper = Data("SCWRAP1-v1".utf8)
        let cef = env.runtime.steamLibrary.appendingPathComponent("bin/cef/cef.win64")
        try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true)
        let helper = cef.appendingPathComponent("steamwebhelper.exe")
        let valve = cef.appendingPathComponent("steamwebhelper-valve.exe")
        try Data("valve-old".utf8).write(to: helper)
        try env.runtime.ensureSteamWebHelperWrapper()
        XCTAssertEqual(try Data(contentsOf: helper), Data("SCWRAP1-v1".utf8))
        XCTAssertEqual(try Data(contentsOf: valve), Data("valve-old".utf8))

        // Simulate Steam client update overwriting the wrapper with a new Valve binary.
        try Data("valve-new-update".utf8).write(to: helper)
        XCTAssertFalse(SteamWebHelper.containsMarker(try Data(contentsOf: helper)))

        env.runtime.steamWebHelperWrapper = Data("SCWRAP1-v2".utf8)
        try env.runtime.ensureSteamWebHelperWrapper()
        XCTAssertEqual(try Data(contentsOf: helper), Data("SCWRAP1-v2".utf8))
        XCTAssertEqual(try Data(contentsOf: valve), Data("valve-new-update".utf8))
        XCTAssertTrue(SteamWebHelper.containsMarker(try Data(contentsOf: helper)))
    }

    /// Regression: a brand-new cef.win64 tree after an older wrap must still get the wrapper.
    func testEnsureSteamWebHelperWrapperCoversNewCefWin64Directory() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        env.runtime.steamWebHelperWrapper = Data("SCWRAP1-test".utf8)
        let win7 = env.runtime.steamLibrary.appendingPathComponent("bin/cef/cef.win7x64")
        try FileManager.default.createDirectory(at: win7, withIntermediateDirectories: true)
        try Data("valve-win7".utf8).write(to: win7.appendingPathComponent("steamwebhelper.exe"))
        try env.runtime.ensureSteamWebHelperWrapper()
        XCTAssertEqual(
            try Data(contentsOf: win7.appendingPathComponent("steamwebhelper.exe")),
            Data("SCWRAP1-test".utf8)
        )

        let win64 = env.runtime.steamLibrary.appendingPathComponent("bin/cef/cef.win64")
        try FileManager.default.createDirectory(at: win64, withIntermediateDirectories: true)
        try Data("valve-win64".utf8).write(to: win64.appendingPathComponent("steamwebhelper.exe"))
        try env.runtime.ensureSteamWebHelperWrapper()
        XCTAssertEqual(
            try Data(contentsOf: win64.appendingPathComponent("steamwebhelper.exe")),
            Data("SCWRAP1-test".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: win64.appendingPathComponent("steamwebhelper-valve.exe")),
            Data("valve-win64".utf8)
        )
    }

    func testInspectSessionRewrapsWebHelperWhileSteamLive() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        env.steamClient.running = true
        env.runtime.steamWebHelperWrapper = Data("SCWRAP1-live".utf8)
        let cef = env.runtime.steamLibrary.appendingPathComponent("bin/cef/cef.win64")
        try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true)
        let helper = cef.appendingPathComponent("steamwebhelper.exe")
        try Data("valve-live".utf8).write(to: helper)
        _ = env.runtime.inspectSession()
        XCTAssertEqual(try Data(contentsOf: helper), Data("SCWRAP1-live".utf8))
    }

    func testSteamWebHelperWrapperInjectsDisableGPUAndSingleProcess() {
        let bytes = SteamWebHelper.wrapperBytes
        XCTAssertTrue(SteamWebHelper.containsMarker(bytes))
        let disableGPU = Data("disable-gpu".utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
        let singleProcess = Data("single-process".utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
        XCTAssertNotNil(bytes.range(of: disableGPU))
        XCTAssertNotNil(bytes.range(of: singleProcess))
    }

    func testSteamWebHelperInjectsOnlyForMainBrowserProcess() {
        XCTAssertTrue(SteamWebHelper.shouldInjectSingleProcess(cmd: nil))
        XCTAssertTrue(SteamWebHelper.shouldInjectSingleProcess(cmd: "--no-sandbox"))
        XCTAssertFalse(SteamWebHelper.shouldInjectSingleProcess(cmd: "--type=renderer"))
        XCTAssertFalse(SteamWebHelper.shouldInjectSingleProcess(cmd: "--single-process"))
    }

    func testWineSteamArgumentsKeepsDisableGPUDropsBrokenFlags() {
        let arguments = Runtime.wineSteamArguments([
            "-cef-single-process", "-cef-force-32bit", "-allosarches", "-cef-disable-gpu", "-extra",
        ])
        XCTAssertFalse(arguments.contains("-cef-single-process"))
        XCTAssertFalse(arguments.contains("-cef-force-32bit"))
        XCTAssertFalse(arguments.contains("-allosarches"))
        XCTAssertTrue(arguments.contains("-cef-disable-gpu"))
        XCTAssertTrue(arguments.contains("-extra"))
        XCTAssertTrue(arguments.contains("-nofriendsui"))
        XCTAssertTrue(arguments.contains("-noverifyfiles"))
    }

    func testWineSteamArgumentsCanAllowFileVerifyForBootstrap() {
        let bootstrap = Runtime.wineSteamArguments([], verifyFiles: true)
        XCTAssertFalse(bootstrap.contains("-noverifyfiles"))
        XCTAssertTrue(bootstrap.contains("-nofriendsui"))
        XCTAssertTrue(bootstrap.contains("-cef-disable-gpu"))
        let normal = Runtime.wineSteamArguments([])
        XCTAssertTrue(normal.contains("-noverifyfiles"))
    }

    func testSetupBootstrapOmitsNoVerifyFiles() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        let steamStart = try XCTUnwrap(
            env.commands.started.first(where: { _, arguments in
                arguments.contains(where: { $0.lowercased().hasSuffix("steam.exe") })
            })
        )
        XCTAssertFalse(
            steamStart.1.contains("-noverifyfiles"),
            "Bootstrap must verify/download the client so steamui.dll arrives."
        )
    }

    func testOpenSteamKeepsNoVerifyFilesAfterBootstrap() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        env.commands.started.removeAll()
        try env.runtime.openSteam(play: false)
        let steamStart = try XCTUnwrap(
            env.commands.started.first(where: { _, arguments in
                arguments.contains(where: { $0.lowercased().hasSuffix("steam.exe") })
            })
        )
        XCTAssertTrue(steamStart.1.contains("-noverifyfiles"))
    }

    func testPlayPromotesNestedManifest() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeSignedIn(env)
        env.commands.installSeed = .none
        let game = try XCTUnwrap(env.runtime.game)
        try FileManager.default.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: game)
        let nested = env.runtime.steamLibrary
            .appendingPathComponent("steamapps/common/Spacewar/steamapps/appmanifest_480.acf")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        "AppState" { "appid" "480" "installdir" "Spacewar" "StateFlags" "4" }
        """.write(to: nested, atomically: true, encoding: .utf8)
        try env.runtime.playGame()
        let libraryManifest = env.runtime.steamLibrary.appendingPathComponent("steamapps/appmanifest_480.acf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryManifest.path))
    }

    func testPlayRequiresCompleteInstall() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        XCTAssertThrowsError(try env.runtime.playGame())
    }

    func testIsGameInstalledUsesManifestAndExecutable() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.runtime.setup()
        try writeSignedIn(env)
        XCTAssertFalse(env.runtime.isGameInstalled)
        env.commands.finishSteamInstallOnStart = true
        env.runtime.installPollInterval = 0
        try env.runtime.installGame()
        XCTAssertTrue(env.runtime.isGameInstalled)
        let filesOnly = env.runtime.fileSnapshot()
        XCTAssertTrue(filesOnly.isInstalled)
        XCTAssertFalse(filesOnly.wineSessionLive)
    }

    func testIsSessionLiveUsesWineserverProcessNotOrphanSteam() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.steamClient.running = true
        env.commands.live = false
        env.commands.ran.removeAll()
        XCTAssertFalse(env.runtime.isSessionLive)
        XCTAssertTrue(env.commands.ran.contains(where: { $0.name == "ps" }))
        env.commands.live = true
        env.commands.ran.removeAll()
        XCTAssertTrue(env.runtime.isSessionLive)
        XCTAssertTrue(
            WineSessionProcess.isWineserverRunning(
                in: "\(env.runtime.wineserver.path)\n/bin/ps",
                wineserver: env.runtime.wineserver
            )
        )
        // ps often shows lib/wine/../../bin/wineserver — must still match.
        let engine = env.runtime.wineserver.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(
            WineSessionProcess.isWineserverRunning(
                in: "\(engine.path)/lib/wine/../../bin/wineserver\n/bin/ps",
                wineserver: env.runtime.wineserver
            )
        )
    }

    func testSingleSessionLock() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let otherRoot = env.root.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot.appendingPathComponent("prefix"), withIntermediateDirectories: true)
        let other = Runtime(
            recipe: Recipe(id: "other", title: "Other", steamID: "1", installFolder: "Other", executable: "o.exe"),
            root: otherRoot,
            wine: env.runtime.wine,
            wineserver: env.runtime.wineserver,
            commands: env.commands,
            sink: env.sink
        )
        env.commands.live = true
        XCTAssertThrowsError(try Runtime.requireSingleSession(active: env.runtime, others: [other]))
    }

    func testStopAllSessionsKillsTheSharedPrefix() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cellar-stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let wine = home.appendingPathComponent("wine")
        let wineserver = home.appendingPathComponent("wineserver")
        try Data().write(to: wine, options: .atomic)
        try Data().write(to: wineserver, options: .atomic)
        let first = Recipe(id: "spacewar", title: "Spacewar", steamID: "480", installFolder: "Spacewar", executable: "Spacewar.exe")
        let second = Recipe(id: "mdk", title: "MDK", steamID: "38450", installFolder: "MDK", executable: "MDKD3D.EXE")
        let commands = FakeCommands()
        let library = Library(
            recipes: [first, second],
            wine: wine,
            wineserver: wineserver,
            home: home,
            commands: commands,
            sink: CollectingSink()
        )
        try FileManager.default.createDirectory(at: library.runtime(for: first).prefix, withIntermediateDirectories: true)
        library.stopAllSessions()
        let kills = commands.ran.filter { $0.name == "wineserver" && $0.arguments == ["-k"] }
        XCTAssertEqual(kills.count, 1)
        XCTAssertEqual(kills.first?.prefix, library.runtime(for: first).prefix.path)
    }

    final class RecordingFrontmost: FrontmostActivating, @unchecked Sendable {
        var activated: [URL] = []
        var steamUIActivated: [(URL, TimeInterval)] = []
        var gameWindows: [(URL, String, TimeInterval)] = []
        func bringToFront(executable: URL) { activated.append(executable) }
        func bringSteamUIToFront(executable: URL, timeout: TimeInterval) {
            steamUIActivated.append((executable, timeout))
            activated.append(executable)
        }
        func bringGameWindowToFront(executable: URL, windowName: String, timeout: TimeInterval) {
            gameWindows.append((executable, windowName, timeout))
            activated.append(executable)
        }
    }

    struct FixedDisplay: DisplaySizing {
        var width: Int
        var height: Int
        func mainDisplaySize() -> (width: Int, height: Int)? { (width, height) }
    }

    private struct Environment {
        var root: URL
        var runtime: Runtime
        var commands: FakeCommands
        var sink: CollectingSink
        var frontmost: RecordingFrontmost
        var steamClient: FakeSteamClient
    }

    private func writeSignedIn(_ env: Environment) throws {
        let config = env.runtime.steamLibrary.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        "users" { "1" { "MostRecent" "1" "Timestamp" "1" } }
        """.write(to: env.runtime.loginUsers, atomically: true, encoding: .utf8)
    }

    private func signInAndInstall(_ env: Environment) throws {
        try env.runtime.setup()
        try writeSignedIn(env)
        env.commands.finishSteamInstallOnStart = true
        env.runtime.installPollInterval = 0
        try env.runtime.installGame()
    }

    private func makeEnvironment(
        recipe: Recipe = Recipe(
            id: "spacewar",
            title: "Spacewar",
            steamID: "480",
            installFolder: "Spacewar",
            executable: "Spacewar.exe"
        )
    ) throws -> Environment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cellar-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wine = root.appendingPathComponent("wine")
        let wineserver = root.appendingPathComponent("wineserver")
        try Data().write(to: wine)
        try Data().write(to: wineserver)
        let commands = FakeCommands()
        let sink = CollectingSink()
        let frontmost = RecordingFrontmost()
        let steamClient = FakeSteamClient()
        commands.steamClient = steamClient
        commands.wineserverPath = wineserver.path
        let runtime = Runtime(
            recipe: recipe,
            root: root,
            wine: wine,
            wineserver: wineserver,
            commands: commands,
            sink: sink,
            frontmost: frontmost,
            steamClient: steamClient,
            display: FixedDisplay(width: 2560, height: 1440)
        )
        runtime.expectedSteamSetupSHA256 = SteamInstaller.digest(of: commands.steamSetupBytes)
        runtime.steamClientWait = 0
        return Environment(
            root: root,
            runtime: runtime,
            commands: commands,
            sink: sink,
            frontmost: frontmost,
            steamClient: steamClient
        )
    }
}
