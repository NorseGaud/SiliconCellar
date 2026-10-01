import Foundation

public enum BattleNetInstaller {
    /// Versioned URL, so the file stays the same. Update the version and SHA-256 together, like the Steam pin.
    public static let version = "1.0.66"
    public static let downloadURL = "https://downloader.battle.net/download/installer/win/\(version)/Battle.net-Setup.exe"
    public static let sha256 = "de5d32d4ea5eed5a9e120027fb68b370976dbfecc8f2a8f91305977f0b87fcaf"
    public static let fileName = "Battle.net-Setup.exe"
}

/// `%APPDATA%\Battle.net\Battle.net.config` is JSON. Battle.net writes all values as strings.
public enum BattleNetConfig {
    private static let clientSection = "Client"
    private static let savedAccountNamesKey = "SavedAccountNames"

    /// The Battle.net window can stay black in Wine when hardware acceleration is on.
    public static func disablingHardwareAcceleration(_ data: Data?) throws -> Data {
        try updatingClientSection(data) { $0["HardwareAcceleration"] = "false" }
    }

    public static func removingSavedAccountNames(_ data: Data) throws -> Data {
        try updatingClientSection(data) { $0.removeValue(forKey: savedAccountNamesKey) }
    }

    public static func isSignedIn(_ data: Data) -> Bool {
        let savedAccountNames = clientSection(in: configObject(data))[savedAccountNamesKey] as? String
        return !(savedAccountNames ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func updatingClientSection(_ data: Data?, change: (inout [String: Any]) -> Void) throws -> Data {
        var config = configObject(data)
        var client = clientSection(in: config)
        change(&client)
        config[clientSection] = client
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    /// A missing or broken file gives an empty config. Battle.net writes the other values again.
    private static func configObject(_ data: Data?) -> [String: Any] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func clientSection(in config: [String: Any]) -> [String: Any] {
        config[clientSection] as? [String: Any] ?? [:]
    }
}

public enum BattleNetProcess {
    public static func isClientRunning(in processList: String) -> Bool {
        processCommands(in: processList).contains { $0.contains("battle.net.exe") }
    }

    public static func isInstallerRunning(in processList: String) -> Bool {
        processCommands(in: processList).contains { $0.contains(BattleNetInstaller.fileName.lowercased()) }
    }

    private static func processCommands(in processList: String) -> [String] {
        processList.split(whereSeparator: \.isNewline)
            .map { $0.lowercased() }
            .filter { !ShellCommand.isShell($0) }
    }
}

extension Runtime {
    public var battleNetFolder: URL { programFiles.appendingPathComponent("Battle.net") }

    public var battleNetClient: URL? {
        let client = battleNetFolder.appendingPathComponent("Battle.net.exe")
        return files.fileExists(client) ? client : nil
    }

    public var battleNetConfig: URL {
        userProfile.appendingPathComponent("AppData/Roaming/Battle.net/Battle.net.config")
    }

    var isBattleNetSignedIn: Bool {
        guard let data = try? files.read(battleNetConfig) else { return false }
        return BattleNetConfig.isSignedIn(data)
    }

    /// Battle.net writes `.build.info` in the game folder when the install is complete.
    var isBattleNetGameInstalled: Bool {
        guard let game, files.fileExists(game) else { return false }
        return files.fileExists(gameFolder.appendingPathComponent(".build.info"))
    }

    var isBattleNetClientRunning: Bool {
        ProcessSteamClientInspector.processList(commands: commands).map(BattleNetProcess.isClientRunning) ?? false
    }

    private var battleNetLaunchRequest: String { "--exec=launch \(recipe.battleNetProductCode ?? "")" }

    /// Under Wine, Chromium's GPU process cannot draw into the window of the Battle.net process, so the window stays
    /// white. In-process GPU draws in the process that owns the window.
    static let battleNetChromiumSwitches = ["--in-process-gpu"]

    func ensureBattleNetClient() throws {
        if battleNetClient != nil { return }
        let installer = try downloadPinnedFile(
            name: BattleNetInstaller.fileName,
            url: BattleNetInstaller.downloadURL,
            expected: expectedBattleNetSetupSHA256,
            progress: "Downloading the official Battle.net installer…",
            mismatch: "The downloaded Battle.net installer does not match the pinned SHA-256. Setup stopped without installing it."
        )
        try writeBattleNetConfig()
        try files.createDirectory(logs)
        sink.say("Installing the Battle.net client. Battle.net downloads it from Blizzard.")
        try commands.start(
            executable: wine,
            arguments: [installer.path, "--lang=enUS", "--installpath=C:\\Program Files (x86)\\Battle.net"],
            environment: wineEnvironment(advertiseAVX: false),
            workingDirectory: downloads,
            log: logs.appendingPathComponent("battlenet-setup.log")
        )
        frontmost.bringToFront(executable: wine)
        let deadline = Date().addingTimeInterval(battleNetSetupTimeout)
        while Date() < deadline, battleNetClient == nil || isBattleNetInstallerRunning {
            try pauseBetweenPolls(installPollInterval)
        }
        guard battleNetClient != nil else {
            throw PortError("The Battle.net installer did not finish. Choose Set Up again.")
        }
        sink.say("The Battle.net client is installed.")
    }

    private var isBattleNetInstallerRunning: Bool {
        ProcessSteamClientInspector.processList(commands: commands).map(BattleNetProcess.isInstallerRunning) ?? false
    }

    private func writeBattleNetConfig() throws {
        let current = try? files.read(battleNetConfig)
        try files.createDirectory(battleNetConfig.deletingLastPathComponent())
        try files.write(try BattleNetConfig.disablingHardwareAcceleration(current), to: battleNetConfig)
    }

    /// Starts Battle.net when it does not run. `gamePage` asks Battle.net for the game: it starts an installed game,
    /// or it shows the Install button.
    func openBattleNet(gamePage: Bool) throws {
        guard files.fileExists(readyMarker), let client = battleNetClient else {
            throw PortError("Install Battle.net before you open it.")
        }
        if !isRuntimeCurrent && !isSessionLive { try prepare() }
        if gamePage || !isBattleNetClientRunning {
            try writeBattleNetConfig()
            try files.createDirectory(logs)
            try commands.start(
                executable: wine,
                arguments: [client.path] + Self.battleNetChromiumSwitches + (gamePage ? [battleNetLaunchRequest] : []),
                environment: wineEnvironment(advertiseAVX: false),
                workingDirectory: battleNetFolder,
                log: logs.appendingPathComponent("battlenet-session.log")
            )
        }
        frontmost.bringToFront(executable: wine)
    }

    func installBattleNetGame() throws {
        if !files.fileExists(readyMarker) || battleNetClient == nil { try setup() }
        try openBattleNet(gamePage: true)
        sink.say(
            isSignedIn
                ? "Click Install for \(recipe.title) in the Battle.net window."
                : "Sign in in the Battle.net window, then click Install for \(recipe.title)."
        )
        try waitForLauncherWork(timeout: installTimeout, work: "installing") { isBattleNetGameInstalled }
        sink.say("Battle.net finished installing \(recipe.title).")
    }

    func uninstallBattleNetGame() throws {
        if !isBattleNetGameInstalled {
            sink.say("\(recipe.title) is not installed.")
            return
        }
        try openBattleNet(gamePage: true)
        sink.say("In the Battle.net window, open the gear menu next to Play and choose Uninstall.")
        try waitForLauncherWork(timeout: uninstallTimeout, work: "uninstalling") {
            !(game.map(files.fileExists) ?? false)
        }
        sink.say("Battle.net removed \(recipe.title).")
    }

    func playBattleNetGame() throws {
        try validateGameInstallation()
        let rendererFolder = try prepareRenderer()
        try createProfileFolders()
        try applyWineAppDefaults(rendererFolder: rendererFolder)
        try openBattleNet(gamePage: true)
        sink.say("\(recipe.title) launch requested. Battle.net starts the game.")
    }

    func logoutBattleNet() throws {
        if isSessionLive {
            try openBattleNet(gamePage: false)
            sink.say("Battle.net is open. Sign out in the Battle.net window.")
            return
        }
        if let data = try? files.read(battleNetConfig) {
            try files.write(try BattleNetConfig.removingSavedAccountNames(data), to: battleNetConfig)
        }
        sink.say("Battle.net no longer shows the saved account. To end the sign-in, sign out in the Battle.net window.")
    }
}
