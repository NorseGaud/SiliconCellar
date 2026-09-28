import XCTest

@testable import SiliconCellarCore

final class SteamLaunchProgressTests: XCTestCase {
    func testEmptyWhenSessionIsDown() {
        let progress = SteamLaunchProgress.parse(
            bootstrap: "[2026-09-28 00:27:04] Downloading update (10 of 100 KB)...",
            html: "",
            session: "",
            live: false
        )
        XCTAssertEqual(progress.detail, "")
        XCTAssertNil(progress.fraction)
    }

    func testIgnoresStaleHelperFailure() {
        let progress = SteamLaunchProgress.parse(
            bootstrap: "[2026-09-28 12:58:33] Restart webhelper process, counter 2",
            html: "[2026-09-28 12:58:33] Restart webhelper process, counter 2",
            session: "wine: Unhandled exception 0x80000003 in thread 10c",
            live: true,
            now: date("2026-09-28 13:23:00")
        )
        XCTAssertEqual(progress.detail, "")
        XCTAssertFalse(progress.waitingForWindow)
    }

    func testParsesDownloadFraction() {
        let progress = SteamLaunchProgress.parse(
            bootstrap: """
                [2026-09-28 00:27:04] Downloading update...
                [2026-09-28 00:27:07] Downloading update (211,731 of 336,229 KB)...
                """,
            html: "",
            session: "",
            live: true,
            now: date("2026-09-28 00:27:07")
        )
        XCTAssertEqual(progress.detail, "Steam is downloading a client update (63%).")
        XCTAssertEqual(progress.fraction ?? 0, 211_731.0 / 336_229.0, accuracy: 0.01)
    }

    func testParsesExtractAndHelperRetry() {
        let extract = SteamLaunchProgress.parse(
            bootstrap: "[2026-09-28 00:27:09] Extracting package...",
            html: "",
            session: "",
            live: true,
            now: date("2026-09-28 00:27:09")
        )
        XCTAssertEqual(extract.detail, "Steam is extracting the client update.")

        let helper = SteamLaunchProgress.parse(
            bootstrap: "[2026-09-28 00:28:34] Verification complete",
            html: "[2026-09-28 00:31:18] Restart webhelper process, counter 2",
            session: "wine: Unhandled exception 0x80000003 in thread 10c",
            live: true,
            now: date("2026-09-28 00:31:18"),
            sessionFresh: true
        )
        XCTAssertEqual(helper.detail, "Steam UI helper failed. Steam is starting it again. This can take a while.")
    }

    func testWaitingForWindow() {
        let progress = SteamLaunchProgress.parse(
            bootstrap: "[2026-09-28 00:28:34] Verification complete",
            html: "[2026-09-28 00:28:34] Started webhelper process 484",
            session: "",
            live: true,
            now: date("2026-09-28 00:28:34")
        )
        XCTAssertEqual(progress.detail, "Steam is starting the login window. This can take a while.")
        XCTAssertTrue(progress.waitingForWindow)
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }
}
