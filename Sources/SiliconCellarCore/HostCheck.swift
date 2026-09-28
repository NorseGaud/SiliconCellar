import Foundation

public struct HostStatus: Equatable, Sendable {
    public var architecture: String
    public var hasRosetta: Bool
    public var wine: URL?
    public var wineserver: URL?

    public init(architecture: String, hasRosetta: Bool, wine: URL?, wineserver: URL?) {
        self.architecture = architecture
        self.hasRosetta = hasRosetta
        self.wine = wine
        self.wineserver = wineserver
    }
}

public protocol HostInspecting {
    func inspect() throws -> HostStatus
}

public struct LiveHostInspector: HostInspecting {
    private let commands: CommandRunning
    private let files: FileSystem
    public init(commands: CommandRunning = ProcessCommandRunner(), files: FileSystem = FoundationFileSystem()) {
        self.commands = commands
        self.files = files
    }

    public func inspect() throws -> HostStatus {
        var system = utsname()
        uname(&system)
        let architecture = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1, { String(cString: $0) })
        }
        let hasRosetta = hasRosettaSupport()
        let wine = EngineLocator(commands: commands, files: files).findWine()
        let wineserver = wine.map { EngineLocator.wineserver(nextTo: $0) }
        return HostStatus(architecture: architecture, hasRosetta: hasRosetta, wine: wine, wineserver: wineserver)
    }

    private func hasRosettaSupport() -> Bool {
        do {
            _ = try commands.run(
                executable: URL(fileURLWithPath: "/usr/bin/arch"),
                arguments: ["-x86_64", "/usr/bin/true"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 10,
                workingDirectory: nil
            )
            return true
        } catch {
            return false
        }
    }
}

public enum HostCheck {
    public static func require(_ status: HostStatus) throws -> (wine: URL, wineserver: URL) {
        guard status.architecture == "arm64" else {
            throw PortError("Silicon Cellar needs an Apple Silicon Mac.")
        }
        guard status.hasRosetta else {
            throw PortError("Rosetta is missing. Run: softwareupdate --install-rosetta --agree-to-license")
        }
        guard let wine = status.wine, let wineserver = status.wineserver else {
            throw PortError(EngineLocator.missingMessage)
        }
        return (wine, wineserver)
    }
}
