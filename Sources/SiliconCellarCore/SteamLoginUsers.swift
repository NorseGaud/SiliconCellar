import Foundation

public enum SteamLoginUsers {
    public static func isSignedIn(_ text: String) -> Bool {
        if SteamManifest.value("MostRecent", in: text) == "1" { return true }
        if let timestamp = SteamManifest.value("Timestamp", in: text), timestamp != "0", !timestamp.isEmpty {
            return true
        }
        return false
    }
}
