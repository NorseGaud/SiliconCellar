import Foundation

/// The launcher that the user chose for each game that can use more than one. The app and the CLI share the file.
struct LauncherChoices {
    static let fileName = "launcher-choices.json"

    let file: URL
    let files: FileSystem

    func load() -> [String: Launcher] {
        guard let data = try? files.read(file) else { return [:] }
        return (try? JSONDecoder().decode([String: Launcher].self, from: data)) ?? [:]
    }

    func save(_ launcher: Launcher, gameID: String) throws {
        var choices = load()
        choices[gameID] = launcher
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.createDirectory(file.deletingLastPathComponent())
        try files.write(try encoder.encode(choices), to: file)
    }
}
