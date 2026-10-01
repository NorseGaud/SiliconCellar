import Foundation

/// Total size of the files in a folder, for download progress.
enum FileSystemSize {
    static func bytes(in folder: URL) -> Int64? {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

public enum GameStage: String, Equatable, Sendable {
    case setup
    case signIn
    case install
    case downloading
    case ready
    case running

    public var isOnboarding: Bool {
        self == .setup || self == .signIn
    }
}

public struct LibrarySnapshot: Equatable, Sendable {
    public var stage: GameStage
    public var downloadFraction: Double?
    public var wineSessionLive: Bool
    /// Steam.exe (and UI helper) are up — stronger than wineserver alone.
    public var launcherReady: Bool
    /// A Wine/Steam window is on screen (not only processes).
    public var launcherWindowVisible: Bool
    public var gameRunning: Bool

    public init(
        stage: GameStage,
        downloadFraction: Double? = nil,
        wineSessionLive: Bool = false,
        launcherReady: Bool = false,
        launcherWindowVisible: Bool = false,
        gameRunning: Bool = false
    ) {
        self.stage = stage
        self.downloadFraction = downloadFraction
        self.wineSessionLive = wineSessionLive
        self.launcherReady = launcherReady
        self.launcherWindowVisible = launcherWindowVisible
        self.gameRunning = gameRunning
    }

    public var needsSetup: Bool { stage == .setup }
    public var isSignedIn: Bool { stage != .setup && stage != .signIn }
    public var isInstalled: Bool { stage == .ready || stage == .running }
    public var isRunning: Bool { stage == .running || gameRunning }
    /// Processes up and a Steam/Wine window is visible.
    public var launcherIsUp: Bool { launcherReady && launcherWindowVisible }

    public static func display(_ snapshot: LibrarySnapshot, activity: String, busy: Bool) -> LibrarySnapshot {
        guard busy else { return snapshot }
        if activity == "install" {
            if snapshot.isInstalled {
                return snapshot
            }
            return LibrarySnapshot(
                stage: .downloading,
                downloadFraction: snapshot.downloadFraction,
                wineSessionLive: snapshot.wineSessionLive,
                launcherReady: snapshot.launcherReady,
                launcherWindowVisible: snapshot.launcherWindowVisible,
                gameRunning: false
            )
        }
        if activity == "uninstall" {
            return LibrarySnapshot(
                stage: snapshot.isInstalled || snapshot.stage == .running ? .ready : snapshot.stage,
                wineSessionLive: snapshot.wineSessionLive,
                launcherReady: snapshot.launcherReady,
                launcherWindowVisible: snapshot.launcherWindowVisible,
                gameRunning: false
            )
        }
        return snapshot
    }

    public static func inspect(
        root: URL,
        runtimeReady: Bool,
        signedIn: Bool,
        gameExecutable: URL?,
        manifest: URL?,
        /// Launchers without a Steam manifest give the install state here.
        installComplete: Bool? = nil,
        steamID: String,
        installFolder: String,
        wineSessionLive: Bool,
        launcherReady: Bool = false,
        launcherWindowVisible: Bool = false,
        gameRunning: Bool = false,
        now: Date = Date(),
        files: FileSystem = FoundationFileSystem()
    ) -> LibrarySnapshot {
        let text = (manifest.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
        let flags = Int(SteamManifest.value("StateFlags", in: text) ?? "0") ?? 0
        let downloaded = Double(SteamManifest.value("BytesDownloaded", in: text) ?? "0") ?? 0
        let total = Double(SteamManifest.value("BytesToDownload", in: text) ?? "0") ?? 0
        let gameFileExists = gameExecutable.map(files.fileExists) ?? false
        if installComplete ?? (flags == 4 && gameFileExists) {
            return LibrarySnapshot(
                stage: gameRunning ? .running : .ready,
                wineSessionLive: wineSessionLive,
                launcherReady: launcherReady,
                launcherWindowVisible: launcherWindowVisible,
                gameRunning: gameRunning
            )
        }
        guard runtimeReady || signedIn else {
            return LibrarySnapshot(
                stage: .setup,
                wineSessionLive: wineSessionLive,
                launcherReady: launcherReady,
                launcherWindowVisible: launcherWindowVisible
            )
        }
        if flags != 4 && total > 0 {
            let modified = manifest.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }?.contentModificationDate
            let age = modified.map { now.timeIntervalSince($0) }
            let fresh = age.map { $0 >= 0 && $0 <= 60 } ?? false
            let valid =
                SteamManifest.value("BytesDownloaded", in: text) != nil
                && downloaded.isFinite && total.isFinite && downloaded >= 0 && downloaded <= total
            // Steam writes BytesDownloaded only when the download ends, so read the folder it fills instead.
            let inProgress = manifest?.deletingLastPathComponent().appendingPathComponent("downloading/\(steamID)")
            let folderBytes = inProgress.flatMap(FileSystemSize.bytes(in:)) ?? 0
            let fraction = folderBytes > 0 ? min(Double(folderBytes) / total, 1) : (fresh && valid ? downloaded / total : nil)
            return LibrarySnapshot(
                stage: .downloading,
                downloadFraction: fraction,
                wineSessionLive: wineSessionLive,
                launcherReady: launcherReady,
                launcherWindowVisible: launcherWindowVisible
            )
        }
        if signedIn {
            return LibrarySnapshot(
                stage: .install,
                wineSessionLive: wineSessionLive,
                launcherReady: launcherReady,
                launcherWindowVisible: launcherWindowVisible
            )
        }
        return LibrarySnapshot(
            stage: .signIn,
            wineSessionLive: wineSessionLive,
            launcherReady: launcherReady,
            launcherWindowVisible: launcherWindowVisible
        )
    }
}
