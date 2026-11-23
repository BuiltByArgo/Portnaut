import Foundation
import Darwin

public struct SetupProgress: Sendable {
    public var fraction: Double
    public var message: String
    public init(_ fraction: Double, _ message: String) { self.fraction = fraction; self.message = message }
}

public final class WineService: @unchecked Sendable {
    public let paths: PortnautPaths
    /// Loaded into Wine processes; see Shims/PortnautMetalShim.m. nil outside Portnaut.app.
    public let metalShim: URL?
    public init(paths: PortnautPaths = PortnautPaths(), metalShim: URL? = WineService.bundledMetalShim) {
        self.paths = paths
        self.metalShim = metalShim
    }
    public static var bundledMetalShim: URL? {
        guard let folder = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        let name = "libPortnautMetalShim.dylib"
        // Portnaut runs from Contents/MacOS, portnaut-doctor from Contents/Helpers.
        return [folder.appendingPathComponent(name), folder.deletingLastPathComponent().appendingPathComponent("Helpers/\(name)")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Portnaut's Wine is x86_64 and runs through Rosetta, which macOS installs only when asked to.
    /// Without it, every Wine command fails with an unhelpful "bad CPU type".
    public static var rosettaInstalled: Bool { FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") }
    public static let rosettaMissing = "Portnaut runs Windows programs through Rosetta, which is not installed on this Mac. Open Terminal, run “softwareupdate --install-rosetta”, accept Apple’s licence there, then choose Prepare Portnaut again."

    // MARK: - Environment

    /// Everything a Wine process of this bottle needs. A game started from a launcher inherits it,
    /// so the renderer and the session options apply to the whole bottle.
    public func environment(for bottle: Bottle, game: Game? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("WINE") && !key.hasPrefix("CX_") && !key.hasPrefix("DYLD_") && !key.hasPrefix("DXMT_")
                && !key.hasPrefix("DXVK_") && !key.hasPrefix("D3DM_") && !key.hasPrefix("PORTNAUT_")
        }
        if let profile = bottle.engineProfile {
            env = profile.environment(base: env, layout: paths.profile(profile), prefix: paths.bottle(bottle).prefix, bottle: bottle, cache: paths.cache)
        } else {
            env = rendererEnvironment(for: bottle, base: env)
        }
        // The user's own variables last, so they can adjust Portnaut's (not the ones that keep the bottle apart).
        for (key, value) in bottle.environment.merging(game?.environment ?? [:], uniquingKeysWith: { $1 }) where EnvironmentPolicy.allows(key) { env[key] = value }
        return env
    }

    /// Portnaut's runtime with the bottle's renderer.
    private func rendererEnvironment(for bottle: Bottle, base: [String: String]) -> [String: String] {
        var env = base
        let engine = paths.engine(for: bottle.renderer)
        env["PATH"] = engine.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env["WINEPREFIX"] = paths.bottle(bottle).prefix.path
        env["WINEARCH"] = "win64"
        if bottle.msync { env["WINEMSYNC"] = "1" }
        // Wine's Windows write-copy memory emulation is needed by Ubisoft's CEF browser.
        // It stays session-wide: games started from a launcher inherit its environment.
        env["WINE_SIMULATE_WRITECOPY"] = "1"
        // NVIDIA's API stays off unless DLSS is on: games would otherwise take the Mac for an NVIDIA PC.
        env["WINEDLLOVERRIDES"] = bottle.renderer.dllOverrides + (bottle.dlssActive ? "" : ";nvapi,nvapi64=") + ";winemenubuilder.exe=d"
        // PORTNAUT_WINEDEBUG lets diagnostics trace a session, e.g. "-all,err+all,+loaddll".
        env["WINEDEBUG"] = ProcessInfo.processInfo.environment["PORTNAUT_WINEDEBUG"] ?? "-all,err+all"
        env["DXMT_LOG_PATH"] = paths.logs.path
        if bottle.renderer == .dxvk { env["DXVK_LOG_PATH"] = paths.logs.path }
        let gst = paths.libraries.appendingPathComponent("GStreamer.framework/Versions/1.0")
        // Fallback only: overriding macOS libraries breaks AppKit window creation.
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [paths.libraries.path, gst.appendingPathComponent("lib").path, engine.appendingPathComponent("lib").path,
                                             engine.appendingPathComponent("lib/wine/x86_64-unix").path, "/usr/lib"].joined(separator: ":")
        env["DYLD_FALLBACK_FRAMEWORK_PATH"] = paths.libraries.path
        // Keeps DXMT's dual-source blending pipelines valid for Metal instead of aborting the game.
        if let metalShim { env["DYLD_INSERT_LIBRARIES"] = metalShim.path }
        env["GST_PLUGIN_SYSTEM_PATH_1_0"] = gst.appendingPathComponent("lib/gstreamer-1.0").path
        env["GST_PLUGIN_SCANNER_1_0"] = gst.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner").path
        env["GST_REGISTRY_1_0"] = paths.cache.appendingPathComponent("gstreamer-registry.bin").path
        env["MTL_HUD_ENABLED"] = bottle.options.performanceHUD ? "1" : "0"
        // Read by PortnautMetalShim; both do nothing without it.
        if bottle.options.recordPerformance { env["PORTNAUT_LATENCY_TRACE"] = "1" }
        if bottle.options.reduceFrameQueue { env["PORTNAUT_FRAME_QUEUE"] = "2" }
        if bottle.renderer == .dxmt, let config = GraphicsProfile.dxmtConfig(frameRateLimit: bottle.options.frameRateLimit, metalFXFactor: bottle.metalFXActive ? 2 : nil) {
            env["DXMT_CONFIG"] = config
        }
        // DXMT's swapchain upscales with MetalFX; Wine reports point resolution meanwhile (see retinaMode).
        if bottle.metalFXActive { env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1" }
        if bottle.dlssActive { env[bottle.renderer == .dxmt ? "DXMT_ENABLE_NVEXT" : "D3DM_ENABLE_METALFX"] = "1" }
        // Rosetta on macOS 15 and later translates AVX and AVX2, but reports them only when asked.
        if bottle.options.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        return env
    }

    // MARK: - Library

    public func library() throws -> Library { try paths.loadLibrary() }
    public func save(_ bottle: Bottle) throws {
        var library = try paths.loadLibrary()
        library.update(bottle)
        try paths.saveLibrary(library)
    }
    public func bottle(_ id: String) throws -> Bottle {
        guard let bottle = try paths.loadLibrary().bottle(id) else { throw PortnautError("There is no bottle called \(id).") }
        return bottle
    }

    // MARK: - Runtime

    func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 1200
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url?.scheme == "https" else {
            throw PortnautError("The download server returned an error. Check your connection and retry.")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
    }

    /// A part's archive in Downloads, reusing a verified copy, including one under the names Portnaut
    /// used before component updates.
    private func obtain(_ release: ComponentRelease) async throws -> URL {
        try await obtain(release.url, fileName: release.fileName, sha256: release.sha256, size: release.size,
                         legacy: ["highball-wine.tar.gz", "highball-dxmt.tar.gz", "highball-runtime.tar.xz"])
    }
    /// A pinned file in Downloads, reusing a verified copy (also under one of the `legacy` names).
    private func obtain(_ url: URL, fileName: String, sha256: String, size: Int64?, legacy: [String] = []) async throws -> URL {
        let fm = FileManager.default
        let destination = paths.cache.appendingPathComponent(fileName)
        for candidate in [destination] + legacy.map({ paths.cache.appendingPathComponent($0) }) where fm.fileExists(atPath: candidate.path) {
            let found = (try? fm.attributesOfItem(atPath: candidate.path)[.size] as? NSNumber)?.int64Value
            if let size, found != size { continue }
            if (try? FileIntegrity.verify(candidate, expected: sha256)) != nil { return candidate }
        }
        do { try await download(url, to: destination) }
        catch let error as PortnautError { throw error }
        catch { throw PortnautError("Couldn’t download \(fileName): \(error.localizedDescription)") }
        do { try FileIntegrity.verify(destination, expected: sha256) }
        catch { try? fm.removeItem(at: destination); throw error }
        return destination
    }

    /// Builds an engine profile when it is missing or was built from other files: its downloads checked,
    /// unpacked in a staging folder, the engine linked to D3DMetal, then moved into place. The unpacking
    /// tools and Wine's version check run until they exit.
    public func prepareProfile(_ profile: EngineProfile, progress: @escaping @Sendable (SetupProgress) async -> Void = { _ in }) async throws {
        guard !paths.profileReady(profile) else { return }
        guard Self.rosettaInstalled else { throw PortnautError(Self.rosettaMissing) }
        try paths.createDirectories()
        let fm = FileManager.default
        let layout = paths.profile(profile)
        try fm.createDirectory(at: layout.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let available = (try fm.attributesOfFileSystem(forPath: paths.root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available > 2_000_000_000 else { throw PortnautError("Free at least 2 GB to prepare \(profile.title).") }
        var archives: [String: URL] = [:]
        for (index, item) in profile.downloads.enumerated() {
            await progress(SetupProgress(0.05 + 0.5 * Double(index) / Double(profile.downloads.count), "Downloading \(item.fileName)"))
            archives[item.fileName] = try await obtain(item.url, fileName: item.fileName, sha256: item.sha256, size: item.size)
        }
        await progress(SetupProgress(0.6, "Installing \(profile.title)"))
        let stage = layout.root.deletingLastPathComponent().appendingPathComponent(".staging-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            let tar = URL(fileURLWithPath: "/usr/bin/tar")
            let sources = stage.appendingPathComponent(".sources")
            let staged = EngineProfile.Layout(root: stage)
            try fm.createDirectory(at: sources, withIntermediateDirectories: true)
            func unpack(_ fileName: String, into folder: URL, _ members: [String] = []) async throws {
                guard let archive = archives[fileName] else { throw PortnautError("\(profile.title) lacks \(fileName).") }
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try await ProcessRunner.run(tar, ["-xf", archive.path, "-C", folder.path] + members, log: paths.setupLog, timeout: nil)
            }
            try await unpack(profile.engineArchive, into: stage, ["engine", "launcher-wined3d"])
            try await unpack(profile.templateArchive, into: sources, [EngineProfile.templateApp])
            try fm.createDirectory(at: staged.frameworks.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: sources.appendingPathComponent(EngineProfile.templateApp), to: staged.frameworks)
            try await unpack(profile.d3dmetalArchive, into: sources, [EngineProfile.d3dmetalMember])
            try fm.createDirectory(at: staged.d3dmetal.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: sources.appendingPathComponent(EngineProfile.d3dmetalMember), to: staged.d3dmetal)
            // linkTarget falls back to the template's own (older) D3DMetal for a file this folder lacks, so a
            // folder without D3DMetal's Unix side would mix versions silently.
            guard fm.fileExists(atPath: staged.d3dmetal.appendingPathComponent("external/libd3dshared.dylib").path) else {
                throw PortnautError("\(EngineProfile.d3dmetalMember) has an unexpected layout.")
            }
            // The engine reaches D3DMetal through these links, which replace the engine's own files.
            for (relative, target) in EngineProfile.engineLinks {
                let link = staged.engine.appendingPathComponent(relative)
                var isFolder: ObjCBool = false
                if fm.fileExists(atPath: link.path, isDirectory: &isFolder) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                    guard !isFolder.boolValue else { throw PortnautError("\(profile.title)'s engine has a folder at \(relative).") }
                    try fm.removeItem(at: link)
                }
                let destination = EngineProfile.linkTarget(target) { fm.fileExists(atPath: staged.d3dmetal.appendingPathComponent($0).path) }
                guard fm.fileExists(atPath: stage.appendingPathComponent(destination).path) else { throw PortnautError("\(profile.title) lacks \(target).") }
                try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: EngineProfile.relativeLink(from: "engine/" + relative, to: destination))
            }
            try fm.removeItem(at: sources)
            for copy in profile.systemCopies(layout: staged) where !fm.fileExists(atPath: copy.from.path) {
                throw PortnautError("\(profile.title) lacks \(copy.from.lastPathComponent) for system32.")
            }
            try await ProcessRunner.run(staged.engine.appendingPathComponent("bin/wine"), ["--version"], log: paths.setupLog, timeout: nil)
            try Data(profile.marker.utf8).write(to: staged.markerFile, options: .atomic)
            // The profile it replaces goes aside first and comes back if the new one cannot move into place.
            let old = layout.root.deletingLastPathComponent().appendingPathComponent(".old-" + UUID().uuidString)
            let hadProfile = fm.fileExists(atPath: layout.root.path)
            if hadProfile { try fm.moveItem(at: layout.root, to: old) }
            do { try fm.moveItem(at: stage, to: layout.root) }
            catch { if hadProfile { try? fm.moveItem(at: old, to: layout.root) }; throw error }
            if hadProfile { try? fm.removeItem(at: old) }
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
        await progress(SetupProgress(1, "\(profile.title) is ready"))
    }

    /// Builds a runtime from a set of parts in a staging folder and returns it: one unmodified engine
    /// (wined3d) and an APFS clone of it per renderer with that renderer's modules installed. Clones
    /// share storage, so four renderers cost one engine. Nothing in use is touched.
    func buildRuntime(_ set: RuntimeSet, progress: @escaping @Sendable (SetupProgress) async -> Void) async throws -> URL {
        let fm = FileManager.default
        guard let wine = set.release(.wine), let dxmt = set.release(.dxmt), let support = set.release(.support) else {
            throw PortnautError("That set of components lacks Wine, DXMT or the template.")
        }
        func mb(_ release: ComponentRelease) -> String { release.size.map { " · \(max($0 / 1_000_000, 1)) MB" } ?? "" }
        await progress(SetupProgress(0.05, "Downloading Wine \(wine.version)\(mb(wine))"))
        let wineArchive = try await obtain(wine)
        await progress(SetupProgress(0.25, "Downloading DXMT \(dxmt.version)\(mb(dxmt))"))
        let dxmtArchive = try await obtain(dxmt)
        await progress(SetupProgress(0.32, "Downloading D3DMetal, DXVK and support libraries (template \(support.version))\(mb(support))"))
        let supportArchive = try await obtain(support)
        var extras: [(ComponentRelease, URL)] = []
        for part in [RuntimePart.moltenvk, .d3dmetal] {
            guard let release = set.release(part) else { continue }
            await progress(SetupProgress(0.4, "Downloading \(part.title) \(release.version)\(mb(release))"))
            extras.append((release, try await obtain(release)))
        }
        await progress(SetupProgress(0.45, "Installing verified compatibility tools"))
        let stage = paths.runtime.deletingLastPathComponent().appendingPathComponent(".staging-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            let tar = URL(fileURLWithPath: "/usr/bin/tar")
            func unpack(_ archive: URL, into folder: URL, _ members: [String] = []) async throws {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try await ProcessRunner.run(tar, ["-xf", archive.path, "-C", folder.path] + members, log: paths.setupLog, timeout: 600)
            }
            try await unpack(wineArchive, into: stage)
            let engine = stage.appendingPathComponent("engine")
            guard fm.fileExists(atPath: engine.appendingPathComponent("bin/wine").path) else { throw PortnautError("The Wine archive has no engine/bin/wine.") }
            let sources = stage.appendingPathComponent(".sources")
            try await unpack(dxmtArchive, into: sources.appendingPathComponent("dxmt"))
            // The whole Contents folder: renderers moved from Frameworks/renderer (1.0.11) to SharedSupport/renderer (1.0.24).
            let supportSource = sources.appendingPathComponent("support")
            try await unpack(supportArchive, into: supportSource, support.subpath.map { ["\($0)/Contents"] } ?? [])
            guard let app = support.subpath ?? (try? fm.contentsOfDirectory(atPath: supportSource.path))?.first(where: { $0.hasSuffix(".app") }) else {
                throw PortnautError("The template archive has no .app folder.")
            }
            let contents = supportSource.appendingPathComponent(app).appendingPathComponent("Contents")
            let frameworks = contents.appendingPathComponent("Frameworks")
            guard let renderers = [frameworks.appendingPathComponent("renderer"), contents.appendingPathComponent("SharedSupport/renderer")]
                .first(where: { fm.fileExists(atPath: $0.path) }) else { throw PortnautError("The template \(support.version) has no renderer folder.") }
            try fm.moveItem(at: renderers, to: sources.appendingPathComponent("renderer"))
            let libraries = stage.appendingPathComponent("Libraries")
            try fm.createDirectory(at: libraries, withIntermediateDirectories: true)
            // Only open-source support libraries; never the proprietary wrapper SDK or launcher.
            for file in try fm.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) {
                if file.pathExtension == "dylib" || file.lastPathComponent == "GStreamer.framework" {
                    try fm.copyItem(at: file, to: libraries.appendingPathComponent(file.lastPathComponent))
                }
            }
            for (release, archive) in extras {
                let folder = sources.appendingPathComponent(release.part.rawValue)
                try await unpack(archive, into: folder)
                let item = folder.appendingPathComponent(release.subpath ?? "")
                guard fm.fileExists(atPath: item.path) else { throw PortnautError("\(release.part.title) \(release.version) is not where its archive should have it.") }
                let target = release.part == .moltenvk ? libraries.appendingPathComponent("libMoltenVK.dylib") : sources.appendingPathComponent("renderer/d3dmetal")
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: item, to: target)
            }
            var details = Self.details(renderers: sources.appendingPathComponent("renderer"), set: set)
            try fm.createDirectory(at: stage.appendingPathComponent("renderers"), withIntermediateDirectories: true)
            for renderer in Renderer.allCases {
                guard let folder = renderer.variantFolder else { continue }
                let files = try renderer.installation(from: sources)
                let variant = stage.appendingPathComponent("renderers/\(folder)")
                guard clonefile(engine.path, variant.path, 0) == 0 else {
                    throw PortnautError("Portnaut could not create the \(renderer.title) copy of Wine (\(String(cString: strerror(errno)))). Portnaut’s data folder must be on an APFS disk.")
                }
                for file in files {
                    let target = variant.appendingPathComponent(file.target)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil || fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: sources.appendingPathComponent(file.source), to: target)
                }
            }
            try fm.removeItem(at: sources)
            for renderer in Renderer.allCases {
                let wine = renderer.variantFolder.map { stage.appendingPathComponent("renderers/\($0)/bin/wine") } ?? engine.appendingPathComponent("bin/wine")
                try await ProcessRunner.run(wine, ["--version"], log: paths.setupLog, timeout: 30)
            }
            if let line = (try? String(contentsOf: paths.setupLog, encoding: .utf8))?.components(separatedBy: "\n").last(where: { $0.hasPrefix("wine-") }) {
                details["Wine"] = line.trimmingCharacters(in: .whitespaces)
            }
            try Data("Highball Wine 11; renderers \(Renderer.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8)
                .write(to: stage.appendingPathComponent(paths.runtimeMarker.lastPathComponent))
            let installed = InstalledRuntime(set: set, installedAt: Date(), details: details)
            try Self.json.encoder.encode(installed).write(to: stage.appendingPathComponent(paths.runtimeManifest.lastPathComponent), options: .atomic)
            return stage
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }

    /// Versions read from the unpacked template, for the Component Updates window.
    static func details(renderers: URL, set: RuntimeSet) -> [String: String] {
        var details: [String: String] = [:]
        let plist = renderers.appendingPathComponent("d3dmetal/external/D3DMetal.framework/Versions/A/Resources/Info.plist")
        if let info = NSDictionary(contentsOf: plist), let version = info["CFBundleShortVersionString"] as? String { details["D3DMetal"] = version }
        for (name, folder) in [("DXVK", "dxvk"), ("D9VK", "d9vk")] {
            // The first line names the build; template 1.0.24's D9VK file adds a second, older one.
            if let line = (try? String(contentsOf: renderers.appendingPathComponent("\(folder)/version"), encoding: .utf8))?
                .split(whereSeparator: \.isNewline).first {
                details[name] = line.trimmingCharacters(in: .whitespaces)
            }
        }
        details["MoltenVK"] = set.release(.moltenvk)?.version ?? "the template’s"
        return details
    }

    /// Stops the sessions of every bottle, then puts a built runtime in place. With `keepPrevious`, the
    /// runtime it replaces becomes Runtimes/previous for rolling back.
    func replaceRuntime(with stage: URL, keepPrevious: Bool) async throws {
        let fm = FileManager.default
        // End Windows programs still running from the runtime about to be replaced. An engine profile's bottles
        // run on their own engine and keep running.
        for bottle in (try? paths.loadLibrary().bottles) ?? [] where bottle.engineProfile == nil {
            for wineserver in [paths.wineserver(for: bottle), paths.legacyRuntime.appendingPathComponent("engine/bin/wineserver")]
            where fm.isExecutableFile(atPath: wineserver.path) {
                _ = try? await ProcessRunner.run(wineserver, ["-k"], environment: environment(for: bottle), log: paths.setupLog, timeout: 15, allowFailure: true)
            }
        }
        if fm.fileExists(atPath: paths.runtime.path) {
            if keepPrevious {
                if fm.fileExists(atPath: paths.previousRuntime.path) { try fm.removeItem(at: paths.previousRuntime) }
                try fm.moveItem(at: paths.runtime, to: paths.previousRuntime)
            } else {
                try fm.removeItem(at: paths.runtime)
            }
        }
        try fm.moveItem(at: stage, to: paths.runtime)
        if fm.fileExists(atPath: paths.legacyRuntime.path) { try? fm.removeItem(at: paths.legacyRuntime) }
    }

    /// Builds the runtime when it is missing or from an older layout, keeping the versions an older
    /// runtime of the current family was built from.
    public func prepareRuntime(progress: @escaping @Sendable (SetupProgress) async -> Void = { _ in }) async throws {
        try paths.createDirectories()
        guard !paths.runtimeReady else { return }
        guard Self.rosettaInstalled else { throw PortnautError(Self.rosettaMissing) }
        let available = (try FileManager.default.attributesOfFileSystem(forPath: paths.root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available > 3_000_000_000 else { throw PortnautError("Free at least 3 GB to prepare Portnaut’s compatibility tools.") }
        let kept = (try? Data(contentsOf: paths.runtimeManifest)).flatMap { try? Self.json.decoder.decode(InstalledRuntime.self, from: $0) }
        let stage = try await buildRuntime(kept?.set ?? .builtIn, progress: progress)
        try await replaceRuntime(with: stage, keepPrevious: false)
    }

    // MARK: - Component updates

    /// What the current runtime was built from. A runtime from before component updates was built
    /// from Portnaut's built-in versions.
    public func installedRuntime() -> InstalledRuntime? {
        guard paths.runtimeReady else { return nil }
        if let data = try? Data(contentsOf: paths.runtimeManifest), let installed = try? Self.json.decoder.decode(InstalledRuntime.self, from: data) { return installed }
        let date = (try? FileManager.default.attributesOfItem(atPath: paths.runtimeMarker.path)[.modificationDate] as? Date) ?? Date()
        var details = ["MoltenVK": "the template’s"]
        let plist = paths.engine(for: .d3dmetal).appendingPathComponent("lib/external/D3DMetal.framework/Versions/A/Resources/Info.plist")
        if let version = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String { details["D3DMetal"] = version }
        return InstalledRuntime(set: .builtIn, installedAt: date, details: details)
    }
    /// The runtime before the last update, if one is kept.
    public func previousRuntime() -> InstalledRuntime? {
        let folder = paths.previousRuntime
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(paths.runtimeMarker.lastPathComponent).path) else { return nil }
        return (try? Data(contentsOf: folder.appendingPathComponent(paths.runtimeManifest.lastPathComponent))).flatMap { try? Self.json.decoder.decode(InstalledRuntime.self, from: $0) }
            ?? InstalledRuntime(set: .builtIn, installedAt: .distantPast, details: [:])
    }

    public var updateChannel: UpdateChannel {
        get {
            struct Settings: Decodable { var channel: UpdateChannel }
            return (try? Data(contentsOf: paths.updateSettings)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0).channel } ?? .stable
        }
        set { try? Data("{\"channel\":\"\(newValue.rawValue)\"}\n".utf8).write(to: paths.updateSettings, options: .atomic) }
    }

    /// Installs a set of components: downloads and checks what changed, builds the new runtime beside
    /// the current one, snapshots every bottle, then swaps the runtimes, keeping the old one for rolling
    /// back. Bottles get their profile again; Wine updates each prefix itself when it next starts.
    public func installRuntime(_ set: RuntimeSet, progress: @escaping @Sendable (SetupProgress) async -> Void = { _ in }) async throws {
        guard paths.runtimeReady, let current = installedRuntime() else { throw PortnautError("Prepare Portnaut first.") }
        guard !set.changes(from: current.set).isEmpty else { return }
        let needed = set.downloadSize(from: current.set) + 3_000_000_000
        let available = (try FileManager.default.attributesOfFileSystem(forPath: paths.root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available > needed else { throw PortnautError("Free at least \(needed / 1_000_000_000 + 1) GB to update Portnaut’s components.") }
        let stage = try await buildRuntime(set, progress: progress)
        await progress(SetupProgress(0.75, "Taking snapshots of your bottles"))
        let library = try paths.loadLibrary()
        for bottle in library.bottles where paths.bottle(bottle).ready {
            try? await stop(bottle)
            try takeSnapshot(of: bottle, label: "Before updating components", automatic: true)
        }
        try await replaceRuntime(with: stage, keepPrevious: true)
        for (index, bottle) in library.bottles.enumerated() where paths.bottle(bottle).ready {
            await progress(SetupProgress(0.8 + 0.18 * Double(index) / Double(max(library.bottles.count, 1)), "Preparing \(bottle.name)"))
            try await prepareBottle(bottle)
        }
        pruneDownloads()
        await progress(SetupProgress(1, "Components updated"))
    }

    /// Swaps the current runtime with the one before the last update, after a snapshot of each bottle.
    public func rollBackRuntime(progress: @escaping @Sendable (SetupProgress) async -> Void = { _ in }) async throws {
        let fm = FileManager.default
        guard previousRuntime() != nil else { throw PortnautError("There is no earlier runtime to go back to.") }
        let library = try paths.loadLibrary()
        for bottle in library.bottles where paths.bottle(bottle).ready {
            try? await stop(bottle)
            try takeSnapshot(of: bottle, label: "Before rolling back components", automatic: true)
        }
        let swap = paths.runtime.deletingLastPathComponent().appendingPathComponent(".rollback-" + UUID().uuidString)
        try fm.moveItem(at: paths.previousRuntime, to: swap)
        try await replaceRuntime(with: swap, keepPrevious: true)
        for bottle in library.bottles where paths.bottle(bottle).ready {
            await progress(SetupProgress(0.6, "Preparing \(bottle.name)"))
            try await prepareBottle(bottle)
        }
        await progress(SetupProgress(1, "Back on the previous components"))
    }

    /// Deletes downloaded component archives neither the current nor the previous runtime was built
    /// from. Portnaut's built-in archives (highball-*.tar.*) stay, for repairs.
    func pruneDownloads() {
        // Engine profiles' archives stay too: the templates' names match the pattern below.
        let keep = Set([installedRuntime()?.set, previousRuntime()?.set].compactMap { $0 }.flatMap(\.components).map(\.fileName))
            .union(EngineProfile.allCases.flatMap(\.downloads).map(\.fileName))
        let pattern = try! NSRegularExpression(pattern: #"^(engine-wine-.+\.tar\.gz|dxmt-highball-.+\.tar\.gz|Template-[\d.]+\.tar\.xz|moltenvk-.+\.tar\.gz|MoltenVK-macos\.tar|d3dmetal-.+\.tar\.xz)$"#)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: paths.cache.path)) ?? []
        where !keep.contains(name) && pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            try? FileManager.default.removeItem(at: paths.cache.appendingPathComponent(name))
        }
    }

    /// The runtime plus every existing bottle: missing environments are created, the others get the current profile.
    public func prepare(progress: @escaping @Sendable (SetupProgress) async -> Void = { _ in }) async throws {
        let updating = !paths.runtimeReady
        try await prepareRuntime(progress: progress)
        let library = try paths.loadLibrary()
        for (index, bottle) in library.bottles.enumerated() {
            await progress(SetupProgress(0.7 + 0.25 * Double(index) / Double(max(library.bottles.count, 1)), "Preparing \(bottle.name)"))
            // A new runtime is the biggest change a bottle sees; its sessions have just been ended.
            if updating, paths.bottle(bottle).ready { try takeSnapshot(of: bottle, label: "Before updating Portnaut", automatic: true) }
            try await prepareBottle(bottle)
        }
        // Persists a migrated 0.1.x library in the bottle format.
        try paths.saveLibrary(library)
        await progress(SetupProgress(1, "Portnaut is ready"))
    }

    // MARK: - Bottles

    /// A nil Windows version takes the one from Settings; new bottles record performance as Settings says. A bottle
    /// given an engine profile is set up on it (prepareBottle builds the profile first) and keeps it.
    public func createBottle(name: String, launcher: Launcher?, renderer: Renderer, engineProfile: EngineProfile? = nil,
                             windowsVersion: WindowsVersion? = nil, easyMode: Bool = true) async throws -> Bottle {
        guard paths.runtimeReady else { throw PortnautError("Prepare Portnaut first.") }
        var library = try paths.loadLibrary()
        var bottle = Bottle(id: library.newBottleID(for: name), name: name, launcher: launcher, renderer: renderer)
        let settings = self.settings
        bottle.engineProfile = engineProfile
        bottle.windowsVersion = windowsVersion ?? settings.newBottleWindowsVersion
        bottle.options.recordPerformance = settings.recordPerformanceInNewBottles
        bottle.easyMode = easyMode
        bottle.autoBackupSaves = easyMode
        bottle.createdAt = Date()
        do { try await prepareBottle(bottle) }
        catch {
            try? FileManager.default.removeItem(at: paths.bottle(bottle).prefix)
            throw error
        }
        library.update(bottle)
        try paths.saveLibrary(library)
        return bottle
    }

    /// Creates the Windows environment if needed, then applies the bottle's profile, and its engine profile's
    /// files when it has one (built first, so a failed download leaves the bottle as it was).
    public func prepareBottle(_ bottle: Bottle) async throws {
        let bottlePaths = paths.bottle(bottle)
        let fm = FileManager.default
        if let profile = bottle.engineProfile { try await buildProfile(profile) }
        let isNew = !bottlePaths.ready
        if isNew {
            try fm.createDirectory(at: bottlePaths.prefix, withIntermediateDirectories: true)
            do {
                try await ProcessRunner.run(paths.wine(for: bottle), ["wineboot", "-u"], environment: environment(for: bottle), log: paths.setupLog, timeout: 180)
                try isolateUserFolders(bottlePaths)
            } catch {
                try? await stop(bottle)
                throw error
            }
        }
        try mapRuntimeDrive(bottlePaths, to: bottle.engineProfile.map { paths.profile($0).root } ?? paths.runtime)
        if let profile = bottle.engineProfile { try await applyEngineProfile(profile, to: bottle) } else { try await applyProfile(bottle) }
        try await ProcessRunner.run(paths.wine(for: bottle), ["cmd", "/c", "ver"], environment: environment(for: bottle), directory: bottlePaths.drive, log: paths.setupLog, timeout: 30)
        // Wine writes system.reg when its server exits. A new environment has no programs of the
        // user's running, so wait for that; an existing one may be in use and is already written.
        if isNew {
            _ = try? await ProcessRunner.run(paths.wineserver(for: bottle), ["-w"], environment: environment(for: bottle), log: paths.setupLog, timeout: 60, allowFailure: true)
        }
        try Data("portnaut-bottle-v1\n".utf8).write(to: bottlePaths.marker, options: .atomic)
    }

    /// Moves the bottle's folder to the Trash, so it can still be restored from there.
    public func removeBottle(_ bottle: Bottle) async throws {
        try? await stop(bottle)
        var library = try paths.loadLibrary()
        let prefix = paths.bottle(bottle).prefix
        if FileManager.default.fileExists(atPath: prefix.path) { try FileManager.default.trashItem(at: prefix, resultingItemURL: nil) }
        let snapshots = paths.snapshots(of: bottle)
        if FileManager.default.fileExists(atPath: snapshots.path) { try? FileManager.default.trashItem(at: snapshots, resultingItemURL: nil) }
        library.bottles.removeAll { $0.id == bottle.id }
        try paths.saveLibrary(library)
    }

    private func isolateUserFolders(_ bottlePaths: BottlePaths) throws {
        let fm = FileManager.default
        let users = bottlePaths.drive.appendingPathComponent("users")
        if let folders = try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil) {
            for user in folders {
                for name in ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos", "My Documents", "My Pictures", "My Music", "My Videos"] {
                    let folder = user.appendingPathComponent(name)
                    if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                        try fm.removeItem(at: folder)
                        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    }
                }
            }
        }
        let z = bottlePaths.prefix.appendingPathComponent("dosdevices/z:")
        if (try? z.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { try fm.removeItem(at: z) }
    }

    /// Wine reaches its bundled Gecko (HTML) and Mono (.NET) through a Windows path to its own data
    /// folder. Without Z:, that path is "\\?\unix\…", which Wine's HTML engine shortens to "unix\…" and
    /// rejects, so installers that show HTML asked to download Gecko. This drive exposes only the bottle's
    /// runtime: Portnaut's, or its engine profile's.
    func mapRuntimeDrive(_ bottlePaths: BottlePaths, to runtime: URL) throws {
        let fm = FileManager.default
        let drive = bottlePaths.prefix.appendingPathComponent("dosdevices/\(Self.runtimeDrive):")
        if (try? fm.destinationOfSymbolicLink(atPath: drive.path)) == runtime.path { return }
        try? fm.removeItem(at: drive)
        try fm.createSymbolicLink(at: drive, withDestinationURL: runtime)
    }
    static let runtimeDrive = "y"

    /// The bottle's Windows version, display resolution mode, and per-program values.
    public static func profile(for bottle: Bottle) -> String {
        let dpi = bottle.retinaMode ? "000000c0" : "00000060"
        return """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Wine]
        "Version"="\(bottle.windowsVersion.rawValue)"

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "RetinaMode"="\(bottle.retinaMode ? "y" : "n")"

        \(GraphicsProfile.displayRegistry)
        [HKEY_CURRENT_USER\\Control Panel\\Desktop]
        "LogPixels"=dword:\(dpi)

        [HKEY_CURRENT_USER\\Software\\Wine\\Fonts]
        "LogPixels"=dword:\(dpi)

        """ + controllerRegistry(bottle.controllers) + componentRegistry(bottle) + gameRegistry(bottle.games)
            + (bottle.launcher?.registry ?? "")
            // Rockstar's games open the Rockstar Games Launcher from any store (GTA V and Red Dead
            // Redemption 2 bought on Steam or Epic too), so its Social Club window needs its fix everywhere.
            + (bottle.launcher == .rockstar ? "" : Launcher.rockstar.registry)
            // Last, so the engine profile's per-program overrides replace a game's.
            + (bottle.engineProfile?.registry ?? "")
    }
    /// Wine's controller driver reads these when a session starts.
    static func controllerRegistry(_ settings: ControllerSettings) -> String {
        """
        [HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\winebus]
        "Enable SDL"=dword:\(settings.sdl ? "00000001" : "00000000")
        "Map Controllers"=dword:\(settings.xinput ? "00000001" : "00000000")


        """
    }
    /// Installed components' DLLs: Microsoft's first, then Wine's.
    static func componentRegistry(_ bottle: Bottle) -> String {
        let dlls = WindowsComponent.allCases.filter { bottle.components[$0.rawValue] != nil }.flatMap(\.dllOverrides)
        guard !dlls.isEmpty else { return "" }
        return "[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n" + dlls.map { "\"\($0)\"=\"native,builtin\"" }.joined(separator: "\n") + "\n\n"
    }
    /// Per-program settings by file name. Each game's keys are rewritten, so cleared settings go away.
    static func gameRegistry(_ games: [Game]) -> String {
        var lines: [String] = []
        for game in games {
            let key = "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\\(game.programName)"
            lines.append("[-\(key)\\DllOverrides]")
            if !game.dllOverrides.isEmpty {
                lines.append("[\(key)\\DllOverrides]")
                lines += game.dllOverrides.sorted { $0.key < $1.key }.map { "\"\($0.key)\"=\"\($0.value.rawValue)\"" }
            }
            lines += ["[\(key)]", "\"Version\"=" + (game.windowsVersion.map { "\"\($0.rawValue)\"" } ?? "-"), ""]
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public func applyProfile(_ bottle: Bottle) async throws {
        let directory = paths.bottle(bottle).drive.appendingPathComponent("Portnaut")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.profile(for: bottle).utf8).write(to: directory.appendingPathComponent("profile.reg"), options: .atomic)
        try await ProcessRunner.run(paths.wine(for: bottle), ["reg", "import", "C:\\Portnaut\\profile.reg"], environment: environment(for: bottle),
                                    directory: paths.bottle(bottle).drive, log: paths.setupLog, timeout: 30)
    }

    /// Applies an engine profile's build to the bottle: its files in system32 and the game's arguments, then the
    /// registry profile, and records the build's marker in the prefix once both are done. The profile is built.
    func applyEngineProfile(_ profile: EngineProfile, to bottle: Bottle) async throws {
        let bottlePaths = paths.bottle(bottle)
        try applyFiles(of: profile, to: bottlePaths)
        try await applyProfile(bottle)
        try Data(profile.marker.utf8).write(to: appliedMarkerFile(in: bottlePaths), options: .atomic)
    }
    /// The marker of the engine profile build last applied to the prefix (applyEngineProfile).
    func appliedMarkerFile(in bottlePaths: BottlePaths) -> URL { bottlePaths.drive.appendingPathComponent("Portnaut/engine-profile") }

    /// An engine profile's graphics libraries in system32 and the game's arguments in its commandline.txt.
    func applyFiles(of profile: EngineProfile, to bottlePaths: BottlePaths) throws {
        let fm = FileManager.default
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        for copy in profile.systemCopies(layout: paths.profile(profile)) {
            let target = system32.appendingPathComponent(copy.name)
            if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil || fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: copy.from, to: target)
        }
        try writeGameArguments(to: bottlePaths)
    }
    /// Adds the profile's game arguments to commandline.txt in each folder of the bottle the game is installed in:
    /// the default one, the one the launcher recorded in system.reg, and `folders` (where a session's watch saw
    /// the game appear). Runs before and after every program Portnaut starts in a profile bottle, and while it
    /// runs whenever the game's files change (GameArgumentsWatch), so the first Play in the launcher session that
    /// installs the game has them too.
    func writeGameArguments(to bottlePaths: BottlePaths, also folders: [URL] = []) throws {
        // A session's watch writes from its own queue: one pass at a time, so none publishes a merge of a file
        // another pass has already replaced.
        gameArgumentsLock.lock()
        defer { gameArgumentsLock.unlock() }
        var candidates = [bottlePaths.drive.appendingPathComponent(EngineProfile.gameFolder)] + folders
        let registry = bottlePaths.prefix.appendingPathComponent("system.reg")
        if let text = try? String(contentsOf: registry, encoding: .utf8),
           let recorded = EngineProfile.recordedGameFolder(systemRegistry: text),
           let folder = Self.macFolder(forWindowsPath: recorded, in: bottlePaths) {
            candidates.append(folder)
        }
        var seen = Set<String>()
        for folder in candidates {
            let resolved = folder.resolvingSymlinksInPath()
            guard seen.insert(resolved.path.lowercased()).inserted else { continue }
            try writeGameArguments(inFolder: resolved, of: bottlePaths)
        }
    }
    private let gameArgumentsLock = NSLock()
    /// A Windows path's folder through the prefix's drive links, or nil for a path that is not a plain absolute one.
    static func macFolder(forWindowsPath path: String, in bottlePaths: BottlePaths) -> URL? {
        let parts = path.split(separator: "\\", omittingEmptySubsequences: true)
        guard let drive = parts.first, drive.count == 2, drive.last == ":", drive.first?.isLetter == true,
              !parts.dropFirst().contains(where: { $0 == "." || $0 == ".." || $0.contains("/") }) else { return nil }
        return parts.dropFirst().reduce(bottlePaths.prefix.appendingPathComponent("dosdevices/\(drive.lowercased())")) {
            $0.appendingPathComponent(String($1))
        }
    }
    /// Merges the arguments into commandline.txt in a folder that holds the game's executable and lies inside the
    /// bottle's prefix: what the registry or a watched event names is the bottle's own programs' word, so Portnaut
    /// writes nowhere else on the Mac. A commandline.txt that is a link, or not UTF-8, is left as it is rather than
    /// lose the user's arguments.
    func writeGameArguments(inFolder game: URL, of bottlePaths: BottlePaths) throws {
        let fm = FileManager.default
        guard PortnautPaths.isContained(game, by: bottlePaths.prefix),
              fm.fileExists(atPath: game.appendingPathComponent(EngineProfile.gameExecutable).path) else { return }
        let file = game.appendingPathComponent("commandline.txt")
        if (try? fm.destinationOfSymbolicLink(atPath: file.path)) != nil { return }
        let exists = fm.fileExists(atPath: file.path)
        let data: Data? = exists ? try? Data(contentsOf: file) : nil
        // A file that exists but cannot be read is left alone too.
        if exists && data == nil { return }
        // UTF-16 without a byte-order mark, ASCII only, is valid UTF-8 too; its NUL bytes give it away.
        if let data, data.contains(0) { return }
        let current = data.map { String(decoding: $0, as: UTF8.self) }
        if let data, current.map({ Data($0.utf8) }) != data { return }
        let merged = EngineProfile.commandLine(merging: current)
        if merged != current { try Data(merged.utf8).write(to: file, options: .atomic) }
    }

    /// Saves changed settings and applies the registry part, which takes effect for the next programs started.
    public func update(_ bottle: Bottle) async throws {
        try save(bottle)
        if paths.bottle(bottle).ready { try await applyProfile(bottle) }
    }

    // MARK: - Launchers and games

    public func fetchInstaller(for bottle: Bottle, progress: @escaping @Sendable (SetupProgress) async -> Void = { _ in }) async throws -> URL {
        guard let launcher = bottle.launcher else { throw PortnautError("\(bottle.name) has no launcher to install.") }
        guard paths.bottle(bottle).ready else { throw PortnautError("Prepare Portnaut first.") }
        await progress(SetupProgress(0.10, "Downloading \(launcher.title)"))
        let target = paths.bottle(bottle).drive.appendingPathComponent("Portnaut/\(launcher.installerName)")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await download(launcher.installer, to: target)
        let file = try FileHandle(forReadingFrom: target)
        defer { try? file.close() }
        // A Windows program starts with "MZ"; a Windows Installer package is a compound file.
        let header = launcher.installerIsPackage ? Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) : Data([0x4d, 0x5a])
        guard try file.read(upToCount: header.count) == header else {
            try? FileManager.default.removeItem(at: target)
            throw PortnautError("\(launcher.title) returned an unexpected installer. Retry the download.")
        }
        await progress(SetupProgress(1, "Complete the \(launcher.title) installer in its window"))
        return target
    }

    /// Runs the downloaded launcher installer and waits for it. Installers report success in their
    /// own ways (the EA app's exits with 768), so the check is whether the launcher is there afterwards.
    public func launchInstaller(_ bottle: Bottle) async throws {
        guard let launcher = bottle.launcher else { throw PortnautError("\(bottle.name) has no launcher to install.") }
        let drive = paths.bottle(bottle).drive
        let installer = drive.appendingPathComponent("Portnaut/\(launcher.installerName)")
        // Galaxy's installer starts Galaxy when it finishes.
        try prepare(launcher, in: bottle)
        let status = launcher.installerIsPackage
            ? try await run(drive.appendingPathComponent("windows/system32/msiexec.exe"), in: bottle,
                            arguments: ["/i", try paths.bottle(bottle).windowsPath(installer)] + launcher.installerArguments)
            : try await run(installer, in: bottle, arguments: launcher.installerArguments)
        guard launcherInstalled(bottle) else {
            throw PortnautError("\(launcher.title) was not installed (its installer exited with code \(status)). Open Diagnostics to inspect session.log, then retry.")
        }
        // Galaxy's installer starts Galaxy, but under Wine its web installer passes no campaign data
        // and that first start stops on the missing "campaignParamsForLogIn" setting. The next start
        // works (tested), so Portnaut makes it.
        if launcher == .gog { try await launchLauncher(bottle) }
    }

    public func launcherInstalled(_ bottle: Bottle) -> Bool {
        guard let launcher = bottle.launcher else { return false }
        return paths.bottle(bottle).url(for: launcher.executable) != nil
    }

    /// Returns only after this bottle's Windows session ends, including child processes.
    public func launch(_ executable: URL, in bottle: Bottle, arguments: [String] = [], game: Game? = nil, waitForSession: Bool = true) async throws {
        let status = try await run(executable, in: bottle, arguments: arguments, game: game, waitForSession: waitForSession)
        guard status == 0 else { throw PortnautError("The Windows program exited with code \(status). Open Diagnostics to inspect session.log.") }
    }
    /// Checked before Portnaut starts a program in a bottle: the runtime and the bottle are prepared, and a profile
    /// bottle is on its profile's current build, with its game's arguments. A build the bottle does not have yet (a
    /// new Portnaut changed the profile's marker) is built and applied here, when none of the bottle's Wine runs;
    /// a session still running on the older build has to end first.
    func requireEngine(of bottle: Bottle) async throws {
        guard paths.runtimeReady, paths.bottle(bottle).ready else { throw PortnautError("Prepare Portnaut first.") }
        guard let profile = bottle.engineProfile else { return }
        let bottlePaths = paths.bottle(bottle)
        let applied = try? String(contentsOf: appliedMarkerFile(in: bottlePaths), encoding: .utf8)
        if !paths.profileReady(profile) || applied != profile.marker {
            if try await serverRunning(for: bottle) {
                throw PortnautError("\(bottle.name) is running on an older build of \(profile.title). Stop its session, then start the program again.")
            }
            try await buildProfile(profile)
            try await applyEngineProfile(profile, to: bottle)
        }
        try writeGameArguments(to: bottlePaths)
    }

    /// Builds the profile unless it is current. Its folder is shared by every bottle on it, so it is not replaced
    /// while any of them runs.
    func buildProfile(_ profile: EngineProfile) async throws {
        guard !paths.profileReady(profile) else { return }
        for other in try paths.loadLibrary().bottles where other.engineProfile == profile {
            if try await serverRunning(for: other) {
                throw PortnautError("\(other.name) is running on an older build of \(profile.title). Stop its session, then try again.")
            }
        }
        try await prepareProfile(profile)
    }

    /// Whether a Wine server runs for the bottle's prefix. `wineserver -k0` sends signal 0 to the server holding
    /// the prefix's lock and exits 0 when one does, 1 when none does (Wine 11.13 server/main.c and request.c,
    /// kill_lock_owner). Without the engine's wineserver, no Wine of the bottle can run from it.
    func serverRunning(for bottle: Bottle) async throws -> Bool {
        let wineserver = paths.wineserver(for: bottle)
        guard FileManager.default.isExecutableFile(atPath: wineserver.path) else { return false }
        let status = try await ProcessRunner.run(wineserver, ["-k0"], environment: environment(for: bottle), log: paths.setupLog, timeout: nil, allowFailure: true)
        guard status == 0 || status == 1 else { throw PortnautError("Portnaut could not check whether \(bottle.name) is in use (wineserver exited with \(status)).") }
        return status == 0
    }

    /// Runs a program of the bottle's drive and returns its exit code, by default after the whole session ends.
    @discardableResult
    func run(_ executable: URL, in bottle: Bottle, arguments: [String] = [], game: Game? = nil, waitForSession: Bool = true) async throws -> Int32 {
        try await runWine(in: bottle, game: game, directory: executable.deletingLastPathComponent(), waitForSession: waitForSession) {
            let winPath = try self.paths.bottle(bottle).windowsPath(executable)
            guard FileManager.default.fileExists(atPath: executable.path) else { throw PortnautError("The Windows program could not be found. Use Locate game or reinstall it.") }
            return [winPath] + arguments
        }
    }
    /// Starts the bottle's Wine with `arguments` (a program and its arguments, or one of Wine's own commands) as
    /// every start Portnaut makes does: after requireEngine, and in a profile bottle with the game's arguments
    /// kept in place while it runs (GameArgumentsWatch). `arguments` is called once the engine is checked. Returns
    /// Wine's exit code, by default after the whole session ends: a launcher can exit while its child still runs.
    /// Without that wait the watch ends when Wine's first process exits; the callers that skip it start an installed
    /// game (launchGame) or a tool, not the launcher session that installs the game.
    @discardableResult
    public func runWine(in bottle: Bottle, game: Game? = nil, directory: URL? = nil, waitForSession: Bool = true,
                        _ arguments: () throws -> [String]) async throws -> Int32 {
        let bottlePaths = paths.bottle(bottle)
        try await requireEngine(of: bottle)
        let watch = bottle.engineProfile == nil ? nil : try GameArgumentsWatch(prefix: bottlePaths.prefix) { [self] folders in
            // Best effort while the session runs; the write after it reports what still fails.
            try? writeGameArguments(to: bottlePaths, also: folders)
            gameArgumentsPass?(folders)
        }
        defer { watch?.stop() }
        // Again now that the watch runs: a session already running could have installed the game since
        // requireEngine wrote.
        if watch != nil { try writeGameArguments(to: bottlePaths) }
        let status = try await ProcessRunner.run(paths.wine(for: bottle), try arguments(), environment: environment(for: bottle, game: game),
                                                 directory: directory ?? bottlePaths.drive, log: paths.sessionLog, timeout: nil, allowFailure: true)
        if waitForSession { try await waitForSessionEnd(bottle) }
        if let watch {
            watch.stop()
            try writeGameArguments(to: bottlePaths, also: watch.folders)
        }
        return status
    }
    /// Called after each pass of a session's GameArgumentsWatch, with the folders it has seen the game in (tests).
    var gameArgumentsPass: (@Sendable ([URL]) -> Void)?
    public func launchLauncher(_ bottle: Bottle) async throws {
        guard let launcher = bottle.launcher, let executable = paths.bottle(bottle).url(for: launcher.executable) else {
            throw PortnautError("\(bottle.launcher?.title ?? "The launcher") is not installed in \(bottle.name).")
        }
        // Launchers restart themselves after updating (Steam's first process exits with 42), so
        // their exit code says nothing about the session.
        try prepare(launcher, in: bottle)
        try await run(executable, in: bottle, arguments: launcher.arguments)
    }
    /// What the compatibility database knows about a game: a Steam game by its app id, others by name.
    public func compatibilityReport(for game: Game, in bottle: Bottle, database: CompatibilityDatabase?) -> CompatibilityReport? {
        // Games Portnaut itself has tested come first.
        if let known = KnownGame.all.first(where: { $0.id == game.id || $0.executable.caseInsensitiveCompare(game.programName) == .orderedSame }) {
            return CompatibilityReport(id: known.id, title: known.title, status: .tested, renderer: known.recommendation.renderer, notes: known.recommendation.reason)
        }
        guard let database else { return nil }
        return database.report(steamAppID: bottle.launcher == .steam ? game.steamAppID : nil, title: game.name)
    }

    /// The renderer an easy-mode bottle switches to for a game: the one measured fastest on this Mac,
    /// else the one it was tested or reported on with a Mac, else the one its files suggest; always
    /// one the bottle's launcher starts on.
    public func easyModeChoice(for game: Game, in bottle: Bottle, report: CompatibilityReport?) -> Recommendation? {
        if let best = game.bestSetup, bottle.launcher?.unsupportedRenderers.contains(best.renderer) != true {
            return Recommendation(renderer: best.renderer, reason: "Measured fastest on this Mac on \(best.measuredAt.formatted(date: .abbreviated, time: .omitted)). \(best.reason)")
        }
        if let report, let tested = report.renderer, report.status >= .reported, bottle.launcher?.unsupportedRenderers.contains(tested) != true {
            return Recommendation(renderer: tested, reason: "\(report.status == .tested ? "Tested" : "Reported working") on \(tested.title) on Apple silicon, in Highball’s compatibility database.")
        }
        return analyze(game, in: bottle)?.recommendation
    }

    /// Fixes kept in a launcher's own files, applied while the launcher is not running.
    func prepare(_ launcher: Launcher, in bottle: Bottle) throws {
        guard launcher == .gog else { return }
        let drive = paths.bottle(bottle).drive
        let settings = drive.appendingPathComponent(Launcher.galaxySettings)
        if let merged = Launcher.galaxySettings(merging: try? Data(contentsOf: settings)) {
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try merged.write(to: settings, options: .atomic)
        }
        // A stopped session leaves Galaxy's lock file behind. Galaxy asks its service to remove stale
        // ones but checks before it has, takes itself for a second copy and quits (tested).
        let locks = drive.appendingPathComponent(Launcher.galaxyLockFiles)
        for file in (try? FileManager.default.contentsOfDirectory(at: locks, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "lock" {
            try? FileManager.default.removeItem(at: file)
        }
    }
    /// The program and arguments that start a game: its launcher for a game the launcher must start,
    /// otherwise the game's own executable.
    public func launchCommand(for game: Game, in bottle: Bottle) throws -> (executable: URL, arguments: [String]) {
        let bottlePaths = paths.bottle(bottle)
        if let viaLauncher = game.launcherArguments {
            guard let launcher = bottle.launcher, let executable = bottlePaths.url(for: launcher.executable) else {
                throw PortnautError("\(game.name) starts through \(bottle.launcher?.title ?? "its launcher"), which is not installed in \(bottle.name).")
            }
            return (executable, launcher.arguments + viaLauncher + game.arguments)
        }
        guard let executable = bottlePaths.url(for: game.executable) else { throw PortnautError("\(game.name) is no longer at its saved location. Use Locate game.") }
        return (executable, game.arguments)
    }
    /// `waitForSession` false hands a launcher-started game to the launcher already running, and returns.
    /// Otherwise an easy-mode bottle first switches to the game's renderer, and the saves are backed
    /// up when the bottle asks for it.
    public func launchGame(_ game: Game, in bottle: Bottle, waitForSession: Bool = true, compatibility: CompatibilityDatabase? = nil) async throws {
        var bottle = bottle
        var game = game
        if waitForSession {
            bottle = try self.bottle(bottle.id)
            game = bottle.games.first { $0.id == game.id } ?? game
            // A profile bottle has no renderers to compare, so no best-setup round either.
            if bottle.engineProfile != nil { game.setupTrial = nil }
            // A best-setup round plays on its renderer, recorded; otherwise easy mode chooses.
            let target: Renderer?
            if bottle.engineProfile != nil {
                // The profile's engine replaces the renderer, so there is none to choose.
                target = nil
            } else if let round = game.setupTrial?.next {
                target = round
            } else if bottle.easyMode {
                target = easyModeChoice(for: game, in: bottle, report: compatibilityReport(for: game, in: bottle, database: compatibility ?? compatibilityDatabase()))?.renderer
            } else {
                target = nil
            }
            if let target { bottle.renderer = target }
            if bottle != (try self.bottle(bottle.id)) { try await update(bottle) }
            // A round is recorded even when the bottle's recording is off, without changing that setting.
            if game.setupTrial?.next != nil { bottle.options.recordPerformance = true }
            // A bottle without save folders yet has nothing to back up.
            if bottle.autoBackupSaves { _ = try? await backUpSaves(of: bottle, automatic: true) }
        }
        let command = try launchCommand(for: game, in: bottle)
        var updated = try self.bottle(bottle.id)
        if let index = updated.games.firstIndex(where: { $0.id == game.id }) { updated.games[index].lastPlayedAt = Date() }
        try save(updated)
        // Where this session's lines start in session.log; a game handed to a running launcher has no end Portnaut sees.
        let start = waitForSession && bottle.options.recordPerformance ? logSize() : nil
        do {
            if game.launcherArguments != nil {
                try await run(command.executable, in: bottle, arguments: command.arguments, waitForSession: waitForSession)
            } else {
                try await launch(command.executable, in: bottle, arguments: command.arguments, game: game, waitForSession: waitForSession)
            }
        } catch {
            if let start { recordSetupRound(recordPerformance(of: game, in: bottle, since: start), of: game, in: bottle) }
            throw error
        }
        if let start { recordSetupRound(recordPerformance(of: game, in: bottle, since: start), of: game, in: bottle) }
    }

    func logSize() -> UInt64 { ((try? FileManager.default.attributesOfItem(atPath: paths.sessionLog.path))?[.size] as? NSNumber)?.uint64Value ?? 0 }

    /// Adds the session's summary to the game's records (the latest 20 are kept). Another bottle's
    /// game running at the same time would mix its lines in; Portnaut runs one session per bottle.
    @discardableResult
    func recordPerformance(of game: Game, in bottle: Bottle, since offset: UInt64) -> PerformanceRun? {
        guard let handle = try? FileHandle(forReadingFrom: paths.sessionLog) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(),
              let run = PerformanceLog.run(from: String(decoding: data, as: UTF8.self), bottle: bottle),
              var updated = try? self.bottle(bottle.id), let index = updated.games.firstIndex(where: { $0.id == game.id }) else { return nil }
        updated.games[index].performance = Array((updated.games[index].performance + [run]).suffix(20))
        try? save(updated)
        return run
    }
    public func waitForSessionEnd(_ bottle: Bottle) async throws {
        guard paths.runtimeReady else { return }
        try await ProcessRunner.run(paths.wineserver(for: bottle), ["-w"], environment: environment(for: bottle), log: paths.sessionLog, timeout: nil)
    }
    public func stop(_ bottle: Bottle) async throws {
        guard paths.runtimeReady else { return }
        try await ProcessRunner.run(paths.wineserver(for: bottle), ["-k"], environment: environment(for: bottle), log: paths.sessionLog, timeout: 15)
    }

    /// Adds a program inside the bottle as a game, named after a known title or its file.
    @discardableResult
    public func addGame(_ executable: URL, to bottle: Bottle) throws -> Game {
        let relative = try paths.bottle(bottle).relativePath(executable)
        let name = KnownGame.matching(executable)?.title ?? executable.deletingPathExtension().lastPathComponent
        return try addPrograms([DetectedProgram(name: name, executable: relative, source: .shortcut)], to: bottle)[0]
    }
    /// Adds found programs as games; one already in the library is returned as it is.
    @discardableResult
    public func addPrograms(_ programs: [DetectedProgram], to bottle: Bottle) throws -> [Game] {
        var updated = try self.bottle(bottle.id)
        var games: [Game] = []
        for program in programs {
            guard let executable = paths.bottle(bottle).url(for: program.executable), (try? PEImage.wineArchitecture(of: executable)) != nil else {
                throw PortnautError("\(program.name) is not a Windows program Portnaut can run.")
            }
            if let existing = updated.games.first(where: { Self.same($0, program) }) { games.append(existing); continue }
            let stem = KnownGame.matching(executable)?.id ?? Library.slug(program.name, fallback: "game")
            var id = stem, suffix = 2
            while updated.games.contains(where: { $0.id == id }) { id = "\(stem)-\(suffix)"; suffix += 1 }
            var game = Game(id: id, name: program.name, executable: program.executable)
            game.arguments = program.arguments
            game.launcherArguments = program.launcherArguments
            if game.arguments.isEmpty, let launch = program.launcherArguments, launch.first == "-applaunch", launch.count > 1,
               let options = KnownGame.steamLaunchOptions[launch[1]] {
                game.arguments = options
            }
            game.addedAt = Date()
            updated.games.append(game)
            games.append(game)
        }
        try save(updated)
        return games
    }
    static func same(_ game: Game, _ program: DetectedProgram) -> Bool {
        if let viaLauncher = program.launcherArguments { return game.launcherArguments == viaLauncher }
        return game.launcherArguments == nil && game.executable.caseInsensitiveCompare(program.executable) == .orderedSame
    }
    /// Saves a game's settings; its per-program registry part applies to the next start.
    public func updateGame(_ game: Game, in bottle: Bottle) async throws {
        var updated = try self.bottle(bottle.id)
        guard let index = updated.games.firstIndex(where: { $0.id == game.id }) else { throw PortnautError("\(game.name) is no longer in \(bottle.name).") }
        updated.games[index] = game
        try await update(updated)
    }

    /// Wine's Game Controllers panel, which lists and tests controllers as Windows programs see them.
    public func openControllerPanel(_ bottle: Bottle, waitForSession: Bool = true) async throws {
        try await runWine(in: bottle, waitForSession: waitForSession) { ["control", "joy.cpl"] }
    }

    /// Downloads and installs a Windows component, then has Wine prefer its DLLs. With
    /// `waitForSession` false, as when the bottle's launcher is open, Portnaut waits for the installers only.
    public func installComponent(_ component: WindowsComponent, in bottle: Bottle, waitForSession: Bool = true,
                                 progress: @escaping @Sendable (SetupProgress) async -> Void = { _ in }) async throws {
        guard paths.runtimeReady, paths.bottle(bottle).ready else { throw PortnautError("Prepare Portnaut first.") }
        let fm = FileManager.default
        let cache = paths.cache.appendingPathComponent("Components")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        var files: [(ComponentDownload, URL)] = []
        for (index, item) in component.downloads.enumerated() {
            await progress(SetupProgress(0.1 + 0.4 * Double(index) / Double(component.downloads.count), "Downloading \(component.title) · \(component.downloadSize)"))
            let file = cache.appendingPathComponent(item.fileName)
            if let sha256 = item.sha256 {
                if (try? FileIntegrity.verify(file, expected: sha256)) == nil {
                    try await download(item.url, to: file)
                    do { try FileIntegrity.verify(file, expected: sha256) } catch { try? fm.removeItem(at: file); throw error }
                }
            } else {
                // A "latest" link: fetch the current release every time.
                try await download(item.url, to: file)
            }
            guard (try? PEImage.wineArchitecture(of: file)) != nil else {
                try? fm.removeItem(at: file)
                throw PortnautError("Microsoft returned an unexpected file for \(component.title). Retry the download.")
            }
            files.append((item, file))
        }
        await progress(SetupProgress(0.6, "Installing \(component.title)"))
        try takeSnapshot(of: bottle, label: "Before installing \(component.title)", automatic: true)
        if component == .d3dx {
            try await installD3DX(from: files[0].1, into: paths.bottle(bottle))
        } else {
            let folder = paths.bottle(bottle).drive.appendingPathComponent("Portnaut/Components")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }
            for (item, file) in files {
                let copy = folder.appendingPathComponent(item.fileName)
                try? fm.removeItem(at: copy)
                try fm.copyItem(at: file, to: copy)
                let status = try await run(copy, in: bottle, arguments: item.arguments, waitForSession: false)
                guard WindowsComponent.acceptedExitCodes.contains(status) else {
                    throw PortnautError("\(item.fileName) exited with code \(status). Open Diagnostics to inspect session.log, then retry.")
                }
            }
        }
        if waitForSession { try await waitForSessionEnd(bottle) }
        // "Latest" installers are fetched again next time; keep only the pinned ones.
        for (item, file) in files where item.sha256 == nil { try? fm.removeItem(at: file) }
        var updated = try self.bottle(bottle.id)
        updated.components[component.rawValue] = Date()
        try await update(updated)
        await progress(SetupProgress(1, "\(component.title) is installed in \(bottle.name)"))
    }

    /// Copies D3DX and D3DCompiler out of the DirectX package with the Mac's tar, which reads
    /// Microsoft's cabinets: x64 ones into system32, x86 ones into syswow64.
    func installD3DX(from package: URL, into bottlePaths: BottlePaths) async throws {
        let fm = FileManager.default
        let stage = paths.cache.appendingPathComponent("Components/.d3dx-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        try await ProcessRunner.run(tar, ["-xf", package.path, "-C", stage.path], log: paths.setupLog, timeout: 300)
        let packages = try fm.contentsOfDirectory(atPath: stage.path).filter(WindowsComponent.isD3DXPackage)
        guard !packages.isEmpty else { throw PortnautError("The DirectX package held no D3DX libraries.") }
        for name in packages {
            let cab = stage.appendingPathComponent(name)
            let target = bottlePaths.drive.appendingPathComponent(name.lowercased().hasSuffix("_x64.cab") ? "windows/system32" : "windows/syswow64")
            // Only the libraries, by name: tar treats a pattern that matches nothing as an error.
            let listing = stage.appendingPathComponent(name + ".txt")
            try await ProcessRunner.run(tar, ["-tf", cab.path], log: listing, timeout: 60)
            let dlls = (try String(contentsOf: listing, encoding: .utf8)).split(whereSeparator: \.isNewline).map(String.init)
                .filter { $0.lowercased().hasSuffix(".dll") && !$0.contains("/") && !$0.contains("..") }
            guard !dlls.isEmpty else { continue }
            try await ProcessRunner.run(tar, ["-xf", cab.path, "-C", target.path] + dlls, log: paths.setupLog, timeout: 60)
        }
    }

    public func removeGame(_ game: Game, from bottle: Bottle) throws {
        var updated = try self.bottle(bottle.id)
        updated.games.removeAll { $0.id == game.id }
        try save(updated)
    }

    /// Programs installed in the bottle that are not in the library yet.
    public func detectPrograms(in bottle: Bottle, reliableOnly: Bool = false) -> [DetectedProgram] {
        let steamApps = Set(bottle.games.compactMap { $0.launcherArguments?.last })
        return ProgramScanner.scan(drive: paths.bottle(bottle).drive, reliableOnly: reliableOnly, steamAppsInLibrary: steamApps)
            .filter { program in !bottle.games.contains { Self.same($0, program) } }
    }
    /// Adds what launchers record and known games, as soon as they are installed. Cheap enough to
    /// repeat: shortcuts and guesses are left for Find Programs.
    @discardableResult
    public func addInstalledGames(in bottle: Bottle) throws -> [Game] {
        let found = detectPrograms(in: bottle, reliableOnly: true).filter(\.reliable)
        return found.isEmpty ? [] : try addPrograms(found, to: bottle)
    }

    /// Runs a Windows installer (.exe or .msi) from the Mac. Its folder is drive H: until it finishes,
    /// so installers that read files beside them work without copying anything. Returns the programs
    /// it added. With `waitForSession` false, as when the bottle's launcher is open, Portnaut waits
    /// only for the installer's own process.
    public func runInstaller(_ file: URL, in bottle: Bottle, arguments: [String] = [], waitForSession: Bool = true) async throws -> [DetectedProgram] {
        try await requireEngine(of: bottle)
        let kind = file.pathExtension.lowercased()
        guard kind == "msi" || (kind == "exe" && (try? PEImage.wineArchitecture(of: file)) != nil) else {
            throw PortnautError("\(file.lastPathComponent) is not a Windows installer. Choose an .exe or .msi file.")
        }
        let before = Set(detectPrograms(in: bottle).map(\.id))
        try takeSnapshot(of: bottle, label: "Before installing \(file.lastPathComponent)", automatic: true)
        let fm = FileManager.default
        let drive = paths.bottle(bottle).prefix.appendingPathComponent("dosdevices/\(Self.installerDrive):")
        try? fm.removeItem(at: drive)
        try fm.createSymbolicLink(at: drive, withDestinationURL: file.deletingLastPathComponent())
        defer { try? fm.removeItem(at: drive) }
        let windowsFile = "\(Self.installerDrive.uppercased()):\\\(file.lastPathComponent)"
        let status = try await runWine(in: bottle, directory: file.deletingLastPathComponent(), waitForSession: waitForSession) {
            (kind == "msi" ? ["msiexec", "/i", windowsFile] : [windowsFile]) + arguments
        }
        // Installing a launcher into a bottle without one makes it that launcher's bottle.
        var current = try self.bottle(bottle.id)
        if current.launcher == nil, let launcher = Launcher.allCases.first(where: { paths.bottle(current).url(for: $0.executable) != nil }) {
            current.launcher = launcher
            try await update(current)
        }
        let added = detectPrograms(in: current).filter { !before.contains($0.id) }
        if added.isEmpty, status != 0, current.launcher == bottle.launcher {
            throw PortnautError("The installer exited with code \(status) and added no programs. Open Diagnostics to inspect session.log.")
        }
        return added
    }
    /// The drive letter an installer's folder gets while it runs.
    static let installerDrive = "h"

    /// Copies an existing Assassin's Creed III installation into a bottle as APFS clones.
    public func importGame(from source: URL, into bottle: Bottle) async throws -> Game {
        guard paths.bottle(bottle).ready else { throw PortnautError("Prepare Portnaut before importing game files.") }
        try GameImport.validate(source)
        let destination = paths.bottle(bottle).drive.appendingPathComponent("Games/Assassin's Creed III Remastered")
        if !FileManager.default.fileExists(atPath: destination.path) {
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".import-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            try await Task.detached { try GameImport.cloneTree(from: source, to: staging) }.value
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        try GameImport.validate(destination)
        return try addGame(destination.appendingPathComponent(KnownGame.ac3.executable), to: bottle)
    }

    /// The game's analysis, with a recommendation its bottle's launcher can start on.
    public func analyze(_ game: Game, in bottle: Bottle) -> GraphicsAnalysis? {
        guard var analysis = paths.bottle(bottle).url(for: game.executable).map(GraphicsAdvisor.analyze) else { return nil }
        if let launcher = bottle.launcher { analysis.recommendation = launcher.adjusted(analysis.recommendation) }
        return analysis
    }
    public func recommendation(for bottle: Bottle) -> Recommendation {
        GraphicsAdvisor.recommendation(for: bottle, analyses: bottle.games.compactMap { analyze($0, in: bottle) })
    }
}
