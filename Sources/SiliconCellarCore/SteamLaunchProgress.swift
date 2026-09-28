import Foundation

public struct SteamLaunchProgress: Equatable, Sendable {
    public var detail: String
    public var fraction: Double?
    public var waitingForWindow: Bool

    public init(detail: String = "", fraction: Double? = nil, waitingForWindow: Bool = false) {
        self.detail = detail
        self.fraction = fraction
        self.waitingForWindow = waitingForWindow
    }

    public static let freshness: TimeInterval = 90

    public static func inspect(
        bootstrapLog: URL?,
        htmlLog: URL?,
        sessionLog: URL?,
        wineSessionLive: Bool,
        now: Date = Date(),
        files: FileSystem = FoundationFileSystem()
    ) -> SteamLaunchProgress {
        parse(
            bootstrap: text(bootstrapLog, files: files),
            html: text(htmlLog, files: files),
            session: text(sessionLog, files: files),
            live: wineSessionLive,
            now: now,
            sessionFresh: isFresh(sessionLog, now: now, files: files)
        )
    }

    public static func parse(
        bootstrap: String,
        html: String,
        session: String,
        live: Bool,
        now: Date = Date(),
        maxAge: TimeInterval = freshness,
        sessionFresh: Bool = false
    ) -> SteamLaunchProgress {
        guard live else { return SteamLaunchProgress() }
        var events: [Event] = []
        collect(bootstrap, untimestamped: false, now: now, maxAge: maxAge, sessionFresh: false, into: &events)
        collect(html, untimestamped: false, now: now, maxAge: maxAge, sessionFresh: false, into: &events)
        collect(session, untimestamped: true, now: now, maxAge: maxAge, sessionFresh: sessionFresh, into: &events)
        guard let event = events.max() else { return SteamLaunchProgress() }
        return event.progress
    }

    private static func text(_ url: URL?, files: FileSystem) -> String {
        guard let url, files.fileExists(url), let data = try? files.read(url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func collect(
        _ text: String,
        untimestamped: Bool,
        now: Date,
        maxAge: TimeInterval,
        sessionFresh: Bool,
        into events: inout [Event]
    ) {
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let recognized = recognize(line) else { continue }
            if let stamp = timestamp(in: line), let date = parseStamp(stamp) {
                if now.timeIntervalSince(date) > maxAge { continue }
            } else if untimestamped {
                if !sessionFresh { continue }
            } else {
                continue
            }
            events.append(
                Event(
                    date: timestamp(in: line) ?? (untimestamped ? "9999" : "0000"),
                    rank: recognized.rank,
                    progress: recognized.progress
                )
            )
        }
    }

    private static func isFresh(_ url: URL?, now: Date, files: FileSystem) -> Bool {
        guard let url, files.fileExists(url) else { return false }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return modified.map { now.timeIntervalSince($0) <= freshness } ?? false
    }

    private static func timestamp(in line: String) -> String? {
        guard let start = line.firstIndex(of: "["), let end = line.firstIndex(of: "]") else { return nil }
        let value = String(line[line.index(after: start)..<end])
        return value.count >= 19 ? value : nil
    }

    private static func parseStamp(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: String(text.prefix(19)))
    }

    private static func recognize(_ line: String) -> (progress: SteamLaunchProgress, rank: Int)? {
        if line.contains("Downloading update"), let fraction = downloadFraction(in: line) {
            let percent = Int((fraction * 100).rounded())
            return (
                SteamLaunchProgress(detail: "Steam is downloading a client update (\(percent)%).", fraction: fraction),
                80
            )
        }
        if line.contains("Downloading update") {
            return (SteamLaunchProgress(detail: "Steam is downloading a client update."), 70)
        }
        if line.contains("Extracting package") {
            return (SteamLaunchProgress(detail: "Steam is extracting the client update."), 70)
        }
        if line.contains("Installing update") {
            return (SteamLaunchProgress(detail: "Steam is installing the client update."), 70)
        }
        if line.contains("Unhandled exception") || line.contains("Restart webhelper") || line.contains("Timed out waiting for webhelper") {
            return (
                SteamLaunchProgress(
                    detail: "Steam UI helper failed. Steam is starting it again. This can take a while.",
                    waitingForWindow: true
                ),
                90
            )
        }
        if line.contains("Started webhelper") || line.contains("Update complete") {
            return (
                SteamLaunchProgress(
                    detail: "Steam is starting the login window. This can take a while.",
                    waitingForWindow: true
                ),
                60
            )
        }
        if line.contains("Verifying installation") {
            return (SteamLaunchProgress(detail: "Steam is verifying the client."), 50)
        }
        if line.contains("Verification complete") || line.contains("Nothing to do") {
            return (
                SteamLaunchProgress(
                    detail: "Steam is starting the login window. This can take a while.",
                    waitingForWindow: true
                ),
                50
            )
        }
        if line.contains("Steam Client launched") {
            return (SteamLaunchProgress(detail: "Steam started. The client is loading."), 40)
        }
        return nil
    }

    private static func downloadFraction(in line: String) -> Double? {
        let parts = line.replacingOccurrences(of: ",", with: "").split(whereSeparator: { !$0.isNumber })
        guard parts.count >= 2,
            let done = Double(parts[parts.count - 2]),
            let total = Double(parts[parts.count - 1]),
            total > 0, done >= 0, done <= total
        else { return nil }
        return done / total
    }
}

private struct Event: Comparable {
    var date: String
    var rank: Int
    var progress: SteamLaunchProgress

    static func < (lhs: Event, rhs: Event) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.rank < rhs.rank
    }
}
