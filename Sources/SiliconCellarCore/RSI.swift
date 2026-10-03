import Foundation

public enum RSIInstaller {
    /// Versioned URL, so the file stays the same. Update the version and SHA-256 together, like the Steam pin.
    public static let version = "2.17.0"
    public static let downloadURL =
        "https://install.robertsspaceindustries.com/rel/2/RSI%20Launcher-Setup-\(version).exe"
    public static let sha256 = "5dd749ac43158b2e5f6a761d2bc283557b4b59625e95328aecb60cd217f61d21"
    public static let fileName = "RSI Launcher-Setup-\(version).exe"
    /// The installer looks for a process whose name contains "RSI Launcher". Its own file name matches that
    /// search, so it tries to close itself and then stops. Wine runs this extra name for the same file.
    public static let launchFileName = "rsi-setup-\(version).exe"
    /// NSIS `/D=` path. It must be the last installer argument.
    public static let windowsInstallPath = "C:\\Program Files\\Roberts Space Industries\\RSI Launcher"
    public static let companyFolderName = "Roberts Space Industries"
    public static let clientFileName = "RSI Launcher.exe"
    /// NSIS titles the installer window "RSI Launcher Setup". The launcher window uses the same first words.
    public static let windowTitle = "RSI Launcher"
}

public enum RSIProcess {
    public static func isClientRunning(in processList: String) -> Bool {
        processCommands(in: processList).contains { $0.contains(RSIInstaller.clientFileName.lowercased()) }
    }

    public static func isInstallerRunning(in processList: String) -> Bool {
        let names = [RSIInstaller.launchFileName, RSIInstaller.fileName].map { $0.lowercased() }
        return processCommands(in: processList).contains { command in
            names.contains { command.contains($0) }
        }
    }

    private static func processCommands(in processList: String) -> [String] {
        processList.split(whereSeparator: \.isNewline)
            .map { $0.lowercased() }
            .filter { !ShellCommand.isShell($0) }
    }
}

extension Runtime {
    /// 64-bit Program Files. The RSI Launcher installs into this folder.
    public var programFiles64: URL { prefix.appendingPathComponent("drive_c/Program Files") }

    public var rsiCompanyFolder: URL { programFiles64.appendingPathComponent(RSIInstaller.companyFolderName) }

    public var rsiClient: URL? {
        let client = rsiCompanyFolder
            .appendingPathComponent("RSI Launcher")
            .appendingPathComponent(RSIInstaller.clientFileName)
        return files.fileExists(client) ? client : nil
    }

    /// Chromium writes the sign-in into this profile. The cookie file stays after the window closes.
    public var rsiProfile: URL { userProfile.appendingPathComponent("AppData/Roaming/rsilauncher") }

    /// The folder the RSI Launcher must use for the game. Silicon Cellar looks for the game only in this folder.
    var rsiGameWindowsFolder: String {
        "C:\\Program Files\\\(RSIInstaller.companyFolderName)\\\(recipe.installFolder)"
    }

    var isRSISignedIn: Bool {
        ["Network/Cookies", "Cookies"].contains { relative in
            let cookies = rsiProfile.appendingPathComponent(relative)
            guard files.fileExists(cookies), let data = try? files.read(cookies) else { return false }
            return !data.isEmpty
        }
    }

    var isRSIGameInstalled: Bool {
        game.map(files.fileExists) ?? false
    }

    var isRSIClientRunning: Bool {
        ProcessSteamClientInspector.processList(commands: commands).map(RSIProcess.isClientRunning) ?? false
    }

    /// Under Wine, Chromium's GPU process cannot draw into the window of the Electron process, so the window stays
    /// white. In-process GPU draws in the process that owns the window.
    static let rsiChromiumSwitches = ["--in-process-gpu"]

    func ensureRSIClient() throws {
        if rsiClient != nil { return }
        let installer = try downloadPinnedFile(
            name: RSIInstaller.fileName,
            url: RSIInstaller.downloadURL,
            expected: expectedRSISetupSHA256,
            progress: "Downloading the official RSI Launcher installer…",
            mismatch: "The downloaded RSI Launcher installer does not match the pinned SHA-256. Setup stopped without installing it.",
            timeout: rsiInstallerDownloadTimeout
        )
        try files.createDirectory(logs)
        let launchedInstaller = try launchInstallerCopy(of: installer)
        sink.say("Finish the RSI Launcher installer. Keep this folder: \(RSIInstaller.windowsInstallPath).")
        try commands.start(
            executable: wine,
            arguments: [launchedInstaller.path, "/D=\(RSIInstaller.windowsInstallPath)"],
            environment: wineEnvironment(advertiseAVX: false),
            workingDirectory: downloads,
            log: logs.appendingPathComponent("rsi-setup.log")
        )
        let deadline = Date().addingTimeInterval(rsiSetupTimeout)
        let raiseUntil = Date().addingTimeInterval(45)
        var raisedInstallerWindow = false
        var pollsWithoutInstaller = 0
        let pollsBeforeInstallerIsGone = max(1, Int(15 / max(installPollInterval, 0.05)))
        while Date() < deadline {
            if !raisedInstallerWindow, Date() < raiseUntil {
                raisedInstallerWindow = frontmost.raiseNamedWindow(
                    executable: wine,
                    windowName: RSIInstaller.windowTitle
                )
            }
            if rsiClient != nil, !isRSIInstallerRunning { break }
            if isRSIInstallerRunning {
                pollsWithoutInstaller = 0
            } else if rsiClient == nil {
                pollsWithoutInstaller += 1
                if pollsWithoutInstaller >= pollsBeforeInstallerIsGone {
                    throw PortError("The RSI Launcher installer closed before it finished. Choose Install RSI Launcher again.")
                }
            }
            try pauseBetweenPolls(installPollInterval)
        }
        guard rsiClient != nil else {
            throw PortError("The RSI Launcher installer did not finish. Choose Install RSI Launcher again.")
        }
        sink.say("The RSI Launcher is installed.")
    }

    /// A second directory entry for the pinned installer. The bytes stay one file.
    private func launchInstallerCopy(of installer: URL) throws -> URL {
        let launched = downloads.appendingPathComponent(RSIInstaller.launchFileName)
        if files.fileExists(launched) { try files.removeItem(launched) }
        try files.linkItem(from: installer, to: launched)
        return launched
    }

    private var isRSIInstallerRunning: Bool {
        ProcessSteamClientInspector.processList(commands: commands).map(RSIProcess.isInstallerRunning) ?? false
    }

    func openRSI() throws {
        guard files.fileExists(readyMarker), let client = rsiClient else {
            throw PortError("Install the RSI Launcher before you open it.")
        }
        if !isRuntimeCurrent && !isSessionLive { try prepare() }
        if !isRSIClientRunning {
            try files.createDirectory(logs)
            try commands.start(
                executable: wine,
                arguments: [client.path] + Self.rsiChromiumSwitches,
                environment: wineEnvironment(advertiseAVX: false),
                workingDirectory: client.deletingLastPathComponent(),
                log: logs.appendingPathComponent("rsi-session.log")
            )
        }
        frontmost.bringToFront(executable: wine)
    }

    func installRSIGame() throws {
        if !files.fileExists(readyMarker) || rsiClient == nil { try setup() }
        try openRSI()
        sink.say(
            isSignedIn
                ? "Click Install for \(recipe.title) in the RSI Launcher window. Use this folder: \(rsiGameWindowsFolder)."
                : "Sign in in the RSI Launcher window, then install \(recipe.title) in \(rsiGameWindowsFolder)."
        )
        try waitForLauncherWork(timeout: installTimeout, work: "installing") { isRSIGameInstalled }
        sink.say("RSI Launcher finished installing \(recipe.title).")
    }

    func uninstallRSIGame() throws {
        if !isRSIGameInstalled {
            sink.say("\(recipe.title) is not installed.")
            return
        }
        try openRSI()
        sink.say("In the RSI Launcher window, open Settings and uninstall \(recipe.title).")
        try waitForLauncherWork(timeout: uninstallTimeout, work: "uninstalling") { !isRSIGameInstalled }
        sink.say("RSI Launcher removed \(recipe.title).")
    }

    func playRSIGame() throws {
        try validateGameInstallation()
        let rendererFolder = try prepareRenderer()
        try createProfileFolders()
        try applyWineAppDefaults(rendererFolder: rendererFolder)
        try openRSI()
        sink.say("Click Launch for \(recipe.title) in the RSI Launcher window.")
    }

    func logoutRSI() throws {
        if isSessionLive {
            try openRSI()
            sink.say("RSI Launcher is open. Sign out in the RSI Launcher window.")
            return
        }
        for relative in ["Network/Cookies", "Cookies", "Local Storage", "Session Storage"] {
            let url = rsiProfile.appendingPathComponent(relative)
            if files.fileExists(url) { try files.removeItem(url) }
        }
        sink.say("RSI Launcher no longer has the saved sign-in. To end the sign-in, sign out in the RSI Launcher window.")
    }
}
