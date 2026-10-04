import Foundation

enum GameFixes {
    static let witcherOriginalSHA = "e2d85aa05a9bd9ed8b38935fdf5199372cca6f74c12015143bb6f945ee1608aa"
    static let witcherProxySHA = "9401692ea76b93be5c1b4bc0eb9f1622e04b368990e905d7063e5dd98bcbf7c6"
    static let coh3DLLSHA = "51cbbde17a768930300236facd9738f54b7801e6715771ff8af90bfbe3fad44f"
    static let coh3PackageSHA = "52b196bbe9016488c735e7b41805b651261ffa5d7aa86eb6a1d0095be83687b2"
    static let coh3PackageURL =
        "https://download.visualstudio.microsoft.com/download/pr/85d47aa9-69ae-4162-8300-e6b7e4bf3cf3/52B196BBE9016488C735E7B41805B651261FFA5D7AA86EB6A1D0095BE83687B2/VC_redist.x64.exe"
    static let aoe3ExecutableSHA = "a3fcaa23f57ffcfe5fb799e2b19f89560793784c73aded74747d955c95a4c625"
    /// Steam `brink.exe` before the OpenGL adjustment.
    static let brinkExecutableSHA = "0145ce773aeaf63563350930d9b93424c151128567b5dd9af5d6ed5ff26aa53f"
    /// Version test and `GL_EXT_texture3D` name only. Play still applies the texture-format check.
    static let brinkOpenGLPartialSHA = "591fd3c35d21c802cfac0288ee612f15d70ff38dfd0d696397901027cda15ae9"
    /// Version test, `GL_EXT_texture3D` name, and the format check skipped with an unconditional jump.
    static let brinkOpenGLSkippedSHA = "2a10e6f14fc1dc92a93507a96f276c86eaf7f46ebc53561829ff3147559e922f"
    /// Version test, `GL_EXT_texture3D` name, and the texture record set to the driver format.
    static let brinkOpenGLFormatSHA = "cb36917c9e174ddc1af9212c66e55bec114dc380ee2e4e765842786fded227be"
    /// Format record, plus `glColorMask` in place of the missing `glColorMaski`.
    static let brinkOpenGLColorMaskSHA = "5aed449d904fbbc3da66e6abca8050137d61da669dcf4f84ff3032d135254a32"
    /// Color mask, plus `brinkglsl.dll` in front of `glShaderSourceARB`.
    static let brinkOpenGLSHA = "eff78630d9b0e63474347787b55b68bd798bf04b23463b0ccdb6550823243577"
    /// The Steam file and each earlier Play adjustment. Play finishes any of them.
    static let brinkOpenGLInputSHAs: Set<String> = [
        brinkExecutableSHA, brinkOpenGLPartialSHA, brinkOpenGLSkippedSHA, brinkOpenGLFormatSHA, brinkOpenGLColorMaskSHA,
    ]
    /// `atof` of the legacy context version (`2.1 Metal - 90.5`) is compared with this float.
    static let brinkVersionCheckOffset = 0x414788
    static let brinkVersionCheckOriginal: [UInt8] = [0x66, 0x66, 0x46, 0x40]
    static let brinkVersionCheckAdjusted: [UInt8] = [0x00, 0x00, 0x00, 0x40]
    /// `cmp byte ptr [flag], 0` for the `GL_EXT_texture3D` requirement. The immediate is the last `0x00`.
    static let brinkTexture3DCheckOffset = 0x6EC7C
    static let brinkTexture3DCheckOriginal: [UInt8] = [0x80, 0x3D, 0xD1, 0x84, 0x92, 0x00, 0x00, 0x75]
    static let brinkTexture3DCheckAdjusted: [UInt8] = [0x80, 0x3D, 0xD1, 0x84, 0x92, 0x00, 0xFF, 0x75]
    /// `cmp esi, eax; je` after `glGetTexLevelParameter`. The Mac driver returns a sized format.
    static let brinkFormatCheckOffset = 0x6B4AF
    static let brinkFormatCheckOriginal: [UInt8] = [
        0x8B, 0x44, 0x24, 0x28, 0x3B, 0xF0, 0x74, 0x12, 0x50, 0x56, 0x68, 0xDC, 0x46, 0x81,
    ]
    static let brinkFormatCheckSkipped: [UInt8] = [
        0x8B, 0x44, 0x24, 0x28, 0x3B, 0xF0, 0xEB, 0x12, 0x50, 0x56, 0x68, 0xDC, 0x46, 0x81,
    ]
    /// `mov eax, [esp+0x28]; mov [edi+0x78], eax; mov esi, eax; jmp` to the success path.
    static let brinkFormatCheckAdjusted: [UInt8] = [
        0x8B, 0x44, 0x24, 0x28, 0x89, 0x87, 0x78, 0x00, 0x00, 0x00, 0x8B, 0xF0, 0xEB, 0x0C,
    ]
    /// `call dword ptr [glColorMaski]`. The legacy context does not provide that entry point.
    static let brinkColorMaskCallOffset = 0x67EBC
    static let brinkColorMaskCallOriginal: [UInt8] = [0xFF, 0x15, 0x04, 0x0F, 0xC0, 0x00]
    /// `call` the stub below, then `nop`.
    static let brinkColorMaskCallAdjusted: [UInt8] = [0xE8, 0xA0, 0xA4, 0xFD, 0xFF, 0x90]
    static let brinkColorMaskStubOffset = 0x42361
    static let brinkColorMaskStubOriginal: [UInt8] = [UInt8](repeating: 0xCC, count: 33)
    /// For buffer 0, call `glColorMask`. Leave other buffers unchanged. `ret 0x14` pops the five arguments.
    static let brinkColorMaskStubAdjusted: [UInt8] = [
        0x8B, 0x44, 0x24, 0x04, 0x85, 0xC0, 0x75, 0x16,
        0xFF, 0x74, 0x24, 0x14, 0xFF, 0x74, 0x24, 0x14, 0xFF, 0x74, 0x24, 0x14, 0xFF, 0x74, 0x24, 0x14,
        0xFF, 0x15, 0x38, 0xA5, 0x7F, 0x00, 0xC2, 0x14, 0x00,
    ]
    /// `call dword ptr [glShaderSourceARB]` in the render-program compile.
    static let brinkShaderSourceCallOffset = 0x1275DD
    static let brinkShaderSourceCallOriginal: [UInt8] = [0xFF, 0x15, 0xFC, 0x0E, 0xC0, 0x00]
    /// `call` the loader below, then `nop`.
    static let brinkShaderSourceCallAdjusted: [UInt8] = [0xE8, 0xB3, 0x9D, 0x09, 0x00, 0x90]
    static let brinkShaderLoaderOffset = 0x1C1395
    static let brinkShaderLoaderOriginal: [UInt8] = [UInt8](repeating: 0xCC, count: 36)
    /// `LoadLibraryA("brinkglsl")` and `GetProcAddress(module, 1)`, then `jmp` to that export.
    /// Without the DLL, `jmp` to `glShaderSourceARB`. The caller's arguments stay on the stack.
    static let brinkShaderLoaderAdjusted: [UInt8] = [
        0x68, 0x84, 0x2F, 0x44, 0x00, 0xFF, 0x15, 0x54, 0xA1, 0x7F, 0x00, 0x85, 0xC0, 0x74, 0x0F,
        0x6A, 0x01, 0x50, 0xFF, 0x15, 0x2C, 0xA2, 0x7F, 0x00, 0x85, 0xC0, 0x74, 0x02, 0xFF, 0xE0,
        0xFF, 0x25, 0xFC, 0x0E, 0xC0, 0x00,
    ]
    /// Unused bytes after the color-mask stub hold the DLL name.
    static let brinkShaderLibraryNameOffset = 0x42384
    static let brinkShaderLibraryNameOriginal: [UInt8] = [UInt8](repeating: 0xCC, count: 10)
    static let brinkShaderLibraryNameAdjusted: [UInt8] = Array("brinkglsl".utf8) + [0]
    /// Built from `scripts/brink-glsl.c`. Rewrites BRINK's GLSL 1.30 shaders to GLSL 1.20 for the Mac driver.
    static let brinkShaderLibraryArchive = "Brink/brinkglsl.tar.xz"
    static let brinkShaderLibraryArchiveSHA = "acada49b9acd7302a612bebe4b2aa6170de2dcc4a0579927990b9f155a78f676"
    static let brinkShaderLibrarySHA = "4af186010654efda3f98dd33c502a7b79414aecd161810acbfd0510d5bfea9b1"

    struct BrinkReplacement {
        let offset: Int
        let originals: [[UInt8]]
        let adjusted: [UInt8]
    }

    static let brinkReplacements: [BrinkReplacement] = [
        BrinkReplacement(offset: brinkVersionCheckOffset, originals: [brinkVersionCheckOriginal], adjusted: brinkVersionCheckAdjusted),
        BrinkReplacement(offset: brinkTexture3DCheckOffset, originals: [brinkTexture3DCheckOriginal], adjusted: brinkTexture3DCheckAdjusted),
        BrinkReplacement(
            offset: brinkFormatCheckOffset,
            originals: [brinkFormatCheckOriginal, brinkFormatCheckSkipped],
            adjusted: brinkFormatCheckAdjusted
        ),
        BrinkReplacement(offset: brinkColorMaskStubOffset, originals: [brinkColorMaskStubOriginal], adjusted: brinkColorMaskStubAdjusted),
        BrinkReplacement(offset: brinkColorMaskCallOffset, originals: [brinkColorMaskCallOriginal], adjusted: brinkColorMaskCallAdjusted),
        BrinkReplacement(
            offset: brinkShaderLibraryNameOffset,
            originals: [brinkShaderLibraryNameOriginal],
            adjusted: brinkShaderLibraryNameAdjusted
        ),
        BrinkReplacement(offset: brinkShaderLoaderOffset, originals: [brinkShaderLoaderOriginal], adjusted: brinkShaderLoaderAdjusted),
        BrinkReplacement(
            offset: brinkShaderSourceCallOffset,
            originals: [brinkShaderSourceCallOriginal],
            adjusted: brinkShaderSourceCallAdjusted
        ),
    ]
    /// `Fixes/MFC42/mfc42.tar.xz` holds `mfc42.dll` from the Visual C++ 6 SP4 redistributable.
    static let mfc42ArchiveSHA = "35140a3cb9baf12546f86df9c96554d99864fe2dbe6ab46482497ba322999310"
    static let mfc42DLLSHA = "ec63a85030c60716acdcf060abfaa95a6a3528631622fa60e7d17fbea2f751f9"
    static let heroesMusicOriginalSHA = "09e2dec3d1e996571fb2c95e5de393410d486f1728c86473b550282edd83588c"
    static let heroesMusicFixedSHA = "57191b1e7a07df187ee4aff128c0f522d1ac11a7657ebe7e4f40d3b5f99b23c8"
    static let cncDdrawArchive = "CncDdraw/ddraw.tar.xz"
    static let cncDdrawArchiveSHA = "18cf1ccd2af6af3e8227ff5e787425c07d5404a2ee6aaf684866ad3425484c67"
    static let cncDdrawSHA = "6a29d666b6e06d9dfe56d7489a3d88820e514316ff481cf63a9fe7bcbd59ab29"
    static let witcherProxyArchive = "Witcher3/amd_fidelityfx_loader_dx12.tar.xz"
    static let witcherProxyArchiveSHA = "8f75453d58b7d324600994b8cad060a6e6beaf3c83fe04edc21a40466e233de2"
    static let generalsOnlineURL = "https://cdn.playgenerals.online/GeneralsOnline_setup_092226_QFE2.exe"
    static let generalsOnlineSHA = "307d27ac21cd398259dec4e95f4eb85f90d571bdc0efe063a65734386896317b"
    static let generalsOnlineFiles = [
        "GeneralsOnlineZH.exe": "cdce2df2e9c4d278b268bb5822944796c93e616b5cad7989a149760b5acae5f1",
        "GeneralsOnlineZH_60.exe": "ff21df13c5cb0f524e4d56585c1867467efbcff44a94ed2e1b2f30eef2aaca8b",
        "GameNetworkingSockets.dll": "a8558739b1dcc1c78811d5c0f4a86bfb49071a10dcc894e442b40352105da190",
    ]
    /// WAVEFORMATEX patch: PCM, 2 channels, 44100 Hz. From Narzoul's Heroes III stereo fix.
    static let heroesAudioCode: [UInt8] =
        [
            0x66, 0xB8, 0x01, 0x00, 0x66, 0x89, 0x03,
            0x66, 0xB8, 0x02, 0x00, 0x66, 0x89, 0x43, 0x02,
            0xB8, 0x44, 0xAC, 0x00, 0x00, 0x89, 0x43, 0x04,
            0xC1, 0xE0, 0x02, 0x89, 0x43, 0x08,
            0x66, 0xB8, 0x04, 0x00, 0x66, 0x89, 0x43, 0x0C,
            0x66, 0xB8, 0x10, 0x00, 0x66, 0x89, 0x43, 0x0E,
        ] + Array(repeating: 0x90, count: 11)

    static func fixesRoot() throws -> URL {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Fixes", isDirectory: true),
            FileManager.default.fileExists(atPath: root.path)
        else {
            throw PortError("Game fix files are missing from the app.")
        }
        return root
    }

    /// Microsoft cabinets embedded in a VC++ redistributable. Each cabinet starts with MSCF.
    static func cabinets(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [77, 83, 67, 70, 0, 0, 0, 0]
        guard bytes.count >= 36 else { return [] }
        var result: [Data] = []
        var index = 0
        while index <= bytes.count - 36, result.count < 16 {
            if Array(bytes[index..<(index + 8)]) == signature {
                let size = Int(bytes[index + 8]) | Int(bytes[index + 9]) << 8 | Int(bytes[index + 10]) << 16 | Int(bytes[index + 11]) << 24
                if size >= 36, size <= bytes.count - index {
                    result.append(Data(bytes[index..<(index + size)]))
                    index += size
                    continue
                }
            }
            index += 1
        }
        return result
    }

    static func patchedHeroesAudio(_ original: Data) throws -> Data {
        let digest = SteamInstaller.digest(of: original)
        if digest == heroesMusicFixedSHA { return original }
        guard digest == heroesMusicOriginalSHA else {
            throw PortError("This Heroes III audio component does not match the tested file. It was left unchanged.")
        }
        let start = 0xE39E
        let end = 0xE3D6
        guard end <= original.count, end - start == heroesAudioCode.count else {
            throw PortError("Heroes III audio repair verification failed. No audio files were changed.")
        }
        var fixed = original
        fixed.replaceSubrange(start..<end, with: heroesAudioCode)
        guard SteamInstaller.digest(of: fixed) == heroesMusicFixedSHA else {
            throw PortError("Heroes III audio repair verification failed. No audio files were changed.")
        }
        return fixed
    }

    /// The Mac legacy OpenGL context reports version 2.1 and stores some textures in a sized format.
    /// BRINK stops on both. `glTexImage3D` is present, but the extension string omits `GL_EXT_texture3D`.
    /// The format check copies the driver format into the texture record, then continues.
    /// `glColorMaski` is missing, so buffer 0 uses `glColorMask`.
    /// The shaders are GLSL 1.30, so `glShaderSourceARB` goes through `brinkglsl.dll`, which rewrites them to GLSL 1.20.
    /// Each check is changed only when its original bytes are still present. Returns nil when nothing changes.
    static func brinkOpenGLAdjusted(_ original: Data) -> Data? {
        var bytes = [UInt8](original)
        var changed = false
        for replacement in brinkReplacements {
            for original in replacement.originals
            where replace(&bytes, at: replacement.offset, from: original, to: replacement.adjusted) {
                changed = true
                break
            }
        }
        return changed ? Data(bytes) : nil
    }

    private static func replace(_ bytes: inout [UInt8], at offset: Int, from original: [UInt8], to adjusted: [UInt8]) -> Bool {
        let end = offset + original.count
        guard end <= bytes.count, Array(bytes[offset..<end]) == original else { return false }
        bytes.replaceSubrange(offset..<end, with: adjusted)
        return true
    }

    static func patchedBrinkOpenGL(_ original: Data) throws -> Data {
        let digest = SteamInstaller.digest(of: original)
        if digest == brinkOpenGLSHA { return original }
        guard brinkOpenGLInputSHAs.contains(digest) else {
            throw PortError("This BRINK executable does not match the tested file. It was left unchanged.")
        }
        guard let adjusted = brinkOpenGLAdjusted(original),
            SteamInstaller.digest(of: adjusted) == brinkOpenGLSHA
        else {
            throw PortError("BRINK OpenGL adjustment failed verification. The executable was left unchanged.")
        }
        return adjusted
    }

    static func eldenGraphics(template: Data, width: Int, height: Int) throws -> Data {
        guard (640...16_384).contains(width), (480...16_384).contains(height) else {
            throw PortError("Couldn't detect Elden Ring's display size.")
        }
        guard let text = String(data: template, encoding: .utf16LittleEndian) else {
            throw PortError("Elden Ring's graphics template is invalid.")
        }
        let result = text.replacingOccurrences(of: "DISPLAY_WIDTH", with: String(width))
            .replacingOccurrences(of: "DISPLAY_HEIGHT", with: String(height))
        guard result.contains("<ScreenMode>BORDERLESS</ScreenMode>"),
            result.contains("<RaytracingQuality>DISABLE</RaytracingQuality>"),
            !result.contains("DISPLAY_WIDTH"),
            !result.contains("DISPLAY_HEIGHT")
        else {
            throw PortError("Elden Ring's graphics template is invalid.")
        }
        var data = Data([0xFF, 0xFE])
        data.append(result.data(using: .utf16LittleEndian) ?? Data())
        return data
    }

    static let rockstarInstallerURL = "https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe"
    static let rockstarInstallerSHA = "321886457b7e4ab727a27671c17a815684a3943579eedf7e2248a3b9f0973746"
    static let redDeadCompanionExecutables = ["Launcher.exe", "LauncherPatcher.exe", "SocialClubHelper.exe"]

    static func redDeadSettings(template: Data, width: Int, height: Int) throws -> Data {
        guard (640...16_384).contains(width), (480...16_384).contains(height) else {
            throw PortError("Could not determine the current screen size. Red Dead Redemption 2 settings were left unchanged.")
        }
        let document = try XMLDocument(data: template, options: [.nodeLoadExternalEntitiesNever])
        let values = [
            "/rage__fwuiSystemSettingsCollection/video/windowed": "0",
            "/rage__fwuiSystemSettingsCollection/video/screenWidth": String(width),
            "/rage__fwuiSystemSettingsCollection/video/screenHeight": String(height),
            "/rage__fwuiSystemSettingsCollection/video/screenWidthWindowed": String(width),
            "/rage__fwuiSystemSettingsCollection/video/screenHeightWindowed": String(height),
            "/rage__fwuiSystemSettingsCollection/graphics/hdr": "false",
        ]
        for (xpath, value) in values {
            guard let node = try document.nodes(forXPath: xpath).first as? XMLElement,
                let attribute = node.attribute(forName: "value")
            else {
                throw PortError("Unrecognized Red Dead Redemption 2 graphics settings.")
            }
            attribute.stringValue = value
        }
        guard let api = try document.nodes(forXPath: "/rage__fwuiSystemSettingsCollection/advancedGraphics/API").first as? XMLElement else {
            throw PortError("Red Dead Redemption 2 graphics API is missing.")
        }
        api.stringValue = "kSettingAPI_DX12"
        return document.xmlData(options: [.nodePrettyPrint])
    }
}

extension Runtime {
    func applyGameFixes() throws {
        switch recipe.id {
        case "witcher3": try applyWitcherProxy()
        case "coh3": try applyCoh3Runtime()
        case "aoe3": try applyAoe3Startup()
        case "aoe3-2007": try applyAoe32007KeyLibrary()
        case "elden-ring": try applyEldenGraphics()
        case "red-alert2": try applyRedAlertDraw()
        case "heroes3": try applyHeroes3Fixes()
        case "zero-hour": try applyZeroHourOnline()
        case "rdr2": try applyRedDead()
        case "brink": try applyBrinkOpenGL()
        default: break
        }
    }

    func restoreWitcherLoader() throws {
        guard recipe.id == "witcher3", let folder = game?.deletingLastPathComponent() else { return }
        let loader = folder.appendingPathComponent("amd_fidelityfx_loader_dx12.dll")
        let backup = folder.appendingPathComponent("amd_fidelityfx_loader_dx12_orig.dll")
        guard files.fileExists(backup) else { return }
        if files.fileExists(loader) { try files.removeItem(loader) }
        try files.moveItem(from: backup, to: loader)
    }

    private func installBundledFile(_ relative: String, to destination: URL) throws {
        let source = try GameFixes.fixesRoot().appendingPathComponent(relative)
        let data = try Data(contentsOf: source)
        if files.fileExists(destination), let current = try? files.read(destination), SteamInstaller.digest(of: current) == SteamInstaller.digest(of: data) {
            return
        }
        try files.createDirectory(destination.deletingLastPathComponent())
        try files.write(data, to: destination)
    }

    private func regAdd(key: String, name: String, data: String) throws {
        try commands.run(
            executable: wine,
            arguments: ["reg", "add", key, "/v", name, "/t", "REG_SZ", "/d", data, "/f"],
            environment: wineEnvironment(),
            timeout: 60,
            workingDirectory: nil
        )
    }

    private func applyWitcherProxy() throws {
        guard let folder = game?.deletingLastPathComponent() else { return }
        let loader = folder.appendingPathComponent("amd_fidelityfx_loader_dx12.dll")
        guard files.fileExists(loader) else { return }
        let current = try files.read(loader)
        let digest = SteamInstaller.digest(of: current)
        if digest == GameFixes.witcherProxySHA { return }
        guard digest == GameFixes.witcherOriginalSHA else {
            sink.say("Witcher 3 graphics proxy was left unchanged. This loader does not match the tested file.")
            return
        }
        let backup = folder.appendingPathComponent("amd_fidelityfx_loader_dx12_orig.dll")
        if !files.fileExists(backup) { try files.write(current, to: backup) }
        try unpackBundledArchive(
            GameFixes.witcherProxyArchive,
            member: "amd_fidelityfx_loader_dx12.dll",
            to: loader,
            archiveSHA: GameFixes.witcherProxyArchiveSHA,
            fileSHA: GameFixes.witcherProxySHA
        )
        guard SteamInstaller.digest(of: try files.read(loader)) == GameFixes.witcherProxySHA else {
            try restoreWitcherLoader()
            throw PortError("The Witcher 3 graphics proxy failed verification. The original loader was restored.")
        }
    }

    private func applyCoh3Runtime() throws {
        let dll = prefix.appendingPathComponent("drive_c/windows/system32/ucrtbase.dll")
        let receipt = root.appendingPathComponent("coh3-compatibility.json")
        if coh3RuntimeReady(dll: dll, receipt: receipt) { return }
        sink.say("Preparing Company of Heroes 3 multiplayer compatibility…")
        let package = try downloadPinnedFile(
            name: "VC_redist.x64.exe",
            url: GameFixes.coh3PackageURL,
            expected: GameFixes.coh3PackageSHA,
            progress: "Downloading the pinned Microsoft runtime…",
            mismatch: "The Microsoft runtime download does not match the pinned SHA-256."
        )
        let staged = root.appendingPathComponent("ucrtbase-staging.dll")
        if files.fileExists(staged) { try files.removeItem(staged) }
        try extractCoh3DLL(package: package, to: staged)
        try files.createDirectory(dll.deletingLastPathComponent())
        if files.fileExists(dll) { try files.removeItem(dll) }
        try files.moveItem(from: staged, to: dll)
        try regAdd(key: #"HKCU\Software\Wine\DllOverrides"#, name: "ucrtbase", data: "builtin")
        try regAdd(key: #"HKCU\Software\Wine\AppDefaults\RelicCoH3.exe\DllOverrides"#, name: "ucrtbase", data: "native,builtin")
        _ = try? commands.run(
            executable: wineserver,
            arguments: ["-k"],
            environment: wineEnvironment(),
            timeout: 30,
            workingDirectory: nil
        )
        let body = "{\"version\":\"coh3-ucrt-v1\",\"sha256\":\"\(GameFixes.coh3DLLSHA)\"}\n"
        try files.write(Data(body.utf8), to: receipt)
    }

    private func coh3RuntimeReady(dll: URL, receipt: URL) -> Bool {
        guard files.fileExists(dll), files.fileExists(receipt),
            let dllData = try? files.read(dll), SteamInstaller.digest(of: dllData) == GameFixes.coh3DLLSHA,
            let receiptData = try? files.read(receipt)
        else { return false }
        return String(decoding: receiptData, as: UTF8.self).contains(GameFixes.coh3DLLSHA)
    }

    private func extractCoh3DLL(package: URL, to destination: URL) throws {
        let data = try files.read(package)
        guard SteamInstaller.digest(of: data) == GameFixes.coh3PackageSHA else {
            throw PortError("The Microsoft runtime download differs from the pinned version.")
        }
        let stage = root.appendingPathComponent("crt-extract")
        if files.fileExists(stage) { try files.removeItem(stage) }
        try files.createDirectory(stage)
        defer { try? files.removeItem(stage) }
        for (index, cabinet) in GameFixes.cabinets(in: data).enumerated() {
            let file = stage.appendingPathComponent("payload-\(index).cab")
            try files.write(cabinet, to: file)
            let listing = try commands.run(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-tf", file.path],
                environment: [:],
                timeout: 30,
                workingDirectory: nil
            )
            let names = listing.split(whereSeparator: \.isNewline).map(String.init)
            guard names.contains("a10") else { continue }
            try commands.run(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xf", file.path, "-C", stage.path, "a10"],
                environment: [:],
                timeout: 40,
                workingDirectory: nil
            )
            let inner = stage.appendingPathComponent("a10")
            try commands.run(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xf", inner.path, "-C", stage.path, "ucrtbase.dll"],
                environment: [:],
                timeout: 40,
                workingDirectory: nil
            )
            let extracted = try files.read(stage.appendingPathComponent("ucrtbase.dll"))
            guard SteamInstaller.digest(of: extracted) == GameFixes.coh3DLLSHA else {
                throw PortError("The Microsoft runtime failed verification.")
            }
            try files.write(extracted, to: destination)
            return
        }
        throw PortError("The pinned Microsoft runtime could not be extracted.")
    }

    /// The 2007 CD-key window loads `PidGen.dll`, which imports `MFC42.DLL`. Wine does not ship that library.
    private func applyAoe32007KeyLibrary() throws {
        guard let folder = game?.deletingLastPathComponent() else { return }
        let library = folder.appendingPathComponent("mfc42.dll")
        if let current = try? files.read(library), SteamInstaller.digest(of: current) == GameFixes.mfc42DLLSHA {
            return
        }
        sink.say("Installing the Microsoft library Age of Empires III uses for its CD-key check…")
        try unpackBundledArchive(
            "MFC42/mfc42.tar.xz",
            member: "mfc42.dll",
            to: library,
            archiveSHA: GameFixes.mfc42ArchiveSHA,
            fileSHA: GameFixes.mfc42DLLSHA
        )
        guard SteamInstaller.digest(of: try files.read(library)) == GameFixes.mfc42DLLSHA else {
            throw PortError("The Microsoft library failed verification.")
        }
    }

    /// Unpack a bundled `.tar.xz` when `destination` is missing or does not match `fileSHA`.
    private func unpackBundledArchive(
        _ relative: String,
        member: String,
        to destination: URL,
        archiveSHA: String,
        fileSHA: String
    ) throws {
        if let current = try? files.read(destination), SteamInstaller.digest(of: current) == fileSHA {
            return
        }
        let archive = try GameFixes.fixesRoot().appendingPathComponent(relative)
        let packed = try Data(contentsOf: archive)
        guard SteamInstaller.digest(of: packed) == archiveSHA else {
            throw PortError("The bundled archive \(relative) does not match the pinned SHA-256.")
        }
        let stage = root.appendingPathComponent("archive-extract")
        if files.fileExists(stage) { try files.removeItem(stage) }
        try files.createDirectory(stage)
        defer { try? files.removeItem(stage) }
        try commands.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xJf", archive.path, "-C", stage.path],
            environment: [:],
            timeout: 30,
            workingDirectory: nil
        )
        let extracted = stage.appendingPathComponent(member)
        guard files.fileExists(extracted),
            SteamInstaller.digest(of: try files.read(extracted)) == fileSHA
        else {
            throw PortError("The bundled archive \(relative) did not contain \(member).")
        }
        try files.createDirectory(destination.deletingLastPathComponent())
        if files.fileExists(destination) { try files.removeItem(destination) }
        try files.moveItem(from: extracted, to: destination)
    }

    private func applyAoe3Startup() throws {
        guard let game, files.fileExists(game) else { return }
        guard SteamInstaller.digest(of: try files.read(game)) == GameFixes.aoe3ExecutableSHA else {
            sink.say("This Age of Empires III build keeps its original startup checks and settings.")
            return
        }
        let graphics = userProfile.appendingPathComponent("Games/Age of Empires 3 DE/Common/GraphicalProfile.xml")
        if !files.fileExists(graphics) {
            try installBundledFile("AoE3/graphics-default.xml", to: graphics)
        }
        let key = #"HKEY_CURRENT_USER\Software\Microsoft\Microsoft Games\Age of Empires III DE"#
        try regAdd(key: key, name: "IgnoreUnsupportedSystem", data: "1")
        try regAdd(key: key, name: "SystemInitialization", data: "1")
    }

    private func applyEldenGraphics() throws {
        let graphics = userProfile.appendingPathComponent("AppData/Roaming/EldenRing/GraphicsConfig.xml")
        if files.fileExists(graphics) { return }
        let template = try Data(contentsOf: try GameFixes.fixesRoot().appendingPathComponent("EldenRing/graphics-default.xml"))
        let size = MainScreenDisplay().mainDisplaySize() ?? (width: 1280, height: 720)
        let data = try GameFixes.eldenGraphics(template: template, width: size.width, height: size.height)
        try files.createDirectory(graphics.deletingLastPathComponent())
        try files.write(data, to: graphics)
        sink.say("Elden Ring display defaults: \(size.width) × \(size.height), borderless.")
    }

    private func applyRedAlertDraw() throws {
        guard let folder = game?.deletingLastPathComponent() else { return }
        try unpackBundledArchive(
            GameFixes.cncDdrawArchive,
            member: "ddraw.dll",
            to: folder.appendingPathComponent("ddraw.dll"),
            archiveSHA: GameFixes.cncDdrawArchiveSHA,
            fileSHA: GameFixes.cncDdrawSHA
        )
        try installBundledFile("RedAlert2/ddraw.ini", to: folder.appendingPathComponent("ddraw.ini"))
        try installBundledFile(
            "RedAlert2/Shaders/interpolation/catmull-rom-bilinear.glsl",
            to: folder.appendingPathComponent("Shaders/interpolation/catmull-rom-bilinear.glsl")
        )
    }

    private func applyHeroes3Fixes() throws {
        guard let folder = game?.deletingLastPathComponent() else { return }
        try unpackBundledArchive(
            GameFixes.cncDdrawArchive,
            member: "ddraw.dll",
            to: folder.appendingPathComponent("xdd.dll"),
            archiveSHA: GameFixes.cncDdrawArchiveSHA,
            fileSHA: GameFixes.cncDdrawSHA
        )
        try installBundledFile("Heroes3/ddraw.ini", to: folder.appendingPathComponent("ddraw.ini"))
        let library = folder.appendingPathComponent("MSS32.DLL")
        guard files.fileExists(library) else { return }
        let original = try files.read(library)
        let fixed = try GameFixes.patchedHeroesAudio(original)
        guard fixed != original else { return }
        let backup = root.appendingPathComponent("backups/heroes3/MSS32.DLL")
        if !files.fileExists(backup) {
            try files.createDirectory(backup.deletingLastPathComponent())
            try files.write(original, to: backup)
        }
        try files.write(fixed, to: library)
    }

    private func applyBrinkOpenGL() throws {
        guard let game, files.fileExists(game) else { return }
        let original = try files.read(game)
        let digest = SteamInstaller.digest(of: original)
        guard digest == GameFixes.brinkOpenGLSHA || GameFixes.brinkOpenGLInputSHAs.contains(digest) else {
            sink.say("This BRINK build keeps its original OpenGL check.")
            return
        }
        try unpackBundledArchive(
            GameFixes.brinkShaderLibraryArchive,
            member: "brinkglsl.dll",
            to: game.deletingLastPathComponent().appendingPathComponent("brinkglsl.dll"),
            archiveSHA: GameFixes.brinkShaderLibraryArchiveSHA,
            fileSHA: GameFixes.brinkShaderLibrarySHA
        )
        if digest == GameFixes.brinkOpenGLSHA { return }
        let adjusted = try GameFixes.patchedBrinkOpenGL(original)
        guard adjusted != original else { return }
        let backup = root.appendingPathComponent("backups/brink/brink.exe")
        if !files.fileExists(backup) {
            try files.createDirectory(backup.deletingLastPathComponent())
            try files.write(original, to: backup)
        }
        try files.write(adjusted, to: game)
        sink.say("BRINK accepts the Mac OpenGL driver.")
    }

    private func applyRedDead() throws {
        guard let folder = game?.deletingLastPathComponent() else { return }
        guard files.fileExists(folder.appendingPathComponent("PlayRDR2.exe")) else {
            throw PortError("Red Dead Redemption 2 files are incomplete. Verify the game in Steam, then try Play again.")
        }
        try installRockstarLauncher()
        try seedRedDeadSettings()
    }

    private var rockstarLauncher: URL {
        prefix.appendingPathComponent("drive_c/Program Files/Rockstar Games/Launcher/Launcher.exe")
    }

    private func installRockstarLauncher() throws {
        let patcher = rockstarLauncher.deletingLastPathComponent().appendingPathComponent("LauncherPatcher.exe")
        if files.fileExists(rockstarLauncher), files.fileExists(patcher) { return }
        sink.say("Installing Rockstar Games Launcher…")
        let package = try downloadPinnedFile(
            name: "Rockstar-Games-Launcher.exe",
            url: GameFixes.rockstarInstallerURL,
            expected: GameFixes.rockstarInstallerSHA,
            progress: "Downloading the official Rockstar Games Launcher…",
            mismatch: "The Rockstar Games Launcher download does not match the pinned SHA-256."
        )
        try commands.run(
            executable: wine,
            arguments: [package.path, "/s", "/f"],
            environment: wineEnvironment(advertiseAVX: false),
            timeout: 240,
            workingDirectory: package.deletingLastPathComponent()
        )
        guard files.fileExists(rockstarLauncher), files.fileExists(patcher) else {
            throw PortError("Rockstar setup did not finish. Play again to retry. The downloaded installer is kept.")
        }
        sink.say("Rockstar is installed. On first play, complete its sign-in and any account-linking prompts.")
    }

    private func seedRedDeadSettings() throws {
        let settings = userProfile.appendingPathComponent("Documents/Rockstar Games/Red Dead Redemption 2/Settings/system.xml")
        if files.fileExists(settings) { return }
        let template = try Data(contentsOf: try GameFixes.fixesRoot().appendingPathComponent("RedDead/system-default.xml"))
        let size = MainScreenDisplay().mainDisplaySize() ?? (width: 1920, height: 1080)
        let data = try GameFixes.redDeadSettings(template: template, width: size.width, height: size.height)
        try files.createDirectory(settings.deletingLastPathComponent())
        try files.write(data, to: settings)
        sink.say("Red Dead Redemption 2 fullscreen: \(size.width)×\(size.height).")
    }

    private func applyZeroHourOnline() throws {
        guard let folder = game?.deletingLastPathComponent() else { return }
        if generalsOnlineReady(in: folder) { return }
        let package = try downloadPinnedFile(
            name: "GeneralsOnline_setup_092226_QFE2.exe",
            url: GameFixes.generalsOnlineURL,
            expected: GameFixes.generalsOnlineSHA,
            progress: "Downloading the pinned GeneralsOnline installer…",
            mismatch: "The GeneralsOnline installer does not match the pinned SHA-256."
        )
        let staged = prefix.appendingPathComponent("drive_c/GeneralsOnline_setup.exe")
        try files.write(try files.read(package), to: staged)
        try files.createDirectory(logs)
        try commands.start(
            executable: wine,
            arguments: [#"C:\GeneralsOnline_setup.exe"#],
            environment: wineEnvironment(),
            workingDirectory: prefix.appendingPathComponent("drive_c"),
            log: logs.appendingPathComponent("generals-online-setup.log")
        )
        throw PortError("Finish the GeneralsOnline installer, then play again.")
    }

    private func generalsOnlineReady(in folder: URL) -> Bool {
        for (name, digest) in GameFixes.generalsOnlineFiles {
            let file = folder.appendingPathComponent(name)
            guard files.fileExists(file), let data = try? files.read(file), SteamInstaller.digest(of: data) == digest else { return false }
        }
        return true
    }
}
