import XCTest

@testable import SiliconCellarCore

final class LibraryActionTests: XCTestCase {
    func testLoginIsNotALibraryAction() {
        XCTAssertNil(LibraryAction(rawValue: "login"))
        XCTAssertEqual(LibraryAction(rawValue: "steam"), .steam)
        XCTAssertEqual(LibraryAction(rawValue: "logout"), .logout)
    }
}
