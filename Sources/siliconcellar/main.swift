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

        The game's launcher is Steam, Battle.net, or the RSI Launcher (see list). Steam is the default when a game has more than one.

        Commands:
          list              Show recipes and the launchers they can use
          launcher [--use steam|battlenet|rsi]
                            Show the launcher of the game, or set it
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
            let launchers = recipe.supportedLaunchers.map { $0 == .steam ? "steam \(recipe.steamAppID)" : $0.rawValue }
            print("\(recipe.id)\t\(recipe.title)\t\(launchers.joined(separator: ", "))")
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

    if command == "launcher" {
        if let choice = argument("--use") {
            guard let launcher = Launcher(rawValue: choice) else {
                throw PortError("Unknown launcher \"\(choice)\". Use steam, battlenet, or rsi.")
            }
            try library.setLauncher(launcher, gameID: gameID)
        }
        print(library.runtime(for: try library.recipe(id: gameID)).recipe.launcherKind.rawValue)
        exit(0)
    }

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
