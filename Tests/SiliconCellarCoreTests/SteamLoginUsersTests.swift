import XCTest

@testable import SiliconCellarCore

final class SteamLoginUsersTests: XCTestCase {
    func testMostRecentAccountIsSignedIn() {
        let text = """
            "users"
            {
            \t"76561198000000000"
            \t{
            \t\t"AccountName"\t\t"player"
            \t\t"MostRecent"\t\t"1"
            \t\t"Timestamp"\t\t"0"
            \t}
            }
            """
        XCTAssertTrue(SteamLoginUsers.isSignedIn(text))
    }

    func testNonZeroTimestampIsSignedIn() {
        let text = """
            "users"
            {
            \t"76561198000000000"
            \t{
            \t\t"MostRecent"\t\t"0"
            \t\t"Timestamp"\t\t"1700000000"
            \t}
            }
            """
        XCTAssertTrue(SteamLoginUsers.isSignedIn(text))
    }

    func testMissingOrEmptyIsNotSignedIn() {
        XCTAssertFalse(SteamLoginUsers.isSignedIn(""))
        XCTAssertFalse(SteamLoginUsers.isSignedIn("\"users\" { }"))
        let loggedOff = """
            "users"
            {
            \t"76561198000000000"
            \t{
            \t\t"MostRecent"\t\t"0"
            \t\t"Timestamp"\t\t"0"
            \t}
            }
            """
        XCTAssertFalse(SteamLoginUsers.isSignedIn(loggedOff))
    }
}
