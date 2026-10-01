import Foundation

public struct Recipe: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let steamID: String
    public let installFolder: String
    public let executable: String
    public var executableRelativePath: String?
    public var wineWindowsVersion: String?
    public var steamArguments: [String]?
    public var environment: [String: String]?
    public var dllOverrides: String?
    /// Install-folder files to move aside before play (for example Steam DDrawCompat).
    public var quarantineFiles: [String]?
    /// Relative paths under the install folder written before play (Wine launch fixes).
    public var seedFiles: [String: String]?
    /// When true, start Steam, then run `executable` through Wine instead of `-applaunch`.
    public var directLaunch: Bool?
    /// Wine `Direct3D` renderer for this executable (`gl`, `vulkan`, `gdi`, or `no3d`).
    public var wineD3DRenderer: String?
    /// Wine virtual desktop for direct launch: `WIDTHxHEIGHT`, or `display` to match the Mac screen.
    public var wineVirtualDesktop: String?
    /// Wine Mac driver values for this executable (for example `FullscreenBelowNotch: y`).
    public var macDriverOptions: [String: String]?
    /// Direct3D layer for this executable: `wine` (default) or a `RendererPackage` ID.
    public var renderer: String?

    public init(
        id: String,
        title: String,
        steamID: String,
        installFolder: String,
        executable: String,
        executableRelativePath: String? = nil,
        wineWindowsVersion: String? = "win10",
        steamArguments: [String]? = [
            "-nofriendsui",
            "-nochatui",
            "-noverifyfiles",
        ],
        environment: [String: String]? = [:],
        dllOverrides: String? = "dxgi,d3d11,d3d12=n,b",
        quarantineFiles: [String]? = nil,
        seedFiles: [String: String]? = nil,
        directLaunch: Bool? = nil,
        wineD3DRenderer: String? = nil,
        wineVirtualDesktop: String? = nil
    ) {
        self.id = id
        self.title = title
        self.steamID = steamID
        self.installFolder = installFolder
        self.executable = executable
        self.executableRelativePath = executableRelativePath
        self.wineWindowsVersion = wineWindowsVersion
        self.steamArguments = steamArguments
        self.environment = environment
        self.dllOverrides = dllOverrides
        self.quarantineFiles = quarantineFiles
        self.seedFiles = seedFiles
        self.directLaunch = directLaunch
        self.wineD3DRenderer = wineD3DRenderer
        self.wineVirtualDesktop = wineVirtualDesktop
    }

    public var windowsVersion: String { wineWindowsVersion ?? "win10" }
    public var launchSteamArguments: [String] { steamArguments ?? Runtime.requiredSteamArguments }
    public var extraEnvironment: [String: String] { environment ?? [:] }
    public var graphicsOverrides: String { dllOverrides ?? "dxgi,d3d11,d3d12=n,b" }
    public var launchesDirectly: Bool { directLaunch == true }
    public var filesToQuarantine: [String] { quarantineFiles ?? [] }
    public var filesToSeed: [String: String] { seedFiles ?? [:] }
    public var wineMacDriverOptions: [String: String] { macDriverOptions ?? [:] }
    public var rendererID: String {
        guard let renderer, !renderer.isEmpty else { return RendererPackage.wineID }
        return renderer
    }
    public var d3dRenderer: String? {
        guard let wineD3DRenderer, !wineD3DRenderer.isEmpty else { return nil }
        return wineD3DRenderer
    }
    public var virtualDesktopSize: String? {
        guard let wineVirtualDesktop, !wineVirtualDesktop.isEmpty else { return nil }
        return wineVirtualDesktop
    }
    public var fillsDisplayDesktop: Bool {
        wineVirtualDesktop?.caseInsensitiveCompare(Self.displayDesktopToken) == .orderedSame
    }

    /// Largest standard Wine desktop that fits the Mac screen.
    /// Odd sizes (for example 1920x1242) make some games exit with no window.
    public var fitsStandardDesktop: Bool {
        wineVirtualDesktop?.caseInsensitiveCompare(Self.fitDesktopToken) == .orderedSame
    }

    public static let displayDesktopToken = "display"
    public static let fitDesktopToken = "fit"
    public static let quarantineSuffix = ".siliconcellar-disabled"

    public static let onboardingID = "onboarding"
    public static let onboarding = Recipe(
        id: onboardingID,
        title: "Steam",
        steamID: "0",
        installFolder: "Steam",
        executable: "steam.exe"
    )

    public var gameRelativePath: String {
        if let executableRelativePath, !executableRelativePath.isEmpty { return executableRelativePath }
        return executable
    }

    public func validate(expectedID: String? = nil) throws {
        if let expectedID, expectedID != id {
            throw PortError("Recipe file \(expectedID).json must use id \"\(expectedID)\".")
        }
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw PortError("Recipe id must use ASCII letters, numbers, or hyphens.")
        }
        guard !title.isEmpty else { throw PortError("Recipe \(id) needs a title.") }
        guard !steamID.isEmpty, steamID.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw PortError("Recipe \(id) steamID must be digits only.")
        }
        try Self.validateName(installFolder, field: "installFolder", id: id)
        try Self.validateName(executable, field: "executable", id: id)
        if let executableRelativePath {
            try Self.validateRelativePath(executableRelativePath, id: id)
        }
        for name in filesToQuarantine {
            try Self.validateName(name, field: "quarantineFiles", id: id)
        }
        for path in filesToSeed.keys {
            try Self.validateRelativePath(path, id: id)
        }
        if let wineWindowsVersion, !wineWindowsVersion.hasPrefix("win") {
            throw PortError("Recipe \(id) windows version must start with win.")
        }
        if let d3dRenderer {
            let allowed = Set(["gl", "vulkan", "gdi", "no3d"])
            guard allowed.contains(d3dRenderer) else {
                throw PortError("Recipe \(id) wineD3DRenderer must be gl, vulkan, gdi, or no3d.")
            }
        }
        guard RendererPackage.knownIDs.contains(rendererID) else {
            throw PortError("Recipe \(id) renderer must be one of: \(RendererPackage.knownIDs.joined(separator: ", ")).")
        }
        if let virtualDesktopSize,
            virtualDesktopSize.caseInsensitiveCompare(Self.displayDesktopToken) != .orderedSame,
            virtualDesktopSize.caseInsensitiveCompare(Self.fitDesktopToken) != .orderedSame
        {
            let parts = virtualDesktopSize.split(separator: "x")
            guard parts.count == 2,
                let width = Int(parts[0]), width > 0,
                let height = Int(parts[1]), height > 0
            else {
                throw PortError("Recipe \(id) wineVirtualDesktop must be display, fit, or look like 1920x1080.")
            }
        }
    }

    private static func validateName(_ value: String, field: String, id: String) throws {
        guard !value.isEmpty, value != ".", value != "..",
            !value.contains("/"), !value.contains("\\")
        else {
            throw PortError("Recipe \(id) \(field) is not a safe file name.")
        }
    }

    private static func validateRelativePath(_ value: String, id: String) throws {
        let parts = value.split(separator: "/").map(String.init)
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
            !parts.contains(".."), !parts.contains(".")
        else {
            throw PortError("Recipe \(id) executableRelativePath is not a safe relative path.")
        }
    }
}
