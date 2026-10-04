import Darwin
import Foundation

/// An APFS disk image on an ExFAT drive. Wine needs the links and permissions that ExFAT does not store.
struct LibraryStorageContainer: Codable {
    let token: UUID
    let bookmark: Data
    let volumeID: String
    let volumeName: String
    let path: String
    static let imageName = "Library.sparsebundle"
    static let markerName = ".siliconcellar-container.json"
    /// Spotlight does not index a volume with this file at its root.
    static let spotlightOptOutName = ".metadata_never_index"

    func folder() throws -> URL {
        var stale = false
        let folder = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        try StorageFiles.unlinked(folder)
        guard try folder.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == volumeID else {
            throw PortError("Reconnect \(volumeName) to play.")
        }
        let marker = folder.appendingPathComponent(Self.markerName)
        try StorageFiles.unlinked(marker)
        let stored = try JSONDecoder().decode(LibraryStorageMarker.self, from: Data(contentsOf: marker))
        guard stored == LibraryStorageMarker(profileID: LibraryStorage.recordID, token: token) else {
            throw PortError("The storage image could not be identified. Your files are unchanged.")
        }
        try StorageFiles.unlinked(folder.appendingPathComponent(Self.imageName))
        return folder
    }

    func mountPoint(in store: LibraryStorage) -> URL {
        store.directory.appendingPathComponent("Mounts/" + token.uuidString, isDirectory: true)
    }

    static func create(
        destination: URL,
        store: LibraryStorage,
        required: Int64
    ) throws -> (LibraryStorageContainer, URL) {
        try LibraryStorage.validateDestination(destination, required: required)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw PortError("A folder with this name already exists. Choose a different location.")
        }
        try StorageFiles.createDirectories(destination)
        let token = UUID()
        let values = try destination.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        guard let volumeID = values.volumeUUIDString else {
            throw PortError("This drive could not be identified.")
        }
        let container = LibraryStorageContainer(
            token: token,
            bookmark: try destination.bookmarkData(
                options: [],
                includingResourceValuesForKeys: [.volumeUUIDStringKey],
                relativeTo: nil
            ),
            volumeID: volumeID,
            volumeName: values.volumeName ?? "your game drive",
            path: destination.path
        )
        try JSONEncoder().encode(LibraryStorageMarker(profileID: LibraryStorage.recordID, token: token))
            .write(to: destination.appendingPathComponent(markerName), options: .withoutOverwriting)
        let attributes = try fm.attributesOfFileSystem(forPath: destination.path)
        guard let total = (attributes[.systemSize] as? NSNumber)?.int64Value else {
            throw PortError("The drive capacity could not be checked.")
        }
        let capacity = max(Int64(3_000_000_000), total - 512_000_000)
        do {
            _ = try StorageFiles.command(
                "/usr/bin/hdiutil",
                [
                    "create", "-size", "\(capacity / 1024)k", "-fs", "APFS",
                    "-volname", "Silicon Cellar", "-type", "SPARSEBUNDLE",
                    destination.appendingPathComponent(imageName).path,
                ])
            return (container, try container.mount(store: store))
        } catch {
            try? container.remove(store: store)
            throw error
        }
    }

    func mount(store: LibraryStorage) throws -> URL {
        let image = try folder().appendingPathComponent(Self.imageName)
        let mount = mountPoint(in: store)
        if let previous = try attachedMount(store: store) {
            Self.stopSpotlight(on: previous)
            return previous.appendingPathComponent("Library")
        }
        try StorageFiles.unlinked(mount)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard try FileManager.default.contentsOfDirectory(atPath: mount.path).isEmpty else {
            throw PortError("The storage mount folder is in use. Your files are unchanged.")
        }
        _ = try StorageFiles.command(
            "/usr/bin/hdiutil",
            [
                "attach", image.path, "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-plist",
            ])
        guard let attached = try attachedMount(store: store),
            StorageFiles.canonical(attached) == StorageFiles.canonical(mount)
        else {
            throw PortError("The storage image could not be checked.")
        }
        Self.stopSpotlight(on: mount)
        return mount.appendingPathComponent("Library")
    }

    private static func stopSpotlight(on volume: URL) {
        let file = volume.appendingPathComponent(spotlightOptOutName)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        FileManager.default.createFile(atPath: file.path, contents: nil)
    }

    func attachedMount(store: LibraryStorage) throws -> URL? {
        let image = try folder().appendingPathComponent(Self.imageName)
        let data = try StorageFiles.command("/usr/bin/hdiutil", ["info", "-plist"])
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        for item in plist?["images"] as? [[String: Any]] ?? [] {
            guard let path = item["image-path"] as? String,
                StorageFiles.canonical(URL(fileURLWithPath: path)) == StorageFiles.canonical(image)
            else { continue }
            let mounts = (item["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
            if let path = mounts.first { return URL(fileURLWithPath: path) }
            throw PortError("This storage image is attached, but it is not available. Eject it in Disk Utility, then try again.")
        }
        return nil
    }

    func remove(store: LibraryStorage) throws {
        let folder = try self.folder()
        if let mount = try attachedMount(store: store) {
            guard !StorageFiles.processesUse(mount.appendingPathComponent("Library")) else {
                throw PortError("Close the launcher before you remove the old storage.")
            }
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: mount.path))
            guard
                names.isSubset(of: [
                    "Library", ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DS_Store", Self.spotlightOptOutName,
                ])
            else {
                throw PortError("Extra files were found beside the games. The old storage image was kept.")
            }
            _ = try StorageFiles.command("/usr/bin/hdiutil", ["detach", mount.path])
        }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        guard names.isSubset(of: [Self.imageName, Self.markerName, ".DS_Store"]) else {
            throw PortError("Extra files were found in the old storage folder. It was kept.")
        }
        _ = try self.folder()
        try FileManager.default.removeItem(at: folder)
    }
}

struct StorageTransferJournal: Codable {
    let source: String
    let sourceVolume: String
    let sourceInode: UInt64
    let stage: String
    let destination: String
    let volume: String
    let inode: UInt64
    var stageBookmark: Data?
    var container: LibraryStorageContainer?
    var placedNames: [String]
}

struct StorageTransfer {
    let store: LibraryStorage
    let source: URL
    let destination: URL
    var headroom: Int64
    var destinationContainer: LibraryStorageContainer?
    var progress: (Double, String) -> Void

    func run() throws -> URL? {
        let fm = FileManager.default
        if destinationContainer == nil, try StorageFiles.fileSystem(destination) == "exfat" {
            let bytes = try StorageTree.entries(source, skipping: skip).reduce(Int64(0)) { $0 + $1.size }
            let (container, innerRoot) = try LibraryStorageContainer.create(
                destination: destination,
                store: store,
                required: bytes + headroom
            )
            do {
                return try StorageTransfer(
                    store: store,
                    source: source,
                    destination: innerRoot,
                    headroom: headroom,
                    destinationContainer: container,
                    progress: progress
                ).run()
            } catch {
                if (try? store.readRecord())?.container?.token != container.token {
                    try? container.remove(store: store)
                }
                throw error
            }
        }
        let merging = store.isMetadata(destination)
        if !merging {
            guard !fm.fileExists(atPath: destination.path) else {
                throw PortError("A folder with this name already exists. Choose a different location.")
            }
        }
        let original = try StorageTree.entries(source, skipping: skip)
        let originalStamps = try StorageTree.stamps(source, entries: original)
        let bytes = original.reduce(Int64(0)) { $0 + $1.size }
        try LibraryStorage.validateDestination(destination, required: bytes + headroom)
        if merging { try rejectMergeCollisions(original) }
        guard let volume = try StorageFiles.existingAncestor(destination).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
            let sourceVolume = try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        else {
            throw PortError("The drives could not be identified. Nothing was moved.")
        }
        let parent = merging ? destination : destination.deletingLastPathComponent()
        try StorageFiles.createDirectories(parent)
        let stage = parent.appendingPathComponent(".siliconcellar-moving-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        guard let inode = (try fm.attributesOfItem(atPath: stage.path)[.systemFileNumber] as? NSNumber)?.uint64Value,
            let sourceInode = (try fm.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            throw PortError("The folder could not be identified. Nothing was moved.")
        }
        let journalURL = store.directory.appendingPathComponent(LibraryStorage.recordID + ".transfer")
        var journal = StorageTransferJournal(
            source: source.path,
            sourceVolume: sourceVolume,
            sourceInode: sourceInode,
            stage: stage.path,
            destination: destination.path,
            volume: volume,
            inode: inode,
            stageBookmark: try stage.bookmarkData(options: [], includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil),
            container: destinationContainer,
            placedNames: []
        )
        try fm.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        var committed = false
        defer {
            if !committed {
                try? fm.removeItem(at: stage)
                // A merge keeps the journal so the next attempt can remove files already placed on This Mac.
                if !merging, !fm.fileExists(atPath: stage.path), !fm.fileExists(atPath: destination.path),
                    (try? parent.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == volume
                {
                    try? fm.removeItem(at: journalURL)
                }
            }
        }
        progress(0, "Moving games…")
        try copy(original, from: source, to: stage, bytes: bytes)
        for entry in original.reversed() where entry.kind == S_IFDIR {
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: entry.permissions)],
                ofItemAtPath: stage.appendingPathComponent(entry.path).path
            )
        }
        progress(0.5, "Checking the copy…")
        try verify(original, from: source, to: stage, bytes: bytes)
        let expected = original.map { entry in
            StorageTree.Entry(
                path: entry.path,
                kind: entry.kind,
                size: entry.size,
                permissions: entry.permissions,
                link: entry.link.map { StorageTree.portableLink($0, at: entry.path, from: source) }
            )
        }
        guard try StorageTree.entries(source, skipping: skip) == original,
            try StorageTree.stamps(source, entries: original) == originalStamps,
            try StorageTree.entries(stage, skipping: []) == expected
        else {
            throw PortError("The original files changed during the move. Close the launcher and try again.")
        }
        guard try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == sourceVolume,
            try stage.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == volume
        else {
            throw PortError("A drive disconnected during the move. Reconnect it and try again.")
        }
        let token = UUID()
        try store.writeMarker(token: token, at: stage)
        let sourceContainer = try store.readRecord()?.container
        if merging {
            var names = Set(original.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })
            names.insert(LibraryStorage.markerName)
            for name in names.sorted() {
                journal.placedNames.append(name)
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
                try fm.moveItem(at: stage.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
            try fm.removeItem(at: stage)
            try store.save(root: destination, token: token, container: nil)
        } else {
            try fm.moveItem(at: stage, to: destination)
            try store.save(root: destination, token: token, container: destinationContainer)
        }
        committed = true
        try? fm.removeItem(at: journalURL)
        progress(1, "Move complete")
        return try removeSource(
            source,
            sourceVolume: sourceVolume,
            original: original,
            originalStamps: originalStamps,
            sourceContainer: sourceContainer
        )
    }

    private var skip: Set<String> {
        store.isMetadata(source) ? LibraryStorage.reservedNames : []
    }

    private func rejectMergeCollisions(_ entries: [StorageTree.Entry]) throws {
        let fm = FileManager.default
        let names = Set(entries.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })
        if !names.isDisjoint(with: LibraryStorage.reservedNames) {
            throw PortError("The storage folder contains Wine, Recipes, or Storage. Those names belong to the app. Choose a different folder.")
        }
        for name in names where fm.fileExists(atPath: destination.appendingPathComponent(name).path) {
            throw PortError("This Mac already has \(name). Nothing was moved.")
        }
    }

    private func copy(_ entries: [StorageTree.Entry], from source: URL, to stage: URL, bytes: Int64) throws {
        let fm = FileManager.default
        var copied: Int64 = 0
        for entry in entries {
            let from = source.appendingPathComponent(entry.path)
            let to = stage.appendingPathComponent(entry.path)
            if entry.kind == S_IFDIR {
                try fm.createDirectory(at: to, withIntermediateDirectories: false)
            } else if let link = entry.link {
                try fm.createSymbolicLink(
                    atPath: to.path,
                    withDestinationPath: StorageTree.portableLink(link, at: entry.path, from: source)
                )
            } else {
                try fm.copyItem(at: from, to: to)
                copied += entry.size
                progress(0.5 * Double(copied) / Double(max(bytes, 1)), "Moving games…")
            }
        }
    }

    private func verify(_ entries: [StorageTree.Entry], from source: URL, to stage: URL, bytes: Int64) throws {
        var verified: Int64 = 0
        for entry in entries where entry.kind == S_IFREG {
            let originalHash = try StorageTree.hash(source.appendingPathComponent(entry.path))
            let copyHash = try StorageTree.hash(stage.appendingPathComponent(entry.path)) { count in
                verified += count
                progress(0.5 + 0.5 * Double(verified) / Double(max(bytes, 1)), "Checking the copy…")
            }
            guard originalHash == copyHash else {
                throw PortError("The copy could not be checked. Your original files are unchanged.")
            }
        }
    }

    private func removeSource(
        _ source: URL,
        sourceVolume: String,
        original: [StorageTree.Entry],
        originalStamps: [String: String],
        sourceContainer: LibraryStorageContainer?
    ) throws -> URL? {
        let fm = FileManager.default
        guard !StorageFiles.processesUse(source) else { return source }
        do {
            guard try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == sourceVolume,
                try StorageTree.entries(source, skipping: skip) == original,
                try StorageTree.stamps(source, entries: original) == originalStamps
            else { return source }
            try StorageFiles.unlinked(source)
            if store.isMetadata(source) {
                let names = Set(original.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })
                for name in names {
                    try fm.removeItem(at: source.appendingPathComponent(name))
                }
                return nil
            }
            if let container = sourceContainer {
                try container.remove(store: store)
                return nil
            }
            try fm.removeItem(at: source)
            return nil
        } catch {
            return sourceContainer.map { URL(fileURLWithPath: $0.path) } ?? source
        }
    }
}
