import Foundation
import SiliconCellarCore

func argument(_ key: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: key), arguments.count > index + 1 else { return nil }
    return arguments[index + 1]
}

func printUsage() {
    print(
        """
        siliconcellar <command> [--game ID] [--data-root PATH] [--recipes PATH]

        The game's launcher is Steam or Battle.net (see list).

        Commands:
          list              Show recipes and their launcher
          check             Show host and game status
          setup             Create the launcher prefix and install the launcher
          steam             Open the launcher window
          logout            Clear the local launcher sign-in if the launcher is not running
          install           Start the install in the launcher
          uninstall         Start the uninstall in the launcher
          play              Launch the game through the launcher
          stop              Stop the game, or stop the launcher
          accept-apple-license
                            Accept Apple's licence for D3DMetal games
        """)
}

let command = CommandLine.arguments.dropFirst().first ?? ""
if command.isEmpty || command == "help" || command == "--help" {
    printUsage()
    exit(command.isEmpty ? 1 : 0)
}

do {
    var extra: [URL] = []
    if let recipes = argument("--recipes") {
        extra.append(URL(fileURLWithPath: recipes, isDirectory: true))
    }
    let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let store = RecipeStore.standard(extraPaths: extra, executableDirectory: executableDirectory)
    let recipes = try store.loadAll()

    if command == "list" {
        for recipe in recipes {
            let launcher = recipe.launcherKind == .steam ? "steam \(recipe.steamAppID)" : recipe.launcherKind.rawValue
            print("\(recipe.id)\t\(recipe.title)\t\(launcher)")
        }
        exit(0)
    }

    let gameID = argument("--game") ?? recipes[0].id
    let dataRoot = argument("--data-root").map { URL(fileURLWithPath: $0, isDirectory: true) }
    let status = try LiveHostInspector().inspect()
    let pair = try HostCheck.require(status)
    let library = Library(
        recipes: recipes,
        wine: pair.wine,
        wineserver: pair.wineserver,
        dataRootOverride: dataRoot
    )

    guard let action = LibraryAction(rawValue: command) else {
        throw PortError("Unknown command \"\(command)\".")
    }
    try library.perform(action, gameID: gameID)
} catch let error as PortError {
    fputs("ERROR: \(error.message)\n", stderr)
    exit(1)
} catch let error as AppleLicenseRequired {
    fputs("ERROR: \(error.message)\n", stderr)
    exit(1)
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}
