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

        Commands:
          list              Show recipes
          check             Show host and game status
          setup             Create the prefix and install Steam
          steam             Open the Steam window
          logout            Clear local Steam sign-in if Steam is not running
          install           Start install in Steam
          uninstall         Start uninstall in Steam
          play              Launch the game through Steam
          stop              Stop Steam
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
        for recipe in recipes { print("\(recipe.id)\t\(recipe.title)\tsteam \(recipe.steamID)") }
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
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}
