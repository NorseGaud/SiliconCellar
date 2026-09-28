import Darwin
import Foundation

public final class SessionLock {
    private let fileDescriptor: Int32

    public init(root: URL) throws {
        let url = root.appendingPathComponent("operation.lock")
        fileDescriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fileDescriptor >= 0 else { throw PortError("Could not open the operation lock.") }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(fileDescriptor)
            throw PortError("Another install or launch is already in progress. Wait for it to finish.")
        }
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
