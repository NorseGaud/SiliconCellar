import AppKit
import CoreGraphics
import Foundation

public protocol FrontmostActivating: Sendable {
    func bringToFront(executable: URL)
    func bringSteamUIToFront(executable: URL, timeout: TimeInterval)
    /// Activate Wine and raise a window whose title contains `windowName` (game cursor capture).
    func bringGameWindowToFront(executable: URL, windowName: String, timeout: TimeInterval)
}

/// Main display size in points (Wine mac driver units without RetinaMode).
public protocol DisplaySizing: Sendable {
    func mainDisplaySize() -> (width: Int, height: Int)?
}

public struct MainScreenDisplay: DisplaySizing {
    public init() {}

    public func mainDisplaySize() -> (width: Int, height: Int)? {
        guard let screen = NSScreen.main else { return nil }
        let width = max(640, Int(screen.frame.width.rounded()))
        let height = max(480, Int(screen.frame.height.rounded()))
        return (width - (width % 2), height - (height % 2))
    }
}

extension FrontmostActivating {
    public func bringSteamUIToFront(executable: URL, timeout: TimeInterval) {
        bringToFront(executable: executable)
    }

    public func bringGameWindowToFront(executable: URL, windowName: String, timeout: TimeInterval) {
        bringToFront(executable: executable)
    }
}

public enum WineHost {
    public struct RunningApp: Equatable, Sendable {
        public var executable: URL?
        public var bundle: URL?

        public init(executable: URL?, bundle: URL?) {
            self.executable = executable
            self.bundle = bundle
        }
    }

    public static func applicationBundle(containing executable: URL) -> URL? {
        var url = executable
        for _ in 0..<8 {
            if url.pathExtension == "app" { return url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    public static func appsToActivate(wineExecutable: URL, running: [RunningApp]) -> [RunningApp] {
        running.filter { isWineProcess(wineExecutable: wineExecutable, running: $0) }
    }

    public static func isWineProcess(wineExecutable: URL, running: RunningApp) -> Bool {
        let paths = [running.executable, running.bundle].compactMap { $0?.standardizedFileURL }
        guard !paths.isEmpty else { return false }
        if let launcher = applicationBundle(containing: wineExecutable)?.appendingPathComponent("Contents/MacOS") {
            if paths.contains(where: { $0.path.hasPrefix(launcher.path) }) { return false }
        }
        if paths.contains(wineExecutable.standardizedFileURL) { return true }
        guard let root = wineRuntimeRoot(containing: wineExecutable) else { return false }
        return paths.contains { $0.path.hasPrefix(root.path) }
    }

    public static func wineRuntimeRoot(containing executable: URL) -> URL? {
        let folder = executable.deletingLastPathComponent()
        if folder.lastPathComponent == "bin" {
            return folder.deletingLastPathComponent()
        }
        return folder
    }
}

public enum WineTerminal {
    public static let stagingMarker = "winehelp --clear"

    public static func shouldClose(history: String) -> Bool {
        history.contains(stagingMarker)
    }

    public static let closeScript = """
        tell application "System Events"
          if not (exists process "Terminal") then return
        end tell
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (history of t as string) contains "winehelp --clear" then close t
              end try
            end repeat
          end repeat
          if (count of windows) is 0 then quit
        end tell
        """

    public static func closeStagingSessions() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", closeScript]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { process.terminate() }
        } catch {}
    }
}

public struct WorkspaceFrontmost: FrontmostActivating {
    public init() {}

    public func bringToFront(executable: URL) {
        if Thread.isMainThread {
            _ = activateNow(executable: executable)
            WineTerminal.closeStagingSessions()
        } else {
            DispatchQueue.main.async {
                _ = self.activateNow(executable: executable)
                WineTerminal.closeStagingSessions()
            }
        }
    }

    public func bringSteamUIToFront(executable: URL, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let activated = activateNow(executable: executable)
            if activated, SteamUIFocus.hasVisibleWineWindow(for: executable) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        WineTerminal.closeStagingSessions()
    }

    public func bringGameWindowToFront(executable: URL, windowName: String, timeout: TimeInterval) {
        let needle = windowName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            bringToFront(executable: executable)
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            _ = activateNow(executable: executable)
            if SteamUIFocus.raiseWineWindow(titled: needle, wineExecutable: executable) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        WineTerminal.closeStagingSessions()
    }

    @discardableResult
    private func activateNow(executable: URL) -> Bool {
        let work = {
            let running = NSWorkspace.shared.runningApplications.map {
                WineHost.RunningApp(executable: $0.executableURL, bundle: $0.bundleURL)
            }
            let wanted = WineHost.appsToActivate(wineExecutable: executable, running: running)
            var didActivate = false
            for app in NSWorkspace.shared.runningApplications {
                let ref = WineHost.RunningApp(executable: app.executableURL, bundle: app.bundleURL)
                guard wanted.contains(ref) else { continue }
                NSApp.yieldActivation(to: app)
                _ = app.activate()
                didActivate = true
            }
            return didActivate
        }
        if Thread.isMainThread {
            return work()
        }
        var result = false
        DispatchQueue.main.sync { result = work() }
        return result
    }
}

public enum SteamUIFocus {
    public static func wineProcessIDs(for wineExecutable: URL) -> Set<Int32> {
        let running = NSWorkspace.shared.runningApplications.map {
            WineHost.RunningApp(executable: $0.executableURL, bundle: $0.bundleURL)
        }
        return Set(
            NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
                let ref = WineHost.RunningApp(executable: app.executableURL, bundle: app.bundleURL)
                return WineHost.appsToActivate(wineExecutable: wineExecutable, running: running).contains(ref)
                    ? app.processIdentifier
                    : nil
            }
        )
    }

    public static func hasVisibleWineWindow(for wineExecutable: URL) -> Bool {
        let wantedPIDs = wineProcessIDs(for: wineExecutable)
        guard !wantedPIDs.isEmpty else { return false }
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, wantedPIDs.contains(pid),
                (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: Any]
            else { return false }
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            return width > 100 && height > 100
        }
    }

    /// Raise a Wine window whose title contains `title` so the game can capture the cursor.
    @discardableResult
    public static func raiseWineWindow(titled title: String, wineExecutable: URL) -> Bool {
        let wantedPIDs = wineProcessIDs(for: wineExecutable)
        guard !wantedPIDs.isEmpty else { return false }
        let needle = title.lowercased()
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let match = windows.first { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, wantedPIDs.contains(pid),
                (window[kCGWindowLayer as String] as? Int) == 0,
                let name = window[kCGWindowName as String] as? String,
                name.lowercased().contains(needle),
                let bounds = window[kCGWindowBounds as String] as? [String: Any]
            else { return false }
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            return width > 100 && height > 100
        }
        guard let match,
            let pid = match[kCGWindowOwnerPID as String] as? Int32,
            let name = match[kCGWindowName as String] as? String
        else { return false }

        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "System Events"
              set targetProc to first process whose unix id is \(pid)
              set frontmost of targetProc to true
              try
                perform action "AXRaise" of window "\(escaped)" of targetProc
              end try
            end tell
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
