import AppKit
import Carbon
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

/// Standard `explorer /desktop` sizes. Skip modes that stay invisible on this Mac driver
/// (1920x1200 on a 1920x1242 screen produced no window).
public enum WineVirtualDesktop {
    public static let standardModes: [(width: Int, height: Int)] = [
        (3840, 2160), (2560, 1440), (1920, 1080),
        (1680, 1050), (1600, 1200), (1600, 900), (1440, 900),
        (1366, 768), (1280, 1024), (1280, 960), (1280, 800), (1280, 720),
        (1024, 768), (800, 600), (640, 480),
    ]

    public static func sizeFitting(width: Int, height: Int) -> (width: Int, height: Int) {
        let maxWidth = max(640, width)
        let maxHeight = max(480, height)
        if let mode = standardModes.first(where: { $0.width <= maxWidth && $0.height <= maxHeight }) {
            return mode
        }
        return (640, 480)
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

    /// Steam UI windows belong to steamwebhelper-valve.exe. steam.exe has no windows: if it is
    /// activated last, the menu bar shows "steam" and the Steam window stays behind other apps.
    public static func activationTargets(candidates: [Int32], windowOwner: Int32?) -> [Int32] {
        guard let windowOwner else { return candidates }
        return [windowOwner]
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

/// Hide the Mac menu bar / Dock while a Wine game holds the screen.
public enum SystemChrome {
    private static let lock = NSLock()
    private static var observer: NSObjectProtocol?
    private static var wineExecutable: URL?

    public static func hideMenuBarAndDock(whileWine wine: URL) {
        lock.lock()
        wineExecutable = wine
        lock.unlock()
        SetSystemUIMode(UInt32(kUIModeAllHidden), 0)
        startLeavingWineMonitor()
    }

    public static func showMenuBarAndDock() {
        SetSystemUIMode(UInt32(kUIModeNormal), 0)
    }

    private static func startLeavingWineMonitor() {
        lock.lock()
        let alreadyWatching = observer != nil
        lock.unlock()
        guard !alreadyWatching else { return }
        let handle = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            let wine: URL?
            lock.lock()
            wine = wineExecutable
            lock.unlock()
            guard let wine else {
                showMenuBarAndDock()
                return
            }
            if SteamUIFocus.isWineFrontmost(for: wine) { return }
            showMenuBarAndDock()
        }
        lock.lock()
        if observer == nil {
            observer = handle
        } else {
            NSWorkspace.shared.notificationCenter.removeObserver(handle)
        }
        lock.unlock()
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
        // Raise until a Wine window appears, then stop. Do not keep stealing focus for the
        // full timeout after the user returns to Silicon Cellar.
        let deadline = Date().addingTimeInterval(min(timeout, 8))
        while Date() < deadline {
            // Check before activating, so the last activation targets the window owner.
            let windowWasVisible = SteamUIFocus.hasVisibleWineWindow(for: executable)
            _ = activateNow(executable: executable, raiseLargestWindow: true)
            if windowWasVisible { break }
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
        var raised = false
        while Date() < deadline {
            // Do not raise the largest Wine window (often Steam) — that hides the game.
            _ = activateNow(executable: executable, raiseLargestWindow: false)
            if SteamUIFocus.raiseWineWindow(titled: needle, wineExecutable: executable) {
                raised = true
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if raised {
            // Borderless Wine desktops still leave the Mac menu bar; hide it and clip focus.
            SystemChrome.hideMenuBarAndDock(whileWine: executable)
        }
        WineTerminal.closeStagingSessions()
    }

    @discardableResult
    private func activateNow(executable: URL, raiseLargestWindow: Bool = true) -> Bool {
        let work = {
            let running = NSWorkspace.shared.runningApplications.map {
                WineHost.RunningApp(executable: $0.executableURL, bundle: $0.bundleURL)
            }
            let wanted = WineHost.appsToActivate(wineExecutable: executable, running: running)
            let candidates = NSWorkspace.shared.runningApplications.filter {
                wanted.contains(WineHost.RunningApp(executable: $0.executableURL, bundle: $0.bundleURL))
            }
            // Game focus raises its own titled window; the largest window there is often Steam.
            let windowOwner = raiseLargestWindow ? SteamUIFocus.largestVisibleWineWindowOwner(for: executable) : nil
            let targets = WineHost.activationTargets(
                candidates: candidates.map(\.processIdentifier),
                windowOwner: windowOwner
            ).compactMap { NSRunningApplication(processIdentifier: $0) }
            var didActivate = false
            for app in targets {
                NSApp?.yieldActivation(to: app)
                // activateAllWindows: Steam's UI is often a child Wine window, not the first one.
                _ = app.activate(options: [.activateAllWindows])
                didActivate = true
            }
            if didActivate, raiseLargestWindow {
                _ = SteamUIFocus.raiseVisibleWineWindows(for: executable)
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
    /// Processes that own the visible Wine windows: the Engine processes plus every process named "wine".
    /// Wine processes that the client starts (for example steamwebhelper) report their Windows path as the
    /// executable, so the Engine path does not match them.
    private static func visibleWineProcessIDs(for wineExecutable: URL) -> Set<Int32> {
        let processesNamedWine = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.localizedName == "wine" }
                .map(\.processIdentifier)
        )
        return processesNamedWine.union(wineProcessIDs(for: wineExecutable))
    }

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
        largestVisibleWineWindow(for: wineExecutable) != nil
    }

    /// Process that owns the largest on-screen Wine window (steamwebhelper-valve for the Steam UI).
    public static func largestVisibleWineWindowOwner(for wineExecutable: URL) -> Int32? {
        largestVisibleWineWindow(for: wineExecutable)?.pid
    }

    /// True when the frontmost macOS app is a Wine host process for this runtime.
    public static func isWineFrontmost(for wineExecutable: URL) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let ref = WineHost.RunningApp(executable: front.executableURL, bundle: front.bundleURL)
        return WineHost.isWineProcess(wineExecutable: wineExecutable, running: ref)
    }

    public struct WindowArea: Equatable, Sendable {
        public var name: String
        public var area: Double

        public init(name: String, area: Double) {
            self.name = name
            self.area = area
        }
    }

    /// Largest first, so smaller dialogs and prompts (Install, Uninstall) end on top of the main Steam window.
    public static func raiseOrder(_ windows: [WindowArea]) -> [String] {
        windows.sorted { $0.area > $1.area }.map(\.name).filter { !$0.isEmpty }
    }

    /// Raise the windows of the process that owns the largest on-screen Wine window (Steam UI / game)
    /// without forcing always-on-top.
    @discardableResult
    public static func raiseVisibleWineWindows(for wineExecutable: URL) -> Bool {
        let windows = visibleWineWindows(for: wineExecutable)
        guard let owner = windows.max(by: { $0.area < $1.area })?.pid else { return false }
        let names = raiseOrder(windows.filter { $0.pid == owner }.map { WindowArea(name: $0.name, area: $0.area) })
        return raiseWindows(pid: owner, names: names)
    }

    /// Raise a Wine window whose title contains `title` so the game can capture the cursor.
    @discardableResult
    public static func raiseWineWindow(titled title: String, wineExecutable: URL) -> Bool {
        let wantedPIDs = visibleWineProcessIDs(for: wineExecutable)
        guard !wantedPIDs.isEmpty else { return false }
        let needle = title.lowercased()
        // Glide/D3D games often sit on a non-zero window layer and may start off-screen.
        if let match = firstWineWindow(titled: needle, in: wantedPIDs, onScreenOnly: true)
            ?? firstWineWindow(titled: needle, in: wantedPIDs, onScreenOnly: false),
            let pid = match[kCGWindowOwnerPID as String] as? Int32,
            let name = match[kCGWindowName as String] as? String
        {
            return raiseWindow(pid: pid, name: name)
        }
        return false
    }

    private static func firstWineWindow(
        titled needle: String,
        in wantedPIDs: Set<Int32>,
        onScreenOnly: Bool
    ) -> [String: Any]? {
        let options: CGWindowListOption =
            onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, wantedPIDs.contains(pid),
                let name = window[kCGWindowName as String] as? String,
                windowTitle(name, matches: needle),
                let bounds = window[kCGWindowBounds as String] as? [String: Any]
            else { return false }
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            return width > 100 && height > 100
        }
    }

    /// Match "MDK 2" to a Wine window titled "mdk2".
    private static func windowTitle(_ name: String, matches needle: String) -> Bool {
        let lowerName = name.lowercased()
        let lowerNeedle = needle.lowercased()
        if lowerName.contains(lowerNeedle) { return true }
        let compactName = lowerName.filter { !$0.isWhitespace }
        let compactNeedle = lowerNeedle.filter { !$0.isWhitespace }
        return !compactNeedle.isEmpty && compactName.contains(compactNeedle)
    }

    /// On-screen, normal-layer Wine windows larger than 100x100 points.
    private static func visibleWineWindows(for wineExecutable: URL) -> [(pid: Int32, name: String, area: Double)] {
        let visibleProcessIDs = visibleWineProcessIDs(for: wineExecutable)
        guard !visibleProcessIDs.isEmpty else { return [] }
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, visibleProcessIDs.contains(pid),
                (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: Any]
            else { return nil }
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            guard width > 100, height > 100 else { return nil }
            return (pid, (window[kCGWindowName as String] as? String) ?? "", width * height)
        }
    }

    private static func largestVisibleWineWindow(for wineExecutable: URL) -> (pid: Int32, name: String, area: Double)? {
        visibleWineWindows(for: wineExecutable).max(by: { $0.area < $1.area })
    }

    private static func raiseWindow(pid: Int32, name: String) -> Bool {
        raiseWindows(pid: pid, names: [name])
    }

    /// Make the process frontmost, then AXRaise each named window in order (the last one ends on top).
    private static func raiseWindows(pid: Int32, names: [String]) -> Bool {
        let raiseNamed = names.filter { !$0.isEmpty }.map { name in
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return """
                  try
                    perform action "AXRaise" of window "\(escaped)" of targetProc
                  end try
                """
        }.joined(separator: "\n")
        let script = """
            tell application "System Events"
              set targetProc to first process whose unix id is \(pid)
              set frontmost of targetProc to true
            \(raiseNamed)
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
