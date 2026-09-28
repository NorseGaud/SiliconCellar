import Foundation

public enum SteamManifest {
    public static func value(_ key: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"" + NSRegularExpression.escapedPattern(for: key) + "\"\\s+\"([^\"]*)\"") else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
            let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[valueRange])
    }

    public static func isCompleteInstall(text: String, steamID: String, installFolder: String) -> Bool {
        value("appid", in: text) == steamID
            && value("installdir", in: text) == installFolder
            && value("StateFlags", in: text) == "4"
    }
}
