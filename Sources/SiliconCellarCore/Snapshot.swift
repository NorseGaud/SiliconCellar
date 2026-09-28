import Foundation

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
    public var gameRunning: Bool

    public init(
        stage: GameStage,
        downloadFraction: Double? = nil,
        wineSessionLive: Bool = false,
        gameRunning: Bool = false
    ) {
        self.stage = stage
        self.downloadFraction = downloadFraction
        self.wineSessionLive = wineSessionLive
        self.gameRunning = gameRunning
    }

    public var needsSetup: Bool { stage == .setup }
    public var isSignedIn: Bool { stage != .setup && stage != .signIn }
    public var isInstalled: Bool { stage == .ready || stage == .running }
    public var isRunning: Bool { stage == .running || gameRunning }

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
                gameRunning: false
            )
        }
        if activity == "uninstall" {
            return LibrarySnapshot(
                stage: snapshot.isInstalled || snapshot.stage == .running ? .ready : snapshot.stage,
                wineSessionLive: snapshot.wineSessionLive,
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
        steamID: String,
        installFolder: String,
        wineSessionLive: Bool,
        gameRunning: Bool = false,
        now: Date = Date(),
        files: FileSystem = FoundationFileSystem()
    ) -> LibrarySnapshot {
        let text = (manifest.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
        let flags = Int(SteamManifest.value("StateFlags", in: text) ?? "0") ?? 0
        let downloaded = Double(SteamManifest.value("BytesDownloaded", in: text) ?? "0") ?? 0
        let total = Double(SteamManifest.value("BytesToDownload", in: text) ?? "0") ?? 0
        if flags == 4, let gameExecutable, files.fileExists(gameExecutable) {
            return LibrarySnapshot(
                stage: gameRunning ? .running : .ready,
                wineSessionLive: wineSessionLive,
                gameRunning: gameRunning
            )
        }
        guard runtimeReady || signedIn else {
            return LibrarySnapshot(stage: .setup, wineSessionLive: wineSessionLive)
        }
        if flags != 4 && total > 0 {
            let modified = manifest.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }?.contentModificationDate
            let age = modified.map { now.timeIntervalSince($0) }
            let fresh = age.map { $0 >= 0 && $0 <= 60 } ?? false
            let valid =
                SteamManifest.value("BytesDownloaded", in: text) != nil
                && downloaded.isFinite && total.isFinite && downloaded >= 0 && downloaded <= total
            return LibrarySnapshot(
                stage: .downloading,
                downloadFraction: fresh && valid ? downloaded / total : nil,
                wineSessionLive: wineSessionLive
            )
        }
        if signedIn {
            return LibrarySnapshot(stage: .install, wineSessionLive: wineSessionLive)
        }
        return LibrarySnapshot(stage: .signIn, wineSessionLive: wineSessionLive)
    }
}
