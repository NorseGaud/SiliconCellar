import Foundation

public final class Runtime: @unchecked Sendable {
    public let recipe: Recipe
    public let root: URL
    public let wine: URL
    public let wineserver: URL
    private let files: FileSystem
    private let commands: CommandRunning
    private let sink: StatusSink
    private let frontmost: FrontmostActivating
    private let steamClient: SteamClientInspecting
    private let display: DisplaySizing
    public var expectedSteamSetupSHA256: String = SteamInstaller.sha256
    public var steamBootstrapTimeout: TimeInterval = 1800
    public var installTimeout: TimeInterval = 7200
    public var uninstallTimeout: TimeInterval = 1800
    public var installPollInterval: TimeInterval = 0.2
    public var steamClientWait: TimeInterval = 90
    public var steamWebHelperWrapper: Data = SteamWebHelper.wrapperBytes

    public init(
        recipe: Recipe,
        root: URL,
        wine: URL,
        wineserver: URL,
        files: FileSystem = FoundationFileSystem(),
        commands: CommandRunning = ProcessCommandRunner(),
        sink: StatusSink = PrintSink(),
        frontmost: FrontmostActivating = WorkspaceFrontmost(),
        steamClient: SteamClientInspecting = ProcessSteamClientInspector(),
        display: DisplaySizing = MainScreenDisplay()
    ) {
        self.recipe = recipe
        self.root = root
        self.wine = wine
        self.wineserver = wineserver
        self.files = files
        self.commands = commands
        self.sink = sink
        self.frontmost = frontmost
        self.steamClient = steamClient
        self.display = display
    }

    public var prefix: URL { root.appendingPathComponent("prefix") }
    public var downloads: URL { root.appendingPathComponent("downloads") }
    public var logs: URL { root.appendingPathComponent("logs") }
    public var readyMarker: URL { root.appendingPathComponent("runtime-ready") }
    public var loginUsers: URL {
        steamLibrary.appendingPathComponent("config/loginusers.vdf")
    }
    public var isSignedIn: Bool {
        guard files.fileExists(loginUsers), let data = try? files.read(loginUsers) else { return false }
        return SteamLoginUsers.isSignedIn(String(decoding: data, as: UTF8.self))
    }

    public var steamLibrary: URL {
        prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
    }

    public var steam: URL? {
        let exe = steamLibrary.appendingPathComponent("steam.exe")
        return files.fileExists(exe) ? exe : nil
    }

    public var steamUI: URL { steamLibrary.appendingPathComponent("steamui.dll") }

    public var game: URL? {
        steamLibrary
            .appendingPathComponent("steamapps/common")
            .appendingPathComponent(recipe.installFolder)
            .appendingPathComponent(recipe.gameRelativePath)
    }

    public var manifest: URL? {
        manifestCandidates.first { files.fileExists($0) } ?? manifestCandidates.first
    }

    private var manifestCandidates: [URL] {
        [
            steamLibrary.appendingPathComponent("steamapps/appmanifest_\(recipe.steamID).acf"),
            steamLibrary
                .appendingPathComponent("steamapps/common")
                .appendingPathComponent(recipe.installFolder)
                .appendingPathComponent("steamapps/appmanifest_\(recipe.steamID).acf"),
        ]
    }

    public var isSessionLive: Bool {
        if steamClient.isRunning(prefix: prefix) { return true }
        guard files.fileExists(wineserver), files.fileExists(prefix) else { return false }
        do {
            // Short wait: when Wine is live, -w blocks until timeout. 1.5s made every UI refresh feel stuck.
            _ = try commands.run(
                executable: wineserver,
                arguments: ["-w"],
                environment: wineEnvironment(),
                timeout: 0.2,
                workingDirectory: nil
            )
            return false
        } catch is TimeoutError {
            return true
        } catch {
            return false
        }
    }

    /// File/manifest check only — does not wait on wineserver.
    public var isGameInstalled: Bool {
        guard let game, files.fileExists(game), let manifest, files.fileExists(manifest),
            let data = try? files.read(manifest)
        else { return false }
        return SteamManifest.isCompleteInstall(
            text: String(decoding: data, as: UTF8.self),
            steamID: recipe.steamID,
            installFolder: recipe.installFolder
        )
    }

    public var isGameRunning: Bool {
        ProcessSteamClientInspector.processList(commands: commands).map {
            GameProcess.isRunning(executable: recipe.executable, in: $0)
        } ?? false
    }

    public func snapshot(now: Date = Date()) -> LibrarySnapshot {
        fileSnapshot(
            now: now,
            wineSessionLive: isSessionLive,
            steamReady: steamClient.isFullyRunning(prefix: prefix),
            gameRunning: isGameRunning
        )
    }

    /// Install/sign-in state from disk only. Does not wait on wineserver or `ps`.
    public func fileSnapshot(
        now: Date = Date(),
        wineSessionLive: Bool = false,
        steamReady: Bool = false,
        gameRunning: Bool = false
    ) -> LibrarySnapshot {
        LibrarySnapshot.inspect(
            root: root,
            runtimeReady: files.fileExists(readyMarker) && files.fileExists(steamUI),
            signedIn: isSignedIn,
            gameExecutable: game,
            manifest: manifest,
            steamID: recipe.steamID,
            installFolder: recipe.installFolder,
            wineSessionLive: wineSessionLive,
            steamReady: steamReady,
            gameRunning: gameRunning,
            now: now,
            files: files
        )
    }

    public func launchProgress(wineSessionLive: Bool? = nil) -> SteamLaunchProgress {
        let steamDirectory = steam?.deletingLastPathComponent()
        return SteamLaunchProgress.inspect(
            bootstrapLog: steamDirectory?.appendingPathComponent("logs/bootstrap_log.txt"),
            htmlLog: steamDirectory?.appendingPathComponent("logs/steamui_html.txt"),
            sessionLog: logs.appendingPathComponent("steam-session.log"),
            wineSessionLive: wineSessionLive ?? isSessionLive,
            signedIn: isSignedIn,
            now: Date(),
            files: files
        )
    }

    public func inspectSession(now: Date = Date()) -> (LibrarySnapshot, SteamLaunchProgress) {
        let live = isSessionLive
        let ready = steamClient.isFullyRunning(prefix: prefix)
        let running = isGameRunning
        // Steam client updates can drop a new cef.win64 helper mid-session; keep the wrap applied.
        if live { try? ensureSteamWebHelperWrapper() }
        return (
            fileSnapshot(now: now, wineSessionLive: live, steamReady: ready, gameRunning: running),
            launchProgress(wineSessionLive: live)
        )
    }

    public func wineEnvironment(hud: Bool = false, advertiseAVX: Bool = true) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !["WINE", "DYLD_", "ROSETTA_", "MTL_", "D3DM_", "GST_"].contains(where: key.hasPrefix)
        }
        environment["WINEPREFIX"] = prefix.path
        environment["WINESERVER"] = wineserver.path
        environment["WINELOADER"] = wine.path
        environment["WINEDEBUG"] = "-all"
        environment["WINEMSYNC"] = "1"
        environment["WINEESYNC"] = "0"
        if advertiseAVX { environment["ROSETTA_ADVERTISE_AVX"] = "1" }
        environment["MTL_HUD_ENABLED"] = hud ? "1" : "0"
        environment["WINEDLLOVERRIDES"] =
            "winemenubuilder.exe=;winedbg.exe=d;mscoree,mshtml=;gameoverlayrenderer,gameoverlayrenderer64=;"
            + recipe.graphicsOverrides
        for (key, value) in recipe.extraEnvironment { environment[key] = value }
        return environment
    }

    public func check() throws {
        try recipe.validate()
        sink.say("Data location: \(root.path)")
        sink.say("Game runtime is ready.")
        sink.say(
            "Runtime: \(files.fileExists(readyMarker) ? "ready" : "not installed") | Steam: \(files.fileExists(steamUI) ? "ready" : "not installed") | Sign-in: \(isSignedIn ? "yes" : "no") | \(recipe.title): \(game.map { files.fileExists($0) } == true ? "installed" : "not installed")"
        )
        if let game, files.fileExists(game) {
            do {
                try validateGameInstallation()
                sink.say("Game installation is complete. Steam manages game updates.")
            } catch let error as PortError {
                sink.say("Game launch is blocked: \(error.message)")
            }
        }
    }

    public func removeLegacyData() {
        for url in AppPaths.legacyPaths(supportRoot: root) where files.fileExists(url) {
            try? files.removeItem(url)
        }
    }

    public func prepare() throws {
        try recipe.validate()
        try requireIdle()
        try files.createDirectory(root)
        try files.createDirectory(prefix)
        try files.createDirectory(downloads)
        try files.createDirectory(logs)
        sink.say("Preparing a Windows environment in \(prefix.path)…")
        if !files.fileExists(prefix.appendingPathComponent("system.reg")) {
            try commands.run(
                executable: wine,
                arguments: ["wineboot", "--init"],
                environment: wineEnvironment(),
                timeout: 180,
                workingDirectory: nil
            )
        }
        let deadline = Date().addingTimeInterval(90)
        while !files.fileExists(prefix.appendingPathComponent("system.reg")), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard files.fileExists(prefix.appendingPathComponent("system.reg")) else {
            throw PortError("The Windows environment did not finish creating.")
        }
        try commands.run(
            executable: wine,
            arguments: ["winecfg", "-v", recipe.windowsVersion],
            environment: wineEnvironment(),
            timeout: 30,
            workingDirectory: nil
        )
        try isolateUserLinks()
        try files.write(Data("runtime-v1\n".utf8), to: readyMarker)
        sink.say("The independent runtime is ready.")
    }

    public func setup() throws {
        removeLegacyData()
        try prepare()
        try ensureSteamClient()
        sink.say("Steam is ready. Sign in in the Steam window.")
    }

    public func logout() throws {
        if isSessionLive {
            try openSteam(play: false)
            sink.say("Steam is open. Sign out in the Steam window.")
            return
        }
        if files.fileExists(loginUsers) { try files.removeItem(loginUsers) }
        sink.say("Local Steam sign-in is cleared.")
    }

    public func installGame() throws {
        if !files.fileExists(readyMarker) { try setup() }
        guard isSignedIn else {
            try openSteam(play: false)
            throw PortError("Sign in in the Steam window, then install the game.")
        }
        try ensureSteamClient()
        try openSteam(play: false, install: true)
        try waitForInstall()
        try promoteLibraryManifest()
        try quarantineGameFiles()
        sink.say("Steam finished installing \(recipe.title).")
    }

    public func uninstallGame() throws {
        if !files.fileExists(readyMarker) { try setup() }
        guard isSignedIn else {
            try openSteam(play: false)
            throw PortError("Sign in in the Steam window, then uninstall the game.")
        }
        try ensureSteamClient()
        try openSteam(play: false, uninstall: true)
        try waitForUninstall()
        try removeInstalledGameFiles()
        sink.say("Removed \(recipe.title) from this Steam library.")
    }

    public func playGame() throws {
        try validateGameInstallation()
        try ensureSteamClient()
        try promoteLibraryManifest()
        try quarantineGameFiles()
        try applyWineAppDefaults()
        try openSteam(play: true)
    }

    public func ensureSteamClient() throws {
        if steam == nil {
            let setup = try downloadSteamSetup()
            try files.createDirectory(steamLibrary)
            sink.say("Installing the Steam client…")
            try commands.run(
                executable: wine,
                arguments: [setup.path, "/S"],
                environment: wineEnvironment(),
                timeout: 600,
                workingDirectory: steamLibrary
            )
            let exe = steamLibrary.appendingPathComponent("steam.exe")
            let deadline = Date().addingTimeInterval(120)
            while !files.fileExists(exe), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard files.fileExists(exe) else {
                throw PortError("Steam client install did not produce steam.exe.")
            }
        }
        try completeSteamBootstrap()
    }

    private func completeSteamBootstrap() throws {
        if files.fileExists(steamUI) { return }
        guard let steam else {
            throw PortError("Install Steam before you open the library.")
        }
        sink.say("Steam is downloading the client. This can take several minutes.")
        try files.createDirectory(logs)
        try resetSteamHTMLCache()
        try commands.start(
            executable: wine,
            arguments: [steam.path] + Self.wineSteamArguments([], verifyFiles: true),
            environment: wineEnvironment(advertiseAVX: false),
            workingDirectory: steamLibrary,
            log: logs.appendingPathComponent("steam-bootstrap.log")
        )
        frontmost.bringSteamUIToFront(executable: wine, timeout: 30)
        let deadline = Date().addingTimeInterval(steamBootstrapTimeout)
        while Date() < deadline {
            try? ensureSteamWebHelperWrapper()
            if files.fileExists(steamUI) { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard files.fileExists(steamUI) else {
            throw PortError("Steam did not finish downloading steamui.dll. Try Play again after Steam updates.")
        }
        try ensureSteamWebHelperWrapper()
        sink.say("The Steam client is ready.")
    }

    public func openSteam(play: Bool, install: Bool = false, uninstall: Bool = false, hud: Bool = false) throws {
        guard files.fileExists(readyMarker), steam != nil else {
            throw PortError("Install Steam before you open the library.")
        }
        if play { try validateGameInstallation() }
        try files.createDirectory(logs)
        let log = logs.appendingPathComponent("steam-session.log")
        try ensureSteamWebHelperWrapper()
        let steamOpen = steamClient.isRunning(prefix: prefix)
        let directPlay = play && recipe.launchesDirectly
        if !steamOpen {
            // Direct play starts Steam only; the game exe starts after Steam is up.
            try startSteamDesktop(play: play && !directPlay, hud: hud, log: log)
        } else if play && !directPlay {
            sink.say("Steam is already open. Requesting \(recipe.title)…")
            try startSteamPlayRequest(hud: hud, log: log)
        } else if play && directPlay {
            sink.say("Steam is already open. Starting \(recipe.title)…")
        } else if !(install || uninstall) {
            sink.say("Steam is already open.")
            try startSteamDesktop(play: false, hud: hud, log: log)
        }
        // Install/uninstall need a live Steam client before the steam:// URI, or Steam drops it.
        if install || uninstall {
            try waitForSteamClient()
            try startSteamRequest(install: install, uninstall: uninstall, hud: hud, log: log)
        } else if !steamOpen {
            try waitForSteamClient()
        }
        if directPlay {
            try startDirectGame(hud: hud, log: log)
        }
        // Install/uninstall must not block on a long focus poll — waitForInstall needs to run.
        // Raise immediately, then keep polling Steam UI on a side queue.
        if install || uninstall {
            let front = frontmost
            let wineURL = wine
            front.bringToFront(executable: wineURL)
            DispatchQueue.global(qos: .userInitiated).async {
                front.bringSteamUIToFront(executable: wineURL, timeout: 30)
            }
        } else if directPlay {
            // Game must be frontmost so Wine can hide the host cursor.
            frontmost.bringGameWindowToFront(
                executable: wine,
                windowName: recipe.title,
                timeout: 20
            )
        } else {
            frontmost.bringSteamUIToFront(executable: wine, timeout: 30)
        }
        sink.say(
            play
                ? "\(recipe.title) launch requested. Steam may show a confirmation dialog."
                : install
                    ? "Install requested for \(recipe.title). Watch Steam until the download finishes."
                    : uninstall
                        ? "Uninstall requested for \(recipe.title). Watch Steam until removal finishes."
                        : "Steam launch requested. Watch the status bar until the Steam window opens.")
    }

    private func startSteamDesktop(play: Bool, hud: Bool, log: URL) throws {
        guard let steam else {
            throw PortError("Install Steam before you open the library.")
        }
        var arguments = [steam.path] + Self.wineSteamArguments(recipe.launchSteamArguments)
        if play {
            arguments += ["-applaunch", recipe.steamID]
        }
        try resetSteamHTMLCache()
        try ensureSteamWebHelperWrapper()
        try commands.start(
            executable: wine,
            arguments: arguments,
            environment: wineEnvironment(hud: hud, advertiseAVX: false),
            workingDirectory: steam.deletingLastPathComponent(),
            log: log
        )
    }

    private func startDirectGame(hud: Bool, log: URL) throws {
        guard let game else {
            throw PortError("Install \(recipe.title) before you play.")
        }
        let arguments: [String]
        if recipe.virtualDesktopSize != nil {
            let desktop = try resolvedVirtualDesktop()
            // explorer /desktop keeps old Glide/D3D titles drawing on macOS Wine.
            arguments = ["explorer", "/desktop=\(recipe.id),\(desktop)", game.path]
            sink.say("Starting \(recipe.title) in a \(desktop) Wine desktop.")
        } else {
            arguments = [game.path]
        }
        try commands.start(
            executable: wine,
            arguments: arguments,
            environment: wineEnvironment(hud: hud, advertiseAVX: false),
            workingDirectory: game.deletingLastPathComponent(),
            log: log
        )
    }

    private func resolvedVirtualDesktop() throws -> String {
        if recipe.fillsDisplayDesktop {
            guard let size = display.mainDisplaySize() else {
                throw PortError("Could not read the display size for \(recipe.title).")
            }
            return "\(size.width)x\(size.height)"
        }
        guard let desktop = recipe.virtualDesktopSize else {
            throw PortError("Recipe \(recipe.id) is missing wineVirtualDesktop.")
        }
        return desktop
    }

    /// Move install-folder files aside when they break Wine (for example Steam DDrawCompat).
    public func quarantineGameFiles() throws {
        let names = recipe.filesToQuarantine
        guard !names.isEmpty else { return }
        let folder =
            steamLibrary
            .appendingPathComponent("steamapps/common")
            .appendingPathComponent(recipe.installFolder)
        guard files.fileExists(folder) else { return }
        for name in names {
            let active = folder.appendingPathComponent(name)
            let disabled = folder.appendingPathComponent(name + Recipe.quarantineSuffix)
            guard files.fileExists(active) else { continue }
            if files.fileExists(disabled) { try files.removeItem(disabled) }
            try files.moveItem(from: active, to: disabled)
            sink.say("Moved \(name) aside so \(recipe.title) can run under Wine.")
        }
    }

    /// Per-exe Wine Direct3D settings under `AppDefaults\<executable>\Direct3D`.
    public func applyWineAppDefaults() throws {
        guard let renderer = recipe.d3dRenderer else { return }
        let key = "HKCU\\Software\\Wine\\AppDefaults\\\(recipe.executable)\\Direct3D"
        _ = try commands.run(
            executable: wine,
            arguments: ["reg", "add", key, "/v", "renderer", "/t", "REG_SZ", "/d", renderer, "/f"],
            environment: wineEnvironment(advertiseAVX: false),
            timeout: 30,
            workingDirectory: nil
        )
        sink.say("Wine Direct3D renderer for \(recipe.executable) is \(renderer).")
    }

    private func startSteamRequest(install: Bool, uninstall: Bool, hud: Bool, log: URL) throws {
        guard let steam else {
            throw PortError("Install Steam before you open the library.")
        }
        let uri =
            install
            ? "steam://install/\(recipe.steamID)"
            : "steam://uninstall/\(recipe.steamID)"
        try commands.start(
            executable: wine,
            arguments: [steam.path, uri],
            environment: wineEnvironment(hud: hud, advertiseAVX: false),
            workingDirectory: steam.deletingLastPathComponent(),
            log: log
        )
    }

    private func startSteamPlayRequest(hud: Bool, log: URL) throws {
        guard let steam else {
            throw PortError("Install Steam before you open the library.")
        }
        try commands.start(
            executable: wine,
            arguments: [steam.path] + Self.wineSteamArguments(recipe.launchSteamArguments) + [
                "-applaunch",
                recipe.steamID,
            ],
            environment: wineEnvironment(hud: hud, advertiseAVX: false),
            workingDirectory: steam.deletingLastPathComponent(),
            log: log
        )
    }

    private func waitForSteamClient() throws {
        if steamClient.isFullyRunning(prefix: prefix) {
            try? ensureSteamWebHelperWrapper()
            return
        }
        let deadline = Date().addingTimeInterval(steamClientWait)
        while Date() < deadline {
            try? ensureSteamWebHelperWrapper()
            // Wineserver alone is not enough — wait for Steam.exe and the UI helper.
            if steamClient.isFullyRunning(prefix: prefix) {
                try? ensureSteamWebHelperWrapper()
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard steamClient.isFullyRunning(prefix: prefix) else {
            throw PortError("Steam did not open a window. Try Sign in again.")
        }
        try? ensureSteamWebHelperWrapper()
    }

    private func waitForInstall() throws {
        let deadline = Date().addingTimeInterval(installTimeout)
        while Date() < deadline {
            try? repairMisplacedInstall()
            if (try? validateGameInstallation()) != nil { return }
            if !isSessionLive {
                throw PortError("Steam closed before \(recipe.title) finished installing.")
            }
            Thread.sleep(forTimeInterval: installPollInterval)
        }
        throw PortError("Steam did not finish installing \(recipe.title).")
    }

    private func waitForUninstall() throws {
        let deadline = Date().addingTimeInterval(uninstallTimeout)
        while Date() < deadline {
            let exeGone = game.map { !files.fileExists($0) } ?? true
            let manifestsGone = manifestCandidates.allSatisfy { !files.fileExists($0) }
            if exeGone && manifestsGone { return }
            if !isSessionLive {
                throw PortError("Steam closed before \(recipe.title) finished uninstalling.")
            }
            Thread.sleep(forTimeInterval: installPollInterval)
        }
        throw PortError("Steam did not finish removing \(recipe.title).")
    }

    public func stop() throws {
        guard files.fileExists(wineserver) else { return }
        _ = try? commands.run(
            executable: wineserver,
            arguments: ["-k"],
            environment: wineEnvironment(),
            timeout: 20,
            workingDirectory: nil
        )
        _ = try? commands.run(
            executable: wineserver,
            arguments: ["-w"],
            environment: wineEnvironment(),
            timeout: 30,
            workingDirectory: nil
        )
        sink.say("Stopped Steam for \(recipe.title).")
    }

    public func stopGame() throws {
        _ = try commands.run(
            executable: wine,
            arguments: ["taskkill", "/F", "/IM", recipe.executable],
            environment: wineEnvironment(advertiseAVX: false),
            timeout: 30,
            workingDirectory: nil
        )
        sink.say("Stopped \(recipe.title). Steam is still open.")
    }

    /// Stop the game if it is running; otherwise stop the Steam/Wine session.
    public func stopGameOrSession() throws {
        if isGameRunning {
            try stopGame()
        } else {
            try stop()
        }
    }

    public func validateGameInstallation() throws {
        try recipe.validate()
        guard isGameInstalled else {
            if game.map({ files.fileExists($0) }) != true {
                throw PortError("Install \(recipe.title) in this Steam client's default library, then choose Play.")
            }
            if manifest.map({ files.fileExists($0) }) != true {
                throw PortError("Finish installing \(recipe.title) in this Steam session before playing.")
            }
            throw PortError("Finish installing or updating \(recipe.title) in this Steam session before playing.")
        }
    }

    public func requireIdle() throws {
        if isSessionLive {
            throw PortError("Save and close \(recipe.title) and Steam before you install or repair this environment.")
        }
    }

    public static func requireSingleSession(active: Runtime, others: [Runtime]) throws {
        for other in others where other.root != active.root && other.isSessionLive {
            throw PortError("Another game's Steam session is open: \(other.recipe.title). Stop it before you switch games.")
        }
    }

    private func removeInstalledGameFiles() throws {
        let common =
            steamLibrary
            .appendingPathComponent("steamapps/common")
            .appendingPathComponent(recipe.installFolder)
        if files.fileExists(common) { try files.removeItem(common) }
        for candidate in manifestCandidates where files.fileExists(candidate) {
            try files.removeItem(candidate)
        }
    }

    private func repairMisplacedInstall() throws {
        guard let expected = game, !files.fileExists(expected) else { return }
        let misplaced = steamLibrary.appendingPathComponent(recipe.gameRelativePath)
        guard files.fileExists(misplaced) else { return }
        let destination =
            steamLibrary
            .appendingPathComponent("steamapps/common")
            .appendingPathComponent(recipe.installFolder)
        try files.createDirectory(destination)
        for item in (try files.contentsOfDirectory(steamLibrary)) {
            if item.lastPathComponent.lowercased() == "steamapps" { continue }
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if files.fileExists(target) { try files.removeItem(target) }
            try files.moveItem(from: item, to: target)
        }
    }

    private func promoteLibraryManifest() throws {
        let libraryManifest = manifestCandidates[0]
        if files.fileExists(libraryManifest) { return }
        guard let nested = manifestCandidates.dropFirst().first(where: { files.fileExists($0) }) else { return }
        try files.createDirectory(libraryManifest.deletingLastPathComponent())
        try files.write(try files.read(nested), to: libraryManifest)
    }

    private func downloadSteamSetup() throws -> URL {
        try downloadPinnedFile(
            name: "SteamSetup.exe",
            url: SteamInstaller.downloadURL,
            expected: expectedSteamSetupSHA256,
            progress: "Downloading the official Steam installer…",
            mismatch: "The downloaded Steam installer does not match the pinned SHA-256. Play stopped without installing it."
        )
    }

    private func downloadPinnedFile(name: String, url: String, expected: String, progress: String, mismatch: String) throws -> URL {
        let destination = downloads.appendingPathComponent(name)
        if files.fileExists(destination), let data = try? files.read(destination), SteamInstaller.digest(of: data) == expected {
            return destination
        }
        sink.say(progress)
        try files.createDirectory(downloads)
        let partial = destination.appendingPathExtension("partial")
        if files.fileExists(partial) { try files.removeItem(partial) }
        try commands.run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
                "--connect-timeout", "20", "--max-time", "600", "--retry", "2",
                "--output", partial.path, url,
            ],
            environment: ProcessInfo.processInfo.environment,
            timeout: 650,
            workingDirectory: nil
        )
        let data = try files.read(partial)
        guard SteamInstaller.digest(of: data) == expected else {
            try? files.removeItem(partial)
            throw PortError(mismatch)
        }
        if files.fileExists(destination) { try files.removeItem(destination) }
        try files.moveItem(from: partial, to: destination)
        return destination
    }

    static let requiredSteamArguments = [
        "-nofriendsui",
        "-nochatui",
        "-noverifyfiles",
        "-cef-disable-gpu",
    ]

    static func wineSteamArguments(_ extra: [String], verifyFiles: Bool = false) -> [String] {
        var seen = Set<String>()
        let blocked = Set([
            "-cef-single-process",
            "-cef-force-32bit",
            "-allosarches",
        ])
        var base = requiredSteamArguments
        // First bootstrap must verify/download the client; -noverifyfiles skips that and leaves no steamui.dll.
        if verifyFiles {
            base = base.filter { $0 != "-noverifyfiles" }
        }
        return (base + extra).filter { seen.insert($0).inserted && !blocked.contains($0) }
    }

    public func ensureSteamWebHelperWrapper() throws {
        try wrapSteamWebHelpers()
        let steamCfg = steamLibrary.appendingPathComponent("steam.cfg")
        if files.fileExists(steamCfg) {
            try files.removeItem(steamCfg)
        }
    }

    private func wrapSteamWebHelpers() throws {
        let cefRoot = steamLibrary.appendingPathComponent("bin/cef")
        guard files.fileExists(cefRoot) else { return }
        // Wrap every cef.* tree (win7, win7x64, win64, …). Steam updates pick a new folder
        // and leave older wrapped helpers unused — missing wrap on the active tree = black UI.
        for cef in (try? files.contentsOfDirectory(cefRoot)) ?? [] {
            try wrapSteamWebHelper(in: cef)
        }
    }

    private func wrapSteamWebHelper(in cef: URL) throws {
        let helper = cef.appendingPathComponent("steamwebhelper.exe")
        let valve = cef.appendingPathComponent("steamwebhelper-valve.exe")
        guard files.fileExists(helper) || files.fileExists(valve) else { return }
        if files.fileExists(helper) {
            let current = try files.read(helper)
            if SteamWebHelper.containsMarker(current) { return }
            // Steam updates can replace helper; keep Valve binary for the wrapper to launch.
            try files.write(current, to: valve)
        }
        try files.write(steamWebHelperWrapper, to: helper)
        try files.setExecutable(helper)
    }

    private func resetSteamHTMLCache() throws {
        let users = prefix.appendingPathComponent("drive_c/users")
        guard files.fileExists(users) else { return }
        for user in (try? files.contentsOfDirectory(users)) ?? [] {
            let cache = user.appendingPathComponent("AppData/Local/Steam/htmlcache")
            if files.fileExists(cache) { try files.removeItem(cache) }
        }
    }

    private func isolateUserLinks() throws {
        let users = prefix.appendingPathComponent("drive_c/users")
        guard files.fileExists(users) else { return }
        for user in (try? files.contentsOfDirectory(users)) ?? [] {
            for item in (try? files.contentsOfDirectory(user)) ?? [] {
                if files.isSymbolicLink(item) {
                    try files.removeItem(item)
                    try files.createDirectory(item)
                }
            }
        }
    }
}

public enum LibraryAction: String, Sendable {
    case check
    case setup
    case steam
    case install
    case play
    case stop
    case logout
    case uninstall
}

public struct Library: @unchecked Sendable {
    public let recipes: [Recipe]
    public let dataRootOverride: URL?
    public let home: URL
    public let wine: URL
    public let wineserver: URL
    private let files: FileSystem
    private let commands: CommandRunning
    private let sink: StatusSink
    private let frontmost: FrontmostActivating

    public init(
        recipes: [Recipe],
        wine: URL,
        wineserver: URL,
        dataRootOverride: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        files: FileSystem = FoundationFileSystem(),
        commands: CommandRunning = ProcessCommandRunner(),
        sink: StatusSink = PrintSink(),
        frontmost: FrontmostActivating = WorkspaceFrontmost()
    ) {
        self.recipes = recipes
        self.wine = wine
        self.wineserver = wineserver
        self.dataRootOverride = dataRootOverride
        self.home = home
        self.files = files
        self.commands = commands
        self.sink = sink
        self.frontmost = frontmost
    }

    public func runtime(for recipe: Recipe) -> Runtime {
        let root = dataRootOverride ?? AppPaths.supportRoot(home: home)
        return Runtime(
            recipe: recipe,
            root: root,
            wine: wine,
            wineserver: wineserver,
            files: files,
            commands: commands,
            sink: sink,
            frontmost: frontmost
        )
    }

    public func stopAllSessions() {
        guard let recipe = recipes.first else { return }
        let selected = runtime(for: recipe)
        guard files.fileExists(selected.prefix) else { return }
        try? selected.stop()
    }

    public func removeLegacyData() {
        runtime(for: recipes.first ?? Recipe.onboarding).removeLegacyData()
    }

    public func perform(_ action: LibraryAction, gameID: String) throws {
        let blockOtherSessions = ![.check, .stop, .logout].contains(action)
        try performLocked(gameID: gameID, blockOtherSessions: blockOtherSessions) { selected in
            switch action {
            case .check: try selected.check()
            case .setup: try selected.setup()
            case .steam: try selected.openSteam(play: false)
            case .install: try selected.installGame()
            case .uninstall: try selected.uninstallGame()
            case .play: try selected.playGame()
            case .stop: try selected.stopGameOrSession()
            case .logout: try selected.logout()
            }
        }
    }

    private func performLocked(gameID: String, blockOtherSessions: Bool, work: (Runtime) throws -> Void) throws {
        let recipe = try recipe(id: gameID)
        let selected = runtime(for: recipe)
        try files.createDirectory(selected.root)
        let lock = try SessionLock(root: selected.root)
        defer { withExtendedLifetime(lock) {} }
        if blockOtherSessions {
            try Runtime.requireSingleSession(active: selected, others: recipes.map { runtime(for: $0) })
        }
        try work(selected)
    }

    public func recipe(id: String) throws -> Recipe {
        guard let recipe = recipes.first(where: { $0.id == id }) else {
            throw PortError("Unknown game \"\(id)\". Use list to see recipes.")
        }
        return recipe
    }
}

public protocol SteamClientInspecting: Sendable {
    func isRunning(prefix: URL) -> Bool
    /// Steam.exe plus the UI helper (steamwebhelper) — ready for install / sign-in dialogs.
    func isFullyRunning(prefix: URL) -> Bool
}

extension SteamClientInspecting {
    public func isFullyRunning(prefix: URL) -> Bool { isRunning(prefix: prefix) }
}

public struct ProcessSteamClientInspector: SteamClientInspecting {
    private let commands: CommandRunning
    private let timeout: TimeInterval

    public init(commands: CommandRunning = ProcessCommandRunner(), timeout: TimeInterval = 0.5) {
        self.commands = commands
        self.timeout = timeout
    }

    public func isRunning(prefix: URL) -> Bool {
        guard let text = Self.processList(commands: commands, timeout: timeout) else { return false }
        return SteamClientProcess.isRunning(in: text, prefix: prefix)
    }

    public func isFullyRunning(prefix: URL) -> Bool {
        guard let text = Self.processList(commands: commands, timeout: timeout) else { return false }
        return SteamClientProcess.isFullyRunning(in: text, prefix: prefix)
    }

    public static func processList(
        commands: CommandRunning,
        timeout: TimeInterval = 0.5
    ) -> String? {
        try? commands.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ax", "-o", "command="],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: timeout,
            workingDirectory: nil
        )
    }
}

public enum GameProcess {
    public static func isRunning(executable: String, in processList: String) -> Bool {
        let needle = executable.lowercased()
        guard !needle.isEmpty else { return false }
        return processList.split(whereSeparator: \.isNewline).contains { line in
            let lower = String(line).lowercased()
            guard lower.contains(needle) else { return false }
            if lower.contains("steamwebhelper") || lower.contains("steam.exe") { return false }
            if lower.contains("taskkill") { return false }
            return true
        }
    }
}

public enum SteamClientProcess {
    public static func isRunning(in processList: String, prefix: URL) -> Bool {
        processList.split(whereSeparator: \.isNewline).contains { line in
            let command = String(line)
            return isSteamClient(command)
                && (command.contains(prefix.path) || command.localizedCaseInsensitiveContains("steam.exe"))
        }
    }

    /// Steam client process plus steamwebhelper — UI can accept steam:// URIs.
    public static func isFullyRunning(in processList: String, prefix: URL) -> Bool {
        guard isRunning(in: processList, prefix: prefix) else { return false }
        return processList.split(whereSeparator: \.isNewline).contains { line in
            String(line).lowercased().contains("steamwebhelper")
        }
    }

    public static func isSteamClient(_ command: String) -> Bool {
        let lower = command.lowercased()
        if lower.contains("steamservice") || lower.contains("steamwebhelper") { return false }
        let inSteamFolder =
            lower.contains("/steam/steam.exe") || lower.contains("\\steam\\steam.exe")
        guard inSteamFolder else { return false }
        if lower.hasPrefix("/bin/zsh") || lower.hasPrefix("/bin/bash") || lower.hasPrefix("zsh")
            || lower.hasPrefix("bash") || lower.contains("zsh -c") || lower.contains("bash -c")
            || lower.contains("steampath=")
        {
            return false
        }
        return true
    }
}
