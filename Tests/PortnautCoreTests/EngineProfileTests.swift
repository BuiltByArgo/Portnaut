import Foundation
import Testing
@testable import PortnautCore

@Suite
struct EngineProfileTests {
    func gtaBottle() -> Bottle {
        var bottle = Bottle(id: "gta", name: "GTA V", launcher: .rockstar, renderer: .d3dmetal)
        bottle.engineProfile = .gta5Enhanced
        return bottle
    }

    @Test func libraryWithoutProfileStillLoads() throws {
        let json = #"{"id":"b","name":"B","renderer":"dxmt"}"#
        let bottle = try JSONDecoder().decode(Bottle.self, from: Data(json.utf8))
        #expect(bottle.engineProfile == nil)
        let saved = try JSONDecoder().decode(Bottle.self, from: JSONEncoder().encode(gtaBottle()))
        #expect(saved.engineProfile == .gta5Enhanced)
        #expect(String(decoding: try JSONEncoder().encode(gtaBottle()), as: UTF8.self).contains(#""engineProfile":"gta5-enhanced""#))
    }

    @Test func profileBottleRunsOnTheProfileEngine() {
        let paths = PortnautPaths(root: URL(fileURLWithPath: "/tmp/portnaut-root"))
        let engine = paths.profile(.gta5Enhanced).engine
        #expect(engine == URL(fileURLWithPath: "/tmp/portnaut-root").appendingPathComponent("Runtimes/profiles/gta5-enhanced/engine"))
        #expect(paths.wine(for: gtaBottle()) == engine.appendingPathComponent("bin/wine"))
        #expect(paths.wineserver(for: gtaBottle()) == engine.appendingPathComponent("bin/wineserver"))
        let plain = Bottle(id: "p", name: "P", renderer: .dxmt)
        #expect(paths.wine(for: plain) == paths.wine(for: Renderer.dxmt))
    }

    /// No graphics override in the environment: the per-program registry decides between D3DMetal and WineD3D.
    @Test func environmentLeavesGraphicsToThePrograms() {
        let service = WineService(paths: PortnautPaths(root: URL(fileURLWithPath: "/tmp/portnaut-root")), metalShim: URL(fileURLWithPath: "/tmp/shim.dylib"))
        var bottle = gtaBottle()
        bottle.environment = ["WINEDLLOVERRIDES": "d3d12=n", "MY_FLAG": "1"]
        let env = service.environment(for: bottle)
        let overrides = env["WINEDLLOVERRIDES"] ?? ""
        for dll in ["dxgi", "d3d11", "d3d12", "d3d10core"] { #expect(!overrides.contains(dll)) }
        #expect(overrides.contains("nvapi64,nvngx="))
        #expect(env["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(env["WINEDLLPATH"]?.hasPrefix(service.paths.profile(.gta5Enhanced).d3dmetal.appendingPathComponent("wine").path + ":") == true)
        #expect(env["WINEMSYNC"] == "0")
        #expect(env["USER"] == "crossover")
        #expect(env["LOGNAME"] == "crossover")
        #expect(env["MY_FLAG"] == "1")
        #expect(env["PATH"]?.hasPrefix(service.paths.profile(.gta5Enhanced).engine.path) == true)
    }

    /// Portnaut's renderer options do not reach the profile's engine.
    @Test func rendererOptionsDoNotLeakIntoTheProfile() {
        let service = WineService(paths: PortnautPaths(root: URL(fileURLWithPath: "/tmp/portnaut-root")), metalShim: nil)
        var bottle = gtaBottle()
        bottle.renderer = .dxmt
        bottle.msync = true
        bottle.options.metalFXUpscaling = true
        bottle.options.dlss = true
        #expect(!bottle.metalFXActive && !bottle.dlssActive && bottle.retinaMode)
        let env = service.environment(for: bottle)
        #expect(env["WINEMSYNC"] == "0")
        #expect(env["D3DM_ENABLE_METALFX"] == "0")
        #expect(!env.keys.contains { $0.hasPrefix("DXMT_") })
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"]?.contains("/Libraries") == false)
        #expect(env["GTM_ROCKSTAR_SWIFTSHADER"] == "1")
    }

    /// Portnaut's Social Club switches are written first and removed by the profile.
    @Test func socialClubSwitchesAreRemoved() {
        let registry = WineService.profile(for: gtaBottle())
        let added = registry.range(of: "\"CommandLineAppend\"=\"")
        let removed = registry.range(of: "\"CommandLineAppend\"=-")
        #expect(removed != nil)
        if let added, let removed { #expect(added.lowerBound < removed.lowerBound) }
    }

    @Test func gameArgumentsAreWrittenOnceTheGameIsInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portnaut-profile-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        let bottlePaths = service.paths.bottle(gtaBottle())
        try FileManager.default.createDirectory(at: bottlePaths.drive, withIntermediateDirectories: true)
        try service.writeGameArguments(to: bottlePaths)
        let folder = bottlePaths.drive.appendingPathComponent(EngineProfile.gameFolder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A folder without the game's executable is not the game's yet.
        try service.writeGameArguments(to: bottlePaths)
        let file = folder.appendingPathComponent("commandline.txt")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try Data().write(to: folder.appendingPathComponent(EngineProfile.gameExecutable))
        try Data("-windowed\n".utf8).write(to: file)
        try service.writeGameArguments(to: bottlePaths)
        #expect(try String(contentsOf: file, encoding: .utf8) == "-windowed\n-disableSpatialAudioClient\n-nobattleye\n")
        // With a byte-order mark, and without one in either byte order (ASCII only, so also valid UTF-8).
        for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
            let utf16 = "-windowed".data(using: encoding)!
            try utf16.write(to: file)
            try service.writeGameArguments(to: bottlePaths)
            #expect(try Data(contentsOf: file) == utf16)
        }
    }

    /// The profile's per-program overrides come after a game's own, so they win.
    @Test func profileRegistryComesLast() {
        var bottle = gtaBottle()
        var game = Game(id: "gta5", name: "GTA V Enhanced", executable: EngineProfile.gameFolder + "/GTA5_Enhanced.exe")
        game.dllOverrides = ["dxgi": .native]
        bottle.games = [game]
        let registry = WineService.profile(for: bottle)
        let key = "[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\GTA5_Enhanced.exe\\DllOverrides]"
        let gameKey = registry.range(of: key)
        let profileKey = registry.range(of: key, options: .backwards)
        #expect(gameKey != nil && profileKey != nil && gameKey!.lowerBound < profileKey!.lowerBound)
        #expect(registry.hasSuffix(EngineProfile.gta5Enhanced.registry))
        #expect(registry.contains("\"CaptureDisplaysForFullscreen\"=\"y\""))
    }

    @Test func launcherGetsWineD3DAndGameGetsD3DMetal() {
        let copies = EngineProfile.gta5Enhanced.systemCopies(layout: EngineProfile.Layout(root: URL(fileURLWithPath: "/p")))
        var final: [String: String] = [:]
        for copy in copies { final[copy.name] = copy.from.path }
        #expect(final["dxgi.dll"] == "/p/launcher-wined3d/dxgi.dll")
        #expect(final["d3d11.dll"] == "/p/launcher-wined3d/d3d11.dll")
        #expect(final["d3d10core.dll"] == "/p/launcher-wined3d/d3d10core.dll")
        #expect(final["d3d12.dll"] == "/p/packs/sikarugir-d3dmetal-4.0b3/wine/x86_64-windows/d3d12.dll")
        #expect(final["atidxx64.dll"] == "/p/deps/Frameworks/renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll")
    }

    /// Every download is pinned by its SHA-256, and the engine comes from Portnaut's own releases.
    @Test func downloadsArePinned() {
        for profile in EngineProfile.allCases {
            for download in profile.downloads {
                #expect(download.sha256.count == 64 && download.sha256.allSatisfy(\.isHexDigit), "\(download.url)")
                #expect(!download.url.path.lowercased().hasPrefix("/tarikbc/"), "\(download.url)")
            }
        }
        #expect(EngineProfile.gta5Enhanced.downloads.contains { $0.url.absoluteString.hasPrefix("https://github.com/BuiltByArgo/Portnaut/releases/download/") })
    }

    @Test func linksResolveInsideTheProfile() {
        #expect(EngineProfile.linkTarget("renderer/d3dmetal/wine/x86_64-windows/dxgi.dll") { _ in true }
                == "packs/sikarugir-d3dmetal-4.0b3/wine/x86_64-windows/dxgi.dll")
        #expect(EngineProfile.linkTarget("renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll") { _ in false }
                == "deps/Frameworks/renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll")
        #expect(EngineProfile.linkTarget("libfreetype.6.dylib") { _ in true } == "deps/Frameworks/libfreetype.6.dylib")
        // D3DMetal 4.0b3's folder has the Unix side but no atidxx64.dll; that one comes from the template.
        let pack: Set = ["external/libd3dshared.dylib", "wine/x86_64-windows/d3d11.dll"]
        let targets = Dictionary(uniqueKeysWithValues: EngineProfile.engineLinks.map { ($0.link, EngineProfile.linkTarget($0.target) { pack.contains($0) }) })
        #expect(targets["lib/wine/x86_64-unix/d3d12.so"] == "packs/sikarugir-d3dmetal-4.0b3/external/libd3dshared.dylib")
        #expect(targets["lib/wine/x86_64-windows/atidxx64.dll"] == "deps/Frameworks/renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll")
        // The game gets D3DMetal's dxgi from the engine's own folder, which Wine searches before WINEDLLPATH.
        let pack2: Set = ["external/libd3dshared.dylib", "wine/x86_64-windows/dxgi.dll"]
        #expect(EngineProfile.engineLinks.first { $0.link == "lib/wine/x86_64-windows/dxgi.dll" }
                    .map { EngineProfile.linkTarget($0.target) { pack2.contains($0) } } == "packs/sikarugir-d3dmetal-4.0b3/wine/x86_64-windows/dxgi.dll")
        #expect(EngineProfile.relativeLink(from: "engine/lib/wine/x86_64-windows/dxgi.dll", to: "packs/x/dxgi.dll") == "../../../../packs/x/dxgi.dll")
        let base = URL(fileURLWithPath: "/root/engine/lib/wine/x86_64-windows/")
        #expect(URL(fileURLWithPath: "../../../../packs/x/dxgi.dll", relativeTo: base).standardizedFileURL.path == "/root/packs/x/dxgi.dll")
    }

    @Test func commandLineKeepsTheUsersArgumentsAndAddsEachRequiredOnce() {
        #expect(EngineProfile.commandLine(merging: nil) == "-disableSpatialAudioClient\n-nobattleye\n")
        #expect(EngineProfile.commandLine(merging: "-windowed\n-nobattleye\n") == "-windowed\n-nobattleye\n-disableSpatialAudioClient\n")
        let once = EngineProfile.commandLine(merging: "-fullscreen")
        #expect(EngineProfile.commandLine(merging: once) == once)
    }

    @Test func aProfileBottleHasNoBestSetup() {
        let game = Game(id: "gta5", name: "GTA V Enhanced", executable: EngineProfile.gameFolder + "/GTA5_Enhanced.exe")
        let service = WineService(paths: PortnautPaths(root: URL(fileURLWithPath: "/tmp/portnaut-root")), metalShim: nil)
        let error = #expect(throws: PortnautError.self) { try service.startSetupTrial(for: game, in: gtaBottle()) }
        #expect(error?.message.hasSuffix("nothing to compare.") == true)
    }

    // MARK: - Bottles on the profile

    /// A scratch Portnaut root with a prepared runtime (a Wine per renderer that only exits) and a built engine
    /// profile: its marker, its Wine, and a sentinel file for every system32 copy.
    func scratchRoot() throws -> (URL, WineService) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("portnaut-engine-" + UUID().uuidString)
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        let profile = EngineProfile.gta5Enhanced
        let layout = service.paths.profile(profile)
        try fakeWine(layout.engine.appendingPathComponent("bin/wine"))
        try fakeWine(layout.engine.appendingPathComponent("bin/wineserver"))
        try Data(profile.marker.utf8).write(to: layout.markerFile)
        for copy in profile.systemCopies(layout: layout) {
            try fm.createDirectory(at: copy.from.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("profile:\(copy.from.path)".utf8).write(to: copy.from)
        }
        try service.paths.createDirectories()
        for renderer in Renderer.allCases { try fakeWine(service.paths.wine(for: renderer)); try fakeWine(service.paths.wineserver(for: renderer)) }
        try Data().write(to: service.paths.runtimeMarker)
        try fm.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        return (root, service)
    }
    /// A Wine (or wineserver) that exits 0. Its wineboot creates the folders prepareBottle's later steps use and the
    /// system hive a ready bottle has; its `reg` counts itself in the prefix's reg-calls; its `-k0` exits 0 (a server
    /// runs) when the prefix holds a file named running, else 1.
    func fakeWine(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        [ "$1" = wineboot ] && mkdir -p "$WINEPREFIX/dosdevices" "$WINEPREFIX/drive_c/windows/system32" && touch "$WINEPREFIX/system.reg"
        [ "$1" = -k0 ] && { [ -e "$WINEPREFIX/running" ] && exit 0; exit 1; }
        [ "$1" = reg ] && echo reg >> "$WINEPREFIX/reg-calls"
        # A launcher session that installs the game in a folder of its own, its parent moved into the prefix whole
        # from a staging folder outside it (so the watch sees only that folder's rename), then waits for a line on
        # the prefix's FIFO named installed (the test sends it once the watch has written the arguments). The FIFO
        # is open before the move, so the line cannot come before anyone reads it.
        case "$1" in *install-gta.exe)
            exec 3<>"$WINEPREFIX/installed"
            staging="$WINEPREFIX/../staging"
            mkdir -p "$staging/GTA V Enhanced" && : > "$staging/GTA V Enhanced/GTA5_Enhanced.exe"
            mv "$staging" "$WINEPREFIX/drive_c/Games"
            # delay: test deadline: bounds the fake launcher's wait for the watch; on expiry the case fails.
            read -t 60 line <&3 || exit 3
        esac
        exit 0

        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func contents(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    /// A bottle created on the profile is saved with it and set up on it: the profile's files in system32, its
    /// registry, its build's marker, and drive Y: on the profile's runtime.
    @Test func aBottleCreatedOnTheProfileStartsOnIt() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = try await service.createBottle(name: "Rockstar Games Launcher", launcher: .rockstar, renderer: .dxmt, engineProfile: .gta5Enhanced)
        #expect(try service.bottle(bottle.id).engineProfile == .gta5Enhanced)
        let bottlePaths = service.paths.bottle(bottle)
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { #expect(contents(system32.appendingPathComponent(name))?.contains("launcher-wined3d") == true) }
        #expect(contents(system32.appendingPathComponent("d3d12.dll"))?.contains("sikarugir-d3dmetal-4.0b3") == true)
        #expect(contents(system32.appendingPathComponent("atidxx64.dll"))?.hasPrefix("profile:") == true)
        #expect(contents(bottlePaths.prefix.appendingPathComponent("reg-calls")) == "reg\n")
        #expect(contents(bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg"))?.hasSuffix(EngineProfile.gta5Enhanced.registry) == true)
        #expect(contents(service.appliedMarkerFile(in: bottlePaths)) == EngineProfile.gta5Enhanced.marker)
        let drive = bottlePaths.prefix.appendingPathComponent("dosdevices/y:")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: drive.path) == service.paths.profile(.gta5Enhanced).root.path)
        // The kind offers no renderer choices.
        let game = Game(id: "gta5", name: "GTA V Enhanced", executable: EngineProfile.gameFolder + "/GTA5_Enhanced.exe")
        let error = #expect(throws: PortnautError.self) { try service.startSetupTrial(for: game, in: bottle) }
        #expect(error?.message.hasSuffix("nothing to compare.") == true)
    }

    /// A start after the profile's marker changed copies its files and imports its registry again, then records
    /// the marker; a later start with the marker current does neither.
    @Test func aMarkerChangeIsAppliedAtTheNextStart() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = try await service.createBottle(name: "GTA", launcher: .rockstar, renderer: .dxmt, engineProfile: .gta5Enhanced)
        let bottlePaths = service.paths.bottle(bottle)
        let program = bottlePaths.drive.appendingPathComponent("game.exe")
        try Data().write(to: program)
        let d3d12 = bottlePaths.drive.appendingPathComponent("windows/system32/d3d12.dll")
        let regCalls = bottlePaths.prefix.appendingPathComponent("reg-calls")
        // The bottle as an earlier build of the profile left it.
        try Data("earlier build".utf8).write(to: d3d12)
        try Data("gta5-enhanced-v3:old".utf8).write(to: service.appliedMarkerFile(in: bottlePaths))
        try FileManager.default.removeItem(at: regCalls)
        try await service.launch(program, in: bottle, waitForSession: false)
        #expect(contents(d3d12)?.hasPrefix("profile:") == true)
        #expect(contents(regCalls) == "reg\n")
        #expect(contents(service.appliedMarkerFile(in: bottlePaths)) == EngineProfile.gta5Enhanced.marker)
        // Current: nothing is applied again.
        try Data("kept".utf8).write(to: d3d12)
        try await service.launch(program, in: bottle, waitForSession: false)
        #expect(contents(d3d12) == "kept")
        #expect(contents(regCalls) == "reg\n")
    }

    /// A start in a bottle still running on an older build is refused and changes nothing; the first start after
    /// its session ends applies the build.
    @Test func aSessionOnAnOlderBuildEndsFirst() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = try await service.createBottle(name: "GTA", launcher: .rockstar, renderer: .dxmt, engineProfile: .gta5Enhanced)
        let bottlePaths = service.paths.bottle(bottle)
        let program = bottlePaths.drive.appendingPathComponent("game.exe")
        try Data().write(to: program)
        let d3d12 = bottlePaths.drive.appendingPathComponent("windows/system32/d3d12.dll")
        try Data("earlier build".utf8).write(to: d3d12)
        try Data("gta5-enhanced-v3:old".utf8).write(to: service.appliedMarkerFile(in: bottlePaths))
        let running = bottlePaths.prefix.appendingPathComponent("running")
        try Data().write(to: running)
        await #expect(throws: PortnautError.self) { try await service.launch(program, in: bottle, waitForSession: false) }
        #expect(contents(d3d12) == "earlier build")
        #expect(contents(service.appliedMarkerFile(in: bottlePaths)) == "gta5-enhanced-v3:old")
        try FileManager.default.removeItem(at: running)
        try await service.launch(program, in: bottle, waitForSession: false)
        #expect(contents(d3d12)?.hasPrefix("profile:") == true)
        #expect(contents(service.appliedMarkerFile(in: bottlePaths)) == EngineProfile.gta5Enhanced.marker)
    }

    /// The profile's folder is shared, so it is not rebuilt while another bottle on it runs: neither a start in an
    /// idle bottle nor a new bottle replaces it.
    @Test func theSharedProfileIsNotRebuiltUnderARunningBottle() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await service.createBottle(name: "GTA", launcher: .rockstar, renderer: .dxmt, engineProfile: .gta5Enhanced)
        let second = try await service.createBottle(name: "GTA 2", launcher: .rockstar, renderer: .dxmt, engineProfile: .gta5Enhanced)
        let program = service.paths.bottle(second).drive.appendingPathComponent("game.exe")
        try Data().write(to: program)
        // A newer Portnaut: the built profile is an older build, which the first bottle still runs on.
        let markerFile = service.paths.profile(.gta5Enhanced).markerFile
        try Data("gta5-enhanced-v3:old".utf8).write(to: markerFile)
        try Data().write(to: service.paths.bottle(first).prefix.appendingPathComponent("running"))
        let launch = await #expect(throws: PortnautError.self) { try await service.launch(program, in: second, waitForSession: false) }
        #expect(launch?.message.hasPrefix(first.name + " is running") == true)
        await #expect(throws: PortnautError.self) {
            try await service.createBottle(name: "GTA 3", launcher: .rockstar, renderer: .dxmt, engineProfile: .gta5Enhanced)
        }
        #expect(contents(markerFile) == "gta5-enhanced-v3:old")
        #expect(try service.paths.loadLibrary().bottles.count == 2)
    }

    /// The launcher's record of the install folder, as Wine saves it in system.reg.
    @Test func theRecordedInstallFolderIsRead() {
        let registry = #"""
        WINE REGISTRY Version 2

        [Software\\Wow6432Node\\Rockstar Games\\GTAV Enhanced\\Extra] 1795283448
        "InstallFolder"="C:\\Wrong"

        [Software\\Wow6432Node\\Rockstar Games\\GTAV Enhanced] 1795283448
        #time=1dd79e0d7bb5696
        "InstallFolder"="D:\\Games\\Grand Theft Auto V Enhanced"
        "Version"="1.0.1158.16"

        """#
        #expect(EngineProfile.recordedGameFolder(systemRegistry: registry) == #"D:\Games\Grand Theft Auto V Enhanced"#)
        #expect(EngineProfile.recordedGameFolder(systemRegistry: registry.replacingOccurrences(of: "D:\\\\Games", with: "D:\\x{0105}")) == nil)
        #expect(EngineProfile.recordedGameFolder(systemRegistry: "[Software\\\\Wow6432Node\\\\Rockstar Games\\\\Launcher]\n\"InstallFolder\"=\"C:\\\\L\"\n") == nil)
        #expect(WineService.macFolder(forWindowsPath: #"C:\Games\..\x"#, in: BottlePaths(prefix: URL(fileURLWithPath: "/p"))) == nil)
        #expect(WineService.macFolder(forWindowsPath: #"C:\Games\GTA"#, in: BottlePaths(prefix: URL(fileURLWithPath: "/p")))?.path == "/p/dosdevices/c:/Games/GTA")
    }

    /// A profile bottle with Wine's drive links: C: to its drive_c and Z: to a folder outside the prefix.
    func gtaBottleWithDrives(_ service: WineService, root: URL) async throws -> (Bottle, BottlePaths) {
        let bottle = try await service.createBottle(name: "GTA", launcher: .rockstar, renderer: .dxmt, engineProfile: .gta5Enhanced)
        let bottlePaths = service.paths.bottle(bottle)
        let dosdevices = bottlePaths.prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createSymbolicLink(atPath: dosdevices.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dosdevices.appendingPathComponent("z:"), withDestinationURL: outside)
        return (bottle, bottlePaths)
    }
    func installGame(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(EngineProfile.gameExecutable))
    }
    func record(installFolder: String, in bottlePaths: BottlePaths) throws {
        let escaped = installFolder.replacingOccurrences(of: "\\", with: "\\\\")
        let registry = "WINE REGISTRY Version 2\n\n[Software\\\\Wow6432Node\\\\Rockstar Games\\\\GTAV Enhanced] 1795283448\n\"InstallFolder\"=\"\(escaped)\"\n\n"
        try Data(registry.utf8).write(to: bottlePaths.prefix.appendingPathComponent("system.reg"))
    }

    /// A game the launcher installed in a folder of the user's choice gets the arguments at the next start, as in
    /// the default folder; a recorded folder outside the bottle's prefix is not written.
    @Test func aCustomInstallFolderGetsTheArguments() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, bottlePaths) = try await gtaBottleWithDrives(service, root: root)
        let program = bottlePaths.drive.appendingPathComponent("game.exe")
        try Data().write(to: program)
        let custom = bottlePaths.drive.appendingPathComponent("Games/GTA V Enhanced")
        try installGame(in: custom)
        try record(installFolder: #"C:\Games\GTA V Enhanced"#, in: bottlePaths)
        try await service.launch(program, in: bottle, waitForSession: false)
        #expect(contents(custom.appendingPathComponent("commandline.txt")) == "-disableSpatialAudioClient\n-nobattleye\n")
        let outside = root.appendingPathComponent("outside/GTA")
        try installGame(in: outside)
        try record(installFolder: #"Z:\GTA"#, in: bottlePaths)
        try await service.launch(program, in: bottle, waitForSession: false)
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("commandline.txt").path))
    }

    /// The launcher session that installs the game has its arguments in place while it still runs, so its first
    /// Play has them: the fake launcher moves a tree holding the game's folder into the prefix (a folder not in the
    /// registry) and waits until the watch has written commandline.txt there.
    @Test func theSessionThatInstallsTheGameGetsTheArguments() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, bottlePaths) = try await gtaBottleWithDrives(service, root: root)
        let launcher = bottlePaths.drive.appendingPathComponent("install-gta.exe")
        try Data().write(to: launcher)
        let installed = bottlePaths.prefix.appendingPathComponent("installed")
        #expect(mkfifo(installed.path, 0o600) == 0)
        let file = bottlePaths.drive.appendingPathComponent("Games/GTA V Enhanced/commandline.txt")
        let seen = Seen()
        service.gameArgumentsPass = { [self] folders in
            guard folders.contains(where: { $0.appendingPathComponent("commandline.txt").resolvingSymlinksInPath() == file.resolvingSymlinksInPath() }),
                  seen.first(contents(file)) else { return }
            // Non-blocking: with no reader left (the fake launcher gave up), open fails and the launch's exit code
            // fails the case instead of a hang.
            let fd = open(installed.path, O_WRONLY | O_NONBLOCK)
            guard fd >= 0 else { return }
            _ = "go\n".withCString { write(fd, $0, 3) }
            close(fd)
        }
        try await service.launch(launcher, in: bottle)
        #expect(seen.value == "-disableSpatialAudioClient\n-nobattleye\n")
    }

    /// portnaut-doctor's run starts Wine like any other start: a profile bottle on an older build is brought to the
    /// current one first.
    @Test func aWineCommandBringsTheBottleUpToDate() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = try await service.createBottle(name: "GTA", launcher: .rockstar, renderer: .dxmt, engineProfile: .gta5Enhanced)
        let bottlePaths = service.paths.bottle(bottle)
        let d3d12 = bottlePaths.drive.appendingPathComponent("windows/system32/d3d12.dll")
        try Data("earlier build".utf8).write(to: d3d12)
        try Data("gta5-enhanced-v3:old".utf8).write(to: service.appliedMarkerFile(in: bottlePaths))
        let status = try await service.runWine(in: bottle) { ["winecfg"] }
        #expect(status == 0)
        #expect(contents(d3d12)?.hasPrefix("profile:") == true)
        #expect(contents(service.appliedMarkerFile(in: bottlePaths)) == EngineProfile.gta5Enhanced.marker)
    }

    /// An ordinary Rockstar Games bottle is set up as before: Portnaut's renderer, its runtime on drive Y:, and
    /// none of the profile's files, registry or marker.
    @Test func anOrdinaryRockstarBottleIsUnchanged() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = try await service.createBottle(name: "Rockstar Games Launcher", launcher: .rockstar, renderer: .dxmt)
        #expect(try service.bottle(bottle.id).engineProfile == nil)
        #expect(service.paths.wine(for: bottle) == service.paths.wine(for: Renderer.dxmt))
        let bottlePaths = service.paths.bottle(bottle)
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent("d3d12.dll").path))
        #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent("atidxx64.dll").path))
        #expect(contents(bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg")) == WineService.profile(for: bottle))
        #expect(contents(bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg"))?.contains("CaptureDisplaysForFullscreen") == false)
        #expect(!FileManager.default.fileExists(atPath: service.appliedMarkerFile(in: bottlePaths).path))
        let drive = bottlePaths.prefix.appendingPathComponent("dosdevices/y:")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: drive.path) == service.paths.runtime.path)
        #expect(service.environment(for: bottle)["USER"] != "crossover")
    }
}

/// The first value a session's watch saw, kept once.
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String??
    /// Keeps `value` if nothing is kept yet; true when it did.
    func first(_ value: String?) -> Bool { lock.withLock { guard stored == nil else { return false }; stored = .some(value); return true } }
    var value: String? { lock.withLock { stored ?? nil } }
}
