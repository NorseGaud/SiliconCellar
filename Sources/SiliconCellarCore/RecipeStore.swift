import Foundation

public struct RecipeStore: Sendable {
    public var searchPaths: [URL]

    public init(searchPaths: [URL]) {
        self.searchPaths = searchPaths
    }

    public static func standard(
        extraPaths: [URL] = [],
        home: URL? = nil,
        executableDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> RecipeStore {
        var paths = extraPaths
        paths.append(AppPaths.userRecipes(home: home, fileManager: fileManager))
        if let env = ProcessInfo.processInfo.environment["SILICONCELLAR_RECIPES"] {
            paths.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("Recipes") {
            paths.append(resources)
        }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true).appendingPathComponent("Recipes")
        paths.append(cwd)
        if let executableDirectory {
            paths.append(executableDirectory.appendingPathComponent("Recipes"))
            paths.append(executableDirectory.appendingPathComponent("../Recipes"))
            paths.append(executableDirectory.appendingPathComponent("../../Recipes"))
        }
        #if DEBUG
            paths.append(developmentRecipes())
        #endif
        return RecipeStore(searchPaths: paths)
    }

    public static func developmentRecipes(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Recipes")
    }

    public func loadAll(files: FileSystem = FoundationFileSystem()) throws -> [Recipe] {
        var byID: [String: Recipe] = [:]
        var order: [String] = []
        for directory in searchPaths {
            guard files.fileExists(directory) else { continue }
            let jsonFiles =
                (try? files.contentsOfDirectory(directory))?
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            for file in jsonFiles {
                let recipe = try decode(file: file, files: files)
                if byID[recipe.id] == nil {
                    order.append(recipe.id)
                    byID[recipe.id] = recipe
                }
            }
        }
        let recipes = order.compactMap { byID[$0] }
        guard !recipes.isEmpty else { throw PortError("No game recipes found. Add a JSON file in Recipes/.") }
        return recipes
    }

    public func recipe(id: String, files: FileSystem = FoundationFileSystem()) throws -> Recipe {
        let recipes = try loadAll(files: files)
        guard let match = recipes.first(where: { $0.id == id }) else {
            throw PortError("Unknown game \"\(id)\". Use list to see recipes.")
        }
        return match
    }

    private func decode(file: URL, files: FileSystem) throws -> Recipe {
        let data = try files.read(file)
        let recipe: Recipe
        do {
            recipe = try JSONDecoder().decode(Recipe.self, from: data)
        } catch {
            throw PortError("Recipe \(file.lastPathComponent) is not valid JSON.")
        }
        try recipe.validate(expectedID: file.deletingPathExtension().lastPathComponent)
        return recipe
    }
}
