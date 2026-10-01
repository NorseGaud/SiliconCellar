import XCTest

@testable import SiliconCellarCore

final class RecipeTests: XCTestCase {
    func testWineVirtualDesktopFitsOddLaptopScreen() {
        XCTAssertEqual(WineVirtualDesktop.sizeFitting(width: 1920, height: 1242).width, 1920)
        XCTAssertEqual(WineVirtualDesktop.sizeFitting(width: 1920, height: 1242).height, 1080)
        XCTAssertEqual(WineVirtualDesktop.sizeFitting(width: 2560, height: 1440).width, 2560)
        XCTAssertEqual(WineVirtualDesktop.sizeFitting(width: 2560, height: 1440).height, 1440)
    }

    func testValidRecipe() throws {
        let recipe = Recipe(id: "spacewar", title: "Spacewar", steamID: "480", installFolder: "Spacewar", executable: "Spacewar.exe")
        try recipe.validate(expectedID: "spacewar")
        XCTAssertEqual(recipe.gameRelativePath, "Spacewar.exe")
    }

    func testRelativeExecutablePath() throws {
        let recipe = Recipe(
            id: "example",
            title: "Example",
            steamID: "1",
            installFolder: "Example",
            executable: "game.exe",
            executableRelativePath: "Game/Bin/game.exe"
        )
        try recipe.validate(expectedID: "example")
        XCTAssertEqual(recipe.gameRelativePath, "Game/Bin/game.exe")
    }

    func testRejectsPathTraversal() {
        let recipe = Recipe(
            id: "bad",
            title: "Bad",
            steamID: "1",
            installFolder: "Bad",
            executable: "game.exe",
            executableRelativePath: "../Windows/system32/cmd.exe"
        )
        XCTAssertThrowsError(try recipe.validate())
    }

    func testRejectsNonNumericSteamID() {
        let recipe = Recipe(id: "bad", title: "Bad", steamID: "abc", installFolder: "Bad", executable: "game.exe")
        XCTAssertThrowsError(try recipe.validate())
    }

    func testOnboardingRecipeValidates() throws {
        try Recipe.onboarding.validate(expectedID: Recipe.onboardingID)
        XCTAssertEqual(Recipe.onboarding.id, "onboarding")
        XCTAssertEqual(Recipe.onboarding.steamID, "0")
    }

    func testRejectsIDMismatch() {
        let recipe = Recipe(id: "one", title: "One", steamID: "1", installFolder: "One", executable: "a.exe")
        XCTAssertThrowsError(try recipe.validate(expectedID: "two"))
    }

    func testRendererDefaultsToWine() throws {
        let recipe = Recipe(id: "one", title: "One", steamID: "1", installFolder: "One", executable: "a.exe")
        try recipe.validate()
        XCTAssertEqual(recipe.rendererID, RendererPackage.wineID)
    }

    func testRendererMustBeAKnownPackage() throws {
        var recipe = Recipe(id: "one", title: "One", steamID: "1", installFolder: "One", executable: "a.exe")
        for knownRenderer in ["wine", "dxvk", "dxmt", "dxmt-v0.72", "d3dmetal", "d3dmetal-3.0"] {
            recipe.renderer = knownRenderer
            XCTAssertNoThrow(try recipe.validate(), knownRenderer)
        }
        recipe.renderer = "vulkan"
        XCTAssertThrowsError(try recipe.validate())
    }
}

final class RecipeStoreTests: XCTestCase {
    func testUserRecipeOverridesBundled() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cellar-recipes-\(UUID().uuidString)")
        let bundled = temp.appendingPathComponent("bundled")
        let user = temp.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try bundledJSON(id: "spacewar", title: "Bundled", directory: bundled)
        try bundledJSON(id: "spacewar", title: "Mine", directory: user)

        let store = RecipeStore(searchPaths: [user, bundled])
        let recipes = try store.loadAll()
        XCTAssertEqual(recipes.count, 1)
        XCTAssertEqual(recipes[0].title, "Mine")
    }

    func testEmptyStoreFails() {
        let store = RecipeStore(searchPaths: [URL(fileURLWithPath: "/tmp/siliconcellar-missing-recipes")])
        XCTAssertThrowsError(try store.loadAll())
    }

    func testBundledRecipesValidate() throws {
        let recipesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Recipes")
        let recipes = try RecipeStore(searchPaths: [recipesDirectory]).loadAll()
        let ids = Set(recipes.map(\.id))
        let expected = [
            "spacewar", "aoe4", "aoe2", "aoe3", "coh3", "cs2", "zero-hour", "red-alert2",
            "overwatch", "diablo4", "poe2", "hogwarts-legacy", "skyrim-se",
            "san-andreas-de", "heroes3", "elden-ring", "aom-retold", "mdk", "mdk2",
            "witcher3",
        ]
        XCTAssertEqual(ids, Set(expected))
        XCTAssertEqual(recipes.first { $0.id == "mdk" }?.steamID, "38450")
        XCTAssertEqual(recipes.first { $0.id == "mdk" }?.executable, "MDK3DFX.EXE")
        XCTAssertEqual(recipes.first { $0.id == "mdk" }?.launchesDirectly, true)
        XCTAssertEqual(recipes.first { $0.id == "mdk" }?.filesToQuarantine, ["ddraw.dll"])
        XCTAssertEqual(recipes.first { $0.id == "mdk" }?.d3dRenderer, "gl")
        XCTAssertEqual(recipes.first { $0.id == "mdk" }?.virtualDesktopSize, "display")
        XCTAssertEqual(recipes.first { $0.id == "mdk" }?.fillsDisplayDesktop, true)
        XCTAssertEqual(recipes.first { $0.id == "mdk" }?.extraEnvironment["NGLIDE_BACKEND"], "1")
        XCTAssertEqual(recipes.first { $0.id == "mdk" }?.extraEnvironment["NGLIDE_RESOLUTION"], "1")
        XCTAssertEqual(recipes.first { $0.id == "mdk" }?.extraEnvironment["NGLIDE_ASPECT"], "0")
        XCTAssertEqual(recipes.first { $0.id == "aom-retold" }?.wineMacDriverOptions["FullscreenBelowNotch"], "y")
        XCTAssertEqual(recipes.first { $0.id == "skyrim-se" }?.rendererID, "dxmt-v0.72")
        XCTAssertEqual(
            recipes.first { $0.id == "san-andreas-de" }?.extraEnvironment["SILICONCELLAR_CHILD_ARGS"],
            "SocialClubHelper.exe=--in-process-gpu --use-gl=angle --use-angle=swiftshader"
        )
        XCTAssertEqual(recipes.first { $0.id == "mdk2" }?.steamID, "38460")
        XCTAssertEqual(recipes.first { $0.id == "mdk2" }?.executable, "mdk2Main.exe")
        XCTAssertEqual(recipes.first { $0.id == "mdk2" }?.launchesDirectly, true)
        XCTAssertEqual(recipes.first { $0.id == "mdk2" }?.fillsDisplayDesktop, false)
        XCTAssertEqual(recipes.first { $0.id == "mdk2" }?.fitsStandardDesktop, true)
        XCTAssertEqual(recipes.first { $0.id == "mdk2" }?.d3dRenderer, "gl")
        XCTAssertEqual(
            recipes.first { $0.id == "mdk2" }?.filesToSeed["save/config.lua"]?.contains("{displayWidth}"),
            true
        )
        XCTAssertEqual(recipes.first { $0.id == "cs2" }?.gameRelativePath, "game/bin/win64/cs2.exe")
        XCTAssertEqual(recipes.first { $0.id == "elden-ring" }?.gameRelativePath, "Game/eldenring.exe")
        XCTAssertEqual(recipes.first { $0.id == "hogwarts-legacy" }?.gameRelativePath, "Phoenix/Binaries/Win64/HogwartsLegacy.exe")
        XCTAssertEqual(recipes.first { $0.id == "witcher3" }?.steamID, "292030")
        XCTAssertEqual(recipes.first { $0.id == "witcher3" }?.gameRelativePath, "bin/x64_dx12/witcher3.exe")
        XCTAssertEqual(recipes.first { $0.id == "san-andreas-de" }?.gameRelativePath, "Gameface/Binaries/Win64/SanAndreas.exe")
    }

    private func bundledJSON(id: String, title: String, directory: URL) throws {
        let json = """
            {"id":"\(id)","title":"\(title)","steamID":"480","installFolder":"Spacewar","executable":"Spacewar.exe"}
            """
        try json.write(to: directory.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
    }
}
