import Foundation
import CryptoKit
import Darwin

public struct PortnautError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Session-wide settings shared by every bottle.
public enum GraphicsProfile {
    /// WebGL on ANGLE's Direct3D 11 path inside the launcher process; the interface composites in software.
    public static let connectBrowserArguments = ["--in-process-gpu", "--use-gl=angle", "--use-angle=d3d11", "--disable-gpu-compositing"]
    /// Steam's web helper (Chromium) in software, with its compositor in the process that owns the window.
    public static let steamWebHelperSwitches = "--in-process-gpu --disable-gpu"
    /// Wine reports the Mac's current mode and scaled virtual modes, and accepts a game's mode
    /// change without switching the real display. Without it, AC III switched a ProMotion panel
    /// to 47/48 Hz and back on every alt-tab, which mis-scaled the window. Despite the key name,
    /// this is win32u's option for every driver.
    public static let displayRegistry = """
    [HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
    "EmulateModeset"="y"

    """
    public static let frameRateLimits = [30, 40, 45, 60, 90, 120]
    /// DXMT paces presents to this rate. With VSync off, frames no longer queue behind the display.
    /// DXMT's own settings, separated by ";". With MetalFX, DXMT scales the game's output by the factor.
    public static func dxmtConfig(frameRateLimit: Int?, metalFXFactor: Double? = nil) -> String? {
        var options: [String] = []
        if let frameRateLimit, frameRateLimit > 0 { options.append("d3d11.preferredMaxFrameRate = \(frameRateLimit)") }
        if let metalFXFactor { options.append("d3d11.metalSpatialUpscaleFactor = \(metalFXFactor)") }
        return options.isEmpty ? nil : options.joined(separator: ";")
    }
}

public struct PEInfo: Sendable {
    public var architecture: String?
    /// DLL names from the import and delay-import tables, as written in the file.
    public var imports: [String]
}

public enum PEImage {
    /// The Wine library folder matching a Windows program's CPU, or nil when it is not a supported PE image.
    public static func wineArchitecture(of url: URL) throws -> String? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let dos = try file.read(upToCount: 64), dos.count == 64, dos.prefix(2) == Data("MZ".utf8) else { return nil }
        let offset = UInt64(dos[60]) | UInt64(dos[61]) << 8 | UInt64(dos[62]) << 16 | UInt64(dos[63]) << 24
        try file.seek(toOffset: offset)
        guard let header = try file.read(upToCount: 6), header.count == 6, header.prefix(4) == Data([0x50, 0x45, 0, 0]) else { return nil }
        return architecture(machine: Int(header[4]) | Int(header[5]) << 8)
    }

    static func architecture(machine: Int) -> String? {
        switch machine {
        case 0x8664: "x86_64-windows"
        case 0x014c: "i386-windows"
        default: nil
        }
    }

    /// Architecture and imported DLLs, read from the PE headers. The file is mapped, not loaded.
    public static func inspect(_ url: URL) throws -> PEInfo? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= data.count ? Int(data[o]) | Int(data[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? { o >= 0 && o + 4 <= data.count ? (0..<4).reduce(0) { $0 | Int(data[o + $1]) << (8 * $1) } : nil }
        guard data.count >= 64, data[0] == 0x4d, data[1] == 0x5a, let pe = u32(60), u32(pe) == 0x4550 else { return nil }
        let coff = pe + 4
        guard let machine = u16(coff), let sectionCount = u16(coff + 2), let optionalSize = u16(coff + 16) else { return nil }
        let optional = coff + 20
        guard let magic = u16(optional), magic == 0x10b || magic == 0x20b else { return nil }
        let plus = magic == 0x20b
        let imageBase = plus ? (u32(optional + 24) ?? 0) | (u32(optional + 28) ?? 0) << 32 : u32(optional + 28) ?? 0
        let directoryCount = u32(optional + (plus ? 108 : 92)) ?? 0
        let directories = optional + (plus ? 112 : 96)
        var sections: [(address: Int, size: Int, raw: Int)] = []
        for i in 0..<min(sectionCount, 96) {
            let s = optional + optionalSize + i * 40
            guard let virtualSize = u32(s + 8), let address = u32(s + 12), let rawSize = u32(s + 16), let raw = u32(s + 20) else { break }
            sections.append((address, max(virtualSize, rawSize), raw))
        }
        func offset(_ rva: Int) -> Int? {
            sections.first { rva >= $0.address && rva < $0.address + $0.size }.map { rva - $0.address + $0.raw }
        }
        func string(_ rva: Int) -> String? {
            guard let start = offset(rva), start < data.count else { return nil }
            let end = data[start..<min(start + 256, data.count)].firstIndex(of: 0) ?? min(start + 256, data.count)
            return String(data: data[start..<end], encoding: .ascii)
        }
        var imports: [String] = []
        if directoryCount > 1, let rva = u32(directories + 8), rva != 0, var entry = offset(rva) {
            for _ in 0..<1024 {
                guard let lookup = u32(entry), let name = u32(entry + 12), lookup != 0 || name != 0 else { break }
                if let module = string(name) { imports.append(module) }
                entry += 20
            }
        }
        if directoryCount > 13, let rva = u32(directories + 13 * 8), rva != 0, var entry = offset(rva) {
            for _ in 0..<1024 {
                guard let attributes = u32(entry), let field = u32(entry + 4), attributes != 0 || field != 0 else { break }
                // Old-style descriptors hold virtual addresses rather than RVAs.
                if let module = string(attributes & 1 != 0 ? field : field - imageBase) { imports.append(module) }
                entry += 32
            }
        }
        return PEInfo(architecture: architecture(machine: machine), imports: imports)
    }
}

public struct PortnautPaths: Sendable {
    public let root: URL
    /// Save backups go to ~/Documents/Portnaut Backups, or inside an isolated test root.
    public let saveBackups: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Portnaut", isDirectory: true)
        saveBackups = root?.appendingPathComponent("Portnaut Backups")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Portnaut Backups")
    }
    public var runtime: URL { root.appendingPathComponent("Runtimes/highball-wine-11-r27") }
    /// Portnaut 0.1.x's runtime: one engine with DXMT built in.
    public var legacyRuntime: URL { root.appendingPathComponent("Runtimes/highball-wine-11-r27-dxmt-a444716") }
    /// The unmodified engine, which is also the wined3d renderer.
    public var engine: URL { runtime.appendingPathComponent("engine") }
    public func engine(for renderer: Renderer) -> URL {
        renderer.variantFolder.map { runtime.appendingPathComponent("renderers/\($0)") } ?? engine
    }
    public func wine(for renderer: Renderer) -> URL { engine(for: renderer).appendingPathComponent("bin/wine") }
    public func wineserver(for renderer: Renderer) -> URL { engine(for: renderer).appendingPathComponent("bin/wineserver") }
    public var libraries: URL { runtime.appendingPathComponent("Libraries") }
    public var bottles: URL { root.appendingPathComponent("Bottles") }
    public var logs: URL { root.appendingPathComponent("Logs") }
    public var cache: URL { root.appendingPathComponent("Downloads") }
    public var library: URL { root.appendingPathComponent("library.json") }
    /// v3: an unmodified engine plus one clone per renderer.
    /// v4 adds DXMT's DLSS bridge (nvapi64, nvngx) to its copy.
    public var runtimeMarker: URL { runtime.appendingPathComponent(".portnaut-runtime-v4") }
    /// What the runtime was built from (InstalledRuntime).
    public var runtimeManifest: URL { runtime.appendingPathComponent("components.json") }
    /// The runtime before the last component update, kept for rolling back.
    public var previousRuntime: URL { root.appendingPathComponent("Runtimes/previous") }
    /// The chosen update channel.
    public var updateSettings: URL { root.appendingPathComponent("updates.json") }
    /// APFS clones of bottles, by bottle id.
    public var snapshots: URL { root.appendingPathComponent("Snapshots") }
    public var setupLog: URL { logs.appendingPathComponent("setup.log") }
    public var sessionLog: URL { logs.appendingPathComponent("session.log") }
    public func createDirectories() throws {
        for url in [root, runtime.deletingLastPathComponent(), bottles, logs, cache] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
    public var runtimeReady: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: runtimeMarker.path)
            && Renderer.allCases.allSatisfy { fm.isExecutableFile(atPath: wine(for: $0).path) }
            && fm.fileExists(atPath: libraries.appendingPathComponent("libinotify.0.dylib").path)
    }
    /// An older runtime is installed: 0.1.x's, or this one from before the current layout.
    public var runtimeOutdated: Bool {
        !runtimeReady && (FileManager.default.fileExists(atPath: legacyRuntime.path) || FileManager.default.fileExists(atPath: runtime.appendingPathComponent("engine").path))
    }
    public func bottle(_ bottle: Bottle) -> BottlePaths { BottlePaths(prefix: bottles.appendingPathComponent(bottle.id)) }

    /// Reads library.json, migrating Portnaut 0.1.x's single-game file into a Ubisoft Connect bottle.
    public func loadLibrary() throws -> Library {
        let fm = FileManager.default
        guard fm.fileExists(atPath: library.path) else {
            // A 0.1.x environment without a library file still becomes a bottle.
            let legacy = bottles.appendingPathComponent(KnownGame.ac3.legacyBottleID)
            return fm.fileExists(atPath: legacy.appendingPathComponent(".portnaut-ready-v1").path) ? LegacyLibraryState().migrated() : Library()
        }
        let data = try Data(contentsOf: library)
        struct Schema: Decodable { var schema: Int? }
        if (try JSONDecoder().decode(Schema.self, from: data)).schema ?? 1 >= 2 {
            return try JSONDecoder().decode(Library.self, from: data)
        }
        return try JSONDecoder().decode(LegacyLibraryState.self, from: data).migrated()
    }
    public func saveLibrary(_ state: Library) throws {
        try createDirectories()
        let fm = FileManager.default
        // Keep a 0.1.x file once, before the first save in the new format replaces it.
        let backup = root.appendingPathComponent("library.v1.json")
        if fm.fileExists(atPath: library.path), !fm.fileExists(atPath: backup.path),
           let data = try? Data(contentsOf: library), !String(decoding: data, as: UTF8.self).contains("\"bottles\"") {
            try fm.copyItem(at: library, to: backup)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: library, options: .atomic)
    }
    public static func isContained(_ candidate: URL, by parent: URL) -> Bool {
        let p = parent.resolvingSymlinksInPath().standardizedFileURL.path
        let c = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return c.hasPrefix(p + "/")
    }
}

public struct BottlePaths: Sendable {
    public let prefix: URL
    public var drive: URL { prefix.appendingPathComponent("drive_c") }
    public var marker: URL { prefix.appendingPathComponent(".portnaut-ready-v1") }
    public var ready: Bool {
        FileManager.default.fileExists(atPath: marker.path) && FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path)
    }
    /// A path stored relative to drive_c, if it stays inside it and exists.
    public func url(for relative: String) -> URL? {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let url = drive.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard PortnautPaths.isContained(url, by: drive), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    public func relativePath(_ url: URL) throws -> String { try Self.relative(url, drive: drive) }
    public static func relative(_ url: URL, drive: URL) throws -> String {
        guard PortnautPaths.isContained(url, by: drive) else { throw PortnautError("Select a file inside this bottle’s Windows drive.") }
        return String(url.resolvingSymlinksInPath().path.dropFirst(drive.resolvingSymlinksInPath().path.count + 1))
    }
    public func windowsPath(_ url: URL) throws -> String {
        "C:\\" + (try relativePath(url)).replacingOccurrences(of: "/", with: "\\")
    }
}

public struct DownloadArtifact: Sendable {
    public let name: String
    public let url: URL
    public let sha256: String
    public static let wine = DownloadArtifact(name: "highball-wine.tar.gz", url: URL(string: "https://github.com/gauthierpiarrette/highball-engine/releases/download/engine-wine-11.0-20261014T003801Z-0024-app-packages-0023-spatial-mixer/engine-wine-11.0-20261014T003801Z-0024-app-packages-0023-spatial-mixer.tar.gz")!, sha256: "1d1a130c0108a4bbb88cd289c3c313292868c3b84010eb315801eba43026e3e8")
    public static let dxmt = DownloadArtifact(name: "highball-dxmt.tar.gz", url: URL(string: "https://github.com/gauthierpiarrette/highball-engine/releases/download/dxmt-highball-20260930T161516Z-a444716/dxmt-highball-20260930T161516Z-a444716.tar.gz")!, sha256: "96feaf5d98d3c6cdc3edea9503e2891d435df8d5bfdf7d3f6998a56ec62bbd58")
    /// The Sikarugir template: support libraries, plus the D3DMetal, DXVK and D9VK renderers.
    public static let support = DownloadArtifact(name: "highball-runtime.tar.xz", url: URL(string: "https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.11.tar.xz")!, sha256: "9fa15479e7ff6abd99c1d07be285fb95f41fc6991586502427152b1f7d6ccb8a")
}

public enum FileIntegrity {
    public static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func verify(_ url: URL, expected: String) throws {
        guard try sha256(url) == expected.lowercased() else {
            throw PortnautError("The download failed its integrity check. Nothing was installed. Retry the download.")
        }
    }
}

public enum GameImport {
    public static func validate(_ folder: URL) throws {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(KnownGame.ac3.executable).path) else {
            throw PortnautError("Choose the Assassin’s Creed III Remastered folder containing ACIII.exe.")
        }
    }
    /// APFS clonefile is mandatory: never silently fall back to a 44 GB physical copy.
    public static func cloneTree(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !fm.fileExists(atPath: destination.path), !PortnautPaths.isContained(destination, by: source) else {
            throw PortnautError("The import destination already exists or is inside the source folder.")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            var traversalError: Error?
            guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey], options: [], errorHandler: { _, error in traversalError = error; return false }) else {
                throw PortnautError("The game folder could not be read.")
            }
            for case let file as URL in enumerator {
                let file = file.standardizedFileURL
                let relative = file.pathComponents.dropFirst(source.pathComponents.count).joined(separator: "/")
                let target = destination.appendingPathComponent(relative)
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                if values.isSymbolicLink == true {
                    throw PortnautError("This folder contains symbolic links. Install the game through its launcher in Portnaut instead.")
                } else if values.isDirectory == true {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else if values.isRegularFile == true {
                    if clonefile(file.path, target.path, 0) != 0 {
                        throw PortnautError("A space-saving copy of \(file.lastPathComponent) could not be created (\(String(cString: strerror(errno)))). Keep the source and Portnaut on the same APFS disk, or install through the launcher.")
                    }
                } else {
                    throw PortnautError("The game folder contains an unsupported file type.")
                }
            }
            if let error = traversalError { throw error }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }
}

extension Renderer {
    /// Whether this renderer's fast path covers a program of the given architecture.
    public func handles(_ architecture: String?) -> Bool {
        switch self {
        case .dxmt, .d3dmetal: architecture == "x86_64-windows"
        case .dxvk, .wined3d: architecture != nil
        }
    }
}
