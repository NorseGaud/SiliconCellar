import Foundation

public struct GPTKCleanup {
    public static let appPath = "/Applications/Game Porting Toolkit.app"
    public static let caskNames = ["gcenx/wine/game-porting-toolkit", "game-porting-toolkit"]

    private let commands: CommandRunning
    private let files: FileSystem

    public init(commands: CommandRunning = ProcessCommandRunner(), files: FileSystem = FoundationFileSystem()) {
        self.commands = commands
        self.files = files
    }

    public func removeLeftovers(progress: @escaping (String) -> Void) throws {
        let app = URL(fileURLWithPath: Self.appPath)
        if files.fileExists(app) {
            progress("Removing Game Porting Toolkit.app…")
            try? files.removeItem(app)
        }
        guard let brew = Homebrew.availableBrews(files: files).first else { return }
        for cask in Self.caskNames {
            progress("Uninstalling Homebrew cask \(cask)…")
            let invocation = Homebrew.invocation(
                brew: brew,
                arguments: ["uninstall", "--cask", "--force", cask]
            )
            _ = try? commands.run(
                executable: invocation.executable,
                arguments: invocation.arguments,
                environment: Homebrew.environment(),
                timeout: 600,
                workingDirectory: nil
            )
        }
    }
}
