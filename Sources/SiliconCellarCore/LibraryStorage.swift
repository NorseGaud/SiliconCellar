import CryptoKit
import Darwin
import Foundation

/// A drive the user can choose for game files.
public struct StorageDestination: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let folder: URL
    public let available: Int64?
    public let problem: String?

    public init(id: String, title: String, folder: URL, available: Int64?, problem: String?) {
        self.id = id
        self.title = title
        self.folder = folder
        self.available = available
        self.problem = problem
    }
}

/// Where Silicon Cellar keeps launcher prefixes and games.
///
/// The record stays in Application Support. An unplugged drive then does not look like a new install.
/// Wine, recipes, and this record stay on the Mac. Prefixes, downloads, and saves move with the chosen folder.
public struct LibraryStorage {
    public static let folderName = "Silicon Cellar"
    public static let markerName = ".siliconcellar-location.json"
    static let recordID = "library"
    static let reservedNames: Set<String> = ["Wine", "Recipes", "Storage"]
    private static let lastDestinationKey = "siliconcellar.storage.lastDestination"
    private static let lastCustomKey = "siliconcellar.storage.lastCustomBookmark"

    public let metadataRoot: URL
    public let directory: URL
    let defaults: UserDefaults
    private let fm = FileManager.default

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard
    ) {
        metadataRoot = AppPaths.supportRoot(home: home)
        directory = metadataRoot.appendingPathComponent("Storage")
        self.defaults = defaults
    }

    public func runtimeRoot() -> URL {
        guard let record = try? readRecord() else { return metadataRoot }
        if let root = try? resolve(record, mountContainers: false) { return root }
        return URL(fileURLWithPath: record.path)
    }

    /// The folder the user chose. For an ExFAT drive this is the folder on that drive, not the mounted image.
    public func location() -> URL {
        if let record = try? readRecord(), let container = record.container {
            return (try? container.folder()) ?? URL(fileURLWithPath: container.path)
        }
        return runtimeRoot()
    }

    public func displayName() -> String {
        guard let record = try? readRecord() else { return "This Mac" }
        if let container = record.container {
            return (try? container.folder().resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? container.volumeName
        }
        if let root = try? resolve(record, mountContainers: false),
            let values = try? root.resourceValues(forKeys: [.volumeIsInternalKey, .volumeNameKey])
        {
            return values.volumeIsInternal == true ? "This Mac" : (values.volumeName ?? record.volumeName)
        }
        return record.volumeName
    }

    public func issue(mountContainers: Bool = true) -> String? {
        let record: LibraryStorageRecord
        do {
            guard let loaded = try readRecord() else { return nil }
            record = loaded
        } catch {
            return "Storage information could not be read. Your files are unchanged."
        }
        if let container = record.container, !mountContainers {
            if (try? container.folder()) != nil { return nil }
            return connectMessage(record)
        }
        do {
            _ = try resolve(record, mountContainers: mountContainers)
            return nil
        } catch {
            return connectMessage(record)
        }
    }

    /// Opens an ExFAT image when the drive is connected, and updates links when the folder path changed.
    public func activate() throws {
        let recordFile = directory.appendingPathComponent(Self.recordID + ".json")
        guard fm.fileExists(atPath: recordFile.path) else { return }
        do {
            try withLock { try activateUnlocked() }
        } catch is StorageBusy {
            return
        }
    }

    public func hasPayload() -> Bool {
        hasPayload(at: runtimeRoot())
    }

    public func usesContainer() -> Bool {
        (try? readRecord())?.container != nil
    }

    public func destinations() -> [StorageDestination] {
        var choices = [StorageDestination(
            id: "internal",
            title: "This Mac",
            folder: metadataRoot,
            available: StorageFiles.available(metadataRoot),
            problem: problem(for: metadataRoot)
        )]
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeNameKey, .volumeUUIDStringKey]
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: keys),
                values.volumeIsInternal == false,
                values.volumeIsLocal == true
            else { continue }
            let folder = Self.gameFolder(in: volume)
            choices.append(StorageDestination(
                id: values.volumeUUIDString ?? volume.path,
                title: values.volumeName ?? volume.lastPathComponent,
                folder: folder,
                available: StorageFiles.available(volume),
                problem: problem(for: folder)
            ))
        }
        if let data = defaults.data(forKey: Self.lastCustomKey) {
            var stale = false
            if let base = try? URL(
                resolvingBookmarkData: data,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let folder = Self.gameFolder(in: base)
                choices.append(StorageDestination(
                    id: "custom",
                    title: base.lastPathComponent,
                    folder: folder,
                    available: StorageFiles.available(base),
                    problem: problem(for: folder)
                ))
            }
        }
        return choices
    }

    public func suggestedID(_ choices: [StorageDestination]) -> String {
        let saved = defaults.string(forKey: Self.lastDestinationKey)
        return choices.first { $0.id == saved && $0.problem == nil }?.id ?? "internal"
    }

    public static func gameFolder(in base: URL) -> URL {
        base.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func availableBytes(_ url: URL) -> Int64? {
        StorageFiles.available(url)
    }

    public static func volumeFormat(_ folder: URL) throws -> String {
        try StorageFiles.fileSystem(folder)
    }

    public static func sameFolder(_ left: URL, _ right: URL) -> Bool {
        StorageFiles.canonical(left) == StorageFiles.canonical(right)
    }

    public static func validateDestination(_ folder: URL, required: Int64 = 0) throws {
        try StorageFiles.unlinked(folder)
        let ancestor = StorageFiles.existingAncestor(folder)
        let values = try ancestor.resourceValues(forKeys: [
            .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeSupportsCaseSensitiveNamesKey,
        ])
        let format = try StorageFiles.fileSystem(folder)
        guard ["apfs", "exfat"].contains(format),
            values.volumeSupportsCaseSensitiveNames != true,
            values.volumeIsLocal == true
        else {
            throw PortError("Choose a writable APFS or ExFAT drive, or use This Mac.")
        }
        guard values.volumeIsReadOnly != true, FileManager.default.isWritableFile(atPath: ancestor.path) else {
            throw PortError("Silicon Cellar cannot save games here. Choose a writable folder or another drive.")
        }
        guard let free = StorageFiles.available(folder), free >= required else {
            throw PortError("There is not enough free space on this drive. Free space, or choose another location.")
        }
    }

    /// Moves game files when they already exist. Creates the folder when they do not.
    /// Returns the original folder when that copy could not be removed.
    @discardableResult
    public func use(
        choice: StorageDestination,
        headroom: Int64 = 2_000_000_000,
        progress: @escaping (Double, String) -> Void = { _, _ in }
    ) throws -> URL? {
        if let problem = choice.problem { throw PortError(problem) }
        let destination = choice.folder.standardizedFileURL
        let kept: URL?
        do {
            kept = try withLock {
                try useUnlocked(destination: destination, headroom: headroom, progress: progress)
            }
        } catch is StorageBusy {
            throw PortError("Storage is in use. Try again in a moment.")
        }
        defaults.set(choice.id, forKey: Self.lastDestinationKey)
        if choice.id == "custom" {
            let base = destination.deletingLastPathComponent()
            if let bookmark = try? base.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(bookmark, forKey: Self.lastCustomKey)
            }
        }
        return kept
    }

    /// Detaches the disk image and ejects the drive. An open launcher keeps the drive mounted.
    public func eject() throws {
        do {
            try withLock { try ejectUnlocked() }
        } catch is StorageBusy {
            throw PortError("Storage is in use. Try again in a moment.")
        }
    }

    func discardInterruptedMove(source: URL) throws {
        let journalURL = directory.appendingPathComponent(Self.recordID + ".transfer")
        guard fm.fileExists(atPath: journalURL.path) else { return }
        let journal = try JSONDecoder().decode(StorageTransferJournal.self, from: Data(contentsOf: journalURL))
        guard StorageFiles.canonical(URL(fileURLWithPath: journal.source)) == StorageFiles.canonical(source) else { return }
        guard fm.fileExists(atPath: source.path) else { return }
        let sourceAttributes = try fm.attributesOfItem(atPath: source.path)
        guard try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == journal.sourceVolume,
            (sourceAttributes[.systemFileNumber] as? NSNumber)?.uint64Value == journal.sourceInode
        else {
            throw PortError("The original folder changed after a move stopped. Both copies are kept.")
        }
        var stale = false
        let resolved = journal.stageBookmark.flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        if let stage = resolved ?? Optional(URL(fileURLWithPath: journal.stage)), fm.fileExists(atPath: stage.path) {
            try StorageFiles.unlinked(stage)
            let values = try stage.resourceValues(forKeys: [.volumeUUIDStringKey])
            let attributes = try fm.attributesOfItem(atPath: stage.path)
            guard values.volumeUUIDString == journal.volume,
                (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == journal.inode,
                StorageFiles.canonical(stage) != StorageFiles.canonical(source)
            else {
                throw PortError("A previous move left files that could not be identified. The original folder is unchanged.")
            }
            try fm.removeItem(at: stage)
        }
        if journal.container != nil,
            (try? readRecord())?.container?.token != journal.container?.token
        {
            try? journal.container?.remove(store: self)
        }
        let placedRoot = URL(fileURLWithPath: journal.destination)
        let recordPath = (try? readRecord()).map { URL(fileURLWithPath: $0.path) }
        if StorageFiles.canonical(placedRoot) == StorageFiles.canonical(metadataRoot),
            recordPath.map(StorageFiles.canonical) != StorageFiles.canonical(metadataRoot)
        {
            for name in journal.placedNames where fm.fileExists(atPath: source.appendingPathComponent(name).path) {
                try? fm.removeItem(at: metadataRoot.appendingPathComponent(name))
            }
        }
        try? fm.removeItem(at: journalURL)
    }

    private func useUnlocked(
        destination: URL,
        headroom: Int64,
        progress: @escaping (Double, String) -> Void
    ) throws -> URL? {
        let source = runtimeRoot().standardizedFileURL
        try discardInterruptedMove(source: source)
        let sameFolder = StorageFiles.canonical(destination) == StorageFiles.canonical(location())
            || StorageFiles.canonical(destination) == StorageFiles.canonical(source)
        if sameFolder {
            try Self.validateDestination(destination, required: 0)
            return nil
        }
        try rejectReservedOverlap(destination)
        if StorageFiles.processesUse(source) || StorageFiles.processesUse(destination) {
            throw PortError("Save and close your games, then close the launcher, before you move storage.")
        }
        if hasPayload(at: source) {
            return try StorageTransfer(
                store: self,
                source: source,
                destination: destination,
                headroom: headroom,
                progress: progress
            ).run()
        }
        try create(at: destination, headroom: headroom)
        return nil
    }

    private func create(at destination: URL, headroom: Int64) throws {
        try Self.validateDestination(destination, required: headroom)
        try rejectReservedOverlap(destination)
        guard !fm.fileExists(atPath: destination.path) || isMetadata(destination) else {
            throw PortError("A folder with this name already exists. Choose a different location.")
        }
        if try StorageFiles.fileSystem(destination) == "exfat" {
            let (container, root) = try LibraryStorageContainer.create(
                destination: destination,
                store: self,
                required: headroom
            )
            do {
                try StorageFiles.createDirectories(root)
                let token = UUID()
                try writeMarker(token: token, at: root)
                try save(root: root, token: token, container: container)
            } catch {
                try? container.remove(store: self)
                throw error
            }
            return
        }
        let root = destination
        if !isMetadata(root) {
            try StorageFiles.createDirectories(root)
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let token = UUID()
        try writeMarker(token: token, at: root)
        try save(root: root, token: token, container: nil)
    }

    private func activateUnlocked() throws {
        guard var record = try readRecord() else { return }
        let root = try resolve(record, mountContainers: true)
        guard record.path != root.path else { return }
        guard !StorageFiles.processesUse(root) else {
            throw PortError("Close the launcher before you use this drive under its new name.")
        }
        try StorageTree.rebaseLinks(in: root, from: URL(fileURLWithPath: record.path))
        record.path = root.path
        try save(record: record, root: root)
    }

    private func ejectUnlocked() throws {
        guard let container = try readRecord()?.container else {
            throw PortError("This storage does not use a disk image.")
        }
        let folder = try container.folder()
        guard let volume = try folder.resourceValues(forKeys: [.volumeURLKey]).volume else {
            throw PortError("This drive could not be identified.")
        }
        if let mount = try container.attachedMount(store: self) {
            guard !StorageFiles.processesUse(mount.appendingPathComponent("Library")) else {
                throw PortError("Save and close your games, then close the launcher, before you eject this drive.")
            }
            _ = try StorageFiles.command("/usr/bin/hdiutil", ["detach", mount.path])
        }
        _ = try StorageFiles.command("/usr/sbin/diskutil", ["eject", volume.path])
    }

    func readRecord() throws -> LibraryStorageRecord? {
        let file = directory.appendingPathComponent(Self.recordID + ".json")
        guard fm.fileExists(atPath: file.path) else { return nil }
        let record = try JSONDecoder().decode(LibraryStorageRecord.self, from: Data(contentsOf: file))
        guard record.profileID == Self.recordID else {
            throw PortError("Storage information could not be checked.")
        }
        return record
    }

    func resolve(_ record: LibraryStorageRecord, mountContainers: Bool) throws -> URL {
        let url: URL
        if let container = record.container {
            _ = try container.folder()
            let mounted = container.mountPoint(in: self).appendingPathComponent("Library")
            if (try? mounted.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == record.volumeID {
                url = mounted
            } else if !mountContainers {
                throw PortError("Preparing storage…")
            } else {
                url = try container.mount(store: self)
            }
        } else {
            var stale = false
            url = try URL(
                resolvingBookmarkData: record.bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ).standardizedFileURL.resolvingSymlinksInPath()
        }
        try StorageFiles.unlinked(url)
        let volume = try url.resourceValues(forKeys: [.volumeUUIDStringKey])
        guard volume.volumeUUIDString == record.volumeID,
            try marker(at: url) == LibraryStorageMarker(profileID: Self.recordID, token: record.token)
        else {
            throw PortError(connectMessage(record))
        }
        return url
    }

    func save(root: URL, token: UUID, container: LibraryStorageContainer?) throws {
        let values = try root.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        guard let volumeID = values.volumeUUIDString else {
            throw PortError("This drive could not be identified. Your original files are kept.")
        }
        let record = LibraryStorageRecord(
            profileID: Self.recordID,
            token: token,
            bookmark: try root.bookmarkData(
                options: [],
                includingResourceValuesForKeys: [.volumeUUIDStringKey],
                relativeTo: nil
            ),
            volumeID: volumeID,
            volumeName: container?.volumeName ?? values.volumeName ?? "your game drive",
            path: root.path,
            container: container
        )
        try writeRecord(record)
    }

    func save(record: LibraryStorageRecord, root: URL) throws {
        let updated = LibraryStorageRecord(
            profileID: record.profileID,
            token: record.token,
            bookmark: try root.bookmarkData(
                options: [],
                includingResourceValuesForKeys: [.volumeUUIDStringKey],
                relativeTo: nil
            ),
            volumeID: record.volumeID,
            volumeName: record.volumeName,
            path: root.path,
            container: record.container
        )
        try writeRecord(updated)
    }

    func writeMarker(token: UUID, at root: URL) throws {
        let marker = LibraryStorageMarker(profileID: Self.recordID, token: token)
        let file = root.appendingPathComponent(Self.markerName)
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        try JSONEncoder().encode(marker).write(to: file, options: .withoutOverwriting)
    }

    func marker(at root: URL) throws -> LibraryStorageMarker {
        let file = root.appendingPathComponent(Self.markerName)
        try StorageFiles.unlinked(file)
        return try JSONDecoder().decode(LibraryStorageMarker.self, from: Data(contentsOf: file))
    }

    func isMetadata(_ url: URL) -> Bool {
        StorageFiles.canonical(url) == StorageFiles.canonical(metadataRoot)
    }

    func hasPayload(at root: URL) -> Bool {
        guard fm.fileExists(atPath: root.path) else { return false }
        let skip = isMetadata(root) ? Self.reservedNames : []
        let entries = (try? StorageTree.entries(root, skipping: skip)) ?? []
        return entries.contains { entry in
            let name = entry.path.split(separator: "/").first.map(String.init) ?? entry.path
            return name != Self.markerName && !name.hasPrefix(".")
        }
    }

    func rejectReservedOverlap(_ destination: URL) throws {
        for name in Self.reservedNames {
            let folder = metadataRoot.appendingPathComponent(name)
            if StorageFiles.contains(folder, destination) {
                throw PortError("This location overlaps the app's own files. Choose a different folder.")
            }
            if StorageFiles.contains(destination, folder), !isMetadata(destination) {
                throw PortError("This location overlaps the app's own files. Choose a different folder.")
            }
        }
    }

    private func problem(for folder: URL) -> String? {
        do {
            try Self.validateDestination(folder)
            return nil
        } catch {
            return (error as? PortError)?.message ?? error.localizedDescription
        }
    }

    private func connectMessage(_ record: LibraryStorageRecord) -> String {
        "Connect \(record.volumeName) to play. Your games are on this drive. If the drive is connected, check that the Silicon Cellar folder is still there."
    }

    private func writeRecord(_ record: LibraryStorageRecord) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(
            to: directory.appendingPathComponent(Self.recordID + ".json"),
            options: .atomic
        )
    }

    func withLock<T>(_ work: () throws -> T) throws -> T {
        try StorageFiles.unlinked(directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("storage.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PortError("Storage is not available. Try again.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw StorageBusy() }
        defer { flock(fd, LOCK_UN) }
        return try work()
    }
}

struct LibraryStorageRecord: Codable {
    let profileID: String
    let token: UUID
    let bookmark: Data
    let volumeID: String
    let volumeName: String
    var path: String
    var container: LibraryStorageContainer?
}

struct LibraryStorageMarker: Codable, Equatable {
    let profileID: String
    let token: UUID
}

private struct StorageBusy: Error {}

public enum StorageFiles {
    static func unlinked(_ url: URL) throws {
        var cursor = url.standardizedFileURL
        while cursor.path != "/" {
            var info = stat()
            if lstat(cursor.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK || ["/tmp", "/var", "/etc"].contains(cursor.path) else {
                    throw PortError("Choose a folder that is not a link to another location.")
                }
            } else if errno != ENOENT {
                throw PortError("This folder could not be checked. Choose another location.")
            }
            cursor.deleteLastPathComponent()
        }
    }

    public static func canonical(_ url: URL) -> String {
        var cursor = url
        var suffix = [String]()
        while true {
            if let pointer = realpath(cursor.path, nil) {
                defer { free(pointer) }
                return suffix.reversed().reduce(String(cString: pointer)) { $0 + "/" + $1 }
            }
            guard cursor.path != "/" else { return url.path }
            suffix.append(cursor.lastPathComponent)
            cursor.deleteLastPathComponent()
        }
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let parentPath = canonical(parent)
        let childPath = canonical(child)
        return parentPath == childPath || childPath.hasPrefix(parentPath + "/")
    }

    static func existingAncestor(_ url: URL) -> URL {
        var path = url
        while !FileManager.default.fileExists(atPath: path.path), path.path != "/" {
            path.deleteLastPathComponent()
        }
        return path
    }

    public static func available(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: existingAncestor(url).path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    public static func fileSystem(_ folder: URL) throws -> String {
        var status = statfs()
        guard statfs(existingAncestor(folder).path, &status) == 0 else {
            throw PortError("This drive could not be checked. Reconnect it and try again.")
        }
        return withUnsafePointer(to: &status.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
    }

    static func createDirectories(_ destination: URL) throws {
        let fm = FileManager.default
        let ancestor = existingAncestor(destination)
        guard let expected = try ancestor.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
            throw PortError("The destination drive is not available.")
        }
        var missing = [URL]()
        var cursor = destination
        while cursor.path != ancestor.path {
            missing.append(cursor)
            cursor.deleteLastPathComponent()
        }
        for folder in missing.reversed() {
            let parent = folder.deletingLastPathComponent()
            guard try parent.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == expected else {
                throw PortError("The destination drive disconnected. Reconnect it and try again.")
            }
            try unlinked(parent)
            if !fm.fileExists(atPath: folder.path) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            }
        }
    }

    static func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let name = executable.split(separator: "/").last.map(String.init) ?? "storage"
            throw PortError("Storage could not be opened or disconnected. Close the launcher and try again. (\(name): \(process.terminationStatus))")
        }
        return data
    }

    static func processesUse(_ root: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ax", "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let launcherMarkers = ["wineserver", "wine", "steam.exe", "steamwebhelper", "Battle.net", "RSI Launcher"]
            return text.split(separator: "\n").contains { line in
                let command = String(line)
                guard commandUses(root.path, command: command) else { return false }
                return launcherMarkers.contains { command.contains($0) }
            }
        } catch {
            return true
        }
    }

    static func commandUses(_ root: String, command: String) -> Bool {
        var rest = command[...]
        while let range = rest.range(of: root) {
            let end = range.upperBound
            if end == command.endIndex || "/ \t\"'".contains(command[end]) { return true }
            rest = rest[end...]
        }
        return false
    }
}

enum StorageTree {
    struct Entry: Equatable {
        let path: String
        let kind: UInt16
        let size: Int64
        let permissions: UInt16
        let link: String?
    }

    static func entries(_ root: URL, skipping: Set<String>) throws -> [Entry] {
        let fm = FileManager.default
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw PortError("The original folder is not available.")
        }
        var folders = [""]
        var result = [Entry]()
        while let folder = folders.popLast() {
            let folderURL = folder.isEmpty ? root : root.appendingPathComponent(folder)
            for name in try fm.contentsOfDirectory(atPath: folderURL.path) {
                if folder.isEmpty, skipping.contains(name) { continue }
                let relative = folder.isEmpty ? name : folder + "/" + name
                let url = root.appendingPathComponent(relative)
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_dev == rootInfo.st_dev else {
                    throw PortError("A game file is not available, or it is on another drive. Nothing was moved.")
                }
                let kind = info.st_mode & S_IFMT
                guard [S_IFREG, S_IFDIR, S_IFLNK].contains(kind) else {
                    throw PortError("Close the game and its launcher before you move storage. A file is still in use.")
                }
                let link = kind == S_IFLNK ? try fm.destinationOfSymbolicLink(atPath: url.path) : nil
                if kind == S_IFDIR { folders.append(relative) }
                result.append(Entry(
                    path: relative,
                    kind: kind,
                    size: kind == S_IFREG ? Int64(info.st_size) : 0,
                    permissions: info.st_mode & 0o7777,
                    link: link
                ))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func stamps(_ root: URL, entries: [Entry]) throws -> [String: String] {
        var values = [String: String]()
        for entry in entries where entry.kind == S_IFREG {
            var info = stat()
            guard lstat(root.appendingPathComponent(entry.path).path, &info) == 0 else {
                throw PortError("A game file changed during the move.")
            }
            values[entry.path] = "\(info.st_ino):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        }
        return values
    }

    static func portableLink(_ target: String, at relativePath: String, from source: URL) -> String {
        let aliases = [source.standardizedFileURL.path, StorageFiles.canonical(source)]
        guard let old = aliases.first(where: { target == $0 || target.hasPrefix($0 + "/") }) else { return target }
        let suffix = String(target.dropFirst(old.count)).split(separator: "/").map(String.init)
        let parent = relativePath.split(separator: "/").dropLast().map(String.init)
        var shared = 0
        while shared < min(parent.count, suffix.count), parent[shared] == suffix[shared] { shared += 1 }
        let parts = Array(repeating: "..", count: parent.count - shared) + suffix.dropFirst(shared)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    static func rebaseLinks(in root: URL, from source: URL) throws {
        let fm = FileManager.default
        for entry in try entries(root, skipping: []) {
            guard let target = entry.link else { continue }
            let replacement = portableLink(target, at: entry.path, from: source)
            if replacement != target {
                let url = root.appendingPathComponent(entry.path)
                try fm.removeItem(at: url)
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: replacement)
            }
        }
    }

    static func hash(_ file: URL, tick: (Int64) -> Void = { _ in }) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { return false }
            hash.update(data: data)
            tick(Int64(data.count))
            return true
        }) {}
        return hash.finalize()
    }
}
