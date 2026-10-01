import Foundation

public final class Runtime: @unchecked Sendable {
    public let recipe: Recipe
    public let root: URL
    public let wine: URL
    public let wineserver: URL
    let files: FileSystem
    let commands: CommandRunning
    let sink: StatusSink
    let frontmost: FrontmostActivating
    private let steamClient: SteamClientInspecting
    private let display: DisplaySizing
    public var expectedSteamSetupSHA256: String = SteamInstaller.sha256
    public var expectedBattleNetSetupSHA256: String = BattleNetInstaller.sha256
    public var steamBootstrapTimeout: TimeInterval = 1800
    public var battleNetSetupTimeout: TimeInterval = 1800
    public var installTimeout: TimeInterval = 7200
    public var uninstallTimeout: TimeInterval = 1800
    public var installPollInterval: TimeInterval = 0.2
    /// After wineserver vanishes mid-install, keep checking files this long (Steam often restarts).
    public var sessionDropGrace: TimeInterval = 30
    public var steamClientWait: TimeInterval = 90
    public var steamWebHelperWrapper: Data = SteamWebHelper.wrapperBytes
    public var rendererPackages: [RendererPackage] = RendererPackage.all
    public var wineServerDirectory: URL = WineServerSocket.defaultDirectory
    var stopRequests = LauncherStopRequests()
    /// The Engine that runs this prefix. A new ID makes `prepare()` update the prefix.
    public var engineID: String

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
        self.engineID = EngineLocator.engineID(wine: wine, files: files)
    }

    public var prefix: URL { prefix(for: recipe.launcherKind) }

    /// Waits between polls. Throws `LauncherStopped` when Stop closed this launcher during the wait.
    func pauseBetweenPolls(_ interval: TimeInterval) throws {
        Thread.sleep(forTimeInterval: interval)
        if stopRequests.isRequested(recipe.launcherKind) { throw LauncherStopped(launcher: recipe.launcherKind) }
    }

    private func prefix(for launcher: Launcher) -> URL {
        root.appendingPathComponent(launcher.prefixFolderName)
    }
    private var systemRegistry: URL { prefix.appendingPathComponent("system.reg") }
    private var readyMarkerText: String { "runtime-v2 \(engineID)\n" }

    /// True when the current Engine prepared the prefix.
    public var isRuntimeCurrent: Bool {
        guard let data = try? files.read(readyMarker) else { return false }
        return String(decoding: data, as: UTF8.self) == readyMarkerText
    }
    public var downloads: URL { root.appendingPathComponent("downloads") }
    public var logs: URL { root.appendingPathComponent("logs") }
    public var readyMarker: URL { root.appendingPathComponent(recipe.launcherKind.readyMarkerName) }
    public var renderersRoot: URL { root.appendingPathComponent("renderers") }
    public var appleLicenseMarker: URL { root.appendingPathComponent("apple-gptk-license-accepted") }
    private var rendererPackage: RendererPackage? { rendererPackages.first { $0.id == recipe.rendererID } }
    public var loginUsers: URL {
        steamLibrary.appendingPathComponent("config/loginusers.vdf")
    }
    public var isSignedIn: Bool {
        if recipe.launcherKind == .battleNet { return isBattleNetSignedIn }
        guard files.fileExists(loginUsers), let data = try? files.read(loginUsers) else { return false }
        return SteamLoginUsers.isSignedIn(String(decoding: data, as: UTF8.self))
    }

    /// The launcher client files are in place (Steam: `steamui.dll`, Battle.net: `Battle.net.exe`).
    public var isLauncherClientInstalled: Bool {
        switch recipe.launcherKind {
        case .steam: return files.fileExists(steamUI)
        case .battleNet: return battleNetClient != nil
        }
    }

    var programFiles: URL { prefix.appendingPathComponent("drive_c/Program Files (x86)") }

    private var windowsUsers: URL { prefix.appendingPathComponent("drive_c/users") }

    /// The Engine names the Windows user "crossover".
    var userProfile: URL { windowsUsers.appendingPathComponent("crossover") }

    public var steamLibrary: URL { programFiles.appendingPathComponent("Steam") }

    public var steam: URL? {
        let exe = steamLibrary.appendingPathComponent("steam.exe")
        return files.fileExists(exe) ? exe : nil
    }

    public var steamUI: URL { steamLibrary.appendingPathComponent("steamui.dll") }

    /// The folder that the launcher installs the game into.
    public var gameFolder: URL {
        switch recipe.launcherKind {
        case .steam:
            return steamLibrary.appendingPathComponent("steamapps/common").appendingPathComponent(recipe.installFolder)
        case .battleNet:
            return programFiles.appendingPathComponent(recipe.installFolder)
        }
    }

    public var game: URL? { gameFolder.appendingPathComponent(recipe.gameRelativePath) }

    public var manifest: URL? {
        manifestCandidates.first { files.fileExists($0) } ?? manifestCandidates.first
    }

    private var manifestCandidates: [URL] {
        [
            steamLibrary.appendingPathComponent("steamapps/appmanifest_\(recipe.steamAppID).acf"),
            gameFolder.appendingPathComponent("steamapps/appmanifest_\(recipe.steamAppID).acf"),
        ]
    }

    public var isSessionLive: Bool {
        // Never call `wineserver -w` for polling — a cold launch often exceeds the short
        // timeout and falsely reports live, flipping Start Steam ↔ Steam is running.
        guard let text = ProcessSteamClientInspector.processList(commands: commands),
            WineSessionProcess.isWineserverRunning(in: text, wineserver: wineserver)
        else {
            return false
        }
        // The process list does not show which prefix a wineserver serves, so look for the socket of this prefix.
        if isWineServerRunning(prefix: prefix) { return true }
        // No socket for any launcher (for example Wine uses another server folder): any Engine wineserver counts.
        return !Launcher.allCases.contains { isWineServerRunning(prefix: prefix(for: $0)) }
    }

    private func isWineServerRunning(prefix: URL) -> Bool {
        WineServerSocket.url(prefix: prefix, in: wineServerDirectory).map(files.fileExists) ?? false
    }

    /// File/manifest check only — does not wait on wineserver.
    public var isGameInstalled: Bool {
        if recipe.launcherKind == .battleNet { return isBattleNetGameInstalled }
        guard let game, files.fileExists(game), let manifest, files.fileExists(manifest),
            let data = try? files.read(manifest)
        else { return false }
        return SteamManifest.isCompleteInstall(
            text: String(decoding: data, as: UTF8.self),
            steamID: recipe.steamAppID,
            installFolder: recipe.installFolder
        )
    }

    public var isGameRunning: Bool {
        ProcessSteamClientInspector.processList(commands: commands).map {
            GameProcess.isRunning(executable: recipe.executable, in: $0)
        } ?? false
    }

    /// Steam: Steam.exe plus the UI helper. Battle.net: Battle.net.exe.
    private var isLauncherClientRunning: Bool {
        switch recipe.launcherKind {
        case .steam: return steamClient.isFullyRunning(prefix: prefix)
        case .battleNet: return isBattleNetClientRunning
        }
    }

    public func snapshot(now: Date = Date()) -> LibrarySnapshot {
        let live = isSessionLive
        let ready = live && isLauncherClientRunning
        return fileSnapshot(
            now: now,
            wineSessionLive: live,
            launcherReady: ready,
            launcherWindowVisible: ready && SteamUIFocus.hasVisibleWineWindow(for: wine),
            gameRunning: isGameRunning
        )
    }

    /// Install/sign-in state from disk only. Does not wait on wineserver or `ps`.
    public func fileSnapshot(
        now: Date = Date(),
        wineSessionLive: Bool = false,
        launcherReady: Bool = false,
        launcherWindowVisible: Bool = false,
        gameRunning: Bool = false
    ) -> LibrarySnapshot {
        LibrarySnapshot.inspect(
            root: root,
            runtimeReady: files.fileExists(readyMarker) && isLauncherClientInstalled,
            signedIn: isSignedIn,
            gameExecutable: game,
            manifest: recipe.launcherKind == .steam ? manifest : nil,
            installComplete: recipe.launcherKind == .steam ? nil : isGameInstalled,
            steamID: recipe.steamAppID,
            installFolder: recipe.installFolder,
            wineSessionLive: wineSessionLive,
            launcherReady: launcherReady,
            launcherWindowVisible: launcherWindowVisible,
            gameRunning: gameRunning,
            now: now,
            files: files
        )
    }

    public func launchProgress(wineSessionLive: Bool? = nil) -> SteamLaunchProgress {
        guard recipe.launcherKind == .steam else { return SteamLaunchProgress() }
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
        // Launcher ready only while wineserver is live — ignore dying steam.exe orphans.
        let ready = live && isLauncherClientRunning
        let windowVisible = ready && SteamUIFocus.hasVisibleWineWindow(for: wine)
        let running = isGameRunning
        // Steam client updates can drop a new cef.win64 helper mid-session; keep the wrap applied.
        if live { try? ensureSteamWebHelperWrapper() }
        return (
            fileSnapshot(
                now: now,
                wineSessionLive: live,
                launcherReady: ready,
                launcherWindowVisible: windowVisible,
                gameRunning: running
            ),
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
        // CrossOver Wine reports the user name "crossover" without this. Steam keys the saved sign-in to the user name.
        environment["CX_REPORT_REAL_USERNAME"] = "1"
        if advertiseAVX { environment["ROSETTA_ADVERTISE_AVX"] = "1" }
        environment["MTL_HUD_ENABLED"] = hud ? "1" : "0"
        environment["WINEDLLOVERRIDES"] =
            "winemenubuilder.exe=;winedbg.exe=d;mscoree,mshtml=;gameoverlayrenderer,gameoverlayrenderer64=;"
            + recipe.graphicsOverrides
        environment.merge(recipe.launcherKind.engineEnvironment) { _, launcherValue in launcherValue }
        for (key, value) in recipe.extraEnvironment { environment[key] = value }
        return environment
    }

    public func check() throws {
        try recipe.validate()
        sink.say("Data location: \(root.path)")
        sink.say("Game runtime is ready.")
        sink.say(
            "Runtime: \(files.fileExists(readyMarker) ? "ready" : "not installed") | \(launcherName): \(isLauncherClientInstalled ? "ready" : "not installed") | Sign-in: \(isSignedIn ? "yes" : "no") | \(recipe.title): \(game.map { files.fileExists($0) } == true ? "installed" : "not installed")"
        )
        if let game, files.fileExists(game) {
            do {
                try validateGameInstallation()
                sink.say("Game installation is complete. \(launcherName) manages game updates.")
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
        let prefixExisted = files.fileExists(systemRegistry)
        if !prefixExisted {
            try commands.run(
                executable: wine,
                arguments: ["wineboot", "--init"],
                environment: wineEnvironment(),
                timeout: 180,
                workingDirectory: nil
            )
        }
        let deadline = Date().addingTimeInterval(90)
        while !files.fileExists(systemRegistry), Date() < deadline {
            try pauseBetweenPolls(0.2)
        }
        guard files.fileExists(systemRegistry) else {
            throw PortError("The Windows environment did not finish creating.")
        }
        if prefixExisted && !isRuntimeCurrent {
            // Steam and the games stay; wineboot only refreshes the Wine files of the prefix.
            sink.say("Updating the Windows environment for Engine \(engineID)…")
            try moveUserProfileToEngineUserName()
            try commands.run(
                executable: wine,
                arguments: ["wineboot", "--update"],
                environment: wineEnvironment(),
                timeout: 600,
                workingDirectory: nil
            )
            // wineboot --update runs the autostart keys, which start "steam.exe -silent" without the Steam arguments.
            endWineSession()
        }
        try commands.run(
            executable: wine,
            arguments: ["winecfg", "-v", recipe.windowsVersion],
            environment: wineEnvironment(),
            timeout: 30,
            workingDirectory: nil
        )
        try isolateUserLinks()
        try files.write(Data(readyMarkerText.utf8), to: readyMarker)
        sink.say("The independent runtime is ready.")
    }

    var launcherName: String { recipe.launcherKind.displayName }

    public func setup() throws {
        removeLegacyData()
        try prepare()
        if recipe.launcherKind == .battleNet {
            try ensureBattleNetClient()
            try openBattleNet(gamePage: false)
            sink.say("Battle.net is ready. Sign in in the Battle.net window.")
            return
        }
        try ensureSteamClient()
        sink.say("Steam is ready. Sign in in the Steam window.")
    }

    /// Opens the launcher window of this recipe (Steam or Battle.net).
    public func openLauncher() throws {
        switch recipe.launcherKind {
        case .steam: try openSteam(play: false)
        case .battleNet: try openBattleNet(gamePage: false)
        }
    }

    public func logout() throws {
        if recipe.launcherKind == .battleNet { return try logoutBattleNet() }
        if isSessionLive {
            try openSteam(play: false)
            sink.say("Steam is open. Sign out in the Steam window.")
            return
        }
        if files.fileExists(loginUsers) { try files.removeItem(loginUsers) }
        sink.say("Local Steam sign-in is cleared.")
    }

    public func installGame() throws {
        if recipe.launcherKind == .battleNet { return try installBattleNetGame() }
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
        try seedGameFiles()
        sink.say("Steam finished installing \(recipe.title).")
    }

    public func uninstallGame() throws {
        if recipe.launcherKind == .battleNet { return try uninstallBattleNetGame() }
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
        if recipe.launcherKind == .battleNet { return try playBattleNetGame() }
        try validateGameInstallation()
        try ensureSteamClient()
        let rendererFolder = try prepareRenderer()
        try promoteLibraryManifest()
        try quarantineGameFiles()
        try seedGameFiles()
        try createProfileFolders()
        try applyWineAppDefaults(rendererFolder: rendererFolder)
        try openSteam(play: true)
    }

    /// Installs the recipe's renderer package once and checks its licence. Returns nil for Wine's own renderer.
    public func prepareRenderer() throws -> URL? {
        guard let package = rendererPackage else { return nil }
        let rendererFolder = renderersRoot.appendingPathComponent(package.id, isDirectory: true)
        let packageMarker = rendererFolder.appendingPathComponent(".siliconcellar-package")
        let installedSHA256 = (try? files.read(packageMarker)).map { String(decoding: $0, as: UTF8.self) }
        if installedSHA256 != package.sha256 {
            try installRendererPackage(package, into: rendererFolder, marker: packageMarker)
        }
        try requireAppleLicense(for: package, in: rendererFolder)
        return rendererFolder
    }

    public func acceptAppleLicense() throws {
        try files.createDirectory(root)
        try files.write(Data(RendererPackage.appleGamePortingToolkitLicenseID.utf8), to: appleLicenseMarker)
        sink.say("Apple's Game Porting Toolkit licence is accepted. Games can use D3DMetal.")
    }

    private func installRendererPackage(_ package: RendererPackage, into rendererFolder: URL, marker: URL) throws {
        let archive = try downloadPinnedFile(
            name: package.archiveName,
            url: package.url,
            expected: package.sha256,
            progress: "Downloading the \(package.id) renderer (\(package.version))…",
            mismatch: "The downloaded \(package.id) renderer does not match the pinned SHA-256. Play stopped."
        )
        let partialFolder = renderersRoot.appendingPathComponent(".\(package.id).partial")
        if files.fileExists(partialFolder) { try files.removeItem(partialFolder) }
        try files.createDirectory(partialFolder)
        try commands.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xJf", archive.path, "-C", partialFolder.path],
            environment: ProcessInfo.processInfo.environment,
            timeout: 300,
            workingDirectory: nil
        )
        try files.write(Data(package.sha256.utf8), to: partialFolder.appendingPathComponent(marker.lastPathComponent))
        if files.fileExists(rendererFolder) { try files.removeItem(rendererFolder) }
        try files.moveItem(from: partialFolder, to: rendererFolder)
    }

    private func requireAppleLicense(for package: RendererPackage, in rendererFolder: URL) throws {
        guard let licenseID = package.appleLicenseID else { return }
        let acceptedLicenseID = (try? files.read(appleLicenseMarker)).map {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard acceptedLicenseID != licenseID else { return }
        throw AppleLicenseRequired(
            licenseFile: rendererFolder.appendingPathComponent("License.rtf"),
            licenseID: licenseID,
            gameTitle: recipe.title
        )
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
                try pauseBetweenPolls(0.5)
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
            try pauseBetweenPolls(0.2)
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
        if !isRuntimeCurrent && !isSessionLive { try prepare() }
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
            // Tell the UI before any window poll — a 20s raise kept Play busy and delayed this line.
            sink.say("\(recipe.title) is starting in a Wine desktop.")
            let front = frontmost
            let wineURL = wine
            let windowName = recipe.title
            front.bringToFront(executable: wineURL)
            DispatchQueue.global(qos: .userInitiated).async {
                // Game must be frontmost so Wine can hide the host cursor.
                front.bringGameWindowToFront(
                    executable: wineURL,
                    windowName: windowName,
                    timeout: 20
                )
            }
            return
        }
        // Focus must not block the work queue — a long poll kept status on "Working: …".
        let front = frontmost
        let wineURL = wine
        front.bringToFront(executable: wineURL)
        DispatchQueue.global(qos: .userInitiated).async {
            front.bringSteamUIToFront(executable: wineURL, timeout: 30)
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
            arguments += ["-applaunch", recipe.steamAppID]
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
            // Match the Mac screen. Some titles (MDK) only draw when the desktop matches it.
            return "\(size.width)x\(size.height)"
        }
        if recipe.fitsStandardDesktop {
            guard let size = display.mainDisplaySize() else {
                throw PortError("Could not read the display size for \(recipe.title).")
            }
            let fitted = WineVirtualDesktop.sizeFitting(width: size.width, height: size.height)
            return "\(fitted.width)x\(fitted.height)"
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
        let folder = gameFolder
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

    /// Write recipe seed files under the install folder (Wine launch config fixes).
    public func seedGameFiles() throws {
        let entries = recipe.filesToSeed
        guard !entries.isEmpty else { return }
        let folder = gameFolder
        guard files.fileExists(folder) else { return }
        for (relative, text) in entries.sorted(by: { $0.key < $1.key }) {
            let target = folder.appendingPathComponent(relative)
            try files.createDirectory(target.deletingLastPathComponent())
            try files.write(Data(expandedSeedText(text).utf8), to: target)
            sink.say("Set \(relative) so \(recipe.title) can run under Wine.")
        }
    }

    /// Create recipe folders under the Windows user profile that the game needs but does not create itself.
    public func createProfileFolders() throws {
        for relative in recipe.userProfileFolders {
            let folder = userProfile.appendingPathComponent(relative, isDirectory: true)
            guard !files.fileExists(folder) else { continue }
            try files.createDirectory(folder)
            sink.say("Created \(relative) so \(recipe.title) can run under Wine.")
        }
    }

    private func expandedSeedText(_ text: String) -> String {
        guard text.contains("{displayWidth}") || text.contains("{displayHeight}") else { return text }
        let size = seedDisplaySize()
        return
            text
            .replacingOccurrences(of: "{displayWidth}", with: "\(size.width)")
            .replacingOccurrences(of: "{displayHeight}", with: "\(size.height)")
    }

    /// Seed placeholders follow the Wine desktop the game will actually get.
    private func seedDisplaySize() -> (width: Int, height: Int) {
        if let desktop = try? resolvedVirtualDesktop() {
            let parts = desktop.split(separator: "x")
            if parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) {
                return (width, height)
            }
        }
        return display.mainDisplaySize() ?? (width: 1920, height: 1080)
    }

    /// Per-exe Wine settings under `AppDefaults\<executable>\{Direct3D,Mac Driver,SiliconCellar}`.
    /// `wine reg` writes through a running wineserver, so a game that Steam starts later sees the values.
    public func applyWineAppDefaults(rendererFolder: URL? = nil) throws {
        if let renderer = recipe.d3dRenderer {
            try setAppDefault(section: "Direct3D", name: "renderer", value: renderer)
            sink.say("Wine Direct3D renderer for \(recipe.executable) is \(renderer).")
        }
        for (name, value) in recipe.wineMacDriverOptions.sorted(by: { $0.key < $1.key }) {
            try setAppDefault(section: "Mac Driver", name: name, value: value)
        }
        try applyRenderer(folder: rendererFolder)
    }

    private static let rendererSection = "SiliconCellar"

    /// The Engine reads `DllPath` and `D3DSharedPath` when the game process starts.
    private func applyRenderer(folder rendererFolder: URL?) throws {
        // The key does not exist on first play, so `reg delete` can fail.
        _ = try? runWineRegistry(["delete", appDefaultsKey(section: Self.rendererSection), "/f"])
        guard let rendererFolder, let package = rendererPackage else { return }
        try setAppDefault(
            section: Self.rendererSection,
            name: "DllPath",
            value: rendererFolder.appendingPathComponent("wine").path
        )
        if package.usesD3DMetal {
            try setAppDefault(
                section: Self.rendererSection,
                name: "D3DSharedPath",
                value: rendererFolder.appendingPathComponent("external/libd3dshared.dylib").path
            )
        }
        sink.say("\(recipe.title) uses the \(package.id) renderer (\(package.version)).")
    }

    private func appDefaultsKey(section: String) -> String {
        "HKCU\\Software\\Wine\\AppDefaults\\\(recipe.executable)\\\(section)"
    }

    private func setAppDefault(section: String, name: String, value: String) throws {
        try runWineRegistry(["add", appDefaultsKey(section: section), "/v", name, "/t", "REG_SZ", "/d", value, "/f"])
    }

    @discardableResult
    private func runWineRegistry(_ arguments: [String]) throws -> String {
        try commands.run(
            executable: wine,
            arguments: ["reg"] + arguments,
            environment: wineEnvironment(advertiseAVX: false),
            timeout: 30,
            workingDirectory: nil
        )
    }

    private func startSteamRequest(install: Bool, uninstall: Bool, hud: Bool, log: URL) throws {
        guard let steam else {
            throw PortError("Install Steam before you open the library.")
        }
        let uri =
            install
            ? "steam://install/\(recipe.steamAppID)"
            : "steam://uninstall/\(recipe.steamAppID)"
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
                recipe.steamAppID,
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
            try pauseBetweenPolls(0.2)
        }
        guard steamClient.isFullyRunning(prefix: prefix) else {
            throw PortError("Steam did not open a window. Try Sign in again.")
        }
        try? ensureSteamWebHelperWrapper()
    }

    private func waitForInstall() throws {
        try waitForLauncherWork(timeout: installTimeout, work: "installing") {
            try? repairMisplacedInstall()
            return (try? validateGameInstallation()) != nil
        }
    }

    private func waitForUninstall() throws {
        try waitForLauncherWork(timeout: uninstallTimeout, work: "uninstalling") { isUninstallComplete() }
    }

    /// Polls `done` while the launcher installs or removes the game. `work` is "installing" or "uninstalling".
    func waitForLauncherWork(timeout: TimeInterval, work: String, done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done() { return }
            if !isSessionLive {
                // Launchers often restart when a download ends. Keep checking the files
                // before treating a dead wineserver as a failure.
                if try waitThroughSessionDrop(until: deadline, done: done) { return }
                if !isSessionLive {
                    throw PortError("\(launcherName) closed before \(recipe.title) finished \(work).")
                }
                continue
            }
            try pauseBetweenPolls(installPollInterval)
        }
        throw PortError("\(launcherName) did not finish \(work) \(recipe.title).")
    }

    private func isUninstallComplete() -> Bool {
        let exeGone = game.map { !files.fileExists($0) } ?? true
        let manifestsGone = manifestCandidates.allSatisfy { !files.fileExists($0) }
        return exeGone && manifestsGone
    }

    /// Returns true when `done` succeeds while the session is down.
    /// Returns false when the session comes back before `done` succeeds (caller should resume waiting).
    private func waitThroughSessionDrop(until outerDeadline: Date, done: () -> Bool) throws -> Bool {
        let graceDeadline = Date().addingTimeInterval(sessionDropGrace)
        let deadline = min(graceDeadline, outerDeadline)
        while Date() < deadline {
            if done() { return true }
            if isSessionLive { return false }
            try pauseBetweenPolls(installPollInterval)
        }
        return done()
    }

    public func stop() throws {
        guard files.fileExists(wineserver) else { return }
        endWineSession()
        sink.say("Stopped \(launcherName).")
    }

    private func endWineSession() {
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
    }

    public func stopGame() throws {
        _ = try commands.run(
            executable: wine,
            arguments: ["taskkill", "/F", "/IM", recipe.executable],
            environment: wineEnvironment(advertiseAVX: false),
            timeout: 30,
            workingDirectory: nil
        )
        sink.say("Stopped \(recipe.title). \(launcherName) is still open.")
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
        if recipe.launcherKind == .battleNet, !isGameInstalled {
            throw PortError("Install \(recipe.title) in the Battle.net window, then choose Play.")
        }
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
            throw PortError("Save and close \(recipe.title) and \(launcherName) before you install or repair this environment.")
        }
    }

    private func removeInstalledGameFiles() throws {
        let common = gameFolder
        if files.fileExists(common) { try files.removeItem(common) }
        for candidate in manifestCandidates where files.fileExists(candidate) {
            try files.removeItem(candidate)
        }
    }

    private func repairMisplacedInstall() throws {
        guard let expected = game, !files.fileExists(expected) else { return }
        let misplaced = steamLibrary.appendingPathComponent(recipe.gameRelativePath)
        guard files.fileExists(misplaced) else { return }
        let destination = gameFolder
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

    func downloadPinnedFile(name: String, url: String, expected: String, progress: String, mismatch: String) throws -> URL {
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
        let users = windowsUsers
        guard files.fileExists(users) else { return }
        for user in (try? files.contentsOfDirectory(users)) ?? [] {
            let cache = user.appendingPathComponent("AppData/Local/Steam/htmlcache")
            if files.fileExists(cache) { try files.removeItem(cache) }
        }
    }

    /// The CrossOver-based Engine always names the Windows user "crossover". Older Engines used the Mac user name,
    /// so move that profile once and keep the old name as a link for paths that games and Steam saved.
    private func moveUserProfileToEngineUserName() throws {
        let users = windowsUsers
        let engineProfile = userProfile
        guard !files.fileExists(engineProfile) else { return }
        let oldProfiles = ((try? files.contentsOfDirectory(users)) ?? []).filter {
            $0.lastPathComponent != "Public" && !files.isSymbolicLink($0)
        }
        guard oldProfiles.count == 1, let oldProfile = oldProfiles.first else { return }
        try files.moveItem(from: oldProfile, to: engineProfile)
        try files.createSymbolicLink(oldProfile, destination: engineProfile.lastPathComponent)
    }

    private func isolateUserLinks() throws {
        let users = windowsUsers
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
    case acceptAppleLicense = "accept-apple-license"
}

public struct Library: @unchecked Sendable {
    public let recipes: [Recipe]
    public let dataRootOverride: URL?
    public let home: URL
    public let wine: URL
    public let wineserver: URL
    let files: FileSystem
    let commands: CommandRunning
    let sink: StatusSink
    let frontmost: FrontmostActivating
    private let stopRequests = LauncherStopRequests()

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

    private var dataRoot: URL { dataRootOverride ?? AppPaths.supportRoot(home: home) }

    private var launcherChoices: LauncherChoices {
        LauncherChoices(file: dataRoot.appendingPathComponent(LauncherChoices.fileName), files: files)
    }

    /// The recipe with the launcher that the user chose for it. Steam (or the only launcher) when there is no choice.
    public func applyingLauncherChoice(_ recipe: Recipe) -> Recipe {
        launcherChoices.load()[recipe.id].map(recipe.using) ?? recipe
    }

    public func setLauncher(_ launcher: Launcher, gameID: String) throws {
        let recipe = try recipe(id: gameID)
        guard recipe.supportedLaunchers.contains(launcher) else {
            throw PortError("\(recipe.title) cannot use \(launcher.displayName).")
        }
        try launcherChoices.save(launcher, gameID: gameID)
    }

    public func runtime(for recipe: Recipe) -> Runtime {
        runtimeIgnoringChoice(for: applyingLauncherChoice(recipe))
    }

    private func runtimeIgnoringChoice(for recipe: Recipe) -> Runtime {
        let runtime = Runtime(
            recipe: recipe,
            root: dataRoot,
            wine: wine,
            wineserver: wineserver,
            files: files,
            commands: commands,
            sink: sink,
            frontmost: frontmost
        )
        runtime.stopRequests = stopRequests
        return runtime
    }

    public func stopAllSessions() {
        for launcher in Launcher.allCases {
            guard let recipe = recipes.first(where: { $0.supportedLaunchers.contains(launcher) }) else { continue }
            stopSession(of: runtimeIgnoringChoice(for: recipe.using(launcher)))
        }
    }

    /// Stops the launcher of this game and its games. The other launcher keeps running.
    public func stopSession(gameID: String) throws {
        stopSession(of: runtime(for: try recipe(id: gameID)))
    }

    private func stopSession(of launcherRuntime: Runtime) {
        stopRequests.request(launcherRuntime.recipe.launcherKind)
        guard files.fileExists(launcherRuntime.prefix) else { return }
        try? launcherRuntime.stop()
    }

    public func removeLegacyData() {
        runtime(for: recipes.first ?? Recipe.onboarding).removeLegacyData()
    }

    public func perform(_ action: LibraryAction, gameID: String) throws {
        try performLocked(gameID: gameID) { selected in
            switch action {
            case .check: try selected.check()
            case .setup: try selected.setup()
            case .steam: try selected.openLauncher()
            case .install: try selected.installGame()
            case .uninstall: try selected.uninstallGame()
            case .play: try selected.playGame()
            case .stop: try selected.stopGameOrSession()
            case .logout: try selected.logout()
            case .acceptAppleLicense: try selected.acceptAppleLicense()
            }
        }
    }

    private func performLocked(gameID: String, work: (Runtime) throws -> Void) throws {
        let selected = runtime(for: try recipe(id: gameID))
        try files.createDirectory(selected.root)
        let lock = try SessionLock(root: selected.root, launcher: selected.recipe.launcherKind)
        defer { withExtendedLifetime(lock) {} }
        // A Stop before this action does not end it.
        stopRequests.clear(selected.recipe.launcherKind)
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
    let commands: CommandRunning
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

public enum WineSessionProcess {
    /// True when our wineserver binary is in the process list (real session, not a poll side effect).
    public static func isWineserverRunning(in processList: String, wineserver: URL) -> Bool {
        let resolved = wineserver.resolvingSymlinksInPath().path
        let raw = wineserver.path
        // Engine root: …/Engine/bin/wineserver → …/Engine
        let engineRoot = wineserver.deletingLastPathComponent().deletingLastPathComponent().path
        return processList.split(whereSeparator: \.isNewline).contains { line in
            let command = String(line)
            if command.contains(raw) || command.contains(resolved) { return true }
            // ps often shows: …/Engine/lib/wine/../../bin/wineserver (no "Engine/bin" substring).
            return command.contains("wineserver")
                && !engineRoot.isEmpty
                && command.contains(engineRoot)
        }
    }
}

public enum WineServerSocket {
    public static let defaultDirectory = URL(fileURLWithPath: "/tmp/.wine-\(getuid())", isDirectory: true)

    /// Wine names the server folder after the device and inode of the prefix. The socket exists while that wineserver runs.
    public static func url(prefix: URL, in directory: URL) -> URL? {
        var status = stat()
        guard stat(prefix.path, &status) == 0 else { return nil }
        let device = String(UInt64(status.st_dev), radix: 16)
        let inode = String(UInt64(status.st_ino), radix: 16)
        return directory.appendingPathComponent("server-\(device)-\(inode)/socket")
    }
}

public enum SteamClientProcess {
    public static func isRunning(in processList: String, prefix: URL) -> Bool {
        let prefixPath = prefix.path
        return processList.split(whereSeparator: \.isNewline).contains { line in
            let command = String(line)
            // Require the Silicon Cellar prefix path. Matching bare "steam.exe" also hits
            // dying Wine orphans (Windows-only argv) and briefly flashes "Steam is running".
            return isSteamClient(command) && command.contains(prefixPath)
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
        return !ShellCommand.isShell(lower) && !lower.contains("steampath=")
    }
}

public enum ShellCommand {
    /// A shell line that only names a launcher (for example a script that greps for it) is not the launcher.
    public static func isShell(_ lowercasedCommand: String) -> Bool {
        lowercasedCommand.hasPrefix("/bin/zsh") || lowercasedCommand.hasPrefix("/bin/bash")
            || lowercasedCommand.hasPrefix("zsh") || lowercasedCommand.hasPrefix("bash")
            || lowercasedCommand.contains("zsh -c") || lowercasedCommand.contains("bash -c")
    }
}
