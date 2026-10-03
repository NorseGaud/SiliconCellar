import XCTest

@testable import SiliconCellarCore

final class LibraryStorageTests: XCTestCase {
    private var home: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: LibraryStorage!

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("cellar-storage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        suiteName = "SiliconCellar.StorageTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = LibraryStorage(home: home, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    func testPortableLinkKeepsExternalTargetsAndRewritesInternalTargets() {
        let source = URL(fileURLWithPath: "/Games")
        XCTAssertEqual(
            StorageTree.portableLink("/Games/prefix/drive_c", at: "prefix/dosdevices/c:", from: source),
            "../drive_c"
        )
        XCTAssertEqual(
            StorageTree.portableLink("/Other/save", at: "prefix/external", from: source),
            "/Other/save"
        )
        XCTAssertEqual(
            StorageTree.portableLink("fix.dll", at: "engine/relative.dll", from: source),
            "fix.dll"
        )
    }

    func testCommandUsesMatchesAPathOnlyAtABoundary() {
        XCTAssertTrue(StorageFiles.commandUses("/bin/ps", command: "/bin/ps -ax"))
        XCTAssertTrue(StorageFiles.commandUses("/Games", command: "WINEPREFIX=/Games/prefix"))
        XCTAssertFalse(StorageFiles.commandUses("/Games", command: "WINEPREFIX=/GamesExtra/prefix"))
    }

    func testMoveKeepsAppFilesAndRebasesLinks() throws {
        let support = storage.metadataRoot
        let prefix = support.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: prefix.appendingPathComponent("drive_c/save.dat"))
        try FileManager.default.createSymbolicLink(
            atPath: prefix.appendingPathComponent("dosdevices/c:").path,
            withDestinationPath: prefix.appendingPathComponent("drive_c").path
        )
        let outside = home.appendingPathComponent("outside-save")
        try Data("other".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: prefix.appendingPathComponent("external").path,
            withDestinationPath: outside.path
        )
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Wine"), withIntermediateDirectories: true)
        try Data("wine".utf8).write(to: support.appendingPathComponent("Wine/keep"))
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Recipes"), withIntermediateDirectories: true)
        try Data("recipe".utf8).write(to: support.appendingPathComponent("Recipes/keep.json"))

        let destination = home.appendingPathComponent("External/Silicon Cellar")
        let kept = try storage.use(choice: destinationChoice(destination), headroom: 0)
        XCTAssertNil(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.path))
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("Wine/keep")), Data("wine".utf8))
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("Recipes/keep.json")), Data("recipe".utf8))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("prefix/drive_c/save.dat"), encoding: .utf8), "save")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("prefix/dosdevices/c:").path),
            "../drive_c"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("prefix/external").path),
            outside.path
        )
        XCTAssertEqual(StorageFiles.canonical(storage.runtimeRoot()), StorageFiles.canonical(destination))
        XCTAssertNil(storage.issue())
        XCTAssertEqual(storage.displayName(), "This Mac")
    }

    func testMoveBackToThisMac() throws {
        try FileManager.default.createDirectory(at: storage.metadataRoot.appendingPathComponent("prefix"), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: storage.metadataRoot.appendingPathComponent("prefix/save.dat"))
        let destination = home.appendingPathComponent("External/Silicon Cellar")
        _ = try storage.use(choice: destinationChoice(destination), headroom: 0)
        let kept = try storage.use(
            choice: StorageDestination(id: "internal", title: "This Mac", folder: storage.metadataRoot, available: nil, problem: nil),
            headroom: 0
        )
        XCTAssertNil(kept)
        XCTAssertEqual(try String(contentsOf: storage.metadataRoot.appendingPathComponent("prefix/save.dat"), encoding: .utf8), "save")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(StorageFiles.canonical(storage.runtimeRoot()), StorageFiles.canonical(storage.metadataRoot))
        XCTAssertNil(storage.issue())
    }

    func testExFATDriveKeepsGamesInAnAPFSImage() throws {
        let image = home.appendingPathComponent("exfat.sparseimage")
        let mount = home.appendingPathComponent("exfat-mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        _ = try StorageFiles.command("/usr/bin/hdiutil", [
            "create", "-size", "4g", "-fs", "ExFAT", "-volname", "SC_EXFAT", "-type", "SPARSE", image.path,
        ])
        _ = try StorageFiles.command("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-mountpoint", mount.path])
        defer {
            let root = storage.runtimeRoot()
            if root.path.contains("/Mounts/") {
                _ = try? StorageFiles.command("/usr/bin/hdiutil", ["detach", root.deletingLastPathComponent().path])
            }
            _ = try? StorageFiles.command("/usr/bin/hdiutil", ["detach", mount.path])
        }
        try FileManager.default.createDirectory(at: storage.metadataRoot.appendingPathComponent("prefix"), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: storage.metadataRoot.appendingPathComponent("prefix/save.dat"))
        let destination = mount.appendingPathComponent("Silicon Cellar")
        _ = try storage.use(choice: destinationChoice(destination), headroom: 0)
        let root = storage.runtimeRoot()
        XCTAssertEqual(try LibraryStorage.volumeFormat(root), "apfs")
        XCTAssertEqual(try LibraryStorage.volumeFormat(destination), "exfat")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("prefix/save.dat"), encoding: .utf8), "save")
        XCTAssertEqual(storage.displayName(), "SC_EXFAT")
        XCTAssertTrue(storage.usesContainer())
        _ = try StorageFiles.command("/usr/bin/hdiutil", ["detach", root.deletingLastPathComponent().path])
        _ = try StorageFiles.command("/usr/bin/hdiutil", ["detach", mount.path])
        XCTAssertNotNil(storage.issue())
    }

    func testChangedMarkerBlocksUse() throws {
        let destination = home.appendingPathComponent("External/Silicon Cellar")
        try FileManager.default.createDirectory(at: storage.metadataRoot.appendingPathComponent("prefix"), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: storage.metadataRoot.appendingPathComponent("prefix/save.dat"))
        _ = try storage.use(choice: destinationChoice(destination), headroom: 0)
        let marker = destination.appendingPathComponent(LibraryStorage.markerName)
        let original = try Data(contentsOf: marker)
        try FileManager.default.removeItem(at: marker)
        XCTAssertNotNil(storage.issue())
        XCTAssertThrowsError(try storage.activate())
        try JSONEncoder().encode(LibraryStorageMarker(profileID: "library", token: UUID())).write(to: marker)
        XCTAssertThrowsError(try storage.activate())
        try original.write(to: marker)
        try storage.activate()
        XCTAssertNil(storage.issue())
    }

    func testLinkDestinationIsRejected() throws {
        let realFolder = home.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFolder)
        XCTAssertThrowsError(try LibraryStorage.validateDestination(link.appendingPathComponent("Silicon Cellar"))) { error in
            XCTAssertEqual(
                (error as? PortError)?.message,
                "Choose a folder that is not a link to another location."
            )
        }
    }

    func testFolderInsideAppFilesIsRejected() throws {
        let folder = storage.metadataRoot.appendingPathComponent("Wine/games")
        XCTAssertThrowsError(try storage.use(choice: destinationChoice(folder), headroom: 0)) { error in
            XCTAssertEqual(
                (error as? PortError)?.message,
                "This location overlaps the app's own files. Choose a different folder."
            )
        }
    }

    func testFailedCheckKeepsTheOriginalFiles() throws {
        let support = storage.metadataRoot
        try FileManager.default.createDirectory(at: support.appendingPathComponent("prefix"), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: support.appendingPathComponent("prefix/save.dat"))
        let destination = home.appendingPathComponent("External/Silicon Cellar")
        var corrupted = false
        XCTAssertThrowsError(try storage.use(choice: destinationChoice(destination), headroom: 0) { _, message in
            guard message == "Checking the copy…", !corrupted else { return }
            corrupted = true
            let journalURL = self.storage.directory.appendingPathComponent("library.transfer")
            let journal = try! JSONDecoder().decode(StorageTransferJournal.self, from: Data(contentsOf: journalURL))
            try! Data("corrupt".utf8).write(to: URL(fileURLWithPath: journal.stage).appendingPathComponent("prefix/save.dat"))
        })
        XCTAssertTrue(corrupted)
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("prefix/save.dat"), encoding: .utf8), "save")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(StorageFiles.canonical(storage.runtimeRoot()), StorageFiles.canonical(support))
    }

    func testInterruptedStageIsRemoved() throws {
        let source = storage.metadataRoot
        try FileManager.default.createDirectory(at: source.appendingPathComponent("prefix"), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: source.appendingPathComponent("prefix/save.dat"))
        let stage = home.appendingPathComponent("partial/.siliconcellar-moving-test")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: stage.appendingPathComponent("bytes"))
        let volume = try stage.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString!
        let sourceVolume = try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString!
        let journal = StorageTransferJournal(
            source: source.path,
            sourceVolume: sourceVolume,
            sourceInode: (try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as! NSNumber).uint64Value,
            stage: stage.path,
            destination: home.appendingPathComponent("retry").path,
            volume: volume,
            inode: (try FileManager.default.attributesOfItem(atPath: stage.path)[.systemFileNumber] as! NSNumber).uint64Value,
            stageBookmark: try stage.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            container: nil,
            placedNames: []
        )
        try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true)
        let journalURL = storage.directory.appendingPathComponent("library.transfer")
        try JSONEncoder().encode(journal).write(to: journalURL)
        let renamed = home.appendingPathComponent("renamed-stage")
        try FileManager.default.moveItem(at: stage, to: renamed)
        try storage.discardInterruptedMove(source: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("prefix/save.dat"), encoding: .utf8), "save")
    }

    func testLibraryUsesTheStorageRoot() throws {
        try FileManager.default.createDirectory(at: storage.metadataRoot.appendingPathComponent("prefix"), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: storage.metadataRoot.appendingPathComponent("prefix/save.dat"))
        let destination = home.appendingPathComponent("External/Silicon Cellar")
        _ = try storage.use(choice: destinationChoice(destination), headroom: 0)
        let library = Library(
            recipes: [Recipe.onboarding],
            wine: home.appendingPathComponent("wine"),
            wineserver: home.appendingPathComponent("wineserver"),
            home: home,
            files: FoundationFileSystem(),
            commands: ProcessCommandRunner()
        )
        XCTAssertEqual(
            StorageFiles.canonical(library.runtime(for: Recipe.onboarding).root),
            StorageFiles.canonical(destination)
        )
    }

    private func destinationChoice(_ folder: URL) -> StorageDestination {
        StorageDestination(id: "test", title: "Test", folder: folder, available: nil, problem: nil)
    }
}
