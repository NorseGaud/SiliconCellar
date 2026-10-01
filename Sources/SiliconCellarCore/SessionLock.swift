import Darwin
import Foundation

public final class SessionLock {
    private let fileDescriptor: Int32

    /// One lock for each launcher, so a long Steam install does not block Battle.net.
    public init(root: URL, launcher: Launcher) throws {
        let url = root.appendingPathComponent(launcher.operationLockName)
        fileDescriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fileDescriptor >= 0 else { throw PortError("Could not open the operation lock.") }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(fileDescriptor)
            throw PortError("Another \(launcher.displayName) install or launch is already in progress. Wait for it to finish.")
        }
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
