import Foundation

/// A pinned Direct3D layer from NorseGaud/siliconcellar-renderers. The Wine Engine loads its `wine/` folder for
/// one game through `HKCU\Software\Wine\AppDefaults\<exe>\SiliconCellar\DllPath`, so Steam keeps the Wine DLLs.
public struct RendererPackage: Equatable, Sendable {
    public let id: String
    public let version: String
    public let sha256: String
    /// Apple licence that the user must accept before a game uses this package (D3DMetal only).
    public let appleLicenseID: String?

    public init(id: String, version: String, sha256: String, appleLicenseID: String? = nil) {
        self.id = id
        self.version = version
        self.sha256 = sha256
        self.appleLicenseID = appleLicenseID
    }

    /// Wine's own layers: wined3d for Direct3D 9 to 11, vkd3d for Direct3D 12. No package.
    public static let wineID = "wine"
    public static let releaseURL = "https://github.com/NorseGaud/siliconcellar-renderers/releases/download/r1"
    /// Apple Game Porting Toolkit licence in the D3DMetal packages (`License.rtf`).
    public static let appleGamePortingToolkitLicenseID = "EA18380"

    public static let all: [RendererPackage] = [
        RendererPackage(
            id: "dxvk",
            version: "DXVK-Sikarugir-async-v1.10.3",
            sha256: "c8a33cded6b40c1beb0d7c3ed9da99c638f9fc9331230fbf0254f46568a2089c"
        ),
        RendererPackage(
            id: "dxmt",
            version: "v0.80-213-g4ddb20e",
            sha256: "85d9ccac646021acb7d7750ae93f9c0291c01c806811b85e2e77adcedf71021b"
        ),
        RendererPackage(
            id: "dxmt-v0.72",
            version: "v0.72",
            sha256: "997e905038754bbce919b7fc8df76d6de3d8ddf379d7e3dc66eedd6da6cc8c94"
        ),
        RendererPackage(
            id: "d3dmetal",
            version: "4.0 beta 2",
            sha256: "3c7813b5439b9e20bdb093cb2b963228f5fb5afa13f367cacd519fe86989d30b",
            appleLicenseID: appleGamePortingToolkitLicenseID
        ),
        RendererPackage(
            id: "d3dmetal-3.0",
            version: "3.0",
            sha256: "cfdf73dfeb36489d38fdb84cc74da51ff25834cd3a4879dbfe237674cf02e711",
            appleLicenseID: appleGamePortingToolkitLicenseID
        ),
    ]

    public static var knownIDs: [String] { [wineID] + all.map(\.id) }

    public var archiveName: String { "\(id).tar.xz" }
    public var url: String { "\(Self.releaseURL)/\(archiveName)" }
    public var usesD3DMetal: Bool { appleLicenseID != nil }
}

/// Play stopped because the user has not accepted Apple's licence for D3DMetal.
public struct AppleLicenseRequired: Error, Equatable {
    public let licenseFile: URL
    public let licenseID: String
    public let gameTitle: String

    public var message: String {
        """
        \(gameTitle) uses Apple D3DMetal. Read Apple's licence first: \(licenseFile.path)
        To accept it, run: siliconcellar accept-apple-license
        Then play again.
        """
    }
}
