import CommonCrypto
import Foundation
import Security

public enum RSIInstaller {
    /// Versioned URL, so the file stays the same. Update the version and SHA-256 together, like the Steam pin.
    public static let version = "2.17.0"
    public static let downloadURL =
        "https://install.robertsspaceindustries.com/rel/2/RSI%20Launcher-Setup-\(version).exe"
    public static let sha256 = "5dd749ac43158b2e5f6a761d2bc283557b4b59625e95328aecb60cd217f61d21"
    /// Byte size of the pinned installer. The log uses it while the file downloads.
    public static let byteCount = 342_574_256
    public static let fileName = "RSI Launcher-Setup-\(version).exe"
    /// The installer looks for a process whose name contains "RSI Launcher". Its own file name matches that
    /// search, so it tries to close itself and then stops. Wine runs this extra name for the same file.
    public static let launchFileName = "rsi-setup-\(version).exe"
    /// NSIS `/D=` path. It must be the last installer argument.
    public static let windowsInstallPath = "C:\\Program Files\\Roberts Space Industries\\RSI Launcher"
    public static let companyFolderName = "Roberts Space Industries"
    public static let clientFileName = "RSI Launcher.exe"
    /// Written after the program files. It shows that the copy finished.
    public static let uninstallerFileName = "Uninstall RSI Launcher.exe"
    /// NSIS titles the installer window "RSI Launcher Setup". The launcher window uses the same first words.
    public static let windowTitle = "RSI Launcher"
}

public enum RSIProcess {
    public static func isClientRunning(in processList: String) -> Bool {
        processCommands(in: processList).contains { $0.contains(RSIInstaller.clientFileName.lowercased()) }
    }

    /// The main process must include `--in-process-gpu`. A separate GPU process cannot draw this window.
    public static func clientDrawsInProcess(in processList: String) -> Bool {
        let client = RSIInstaller.clientFileName.lowercased()
        return processCommands(in: processList).contains { command in
            command.contains(client) && !command.contains("--type=") && command.contains("--in-process-gpu")
        }
    }

    public static func isInstallerRunning(in processList: String) -> Bool {
        let names = [RSIInstaller.launchFileName, RSIInstaller.fileName, "winedbg"].map { $0.lowercased() }
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

/// The RSI Launcher saves the account in `launcher store.json`. The file is encrypted.
/// A sign-in has an identity and a session. The cookie file is written before sign-in.
enum RSILauncherStore {
    static let fileName = "launcher store.json"
    /// electron-store key shipped in the RSI Launcher. It opens the saved account. It is not the account session.
    private static let encryptionKey = "OjPs60LNS7LbbroAuPXDkwLRipgfH6hIFA6wvuBxkg4="

    static func isSignedIn(_ data: Data) -> Bool {
        guard let object = object(from: data) else { return false }
        guard let identity = object["identity"] as? [String: Any] else { return false }
        let name = identity["username"] as? String ?? ""
        guard !name.isEmpty else { return false }
        guard let session = object["session"] as? [String: Any] else { return false }
        let value = session["value"] as? String ?? ""
        return !value.isEmpty
    }

    /// The same file, with the account and session removed.
    static func clearingSignIn(_ data: Data) -> Data? {
        guard var object = object(from: data) else { return nil }
        object["identity"] = NSNull()
        object["session"] = NSNull()
        return encrypted(object)
    }

    static func encrypted(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
            let plain = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        var iv = Data(count: 16)
        let random = iv.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }
        guard random == errSecSuccess, let cipher = crypt(CCOperation(kCCEncrypt), iv: iv, data: plain) else {
            return nil
        }
        var result = iv
        result.append(UInt8(ascii: ":"))
        result.append(cipher)
        return result
    }

    static func object(from data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        guard bytes.count > 17, bytes[16] == UInt8(ascii: ":") else { return nil }
        let iv = Data(bytes[0..<16])
        guard let plain = crypt(CCOperation(kCCDecrypt), iv: iv, data: Data(bytes[17...])) else { return nil }
        return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }

    private static func crypt(_ operation: CCOperation, iv: Data, data: Data) -> Data? {
        let salt = Data(String(decoding: iv, as: UTF8.self).utf8)
        let password = Array(encryptionKey.utf8)
        var key = Data(count: kCCKeySizeAES256)
        let derived = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        10_000,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        kCCKeySizeAES256
                    )
                }
            }
        }
        guard derived == kCCSuccess else { return nil }
        let outputCount = data.count + kCCBlockSizeAES128
        var output = Data(count: outputCount)
        var written = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                iv.withUnsafeBytes { ivBytes in
                    key.withUnsafeBytes { keyBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeAES256,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outBytes.baseAddress, outputCount,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }
}

extension Runtime {
    /// 64-bit Program Files. The RSI Launcher installs into this folder.
    public var programFiles64: URL { prefix.appendingPathComponent("drive_c/Program Files") }

    public var rsiCompanyFolder: URL { programFiles64.appendingPathComponent(RSIInstaller.companyFolderName) }

    public var rsiClient: URL? {
        let client = rsiLauncherFolder.appendingPathComponent(RSIInstaller.clientFileName)
        return files.fileExists(client) ? client : nil
    }

    private var rsiLauncherFolder: URL {
        rsiCompanyFolder.appendingPathComponent("RSI Launcher")
    }

    /// The program files and the uninstaller are both present.
    private var rsiInstallFilesReady: Bool {
        rsiClient != nil && files.fileExists(rsiLauncherFolder.appendingPathComponent(RSIInstaller.uninstallerFileName))
    }

    /// Chromium writes this profile as soon as the window opens.
    public var rsiProfile: URL { userProfile.appendingPathComponent("AppData/Roaming/rsilauncher") }

    /// The folder the RSI Launcher must use for the game. Silicon Cellar looks for the game only in this folder.
    var rsiGameWindowsFolder: String {
        "C:\\Program Files\\\(RSIInstaller.companyFolderName)\\\(recipe.installFolder)"
    }

    var isRSISignedIn: Bool {
        let store = rsiProfile.appendingPathComponent(RSILauncherStore.fileName)
        guard let data = try? files.read(store) else { return false }
        return RSILauncherStore.isSignedIn(data)
    }

    var isRSIGameInstalled: Bool {
        game.map(files.fileExists) ?? false
    }

    var isRSIClientRunning: Bool {
        ProcessSteamClientInspector.processList(commands: commands).map(RSIProcess.isClientRunning) ?? false
    }

    /// Under Wine, Chromium's GPU process cannot draw into the window of the Electron process.
    /// The window stays blank. In-process GPU draws in the process that owns the window.
    static let rsiChromiumSwitches = ["--in-process-gpu"]

    func ensureRSIClient() throws {
        if rsiInstallFilesReady { return }
        let installer = try downloadPinnedFile(
            name: RSIInstaller.fileName,
            url: RSIInstaller.downloadURL,
            expected: expectedRSISetupSHA256,
            progress: "Downloading the official RSI Launcher installer…",
            mismatch: "The downloaded RSI Launcher installer does not match the pinned SHA-256. Setup stopped without installing it.",
            bytes: RSIInstaller.byteCount,
            timeout: rsiInstallerDownloadTimeout
        )
        try files.createDirectory(logs)
        let launchedInstaller = try launchInstallerCopy(of: installer)
        let hiddenPowerShell = try hideWinePowerShellStubs()
        defer { restoreWinePowerShellStubs(hiddenPowerShell) }
        // A crash used to start winedbg and wait. The Installing page then stayed open.
        try disableWineCrashDebugger()
        // The installer then runs the .NET 4.5 web setup. That setup downloads with BITS, and the download does not finish.
        sink.say("The RSI Launcher does not need the .NET Framework download. Setup skips it.")
        try markDotNetProductsPresent()
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
        var installerStopped = false
        while Date() < deadline {
            if !raisedInstallerWindow, Date() < raiseUntil {
                raisedInstallerWindow = frontmost.raiseNamedWindow(
                    executable: wine,
                    windowName: RSIInstaller.windowTitle
                )
            }
            switch rsiInstallerPoll {
            case .running, .unknown:
                // A failed process list is not proof that the installer exited.
                pollsWithoutInstaller = 0
            case .stopped:
                if rsiInstallFilesReady {
                    installerStopped = true
                } else {
                    pollsWithoutInstaller += 1
                    if pollsWithoutInstaller >= pollsBeforeInstallerIsGone {
                        throw PortError("The RSI Launcher installer closed before it finished. Choose Install RSI Launcher again.")
                    }
                }
            }
            if installerStopped { break }
            try pauseBetweenPolls(installPollInterval)
        }
        guard installerStopped else {
            throw PortError("The RSI Launcher installer did not finish. Choose Install RSI Launcher again.")
        }
        sink.say("The RSI Launcher is installed.")
    }

    /// Wine waits when a program crashes and the debugger starts. The installer window then stays on Installing.
    /// A command that exits lets the crashed program close.
    private func disableWineCrashDebugger() throws {
        let key = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug"#
        let environment = wineEnvironment(advertiseAVX: false)
        try commands.run(
            executable: wine,
            arguments: [
                "reg", "add", key, "/v", "Debugger", "/t", "REG_SZ",
                "/d", #"C:\windows\system32\cmd.exe /c exit"#, "/f",
            ],
            environment: environment,
            timeout: 30,
            workingDirectory: nil
        )
        try commands.run(
            executable: wine,
            arguments: ["reg", "add", key, "/v", "Auto", "/t", "REG_DWORD", "/d", "1", "/f"],
            environment: environment,
            timeout: 30,
            workingDirectory: nil
        )
    }

    /// Product codes the .NET 4.5 setup looks up with `MsiGetProductInfo`. Wine stores them squashed, the same way
    /// `squash_guid` does.
    private static let dotNetProductCodes = [
        "FCDAC0A0AD874C333A05DC1548B97920",
        "0D741DA1E0EBC6D3CA11466FCD14361F",
        "5C1093C35543A0E32A41B090A305076A",
        "C28643E881181F13CBC489DC69571E2C",
        "924216F900A444D388FC41D62AEEF129",
        "DFE13B7A64E06F93D920B9B2004D2258",
        "DFC90B5F2B0FFA63D84FD16F6BF37C4B",
    ]

    /// Higher than 4.5.50709. The setup then exits before it downloads `netfx_Full_x64.msi`.
    private static let dotNetReportedVersion = "4.8.04084"

    /// The 32-bit setup reads one of these views. A missing key lets the BITS download start.
    private static let dotNetFrameworkKeys = [
        "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full",
        "HKEY_LOCAL_MACHINE\\SOFTWARE\\Wow6432Node\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full",
    ]

    /// One registry file. `reg import` applies it in one Wine run.
    static var dotNetProductRegistry: String {
        var lines = ["REGEDIT4", ""]
        for code in dotNetProductCodes {
            lines.append("[HKEY_CURRENT_USER\\Software\\Microsoft\\Installer\\Products\\\(code)]")
            lines.append("\"ProductName\"=\"Microsoft .NET Framework 4.5\"")
            lines.append("")
        }
        for key in dotNetFrameworkKeys {
            lines.append("[\(key)]")
            lines.append("\"Version\"=\"\(dotNetReportedVersion)\"")
            lines.append("\"CBS\"=\"1\"")
            lines.append("")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func markDotNetProductsPresent() throws {
        let regFile = downloads.appendingPathComponent("dotnet-products.reg")
        try files.write(Data(Self.dotNetProductRegistry.utf8), to: regFile)
        try commands.run(
            executable: wine,
            arguments: ["reg", "import", regFile.path],
            environment: wineEnvironment(advertiseAVX: false),
            timeout: 30,
            workingDirectory: nil
        )
    }

    /// Wine's `powershell.exe` is a stub. It exits 0 for every command. The installer reads that exit code as
    /// "RSI Launcher is running", then it cannot close the program. Move the stub aside so the installer uses
    /// `tasklist` instead. Put the stub back when setup returns.
    private var winePowerShellStubs: [URL] {
        ["system32", "syswow64"].map { folder in
            prefix.appendingPathComponent("drive_c/windows/\(folder)/WindowsPowerShell/v1.0/powershell.exe")
        }
    }

    private func hideWinePowerShellStubs() throws -> [(original: URL, parked: URL)] {
        var hidden: [(original: URL, parked: URL)] = []
        for original in winePowerShellStubs {
            let parked = original.deletingLastPathComponent().appendingPathComponent("powershell.exe.siliconcellar")
            if files.fileExists(original) {
                if files.fileExists(parked) { try files.removeItem(parked) }
                try files.moveItem(from: original, to: parked)
                hidden.append((original, parked))
            } else if files.fileExists(parked) {
                hidden.append((original, parked))
            }
        }
        return hidden
    }

    private func restoreWinePowerShellStubs(_ hidden: [(original: URL, parked: URL)]) {
        for item in hidden {
            if files.fileExists(item.original) { try? files.removeItem(item.original) }
            try? files.moveItem(from: item.parked, to: item.original)
        }
    }

    /// A second directory entry for the pinned installer. The bytes stay one file.
    private func launchInstallerCopy(of installer: URL) throws -> URL {
        let launched = downloads.appendingPathComponent(RSIInstaller.launchFileName)
        if files.fileExists(launched) { try files.removeItem(launched) }
        try files.linkItem(from: installer, to: launched)
        return launched
    }

    private enum RSIInstallerPoll {
        case running
        case stopped
        case unknown
    }

    /// `ps` on a busy Mac can take longer than the default half second. A timeout is `.unknown`, not stopped.
    private var rsiInstallerPoll: RSIInstallerPoll {
        guard let list = ProcessSteamClientInspector.processList(commands: commands, timeout: 5) else {
            return .unknown
        }
        return RSIProcess.isInstallerRunning(in: list) ? .running : .stopped
    }

    func openRSI() throws {
        guard files.fileExists(readyMarker), let client = rsiClient else {
            throw PortError("Install the RSI Launcher before you open it.")
        }
        if !isRuntimeCurrent && !isSessionLive { try prepare() }
        let list = ProcessSteamClientInspector.processList(commands: commands, timeout: 5)
        let running = list.map(RSIProcess.isClientRunning) ?? false
        let draws = list.map(RSIProcess.clientDrawsInProcess) ?? false
        // The installer starts the launcher with no switches. That process plays audio and leaves a blank window.
        if running && !draws {
            sink.say("The RSI Launcher window did not open. Starting it again.")
            endWineSession()
        }
        if !running || !draws {
            try files.createDirectory(logs)
            try commands.start(
                executable: wine,
                arguments: [client.path] + Self.rsiChromiumSwitches,
                environment: wineEnvironment(advertiseAVX: false),
                workingDirectory: client.deletingLastPathComponent(),
                log: logs.appendingPathComponent("rsi-session.log")
            )
        }
        try raiseRSILauncherWindow()
    }

    /// The Electron window appears after the process starts. Raise it when the title exists.
    private func raiseRSILauncherWindow() throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if frontmost.raiseNamedWindow(executable: wine, windowName: RSIInstaller.windowTitle) {
                return
            }
            try pauseBetweenPolls(0.25)
        }
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

    /// Removes the RSI Launcher program and its saved sign-in. The game files stay.
    func uninstallRSILauncher() throws {
        let clientFolder = rsiLauncherFolder
        let hasClient = files.fileExists(clientFolder)
        let hasProfile = files.fileExists(rsiProfile)
        guard hasClient || hasProfile else {
            sink.say("The RSI Launcher is not installed.")
            return
        }
        if files.fileExists(wineserver) { try stop() }
        if hasClient { try files.removeItem(clientFolder) }
        if files.fileExists(rsiProfile) { try files.removeItem(rsiProfile) }
        sink.say("The RSI Launcher is uninstalled. The game files stay.")
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
        let store = rsiProfile.appendingPathComponent(RSILauncherStore.fileName)
        if let data = try? files.read(store), let cleared = RSILauncherStore.clearingSignIn(data) {
            try files.write(cleared, to: store)
        }
        sink.say("RSI Launcher no longer has the saved sign-in. To end the sign-in, sign out in the RSI Launcher window.")
    }
}
