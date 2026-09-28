import Foundation

public enum AppPaths {
    public static let applicationSupportName = "SiliconCellar"

    public static func home(_ fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
    }

    public static func supportRoot(home: URL? = nil, fileManager: FileManager = .default) -> URL {
        (home ?? self.home(fileManager))
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(applicationSupportName)
    }

    public static func gamesRoot(home: URL? = nil, fileManager: FileManager = .default) -> URL {
        supportRoot(home: home, fileManager: fileManager).appendingPathComponent("Games")
    }

    public static func gameRoot(id: String, home: URL? = nil, fileManager: FileManager = .default) -> URL {
        gamesRoot(home: home, fileManager: fileManager).appendingPathComponent(id)
    }

    public static func userRecipes(home: URL? = nil, fileManager: FileManager = .default) -> URL {
        supportRoot(home: home, fileManager: fileManager).appendingPathComponent("Recipes")
    }

    public static func steamCMDRoot(home: URL? = nil, fileManager: FileManager = .default) -> URL {
        supportRoot(home: home, fileManager: fileManager).appendingPathComponent("SteamCMD")
    }

    public static func loginMarker(home: URL? = nil, fileManager: FileManager = .default) -> URL {
        supportRoot(home: home, fileManager: fileManager).appendingPathComponent("steamcmd-logged-in")
    }

    public static func wineApp(home: URL? = nil, fileManager: FileManager = .default) -> URL {
        supportRoot(home: home, fileManager: fileManager).appendingPathComponent("Wine/Wine Staging.app")
    }

    public static func wineBinary(home: URL? = nil, fileManager: FileManager = .default) -> URL {
        wineApp(home: home, fileManager: fileManager)
            .appendingPathComponent("Contents/Resources/wine/bin/wine")
    }

    public static func bundledEngineRoot(bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/Engine")
    }

    public static func bundledWineBinary(bundle: URL) -> URL {
        bundledEngineRoot(bundle: bundle).appendingPathComponent("bin/wine")
    }

    public static func legacyPaths(supportRoot: URL) -> [URL] {
        [
            supportRoot.appendingPathComponent("Games"),
            supportRoot.appendingPathComponent("SteamCMD"),
            supportRoot.appendingPathComponent("steamcmd-logged-in"),
            supportRoot.appendingPathComponent("steam-sign-in-confirmed"),
            supportRoot.appendingPathComponent("downloads/steamcmd.zip"),
        ]
    }
}
