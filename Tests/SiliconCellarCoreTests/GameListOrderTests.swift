import XCTest

@testable import SiliconCellarCore

final class GameListOrderTests: XCTestCase {
    func testInstalledGamesStayAboveRecentGames() {
        let games = [
            recipe("old-installed"),
            recipe("new-missing"),
            recipe("new-installed"),
            recipe("untouched"),
        ]
        let now = Date(timeIntervalSince1970: 1_000)
        let order = GameListOrder.sorted(
            games,
            installed: ["old-installed", "new-installed"],
            interactions: [
                "old-installed": now,
                "new-missing": now.addingTimeInterval(50),
                "new-installed": now.addingTimeInterval(10),
            ]
        )
        XCTAssertEqual(order.map(\.id), ["new-installed", "old-installed", "new-missing", "untouched"])
    }

    func testInteractionsRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("game-interactions.json")
        var interactions = GameInteractions()
        let date = Date(timeIntervalSince1970: 1_791_033_945)
        interactions.note("star-citizen", at: date)
        try interactions.save(url: url)
        XCTAssertEqual(GameInteractions.load(url: url).times["star-citizen"], date)
    }

    private func recipe(_ id: String) -> Recipe {
        Recipe(id: id, title: id, steamID: "1", installFolder: id, executable: "\(id).exe")
    }
}
