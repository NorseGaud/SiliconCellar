import CryptoKit
import Foundation

public enum SteamInstaller {
    public static let downloadURL = "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
    public static let sha256 = "7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb"

    public static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
