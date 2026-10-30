import Foundation
import Testing
@testable import PortnautCore

@Suite
final class CoreTests {
    var root: URL!
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("portnaut-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    // MARK: - Paths and files

    @Test func testGamePathsCannotEscapeTheBottle() throws {
        let paths = PortnautPaths(root: root).bottle(Bottle(id: "test", name: "Test", renderer: .dxmt))
        try FileManager.default.createDirectory(at: paths.drive, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("ACIII.exe")
        try Data("game".utf8).write(to: outside)
        #expect(paths.url(for: "../../ACIII.exe") == nil)
        #expect(paths.url(for: outside.path) == nil)
        try FileManager.default.createSymbolicLink(at: paths.drive.appendingPathComponent("escape.exe"), withDestinationURL: outside)
        #expect(paths.url(for: "escape.exe") == nil)
        #expect(throws: PortnautError.self) { try paths.windowsPath(outside) }
    }
    @Test func testWindowsPathsPreserveSpacesAndApostrophes() throws {
        let paths = PortnautPaths(root: root).bottle(Bottle(id: "test", name: "Test", renderer: .dxmt))
        try FileManager.default.createDirectory(at: paths.drive, withIntermediateDirectories: true)
        let url = paths.drive.appendingPathComponent("Games/Assassin's Creed III/ACIII.exe")
        #expect(try paths.windowsPath(url) == "C:\\Games\\Assassin's Creed III\\ACIII.exe")
        #expect(!PortnautPaths.isContained(root.appendingPathComponent("Bottles/test/drive_c-other/file"), by: paths.drive))
    }
    @Test func testIntegrityRejectsChangedDownloads() throws {
        let file = root.appendingPathComponent("download")
        try Data("abc".utf8).write(to: file)
        #expect(try FileIntegrity.sha256(file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(throws: PortnautError.self) { try FileIntegrity.verify(file, expected: String(repeating: "0", count: 64)) }
    }
    @Test func testClonedGameDoesNotChangeOriginal() throws {
        let source = root.appendingPathComponent("original")
        let destination = root.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("ACIII.exe")
        try Data("original".utf8).write(to: file)
        try GameImport.cloneTree(from: source, to: destination)
        try Data("changed".utf8).write(to: destination.appendingPathComponent("ACIII.exe"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        #expect(throws: PortnautError.self) { try GameImport.cloneTree(from: source, to: destination) }
    }
    @Test func testImportRejectsSymlinksAndCleansPartialCopy() throws {
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("external"), withDestinationURL: root.appendingPathComponent("not-game-data"))
        #expect(throws: PortnautError.self) { try GameImport.cloneTree(from: source, to: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Bottles

    @Test func testEachBottleGetsItsOwnPrefixRendererAndOptions() {
        let paths = PortnautPaths(root: root)
        let shim = root.appendingPathComponent("libPortnautMetalShim.dylib")
        let service = WineService(paths: paths, metalShim: shim)
        var ubisoft = Bottle(id: "ubisoft", name: "Ubisoft Connect", launcher: .ubisoft, renderer: .dxmt)
        ubisoft.options.frameRateLimit = 45
        ubisoft.options.performanceHUD = true
        ubisoft.options.reduceFrameQueue = true
        let env = service.environment(for: ubisoft)
        #expect(env["WINEPREFIX"] == paths.bottles.appendingPathComponent("ubisoft").path)
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEDLLOVERRIDES"] == "d3d11,dxgi,d3d10core=b;nvapi,nvapi64=;winemenubuilder.exe=d")
        #expect(env["PATH"]?.hasPrefix(paths.runtime.appendingPathComponent("renderers/dxmt/bin").path) == true)
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"]?.contains(paths.runtime.appendingPathComponent("renderers/dxmt/lib/wine/x86_64-unix").path) == true)
        #expect(env["DYLD_INSERT_LIBRARIES"] == shim.path)
        #expect(env["DYLD_LIBRARY_PATH"] == nil)
        #expect(env["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate = 45")
        #expect(env["MTL_HUD_ENABLED"] == "1" && env["PORTNAUT_LATENCY_TRACE"] == "1" && env["PORTNAUT_FRAME_QUEUE"] == "2")
        // Ubisoft's browser does not render through DXMT, so its cross-process mode stays off.
        #expect(env["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"] == nil)

        var steam = Bottle(id: "games", name: "Games", renderer: .d3dmetal)
        steam.msync = false
        steam.options.frameRateLimit = 45
        let other = WineService(paths: paths, metalShim: nil).environment(for: steam)
        #expect(other["WINEPREFIX"] == paths.bottles.appendingPathComponent("games").path)
        #expect(other["WINEMSYNC"] == nil)
        #expect(other["WINEDLLOVERRIDES"] == "d3d11,dxgi,d3d10core,d3d12=b;nvapi,nvapi64=;winemenubuilder.exe=d")
        #expect(other["PATH"]?.hasPrefix(paths.runtime.appendingPathComponent("renderers/d3dmetal/bin").path) == true)
        #expect(other["DXMT_CONFIG"] == nil)
        #expect(other["DYLD_INSERT_LIBRARIES"] == nil)
        // Recording is on by default and independent of the HUD.
        #expect(other["MTL_HUD_ENABLED"] == "0" && other["PORTNAUT_LATENCY_TRACE"] == "1")
        steam.options.recordPerformance = false
        #expect(WineService(paths: paths, metalShim: nil).environment(for: steam)["PORTNAUT_LATENCY_TRACE"] == nil)
        #expect(WineService(paths: paths).environment(for: Bottle(id: "w", name: "W", renderer: .wined3d))["PATH"]?.hasPrefix(paths.engine.appendingPathComponent("bin").path) == true)
    }
    @Test func testProfileFollowsBottleSettings() {
        let ubisoft = WineService.profile(for: Bottle(id: "ubisoft", name: "Ubisoft Connect", launcher: .ubisoft, renderer: .dxmt))
        #expect(ubisoft.contains("\"Version\"=\"win10\"") && ubisoft.contains("\"RetinaMode\"=\"y\"") && ubisoft.contains("\"LogPixels\"=dword:000000c0"))
        #expect(ubisoft.contains("\"EmulateModeset\"=\"y\""))
        var plain = Bottle(id: "games", name: "Games", renderer: .dxvk)
        plain.windowsVersion = .win11
        plain.highResolution = false
        let other = WineService.profile(for: plain)
        #expect(other.contains("\"Version\"=\"win11\"") && other.contains("\"RetinaMode\"=\"n\"") && other.contains("\"LogPixels\"=dword:00000060"))
        #expect(!other.contains("AppDefaults"))
    }
    @Test func testUbisoftConnectGetsBrowserSwitchesAndNoGPUIdentity() {
        // Connect's browser draws through ANGLE in its own process. Portnaut never changes the GPU that
        // Connect reports (0.6.0's optional AMD identity was removed in 0.7.0).
        #expect(Launcher.ubisoft.arguments == ["--in-process-gpu", "--use-gl=angle", "--use-angle=d3d11", "--disable-gpu-compositing"])
        let profile = WineService.profile(for: Bottle(id: "u", name: "U", launcher: .ubisoft, renderer: .dxmt))
        #expect(!profile.contains("VideoPci") && !profile.contains("UbisoftConnect.exe") && Launcher.ubisoft.registry.isEmpty)
    }
    @Test func testLegacyLibraryBecomesAUbisoftBottle() throws {
        let paths = PortnautPaths(root: root)
        try Data(#"{"schema":1,"gameRelativePath":"Games/ACIII.exe","connectGPUOverride":true,"frameRateLimit":45,"performanceHUD":true,"reduceFrameQueue":true}"#.utf8).write(to: paths.library)
        let library = try paths.loadLibrary()
        let bottle = try #require(library.bottles.first)
        #expect(library.bottles.count == 1)
        #expect(bottle.id == "ac3-remastered" && bottle.launcher == .ubisoft && bottle.renderer == .dxmt)
        // The 0.1.x file's connectGPUOverride is a removed setting and is ignored.
        #expect(bottle.options.frameRateLimit == 45 && bottle.options.performanceHUD && bottle.options.reduceFrameQueue)
        #expect(bottle.games.map(\.executable) == ["Games/ACIII.exe"] && bottle.games.first?.id == "ac3-remastered")
        try paths.saveLibrary(library)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.v1.json").path))
        #expect(try paths.loadLibrary().bottles == library.bottles)
    }
    @Test func testLegacyEnvironmentWithoutLibraryFileIsKept() throws {
        let paths = PortnautPaths(root: root)
        #expect(try paths.loadLibrary().bottles.isEmpty)
        let legacy = paths.bottles.appendingPathComponent("ac3-remastered")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("ac3-remastered-profile-v1\n".utf8).write(to: legacy.appendingPathComponent(".portnaut-ready-v1"))
        #expect(try paths.loadLibrary().bottles.map(\.id) == ["ac3-remastered"])
    }
    @Test func testBottleIDsAreFolderSafeAndUnique() {
        var library = Library()
        #expect(library.newBottleID(for: "Steam & Friends!") == "steam-friends")
        library.bottles = [Bottle(id: "steam", name: "Steam", renderer: .dxmt)]
        #expect(library.newBottleID(for: "Steam") == "steam-2")
        #expect(library.newBottleID(for: "😀") == "bottle")
    }

    // MARK: - Renderers and recommendations

    /// A minimal PE file with an import table and a delay-import table.
    private func writePE(_ url: URL, machine: UInt16, imports: [String], delayed: [String] = []) throws {
        let plus = machine == 0x8664
        let optionalSize = plus ? 240 : 224
        var data = Data(count: 0x600)
        func put(_ value: Int, _ offset: Int, _ size: Int) { for i in 0..<size { data[offset + i] = UInt8((value >> (8 * i)) & 0xff) } }
        data[0] = 0x4d; data[1] = 0x5a; put(0x40, 0x3c, 4)
        put(0x4550, 0x40, 4)
        let coff = 0x44, optional = coff + 20
        put(Int(machine), coff, 2); put(1, coff + 2, 2); put(optionalSize, coff + 16, 2)
        put(plus ? 0x20b : 0x10b, optional, 2)
        put(16, optional + (plus ? 108 : 92), 4)
        let directories = optional + (plus ? 112 : 96)
        put(0x1000, directories + 8, 4); put(20 * (imports.count + 1), directories + 12, 4)
        if !delayed.isEmpty { put(0x1080, directories + 13 * 8, 4); put(32 * (delayed.count + 1), directories + 13 * 8 + 4, 4) }
        let section = optional + optionalSize
        put(0x1000, section + 8, 4); put(0x1000, section + 12, 4); put(0x400, section + 16, 4); put(0x200, section + 20, 4)
        func rawOffset(_ rva: Int) -> Int { rva - 0x1000 + 0x200 }
        var name = 0x1200
        for (i, module) in imports.enumerated() {
            put(0x1100, rawOffset(0x1000 + 20 * i), 4); put(name, rawOffset(0x1000 + 20 * i + 12), 4)
            data.replaceSubrange(rawOffset(name)..<rawOffset(name) + module.utf8.count, with: Data(module.utf8)); name += 0x20
        }
        for (i, module) in delayed.enumerated() {
            put(1, rawOffset(0x1080 + 32 * i), 4); put(name, rawOffset(0x1080 + 32 * i + 4), 4)
            data.replaceSubrange(rawOffset(name)..<rawOffset(name) + module.utf8.count, with: Data(module.utf8)); name += 0x20
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    @Test func testPEImportsAreRead() throws {
        let x64 = root.appendingPathComponent("a/game.exe"), x86 = root.appendingPathComponent("b/old.exe"), text = root.appendingPathComponent("c/readme.exe")
        try writePE(x64, machine: 0x8664, imports: ["KERNEL32.dll", "d3d11.dll", "DXGI.dll"], delayed: ["d3d12.dll"])
        try writePE(x86, machine: 0x014c, imports: ["d3d9.dll"])
        try FileManager.default.createDirectory(at: text.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a program".utf8).write(to: text)
        let info = try #require(try PEImage.inspect(x64))
        #expect(info.architecture == "x86_64-windows")
        #expect(info.imports == ["KERNEL32.dll", "d3d11.dll", "DXGI.dll", "d3d12.dll"])
        #expect(try PEImage.inspect(x86)?.imports == ["d3d9.dll"])
        #expect(try PEImage.inspect(x86)?.architecture == "i386-windows")
        #expect(try PEImage.inspect(text) == nil)
        #expect(try PEImage.wineArchitecture(of: x64) == "x86_64-windows")
    }
    @Test func testAdvisorRecommendsByGraphicsAPI() throws {
        func recommended(_ machine: UInt16, _ imports: [String], name: String = "game.exe") throws -> Renderer {
            let url = root.appendingPathComponent(UUID().uuidString + "/" + name)
            try writePE(url, machine: machine, imports: imports)
            return GraphicsAdvisor.analyze(url).recommendation.renderer
        }
        #expect(try recommended(0x8664, ["d3d12.dll", "dxgi.dll"]) == .d3dmetal)
        #expect(try recommended(0x8664, ["d3d11.dll"]) == .dxmt)
        #expect(try recommended(0x014c, ["d3d11.dll"]) == .dxvk)
        #expect(try recommended(0x014c, ["d3d9.dll"]) == .wined3d)
        #expect(try recommended(0x8664, ["vulkan-1.dll"]) == .wined3d)
        #expect(try recommended(0x8664, ["KERNEL32.dll"]) == .wined3d)
        // Engines that keep the renderer in a DLL next to the program.
        let unity = root.appendingPathComponent("unity/Game.exe")
        try writePE(unity, machine: 0x8664, imports: ["KERNEL32.dll"])
        try writePE(unity.deletingLastPathComponent().appendingPathComponent("UnityPlayer.dll"), machine: 0x8664, imports: ["d3d11.dll"])
        #expect(GraphicsAdvisor.analyze(unity).imported == [.d3d11])
        // An overlay that imports every API to hook it does not change a DirectX 11 game's recommendation.
        let hooked = root.appendingPathComponent("hooked/Game.exe")
        try writePE(hooked, machine: 0x8664, imports: ["d3d11.dll"])
        try writePE(hooked.deletingLastPathComponent().appendingPathComponent("overlay64.dll"), machine: 0x8664, imports: ["d3d12.dll", "d3d9.dll", "opengl32.dll"])
        #expect(GraphicsAdvisor.analyze(hooked).imported == [.d3d11] && GraphicsAdvisor.analyze(hooked).recommendation.renderer == .dxmt)
        let overlayOnly = root.appendingPathComponent("overlay-only/Game.exe")
        try writePE(overlayOnly, machine: 0x8664, imports: ["KERNEL32.dll"])
        try writePE(overlayOnly.deletingLastPathComponent().appendingPathComponent("overlay64.dll"), machine: 0x8664, imports: ["d3d12.dll"])
        #expect(GraphicsAdvisor.analyze(overlayOnly).imported.isEmpty)
        // A tested game keeps its known renderer and reason.
        let ac3 = root.appendingPathComponent("ac3/ACIII.exe")
        try writePE(ac3, machine: 0x8664, imports: ["d3d11.dll", "dxgi.dll", "DINPUT8.dll"])
        #expect(GraphicsAdvisor.analyze(ac3).recommendation == KnownGame.ac3.recommendation)
    }
    @Test func testRuntimeLoadedAPIsAreAGuess() throws {
        let url = root.appendingPathComponent("loader/game.exe")
        try writePE(url, machine: 0x8664, imports: ["KERNEL32.dll"])
        var data = try Data(contentsOf: url)
        data.append("D3D12.dll".data(using: .utf16LittleEndian)!)
        try data.write(to: url)
        let analysis = GraphicsAdvisor.analyze(url)
        #expect(analysis.imported.isEmpty && analysis.mentioned == [.d3d12])
        #expect(analysis.recommendation.renderer == .d3dmetal && analysis.recommendation.reason.contains("best guess"))
    }
    @Test func testBottleRecommendationFollowsItsGames() {
        let ubisoft = Bottle(id: "u", name: "Ubisoft", launcher: .ubisoft, renderer: .wined3d)
        #expect(GraphicsAdvisor.recommendation(for: ubisoft, analyses: []) == Launcher.ubisoft.recommendation)
        func analysis(_ renderer: Renderer) -> GraphicsAnalysis {
            GraphicsAnalysis(architecture: "x86_64-windows", imported: [], mentioned: [], recommendation: Recommendation(renderer: renderer, reason: renderer.title))
        }
        let mixed = GraphicsAdvisor.recommendation(for: Bottle(id: "g", name: "G", renderer: .dxmt), analyses: [analysis(.dxmt), analysis(.dxmt), analysis(.d3dmetal)])
        #expect(mixed.renderer == .dxmt && mixed.reason.contains("D3DMetal") && mixed.reason.contains("separate bottle"))
    }
    /// Unpacked archives as Portnaut's runtime build sees them, with a D3DMetal 3 or 4 file set.
    private func makeSources(_ folder: URL, d3dmetal4: Bool = false, dropping: String? = nil) throws {
        let fm = FileManager.default
        func touch(_ relative: String, _ text: String = "x") throws {
            guard relative != dropping else { return }
            let url = folder.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        for name in ["d3d11", "dxgi", "d3d10core", "winemetal", "nvapi64", "nvngx"] { try touch("dxmt/highball/x86_64-windows/\(name).dll") }
        for name in ["d3d11", "dxgi", "d3d10core", "winemetal"] { try touch("dxmt/highball/i386-windows/\(name).dll") }
        try touch("dxmt/highball/x86_64-unix/winemetal.so")
        let modules = d3dmetal4 ? ["d3d11", "d3d12", "d3d12core", "d3d10", "dxgi", "nvapi64", "nvngx"] : ["d3d11", "d3d12", "dxgi", "nvapi64", "nvngx", "atidxx64"]
        for name in modules {
            try touch("renderer/d3dmetal/wine/x86_64-windows/\(name).dll")
            let link = folder.appendingPathComponent("renderer/d3dmetal/wine/x86_64-unix/\(name).so")
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../external/libd3dshared.dylib")
        }
        try touch("renderer/d3dmetal/external/libd3dshared.dylib")
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>\(d3dmetal4 ? "4.0b3" : "3.0")</string></dict></plist>"
        try touch("renderer/d3dmetal/external/D3DMetal.framework/Versions/A/Resources/Info.plist", plist)
        try touch("renderer/d3dmetal/License.rtf")
        for arch in ["x86_64-windows", "i386-windows"] {
            for name in ["d3d11", "d3d10core"] { try touch("renderer/dxvk/wine/\(arch)/\(name).dll") }
            try touch("renderer/d9vk/wine/\(arch)/d3d9.dll")
        }
        try touch("renderer/dxvk/version", "DXVK-Sikarugir-async-v1.10.3\n")
    }

    @Test func testRendererInstallationsFollowTheArchives() throws {
        let three = root.appendingPathComponent("three"), four = root.appendingPathComponent("four")
        try makeSources(three)
        try makeSources(four, d3dmetal4: true)
        for renderer in Renderer.allCases {
            for file in try renderer.installation(from: three) {
                #expect(file.source.hasPrefix("dxmt/highball/") || file.source.hasPrefix("renderer/"))
                #expect(!file.target.contains(".."))
            }
        }
        #expect(try Renderer.wined3d.installation(from: three).isEmpty && Renderer.wined3d.variantFolder == nil)
        let d3dmetal = try Renderer.d3dmetal.installation(from: three).map(\.target)
        #expect(d3dmetal.contains("lib/external/libd3dshared.dylib") && d3dmetal.contains("lib/external/D3DMetal.framework") && d3dmetal.contains("lib/wine/x86_64-windows/atidxx64.dll"))
        // D3DMetal 4's file set: d3d12core and d3d10 come along, atidxx64 is gone.
        let four4 = try Renderer.d3dmetal.installation(from: four).map(\.target)
        #expect(four4.contains("lib/wine/x86_64-windows/d3d12core.dll") && four4.contains("lib/wine/x86_64-unix/d3d10.so") && !four4.contains { $0.contains("atidxx64") })
        // D3DMetal's unix modules are symlinks to ../../external/libd3dshared.dylib.
        let module = URL(fileURLWithPath: "/engine/lib/wine/x86_64-unix/d3d11.so")
        #expect(URL(fileURLWithPath: "../../external/libd3dshared.dylib", relativeTo: module.deletingLastPathComponent()).standardizedFileURL.path == "/engine/lib/external/libd3dshared.dylib")
        #expect(!d3dmetal.contains { $0.contains("i386") })
        // 32-bit programs stay on wined3d with DXMT: only WineMetal is installed for them.
        #expect(try Renderer.dxmt.installation(from: three).map(\.target).filter { $0.contains("i386") } == ["lib/wine/i386-windows/winemetal.dll"])
        #expect(try Renderer.dxmt.installation(from: three).contains { $0.target == "lib/wine/x86_64-windows/nvngx.dll" })
        let broken = root.appendingPathComponent("broken")
        try makeSources(broken, dropping: "renderer/d3dmetal/wine/x86_64-windows/d3d12.dll")
        #expect(throws: PortnautError.self) { try Renderer.d3dmetal.installation(from: broken) }
        #expect(Renderer.dxmt.handles("x86_64-windows") && !Renderer.dxmt.handles("i386-windows") && Renderer.dxvk.handles("i386-windows"))
        #expect(Renderer.d3dmetal.licenseNote != nil && Renderer.dxmt.licenseNote == nil)
    }

    // MARK: - Processes

    // MARK: - Launchers and programs

    @Test func testLauncherRecipesAndProfiles() {
        let profile = WineService.profile(for: Bottle(id: "steam", name: "Steam", launcher: .steam, renderer: .d3dmetal))
        #expect(profile.contains("[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\steamwebhelper.exe]\n\"CommandLineAppend\"=\"--in-process-gpu --disable-gpu\""))
        #expect(!WineService.profile(for: Bottle(id: "u", name: "U", launcher: .ubisoft, renderer: .dxmt)).contains("steamwebhelper"))
        #expect(Launcher.ea.registry.isEmpty)
        #expect(Launcher.steam.arguments == ["-cef-disable-gpu"])
        #expect(Launcher.steam.installerArguments == ["/S"])
        #expect(Launcher.owning("Program Files (x86)/Steam/STEAM.exe") == .steam)
        #expect(Launcher.owning("Games/steam_game.exe") == nil)
        for launcher in Launcher.allCases { #expect(launcher.installer.scheme == "https") }
    }

    /// A shortcut as Wine's IShellLink writes it: an empty ID list, LinkInfo with an ANSI local path,
    /// then Unicode strings. Without `localPath`, only a relative path.
    private func writeShortcut(_ url: URL, localPath: String?, relativePath: String? = nil, arguments: String? = nil) throws {
        var data = Data()
        func le(_ value: Int, _ size: Int) { for i in 0..<size { data.append(UInt8((value >> (8 * i)) & 0xff)) } }
        var flags = 0x1 | 0x80
        if localPath != nil { flags |= 0x2 }
        if relativePath != nil { flags |= 0x8 }
        if arguments != nil { flags |= 0x20 }
        le(0x4C, 4)
        data.append(contentsOf: [0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46])
        le(flags, 4)
        data.append(Data(count: 0x4C - data.count))
        le(2, 2); le(0, 2)
        if let localPath {
            let volume: [UInt8] = [0x11, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0, 0]
            let path = Array(localPath.utf8) + [0]
            le(0x1C + volume.count + path.count + 1, 4); le(0x1C, 4); le(1, 4); le(0x1C, 4); le(0x1C + volume.count, 4); le(0, 4); le(0x1C + volume.count + path.count, 4)
            data.append(contentsOf: volume + path + [0])
        }
        for string in [relativePath, arguments].compactMap({ $0 }) {
            le(string.utf16.count, 2)
            for unit in string.utf16 { le(Int(unit), 2) }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// A drive with Steam (two libraries), an EA game, shortcuts and helpers.
    private func makeDrive() throws -> URL {
        let drive = PortnautPaths(root: root).bottle(Bottle(id: "store", name: "Store", launcher: .steam, renderer: .d3dmetal)).drive
        func write(_ relative: String, _ text: String) throws {
            let url = drive.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func manifest(_ id: String, _ name: String, _ folder: String, _ flags: Int) -> String {
            "\"AppState\"\n{\n\t\"appid\"\t\t\"\(id)\"\n\t\"name\"\t\t\"\(name)\"\n\t\"StateFlags\"\t\t\"\(flags)\"\n\t\"installdir\"\t\t\"\(folder)\"\n}\n"
        }
        let steam = "Program Files (x86)/Steam"
        try writePE(drive.appendingPathComponent(steam + "/steam.exe"), machine: 0x014c, imports: [])
        try write(steam + "/steamapps/libraryfolders.vdf", "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"C:\\\\Program Files (x86)\\\\Steam\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"C:\\\\SteamLibrary\"\n\t}\n}\n")
        try write(steam + "/steamapps/appmanifest_400.acf", manifest("400", "Portal", "Portal", 4))
        try write(steam + "/steamapps/appmanifest_500.acf", manifest("500", "Left 4 Dead", "left 4 dead", 1026))
        try write(steam + "/steamapps/appmanifest_228980.acf", manifest("228980", "Steamworks Common Redistributables", "Steamworks Shared", 4))
        try writePE(drive.appendingPathComponent(steam + "/steamapps/common/Portal/portal.exe"), machine: 0x014c, imports: ["d3d9.dll"])
        try writePE(drive.appendingPathComponent(steam + "/steamapps/common/Steamworks Shared/_CommonRedist/vcredist_x64.exe"), machine: 0x8664, imports: [])
        try write("SteamLibrary/steamapps/appmanifest_620.acf", manifest("620", "Portal 2", "Portal 2", 4))
        try writePE(drive.appendingPathComponent("SteamLibrary/steamapps/common/Portal 2/portal2.exe"), machine: 0x014c, imports: ["d3d9.dll"])
        try write("Program Files/EA Games/Dead Space/__Installer/installerdata.xml", """
            <DiPManifest version="4.0"><gameTitles><gameTitle locale="de_DE">Dead Space DE</gameTitle><gameTitle locale="en_US">Dead Space &amp; More</gameTitle></gameTitles>
            <runtime><launcher><filePath>[HKEY_LOCAL_MACHINE\\SOFTWARE\\Wow6432Node\\EA Games\\Dead Space\\Install Dir]Dead Space.exe</filePath></launcher></runtime></DiPManifest>
            """)
        try writePE(drive.appendingPathComponent("Program Files/EA Games/Dead Space/Dead Space.exe"), machine: 0x8664, imports: ["d3d12.dll"])
        try writePE(drive.appendingPathComponent("Program Files/EA Games/Dead Space/EAAntiCheat.GameServiceLauncher.exe"), machine: 0x8664, imports: [])
        let menu = drive.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")
        try writePE(drive.appendingPathComponent("Games/Witcher 3/bin/x64/witcher3.exe"), machine: 0x8664, imports: ["d3d11.dll"])
        try writeShortcut(menu.appendingPathComponent("The Witcher 3/The Witcher 3.lnk"), localPath: "C:\\Games\\Witcher 3\\bin\\x64\\witcher3.exe", arguments: "-debugscripts \"x y\"")
        try writePE(drive.appendingPathComponent("Games/Witcher 3/unins000.exe"), machine: 0x014c, imports: [])
        try writeShortcut(menu.appendingPathComponent("The Witcher 3/Uninstall.lnk"), localPath: "C:\\Games\\Witcher 3\\unins000.exe")
        try writeShortcut(drive.appendingPathComponent("users/Public/Desktop/Steam.lnk"), localPath: "C:\\Program Files (x86)\\Steam\\steam.exe")
        try writePE(drive.appendingPathComponent("Tools/tool.exe"), machine: 0x8664, imports: [])
        try writeShortcut(drive.appendingPathComponent("users/player/Desktop/Tool.lnk"), localPath: nil, relativePath: "..\\..\\..\\Tools\\tool.exe")
        try writeShortcut(drive.appendingPathComponent("users/player/Desktop/Notes.lnk"), localPath: "C:\\Games\\notes.txt")
        return drive
    }

    @Test func testShortcutsAreParsed() throws {
        let file = root.appendingPathComponent("game.lnk")
        try writeShortcut(file, localPath: "C:\\Games\\Game\\game.exe", arguments: "-windowed")
        let link = try #require(ShellLink(try Data(contentsOf: file)))
        #expect(link.localPath == "C:\\Games\\Game\\game.exe")
        #expect(link.arguments == "-windowed")
        #expect(ShellLink(Data("not a shortcut".utf8)) == nil)
        #expect(ProgramScanner.splitCommandLine("-a \"b c\" d -x \"\"") == ["-a", "b c", "d", "-x", ""])
        #expect(ProgramScanner.relativePath(fromWindows: "c:\\Program Files\\Game\\game.exe") == "Program Files/Game/game.exe")
        #expect(ProgramScanner.relativePath(fromWindows: "D:\\Game\\game.exe") == nil)
        #expect(ProgramScanner.relativePath(fromWindows: "C:\\Games\\..\\..\\escape.exe") == nil)
    }

    @Test func testProgramsAreFoundFromLaunchersAndShortcuts() throws {
        let drive = try makeDrive()
        let found = ProgramScanner.scan(drive: drive)
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Portal", "Portal 2", "Dead Space & More", "The Witcher 3", "Tool"])
        #expect(byName["Portal"]?.launcherArguments == ["-applaunch", "400"])
        #expect(byName["Portal"]?.executable == "Program Files (x86)/Steam/steamapps/common/Portal/portal.exe")
        #expect(byName["Portal 2"]?.executable == "SteamLibrary/steamapps/common/Portal 2/portal2.exe")
        #expect(byName["Dead Space & More"]?.executable == "Program Files/EA Games/Dead Space/Dead Space.exe")
        #expect(byName["Dead Space & More"]?.reliable == true)
        #expect(byName["The Witcher 3"]?.arguments == ["-debugscripts", "x y"])
        #expect(byName["The Witcher 3"]?.reliable == false)
        #expect(byName["Tool"]?.executable == "Tools/tool.exe")
        let quick = ProgramScanner.scan(drive: drive, reliableOnly: true, steamAppsInLibrary: ["400"])
        #expect(Set(quick.map(\.name)) == ["Portal 2", "Dead Space & More"])
        #expect(ProgramScanner.shortcuts(drive: drive, includeHelpers: true).map(\.name).contains("Uninstall"))
    }

    @Test func testMainExecutablePrefersTheGameOverHelpers() throws {
        let folder = root.appendingPathComponent("My Game")
        try writePE(folder.appendingPathComponent("MyGame.exe"), machine: 0x8664, imports: [])
        try writePE(folder.appendingPathComponent("MyGame/Binaries/Win64/MyGame-Win64-Shipping.exe"), machine: 0x8664, imports: ["d3d12.dll"])
        try writePE(folder.appendingPathComponent("Engine/Binaries/Win64/CrashReportClient.exe"), machine: 0x8664, imports: [])
        try writePE(folder.appendingPathComponent("_CommonRedist/DirectX/DXSETUP.exe"), machine: 0x014c, imports: [])
        #expect(ProgramScanner.mainExecutable(in: folder, name: "My Game")?.lastPathComponent == "MyGame-Win64-Shipping.exe")
        let simple = root.appendingPathComponent("Simple")
        try writePE(simple.appendingPathComponent("launcher.exe"), machine: 0x014c, imports: [])
        try writePE(simple.appendingPathComponent("simple.exe"), machine: 0x8664, imports: [])
        try writePE(simple.appendingPathComponent("unins000.exe"), machine: 0x014c, imports: [])
        #expect(ProgramScanner.mainExecutable(in: simple, name: "Simple")?.lastPathComponent == "simple.exe")
        #expect(ProgramScanner.mainExecutable(in: root.appendingPathComponent("missing"), name: "x") == nil)
    }

    @Test func testFoundGamesJoinTheLibraryAndStartThroughTheirLauncher() throws {
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        _ = try makeDrive()
        let bottle = Bottle(id: "store", name: "Store", launcher: .steam, renderer: .d3dmetal)
        try service.paths.saveLibrary(Library(bottles: [bottle]))
        let added = try service.addInstalledGames(in: bottle)
        #expect(Set(added.map(\.name)) == ["Portal", "Portal 2", "Dead Space & More"])
        #expect(try service.addInstalledGames(in: try service.bottle("store")).isEmpty)
        let current = try service.bottle("store")
        #expect(Set(service.detectPrograms(in: current).map(\.name)) == ["The Witcher 3", "Tool"])
        let portal = try #require(current.games.first { $0.name == "Portal" })
        let command = try service.launchCommand(for: portal, in: current)
        #expect(command.executable.lastPathComponent == "steam.exe")
        #expect(command.arguments == ["-cef-disable-gpu", "-applaunch", "400"])
        let deadSpace = try #require(current.games.first { $0.name == "Dead Space & More" })
        #expect(try service.launchCommand(for: deadSpace, in: current).executable.lastPathComponent == "Dead Space.exe")
        #expect(service.analyze(deadSpace, in: current)?.recommendation.renderer == .d3dmetal)
        // Without its launcher, a launcher-started game cannot start.
        var bare = current
        bare.launcher = nil
        #expect(throws: PortnautError.self) { try service.launchCommand(for: portal, in: bare) }
    }

    @Test func testRuntimeIsDriveY() throws {
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        let bottle = service.paths.bottle(Bottle(id: "b", name: "B", renderer: .dxmt))
        let devices = bottle.prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("y:").path, withDestinationPath: "/somewhere/else")
        try service.mapRuntimeDrive(bottle)
        try service.mapRuntimeDrive(bottle)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: devices.appendingPathComponent("y:").path) == service.paths.runtime.path)
        #expect(WineService.runtimeDrive != WineService.installerDrive)
    }

    // MARK: - Settings, components and controllers

    @Test func testOlderLibrariesLoadWithDefaults() throws {
        // A 0.3.0 bottle, before per-game settings, environment, controllers and components.
        let json = """
        {"schema":2,"bottles":[{"id":"steam","name":"Steam","launcher":"steam","renderer":"d3dmetal","windowsVersion":"win10","highResolution":true,"msync":true,
         "options":{"performanceHUD":true,"reduceFrameQueue":false},"connectGPUOverride":false,
         "games":[{"id":"portal","name":"Portal","executable":"Program Files (x86)/Steam/steamapps/common/Portal/portal.exe","arguments":[],"launcherArguments":["-applaunch","400"]}]}]}
        """
        let library = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        let bottle = try #require(library.bottles.first)
        #expect(bottle.options.performanceHUD && !bottle.options.advertiseAVX)
        #expect(bottle.controllers == ControllerSettings() && bottle.controllers.sdl && bottle.controllers.xinput)
        #expect(bottle.environment.isEmpty && bottle.components.isEmpty)
        let game = try #require(bottle.games.first)
        #expect(game.launcherArguments == ["-applaunch", "400"] && game.dllOverrides.isEmpty && game.environment.isEmpty && game.windowsVersion == nil)
        #expect(game.programName == "portal.exe")
        // And what Portnaut writes now reads back the same.
        var changed = bottle
        changed.games[0].dllOverrides = ["dinput8": .nativeThenBuiltin, "xinput1_3": .disabled]
        changed.games[0].windowsVersion = .win7
        changed.components["vcrun2022"] = Date(timeIntervalSince1970: 0)
        let again = try JSONDecoder().decode(Bottle.self, from: try JSONEncoder().encode(changed))
        #expect(again == changed)
    }

    @Test func testProfileCarriesGameComponentAndControllerSettings() {
        var bottle = Bottle(id: "b", name: "B", renderer: .dxmt)
        var game = Game(id: "g", name: "G", executable: "Games/G/bin/game.exe")
        game.dllOverrides = ["dinput8": .nativeThenBuiltin, "xinput1_3": .disabled]
        game.windowsVersion = .win7
        bottle.games = [game, Game(id: "h", name: "H", executable: "Games/H/h.exe")]
        bottle.controllers.xinput = false
        var profile = WineService.profile(for: bottle)
        #expect(profile.contains("[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\winebus]\n\"Enable SDL\"=dword:00000001\n\"Map Controllers\"=dword:00000000"))
        #expect(profile.contains("[-HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\game.exe\\DllOverrides]\n[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\game.exe\\DllOverrides]\n\"dinput8\"=\"native,builtin\"\n\"xinput1_3\"=\"\""))
        #expect(profile.contains("[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\game.exe]\n\"Version\"=\"win7\""))
        // A game without settings gets its old ones cleared.
        #expect(profile.contains("[-HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\h.exe\\DllOverrides]\n[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\h.exe]\n\"Version\"=-"))
        #expect(!profile.contains("Software\\Wine\\DllOverrides]"))
        bottle.components = [WindowsComponent.vcrun2022.rawValue: Date()]
        profile = WineService.profile(for: bottle)
        #expect(profile.contains("[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n\"concrt140\"=\"native,builtin\""))
        #expect(profile.contains("\"vcruntime140_1\"=\"native,builtin\""))
        #expect(!profile.contains("msvcp120"))
    }

    @Test func testUserEnvironmentAddsToPortnautsButCannotReplaceIt() {
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        var bottle = Bottle(id: "b", name: "B", renderer: .d3dmetal)
        bottle.environment = ["D3DM_SUPPORT_DXR": "1", "WINEPREFIX": "/elsewhere", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "bad-name": "1", "MTL_HUD_ENABLED": "1"]
        bottle.options.advertiseAVX = true
        var game = Game(id: "g", name: "G", executable: "g.exe")
        game.environment = ["D3DM_SUPPORT_DXR": "0", "GAME_ONLY": "yes", "PORTNAUT_FRAME_QUEUE": "9"]
        let env = service.environment(for: bottle, game: game)
        #expect(env["ROSETTA_ADVERTISE_AVX"] == "1")
        #expect(env["D3DM_SUPPORT_DXR"] == "0" && env["GAME_ONLY"] == "yes" && env["MTL_HUD_ENABLED"] == "1")
        #expect(env["WINEPREFIX"] == service.paths.bottle(bottle).prefix.path)
        #expect(env["DYLD_INSERT_LIBRARIES"] == nil && env["bad-name"] == nil && env["PORTNAUT_FRAME_QUEUE"] == nil)
        #expect(service.environment(for: bottle)["GAME_ONLY"] == nil)
        #expect(EnvironmentPolicy.allows("DXVK_HUD") && !EnvironmentPolicy.allows("PATH") && !EnvironmentPolicy.allows("1ABC") && !EnvironmentPolicy.allows("portnaut_x"))
    }

    @Test func testComponentCatalog() {
        for component in WindowsComponent.allCases {
            #expect(!component.downloads.isEmpty)
            for item in component.downloads {
                #expect(item.url.scheme == "https")
                #expect(item.sha256.map { $0.count == 64 && $0.allSatisfy(\.isHexDigit) } ?? true)
            }
            #expect(component.downloads.allSatisfy { $0.sha256 != nil } == (component == .vcrun2013 || component == .vcrun2010 || component == .d3dx))
        }
        #expect(WindowsComponent.d3dx.dllOverrides.contains("d3dx9_43") && WindowsComponent.d3dx.dllOverrides.contains("d3dcompiler_43"))
        #expect(WindowsComponent.isD3DXPackage("Jun2010_d3dx9_43_x64.cab") && WindowsComponent.isD3DXPackage("Aug2009_D3DCompiler_42_x86.cab"))
        #expect(!WindowsComponent.isD3DXPackage("Jun2010_XAudio_x64.cab") && !WindowsComponent.isD3DXPackage("Apr2006_MDX1_x86.cab") && !WindowsComponent.isD3DXPackage("dxupdate.cab"))
        #expect(ProgramScanner.splitCommandLine(ProgramScanner.joinCommandLine(["-x", "two words", ""])) == ["-x", "two words", ""])
    }

    // MARK: - Performance, MetalFX and snapshots

    /// Lines as the shim writes them, from a real AC III session on DXMT.
    static let latencyLines = """
    PortnautLatency: no screen time for NSKVONotifying_WineMetalLayer; presentsWithTransaction 0 displaySyncEnabled 0 maximumDrawableCount 2 opaque 1
    PortnautLatency: fps 61.0 | frame ms p50 16.0 p95 17.1 | present to screen ms p50 13.5 p95 14.4 (0 frames without a screen time) | present to release ms p50 13.9 p95 14.8 | drawable wait ms p50 0.01 p95 0.02 | GPU 11.8 ms/frame, 72% busy | input age ms p50 0.0 p95 0.0 max 0.0 (0 events) | frame queue 2
    other output
    PortnautLatency: fps 30.3 | frame ms p50 33.0 p95 33.3 | present to screen ms p50 13.6 p95 17.2 (0 frames without a screen time) | present to release ms p50 14.0 p95 17.5 | drawable wait ms p50 0.00 p95 0.00 | GPU 13.3 ms/frame, 40% busy | input age ms p50 0.0 p95 0.0 max 0.0 (0 events) | frame queue 2
    PortnautLatency: fps 1.3 | frame ms p50 23.3 p95 24.2 | present to screen ms p50 37.0 p95 38.1 (0 frames without a screen time) | present to release ms p50 37.4 p95 38.4 | drawable wait ms p50 15.00 p95 15.90 | GPU 27.9 ms/frame, 4% busy | input age ms p50 0.0 p95 0.0 max 0.0 (0 events) | frame queue 2
    PortnautLatency: fps 62.5 | frame ms p50 16.0 p95 16.4 | present to screen ms p50 12.3 p95 15.9 (0 frames without a screen time) | present to release ms p50 12.7 p95 16.3 | drawable wait ms p50 0.01 p95 0.02 | GPU 11.6 ms/frame, 73% busy | input age ms p50 0.0 p95 0.0 max 0.0 (0 events) | frame queue 2
    PortnautLatency: fps 59.9 | frame ms p50 16.7 p95 16.9 | present to screen ms p50 24.7 p95 28.9 (1 frames without a screen time) | present to release ms p50 25.0 p95 29.2 | drawable wait ms p50 13.20 p95 16.59 | GPU 3.0 ms/frame, 18% busy | input age ms p50 0.0 p95 0.0 max 0.0 (0 events) | frame queue 2
    """

    @Test func testSessionsBecomePerformanceRecords() throws {
        var bottle = Bottle(id: "u", name: "U", launcher: .ubisoft, renderer: .dxmt)
        let run = try #require(PerformanceLog.run(from: Self.latencyLines, bottle: bottle, date: Date(timeIntervalSince1970: 100)))
        // The 1.3 fps stretch (paused or loading) is left out; four stretches remain.
        #expect(run.seconds == 20)
        #expect(abs(run.averageFPS - (61.0 + 30.3 + 62.5 + 59.9) / 4) < 0.01)
        #expect(run.lowFPS == 30.3)
        #expect(run.gpuMilliseconds == 11.8)
        // The stretch with a frame lacking a screen time does not count towards latency.
        #expect(run.latencyMilliseconds == 13.5)
        #expect(run.configuration == "DXMT")
        #expect(PerformanceLog.run(from: "PortnautLatency: no screen time for x", bottle: bottle) == nil)

        bottle.renderer = .d3dmetal
        bottle.options.dlss = true
        var faster = run
        faster.date = Date(timeIntervalSince1970: 200); faster.renderer = .d3dmetal; faster.configuration = bottle.performanceLabel; faster.averageFPS = 70; faster.seconds = 60
        let rows = PerformanceLog.compare([run, faster, run])
        #expect(rows.map(\.configuration) == ["D3DMetal · DLSS", "DXMT"])
        #expect(rows[1].runs == 2 && rows[1].seconds == 40 && rows[0].lastDate == faster.date)
    }

    @Test func testAGameSessionIsRecordedFromItsPartOfTheLog() throws {
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        var bottle = Bottle(id: "r", name: "R", renderer: .dxmt)
        bottle.games = [Game(id: "g", name: "G", executable: "g.exe")]
        try service.paths.saveLibrary(Library(bottles: [bottle]))
        try FileManager.default.createDirectory(at: service.paths.logs, withIntermediateDirectories: true)
        // An earlier session's lines come before the offset and must not count.
        let earlier = String(repeating: "PortnautLatency: fps 10.0 | frame ms p50 100.0 p95 100.0 | present to screen ms p50 1.0 p95 1.0 (0 frames without a screen time) | GPU 1.0 ms/frame\n", count: 5)
        try Data(earlier.utf8).write(to: service.paths.sessionLog)
        let offset = service.logSize()
        let handle = try FileHandle(forWritingTo: service.paths.sessionLog)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(Self.latencyLines.utf8)); try handle.close()
        let run = try #require(service.recordPerformance(of: bottle.games[0], in: bottle, since: offset))
        #expect(run.lowFPS == 30.3 && run.seconds == 20)
        #expect(try service.bottle("r").games[0].performance == [run])
        // Without 15 seconds of play nothing is recorded.
        #expect(service.recordPerformance(of: bottle.games[0], in: bottle, since: service.logSize()) == nil)
    }

    @Test func testMetalFXAndDLSSSettings() {
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        var bottle = Bottle(id: "d", name: "D", renderer: .dxmt)
        bottle.options.metalFXUpscaling = true
        bottle.options.frameRateLimit = 60
        var env = service.environment(for: bottle)
        #expect(env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1")
        #expect(env["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate = 60;d3d11.metalSpatialUpscaleFactor = 2.0")
        // Wine then reports point resolution, whatever High Resolution Mode says.
        #expect(bottle.highResolution && !bottle.retinaMode)
        #expect(WineService.profile(for: bottle).contains("\"RetinaMode\"=\"n\""))
        #expect(bottle.performanceLabel == "DXMT · MetalFX 2× · 60 fps limit")
        #expect(env["WINEDLLOVERRIDES"]?.contains("nvapi,nvapi64=") == true)
        bottle.options.dlss = true
        env = service.environment(for: bottle)
        #expect(env["DXMT_ENABLE_NVEXT"] == "1" && env["WINEDLLOVERRIDES"]?.contains("nvapi") == false)
        // MetalFX upscaling is DXMT's; D3DMetal gets DLSS only.
        bottle.renderer = .d3dmetal
        env = service.environment(for: bottle)
        #expect(env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil && env["D3DM_ENABLE_METALFX"] == "1" && env["DXMT_CONFIG"] == nil)
        #expect(bottle.retinaMode)
        bottle.renderer = .dxvk
        #expect(!bottle.dlssActive && service.environment(for: bottle)["WINEDLLOVERRIDES"]?.contains("nvapi,nvapi64=") == true)
    }

    @Test func testSnapshotsRestoreTheBottleAndKeepTheCurrentState() async throws {
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        var bottle = Bottle(id: "s", name: "Saves", renderer: .dxmt)
        bottle.games = [Game(id: "g", name: "G", executable: "g.exe")]
        try service.paths.saveLibrary(Library(bottles: [bottle]))
        let drive = service.paths.bottle(bottle).drive
        let save = drive.appendingPathComponent("users/player/Documents/My Games/G/save.dat")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("chapter 1".utf8).write(to: save)
        let first = try service.takeSnapshot(of: bottle, label: "Chapter 1")

        try Data("chapter 9".utf8).write(to: save)
        var changed = try service.bottle("s")
        changed.renderer = .d3dmetal
        changed.games[0].performance = [PerformanceRun(date: Date(), renderer: .d3dmetal, configuration: "D3DMetal", seconds: 60, averageFPS: 60, lowFPS: 50, frameTimeP95: 17, gpuMilliseconds: 10, latencyMilliseconds: nil)]
        try service.save(changed)

        try await service.restoreSnapshot(first, of: try service.bottle("s"))
        #expect(try String(contentsOf: save, encoding: .utf8) == "chapter 1")
        let restored = try service.bottle("s")
        #expect(restored.renderer == .dxmt)
        // Records made since the snapshot survive the restore.
        #expect(restored.games[0].performance.count == 1)
        let all = service.snapshots(of: restored)
        let before = try #require(all.first { $0.automatic })
        #expect(before.label == "Before restoring “Chapter 1”" && before.bottle.renderer == .d3dmetal)
        // The current state was kept: restoring it brings chapter 9 back.
        try await service.restoreSnapshot(before, of: restored)
        #expect(try String(contentsOf: save, encoding: .utf8) == "chapter 9")

        // Only the three newest automatic snapshots are kept; manual ones stay.
        for n in 1...4 { try service.takeSnapshot(of: restored, label: "auto \(n)", automatic: true) }
        let kept = service.snapshots(of: restored)
        #expect(kept.filter(\.automatic).map(\.label) == ["auto 4", "auto 3", "auto 2"])
        #expect(kept.contains { $0.label == "Chapter 1" && !$0.automatic })
    }

    @Test func testSaveBackupsSkipCachesAndRestoreOverTheBottle() async throws {
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        let bottle = Bottle(id: "b", name: "Backups", renderer: .dxmt)
        try service.paths.saveLibrary(Library(bottles: [bottle]))
        let drive = service.paths.bottle(bottle).drive
        func write(_ relative: String, _ text: String) throws {
            let url = drive.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("users/player/Saved Games/Game/slot1.sav", "one")
        try write("users/player/AppData/Local/Game/Saved/profile.sav", "profile")
        try write("users/player/AppData/Local/Game/Cache/big.bin", "cache")
        try write("users/player/AppData/Local/Steam/htmlcache/x", "cache")
        try write("users/player/AppData/Roaming/Microsoft/Windows/x", "windows")
        try write("Program Files (x86)/Ubisoft/Ubisoft Game Launcher/savegames/1/2.save", "ubisoft")
        let backup = try await service.backUpSaves(of: bottle)
        // Two saves and Ubisoft's savegame; the cache, Steam's htmlcache and Windows' own folder are left out.
        #expect(backup.files == 3)
        let copy = service.paths.saveBackups.appendingPathComponent("b").appendingPathComponent(backup.id).appendingPathComponent("drive_c")
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("users/player/AppData/Local/Game/Saved/profile.sav").path))
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("users/player/AppData/Local/Game/Cache").path))
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("users/player/AppData/Roaming/Microsoft").path))
        #expect(service.saveBackups(of: bottle).first?.id == backup.id)

        try write("users/player/Saved Games/Game/slot1.sav", "overwritten")
        try write("users/player/Saved Games/Game/slot2.sav", "new")
        try await service.restoreSaves(backup, to: bottle)
        #expect(try String(contentsOf: drive.appendingPathComponent("users/player/Saved Games/Game/slot1.sav"), encoding: .utf8) == "one")
        // Files the backup does not have are left alone, and a snapshot was taken first.
        #expect(FileManager.default.fileExists(atPath: drive.appendingPathComponent("users/player/Saved Games/Game/slot2.sav").path))
        #expect(service.snapshots(of: bottle).first?.automatic == true)
    }

    // MARK: - Component updates

    static func manifest(id: String, channel: String? = nil, dxmt: String = "dxmt-highball-20260930T161516Z-a444716", d3dmetal: Bool = false) -> Data {
        let d3d = d3dmetal ? #","d3dmetal":{"url":"https://example.com/d3dmetal-4.0b3-gptk4.tar.xz","sha256":"DD","size":16553892,"version":"D3DMetal-4.0b3","extract":{"subpath":"renderers/d3dmetal","into":"renderers/d3dmetal"}}"# : ""
        return Data("""
        {"id":"\(id)",\(channel.map { "\"channel\":\"\($0)\"," } ?? "")"notes":["\(id): newest note"],"components":{
         "wine":{"kind":"engine","url":"https://github.com/gauthierpiarrette/highball-engine/releases/download/engine-wine-11.0-20261014T003801Z-0024-app-packages-0023-spatial-mixer/engine.tar.gz","sha256":"1D1A","size":334884359,"version":"wine-11.0","extract":{"subpath":"engine","into":"engine"}},
         "dxmt":{"kind":"renderer","url":"https://github.com/gauthierpiarrette/highball-engine/releases/download/\(dxmt)/\(dxmt).tar.gz","sha256":"96fe","size":18923969,"extract":{"subpath":"highball","into":"renderers/dxmt/wine"}},
         "runtime":{"kind":"frameworks","url":"https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz","sha256":"9fa1","size":84533420,"extract":{"subpath":"Template-1.0.11.app/Contents/Frameworks","into":"frameworks"}},
         "moltenvk":{"kind":"runtime","url":"https://github.com/gauthierpiarrette/highball/releases/download/engine-components/moltenvk-1.4.2-x86_64.tar.gz","sha256":"7c84","size":1733593,"version":"1.4.2+shadow-import-1","extract":{"subpath":"libMoltenVK.dylib","into":"frameworks/libMoltenVK.dylib"}},
         "audiobuf":{"kind":"runtime","url":"https://example.com/audiobuf.tar.xz","sha256":"8b84","size":5700}\(d3d)}}
        """.utf8)
    }

    @Test func testStableFollowsHighballsNewestTestedSet() throws {
        let names = ["x64-crossover26.3-r9.json", "x64-crossover26.3-r29.json", "x64-crossover26.3-r28.json", "x64-sikarugir10.0_6-r40.json", "arm64-wine11.18-r6.json", "x64-crossover26.4-r1.json"]
        #expect(RuntimeUpdates.stableCandidates(names) == ["x64-crossover26.4-r1.json", "x64-crossover26.3-r29.json", "x64-crossover26.3-r28.json", "x64-crossover26.3-r9.json"])
        let set = try #require(try RuntimeUpdates.stableSet(fromManifest: Self.manifest(id: "x64-crossover26.3-r29")))
        #expect(set.label == "Highball r29" && set.notes == "x64-crossover26.3-r29: newest note")
        // Before 0.7.0 a set was labelled with Highball's file name; a saved one reads with the short label.
        var saved = set
        saved.label = "Highball x64-crossover26.3-r29"
        #expect(try JSONDecoder().decode(RuntimeSet.self, from: try JSONEncoder().encode(saved)).label == "Highball r29")
        #expect(try JSONDecoder().decode(RuntimeSet.self, from: try JSONEncoder().encode(RuntimeSet.builtIn)) == RuntimeSet.builtIn)
        #expect(set.components.map(\.part) == [.wine, .dxmt, .support, .moltenvk])
        #expect(set.release(.wine)?.version == "11.0 · build 14 Oct 2026 (0024-app-packages-0023-spatial-mixer)")
        #expect(set.release(.dxmt)?.version == "a444716 · 30 Sep 2026")
        #expect(set.release(.support)?.version == "1.0.11" && set.release(.support)?.subpath == "Template-1.0.11.app")
        #expect(set.release(.moltenvk)?.version == "1.4.2 with Highball’s fixes" && set.release(.moltenvk)?.sha256 == "7c84")
        #expect(set.release(.wine)?.sha256 == "1d1a")
        // Preview and beta lines are not for everyone, so Stable skips them.
        #expect(try RuntimeUpdates.stableSet(fromManifest: Self.manifest(id: "x64-crossover27.0-r1", channel: "preview")) == nil)
        let withD3DMetal = try #require(try RuntimeUpdates.stableSet(fromManifest: Self.manifest(id: "x64-crossover26.3-r28", d3dmetal: true)))
        #expect(withD3DMetal.release(.d3dmetal)?.subpath == "renderers/d3dmetal")
        // Against Portnaut's built-in r27, r29 only adds the patched MoltenVK.
        var builtIn = RuntimeSet.builtIn
        builtIn.components = builtIn.components.map { var release = $0; release.sha256 = String(set.release($0.part)!.sha256); return release }
        #expect(set.changes(from: builtIn) == [.moltenvk] && set.downloadSize(from: builtIn) == 1733593)
    }

    @Test func testLatestTakesTheNewestPublishedBuilds() throws {
        func asset(_ name: String, digest: String? = "sha256:ABC") -> String {
            "{\"name\":\"\(name)\",\"size\":10,\(digest.map { "\"digest\":\"\($0)\"," } ?? "")\"browser_download_url\":\"https://example.com/\(name)\"}"
        }
        func release(_ tag: String, _ date: String, _ assets: [String], pre: Bool = false) -> String {
            "{\"tag_name\":\"\(tag)\",\"draft\":false,\"prerelease\":\(pre),\"published_at\":\"\(date)\",\"assets\":[\(assets.joined(separator: ","))]}"
        }
        let highball = Data(("[" + [
            release("engine-arm64-wine-11.18-20261020T101157Z-r6", "2026-10-20T10:13:00Z", [asset("engine-arm64.tar.gz")]),
            release("engine-wine-11.0-20261020T000000Z-0030-lasterror-trial", "2026-10-20T00:00:00Z", [asset("trial.tar.gz")]),
            release("engine-wine-11.0-20261014T003801Z-0024-app-packages-0023-spatial-mixer", "2026-10-14T00:40:00Z", [asset("engine-wine-11.0-20261014.tar.gz"), asset("engine-wine-11.0-20261014.tar.gz.sha256")]),
            release("dxmt-highball-20261017T231707Z-331c552", "2026-10-17T23:17:00Z", [asset("dxmt-331c552.tar.gz", digest: "sha256:89E7")]),
            release("dxmt-highball-20260930T161516Z-a444716", "2026-09-30T16:15:00Z", [asset("dxmt-a444716.tar.gz")]),
        ].joined(separator: ",") + "]").utf8)
        let found = try RuntimeUpdates.latestHighball(fromReleases: highball)
        #expect(found.first { $0.part == .wine }?.fileName == "engine-wine-11.0-20261014.tar.gz")
        #expect(found.first { $0.part == .dxmt }?.version == "331c552 · 17 Oct 2026" && found.first { $0.part == .dxmt }?.sha256 == "89e7")
        let templates = Data(("[" + release("v1.0", "2024-10-03T00:00:00Z", [asset("Template-1.0.9.tar.xz"), asset("Template-1.0.24.tar.xz", digest: "sha256:4B5F"), asset("Template-1.0.11.tar.xz"), asset("Template-1.0.tar.xz")]) + "]").utf8)
        let template = try #require(try RuntimeUpdates.latestTemplate(fromReleases: templates))
        #expect(template.version == "1.0.24" && template.subpath == "Template-1.0.24.app" && template.sha256 == "4b5f")
        // Without a published checksum, a build is not offered.
        #expect(try RuntimeUpdates.latestTemplate(fromReleases: Data(("[" + release("v1.0", "2024", [asset("Template-1.0.30.tar.xz", digest: nil)]) + "]").utf8)) == nil)
        let upstream = try #require(try RuntimeUpdates.latestMoltenVK(fromRelease: Data(release("v1.4.2", "2026-07-24T00:00:00Z", [asset("MoltenVK-ios.tar"), asset("MoltenVK-macos.tar")]).utf8)))
        #expect(upstream.version == "1.4.2" && upstream.subpath == "MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib")

        let stable = try #require(try RuntimeUpdates.stableSet(fromManifest: Self.manifest(id: "x64-crossover26.3-r29")))
        let (latest, notes) = RuntimeUpdates.latestSet(stable: stable, highball: found, template: template, moltenvk: upstream)
        #expect(latest.release(.dxmt)?.sha256 == "89e7" && latest.release(.support)?.version == "1.0.24")
        // Upstream 1.4.2 is not newer than Highball's patched 1.4.2, so the patched build stays.
        #expect(latest.release(.moltenvk)?.sha256 == "7c84" && notes.isEmpty)
        var newer = upstream
        newer.version = "1.4.3"
        #expect(RuntimeUpdates.latestSet(stable: stable, highball: found, template: template, moltenvk: newer).0.release(.moltenvk)?.version == "1.4.3")
        let (fallback, fallbackNotes) = RuntimeUpdates.latestSet(stable: stable, highball: [], template: nil, moltenvk: nil)
        #expect(fallback.release(.dxmt) == stable.release(.dxmt) && fallbackNotes.count == 3)
        #expect(latest.components.map(\.part) == [.wine, .dxmt, .support, .moltenvk])
    }

    /// Fake archives for the runtime build: an engine whose wine prints a version, DXMT, a template
    /// in 1.0.11 or 1.0.24 layout, and a MoltenVK library.
    private func makeArchives() throws -> (old: RuntimeSet, new: RuntimeSet, broken: RuntimeSet) {
        let fm = FileManager.default
        let work = root.appendingPathComponent("archives"), cache = PortnautPaths(root: root).cache
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        func write(_ url: URL, _ text: String, executable: Bool = false) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        func pack(_ folder: URL, _ name: String, part: RuntimePart, version: String, subpath: String? = nil) throws -> ComponentRelease {
            let archive = cache.appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = [name.hasSuffix(".xz") ? "-cJf" : "-czf", archive.path, "-C", folder.path, "."]
            try process.run(); process.waitUntilExit()
            let size = (try fm.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)!.int64Value
            return ComponentRelease(part: part, version: version, url: URL(string: "https://example.invalid/\(name)")!, sha256: try FileIntegrity.sha256(archive), size: size, subpath: subpath)
        }
        let engine = work.appendingPathComponent("wine")
        for name in ["wine", "wineserver"] { try write(engine.appendingPathComponent("engine/bin/\(name)"), "#!/bin/sh\necho wine-11.0-test\n", executable: true) }
        let sources = work.appendingPathComponent("sources")
        try makeSources(sources)
        let wine = try pack(engine, "engine-wine-11.0-test.tar.gz", part: .wine, version: "11.0 test")
        let dxmt = try pack(sources.appendingPathComponent("dxmt"), "dxmt-highball-test.tar.gz", part: .dxmt, version: "test")
        func template(_ version: String, renderers: String, d3dmetal4: Bool, dropping: String? = nil) throws -> ComponentRelease {
            let folder = work.appendingPathComponent("template-\(version)"), contents = folder.appendingPathComponent("Template-\(version).app/Contents")
            for library in ["libinotify.0.dylib", "libMoltenVK.dylib"] { try write(contents.appendingPathComponent("Frameworks/\(library)"), "template \(library)") }
            try write(contents.appendingPathComponent("Frameworks/GStreamer.framework/GStreamer"), "gst")
            try write(contents.appendingPathComponent("Frameworks/SikarugirSdk.framework/SikarugirSdk"), "proprietary")
            let renderer = work.appendingPathComponent("renderer-\(version)")
            try makeSources(renderer, d3dmetal4: d3dmetal4, dropping: dropping)
            try fm.createDirectory(at: contents.appendingPathComponent(renderers).deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: renderer.appendingPathComponent("renderer"), to: contents.appendingPathComponent(renderers))
            return try pack(folder, "Template-\(version).tar.xz", part: .support, version: version, subpath: "Template-\(version).app")
        }
        let old = try template("1.0.11", renderers: "Frameworks/renderer", d3dmetal4: false)
        let new = try template("1.0.24", renderers: "SharedSupport/renderer", d3dmetal4: true)
        let moltenFolder = work.appendingPathComponent("moltenvk")
        try write(moltenFolder.appendingPathComponent("libMoltenVK.dylib"), "patched MoltenVK")
        let moltenvk = try pack(moltenFolder, "moltenvk-1.4.2-test.tar.gz", part: .moltenvk, version: "1.4.2 test", subpath: "libMoltenVK.dylib")
        let incomplete = try template("1.0.25", renderers: "SharedSupport/renderer", d3dmetal4: true, dropping: "renderer/d3dmetal/wine/x86_64-windows/d3d12.dll")
        return (RuntimeSet(label: "Old", channel: .stable, components: [wine, dxmt, old]), RuntimeSet(label: "New", channel: .latest, components: [wine, dxmt, new, moltenvk]),
                RuntimeSet(label: "Broken", channel: .latest, components: [wine, dxmt, incomplete]))
    }

    @Test func testComponentUpdateBuildsSwapsAndRollsBack() async throws {
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        let fm = FileManager.default
        let (old, new, broken) = try makeArchives()
        try service.paths.createDirectories()
        try service.paths.saveLibrary(Library())
        try await service.replaceRuntime(with: try await service.buildRuntime(old) { _ in }, keepPrevious: false)
        #expect(service.paths.runtimeReady)
        let runtime = service.paths.runtime
        #expect(fm.fileExists(atPath: runtime.appendingPathComponent("renderers/d3dmetal/lib/wine/x86_64-windows/atidxx64.dll").path))
        #expect(try fm.destinationOfSymbolicLink(atPath: runtime.appendingPathComponent("renderers/d3dmetal/lib/wine/x86_64-unix/d3d11.so").path) == "../../external/libd3dshared.dylib")
        #expect(!fm.fileExists(atPath: runtime.appendingPathComponent("renderers/dxmt/lib/wine/i386-windows/d3d11.dll").path))
        #expect(!fm.fileExists(atPath: runtime.appendingPathComponent("Libraries/SikarugirSdk.framework").path))
        #expect(service.installedRuntime()?.set == old && service.installedRuntime()?.details["D3DMetal"] == "3.0")
        #expect(service.installedRuntime()?.details["DXVK"] == "DXVK-Sikarugir-async-v1.10.3" && service.installedRuntime()?.details["Wine"] == "wine-11.0-test")
        #expect(service.installedRuntime()?.summary == "Old: Wine 11.0 test, DXMT test, Sikarugir template 1.0.11 (D3DMetal 3.0)")

        try await service.installRuntime(new)
        // Template 1.0.24 keeps its renderers in SharedSupport; D3DMetal 4 brings d3d12core.
        #expect(fm.fileExists(atPath: runtime.appendingPathComponent("renderers/d3dmetal/lib/wine/x86_64-windows/d3d12core.dll").path))
        #expect(try String(contentsOf: runtime.appendingPathComponent("Libraries/libMoltenVK.dylib"), encoding: .utf8) == "patched MoltenVK")
        #expect(service.installedRuntime()?.set == new && service.installedRuntime()?.details["D3DMetal"] == "4.0b3")
        // Diagnostics name what is installed, though the folder keeps its first name.
        #expect(service.installedRuntime()?.summary == "New: Wine 11.0 test, DXMT test, Sikarugir template 1.0.24 (D3DMetal 4.0b3), MoltenVK 1.4.2 test")
        #expect(service.previousRuntime()?.set == old)
        // Nothing changes, so nothing is rebuilt.
        try await service.installRuntime(new)
        #expect(service.previousRuntime()?.set == old)

        try await service.rollBackRuntime()
        #expect(service.installedRuntime()?.set == old && service.previousRuntime()?.set == new)
        #expect(!fm.fileExists(atPath: runtime.appendingPathComponent("renderers/d3dmetal/lib/wine/x86_64-windows/d3d12core.dll").path))
        // Archives of both kept runtimes stay in Downloads; no staging folders are left.
        service.pruneDownloads()
        #expect(fm.fileExists(atPath: service.paths.cache.appendingPathComponent("Template-1.0.24.tar.xz").path))
        #expect(try fm.contentsOfDirectory(atPath: runtime.deletingLastPathComponent().path).filter { $0.hasPrefix(".staging") || $0.hasPrefix(".rollback") }.isEmpty)

        // A template missing a file D3DMetal needs fails the build and leaves the runtime alone.
        await #expect(throws: PortnautError.self) { try await service.installRuntime(broken) }
        #expect(service.installedRuntime()?.set == old && service.paths.runtimeReady)
        // So does a download that fails: an archive Portnaut cannot fetch is reported as such.
        var unreachable = new
        unreachable.components[2].sha256 = String(repeating: "0", count: 64)
        await #expect(throws: PortnautError.self) { try await service.installRuntime(unreachable) }
        #expect(service.installedRuntime()?.set == old)
        #expect(try fm.contentsOfDirectory(atPath: runtime.deletingLastPathComponent().path).filter { $0.hasPrefix(".staging") }.isEmpty)
    }

    @Test func testBottleNamesFromInstallers() {
        #expect(Library.suggestedBottleName(forInstaller: "setup_the_witcher_3_v4.04.exe") == "The Witcher 3")
        #expect(Library.suggestedBottleName(forInstaller: "setup_cyberpunk_2077_2.13_(78035)_(64bit).exe") == "Cyberpunk 2077")
        #expect(Library.suggestedBottleName(forInstaller: "setup_hollow_knight_1.5.78.11833_(64bit)_(64235).exe") == "Hollow Knight")
        #expect(Library.suggestedBottleName(forInstaller: "Rayman Legends Setup 1.0.msi") == "Rayman Legends")
        #expect(Library.suggestedBottleName(forInstaller: "setup.exe") == "Programs")
    }

    @Test func testRunnerKeepsArgumentsLiteralAndHandlesFailure() async throws {
        let log = root.appendingPathComponent("process.log")
        let argument = "space and ' quote; $(this must stay literal)"
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/printf"), ["%s", argument], log: log)
        let content = try String(contentsOf: log, encoding: .utf8)
        #expect(content.hasSuffix(argument))
        do {
            try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/false"), [], log: log)
            Issue.record("A failing process must throw")
        } catch {}
    }
    @Test func testRunnerTimesOutAnUnresponsiveChild() async throws {
        let start = Date()
        do {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["10"], log: root.appendingPathComponent("timeout.log"), timeout: 0.15)
            Issue.record("The child must time out")
        } catch {
            #expect(error.localizedDescription.contains("took too long"))
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
