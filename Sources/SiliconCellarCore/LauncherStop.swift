import Foundation

/// Stop asks the running action of a launcher to end its waits. All runtimes of one `Library` share one instance.
public final class LauncherStopRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: Set<Launcher> = []

    public init() {}

    func request(_ launcher: Launcher) { lock.withLock { _ = requested.insert(launcher) } }
    func clear(_ launcher: Launcher) { lock.withLock { _ = requested.remove(launcher) } }
    func isRequested(_ launcher: Launcher) -> Bool { lock.withLock { requested.contains(launcher) } }
}

/// The action ended because the user stopped its launcher. This is not a failure.
public struct LauncherStopped: Error, Sendable {
    public let launcher: Launcher
}
