import Foundation

public enum Homebrew {
    public static let brewExecutables = [
        "/usr/local/homebrew/bin/brew",
        "/usr/local/bin/brew",
        "/opt/homebrew/bin/brew",
    ]

    public static func availableBrews(files: FileSystem) -> [String] {
        brewExecutables.filter { files.fileExists(URL(fileURLWithPath: $0)) }
    }

    public static func invocation(brew: String, arguments: [String]) -> (executable: URL, arguments: [String]) {
        if brew.hasPrefix("/usr/local") {
            return (URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", brew] + arguments)
        }
        return (URL(fileURLWithPath: brew), arguments)
    }

    public static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_COLOR"] = "0"
        environment["HOMEBREW_NO_COLOR"] = "1"
        return environment
    }
}
