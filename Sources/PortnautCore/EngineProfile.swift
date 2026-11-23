import Foundation

/// A file an engine profile is built from, pinned by its SHA-256.
public struct ProfileDownload: Sendable, Equatable {
    public var url: URL
    public var fileName: String
    public var sha256: String
    public var size: Int64?
}

/// A whole Wine engine for one game, used by a bottle in place of Portnaut's runtime and renderer. A bottle
/// gets its profile when it is created and keeps it: there is no switching a bottle onto or off a profile.
/// Nothing of the profile ships with Portnaut: its parts are downloaded from their publishers and checked
/// against the hashes below.
///
/// gta5Enhanced is the GTA V Enhanced environment of MacGames 0.1.6 (https://github.com/tarikbc/macgames) on
/// WineHQ's Wine 11.13 with seven of MacGames' patches (the Rockstar Games Launcher's Direct3D feature level,
/// Social Club's browser, the Mac driver's D3DMetal surface and others; not its GTA D3D12Core loading patch),
/// built by the build-gta5-wine workflow on rofrol/Portnaut's gta5-wine-engine branch (engines/gta5-wine) and
/// published there with its source and patches. The same release carries WineD3D builds of d3d11, dxgi and
/// d3d10core for the Rockstar Games Launcher and Social Club, which do not start on D3DMetal; the game runs on
/// Apple's D3DMetal 4.0b3, from Sikarugir's template 1.0.27 (MacGames uses 4.0b2; 4.0b3 played in the same
/// layout). The layout mirrors MacGames' GameEnvironment.gta5, PrefixSetup.graphicsCopies and
/// GameRecipes.registry("gta5-enhanced").
public enum EngineProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case gta5Enhanced = "gta5-enhanced"
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gta5Enhanced: "GTA V Enhanced (Wine 11.13 with MacGames’ patches)"
        }
    }

    /// Short enough for a bottle's row in the sidebar, where a renderer's title goes otherwise.
    public var shortTitle: String {
        switch self {
        case .gta5Enhanced: "GTA V Enhanced engine"
        }
    }

    /// The kind of bottle the profile makes, beside the launcher's own in the New Bottle sheet.
    public var bottleKind: String {
        switch self {
        case .gta5Enhanced: "Rockstar Games (GTA V Enhanced)"
        }
    }

    /// The launcher a bottle of this profile is made for.
    public var launcher: Launcher {
        switch self {
        case .gta5Enhanced: .rockstar
        }
    }

    public var detail: String {
        switch self {
        case .gta5Enhanced: "Wine 11.13 with MacGames’ GTA V patches and Apple’s D3DMetal 4.0b3 for the game; the Rockstar Games Launcher and Social Club draw with Wine’s own Direct3D. Replaces the bottle’s renderer, for good: to leave it, back up the saves, create another bottle and restore them there."
        }
    }

    /// Why a bottle of the profile's launcher may want it, shown where the bottle is created.
    public var recommendationReason: String {
        switch self {
        case .gta5Enhanced: "The Rockstar Games Launcher signs in and GTA V Enhanced plays on it, with voices (tested on an M1 Pro). On Portnaut’s Wine the launcher does not start on D3DMetal, and GTA V Enhanced needs DirectX 12."
        }
    }

    /// Shown wherever the profile can be chosen: the parts' own licences apply.
    public var licenseNote: String {
        switch self {
        case .gta5Enhanced: "Downloaded from rofrol/Portnaut’s releases on GitHub (Wine, LGPL, with its source and patches) and Sikarugir’s templates. D3DMetal is Apple’s, from the Game Porting Toolkit; its licence covers non-commercial use for developing, testing and evaluating games on Apple hardware."
        }
    }

    static let templateApp = "Template-1.0.15.app/Contents/Frameworks"
    /// D3DMetal 4.0b3 as Sikarugir's template 1.0.27 ships it (its renderer/d3dmetal), unpacked under packs/.
    static let d3dmetalPack = "sikarugir-d3dmetal-4.0b3"
    static let d3dmetalMember = "Template-1.0.27.app/Contents/SharedSupport/renderer/d3dmetal"

    /// The engine release (engine/ and launcher-wined3d/), Sikarugir's template 1.0.15 (the engine's
    /// libraries and atidxx64) and Sikarugir's template 1.0.27 (D3DMetal 4.0b3).
    public var downloads: [ProfileDownload] {
        switch self {
        case .gta5Enhanced:
            return [
                ProfileDownload(url: URL(string: "https://github.com/rofrol/Portnaut/releases/download/\(Self.engineRelease)/\(Self.engineRelease).tar.xz")!,
                                fileName: "\(Self.engineRelease).tar.xz", sha256: Self.engineSHA256),
                ProfileDownload(url: URL(string: "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.15.tar.xz")!, fileName: "Template-1.0.15.tar.xz",
                                sha256: "34273bcce885ce5a7fd6937af9ea344bb9961de7d55d6193f7413142e835c8c3"),
                ProfileDownload(url: URL(string: "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.27.tar.xz")!, fileName: "Template-1.0.27.tar.xz",
                                sha256: "dd0778f7b553d63df9b0f4e2cda3f3c6c005aabb75588c84d604afe80cdedbb9", size: 96_161_660),
            ]
        }
    }

    var engineArchive: String { downloads[0].fileName }
    var templateArchive: String { downloads[1].fileName }
    var d3dmetalArchive: String { downloads[2].fileName }

    /// The engine release built by the build-gta5-wine workflow, and its archive's SHA-256.
    static let engineRelease = "gta5-wine-11.13-8c2133a8baac-r3"
    static let engineSHA256 = "da363c8f004cd21e9a635d0511274612a86207eccabf77837130f1d86da54619"

    /// Links the engine gets to D3DMetal, relative to engine/, with their targets in the renderer layout
    /// linkTarget resolves, each replacing the engine's own file: D3DMetal's dxgi, d3d11 and d3d12 builtins
    /// with their Unix side, and the atidxx64 builtin, which GTA5_Enhanced.exe loads (the registry below).
    /// Wine looks for a builtin in the engine's own lib/wine before WINEDLLPATH (init_paths' dll_paths in
    /// dlls/ntdll/unix/loader.c), so the game gets D3DMetal only from here; Wine's own d3d11, dxgi and
    /// d3d10core reach the launcher as native copies in system32. These are the D3DMetal entries of MacGames
    /// 0.1.6's Runtime/dependency-links.json; its library entries are not needed, as the bottle's
    /// DYLD_FALLBACK_LIBRARY_PATH reaches the template's libraries.
    static let engineLinks: [(link: String, target: String)] = [
        ("lib/wine/x86_64-unix/atidxx64.so", "renderer/d3dmetal/external/libd3dshared.dylib"),
        ("lib/wine/x86_64-unix/d3d11.so", "renderer/d3dmetal/external/libd3dshared.dylib"),
        ("lib/wine/x86_64-unix/d3d12.so", "renderer/d3dmetal/external/libd3dshared.dylib"),
        ("lib/wine/x86_64-unix/dxgi.so", "renderer/d3dmetal/external/libd3dshared.dylib"),
        ("lib/wine/x86_64-windows/atidxx64.dll", "renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll"),
        ("lib/wine/x86_64-windows/d3d11.dll", "renderer/d3dmetal/wine/x86_64-windows/d3d11.dll"),
        ("lib/wine/x86_64-windows/d3d12.dll", "renderer/d3dmetal/wine/x86_64-windows/d3d12.dll"),
        ("lib/wine/x86_64-windows/dxgi.dll", "renderer/d3dmetal/wine/x86_64-windows/dxgi.dll"),
    ]

    /// Written into the built profile, and into each bottle once the profile's files and registry are applied
    /// there; a different value rebuilds the profile and, at a bottle's next start, applies it again. The
    /// version names how the profile is assembled and applied (engineLinks, layout, systemCopies, registry):
    /// change it with them, as the downloads' hashes do not.
    public var marker: String { "\(rawValue)-v3:" + downloads.map(\.sha256).joined(separator: "+") }

    // MARK: - Layout

    /// The engine's libraries load from @loader_path/../../deps/Frameworks, so engine/ and deps/ are siblings.
    public struct Layout: Sendable {
        public let root: URL
        public var engine: URL { root.appendingPathComponent("engine") }
        /// The engine release's WineD3D d3d11, dxgi and d3d10core without Wine's builtin mark.
        public var launcherWineD3D: URL { root.appendingPathComponent("launcher-wined3d") }
        public var frameworks: URL { root.appendingPathComponent("deps/Frameworks") }
        public func pack(_ name: String) -> URL { root.appendingPathComponent("packs/\(name)") }
        public var d3dmetal: URL { pack(EngineProfile.d3dmetalPack) }
        public var markerFile: URL { root.appendingPathComponent(".portnaut-engine-profile") }
    }

    /// Where an engine link (engineLinks) points, relative to the profile's root: a D3DMetal file
    /// from the pinned D3DMetal pack when the pack has it (its DLLs and libd3dshared must come from one
    /// D3DMetal), otherwise the template's file. Mirrors MacGames' EngineInstaller.ownD3DMetal.
    static func linkTarget(_ target: String, d3dmetalHas: (String) -> Bool) -> String {
        let prefix = "renderer/d3dmetal/"
        if target.hasPrefix(prefix) {
            let rest = String(target.dropFirst(prefix.count))
            if d3dmetalHas(rest) { return "packs/\(d3dmetalPack)/\(rest)" }
        }
        return "deps/Frameworks/\(target)"
    }

    /// A symbolic link at `link` (relative to the profile's root) to `target` (also relative to it),
    /// written relative so the profile can be built in a staging folder and moved into place.
    static func relativeLink(from link: String, to target: String) -> String {
        let depth = link.split(separator: "/").count - 1
        return String(repeating: "../", count: depth) + target
    }

    // MARK: - Bottle

    /// The bottle's environment under this profile, built on `base` (the Mac's environment with Wine's and
    /// the renderers' variables removed). Mirrors MacGames' WineEnvironment.make() with the gta5-enhanced
    /// recipe's edits; WINEDLLOVERRIDES carries no graphics overrides, so per-program registry overrides decide.
    func environment(base: [String: String], layout: Layout, prefix: URL, bottle: Bottle, cache: URL) -> [String: String] {
        // MacGames also strips these inherited keys before building its environment.
        var env = base.filter { key, _ in !key.hasPrefix("GST_") && !key.hasPrefix("ROSETTA_") && !key.hasPrefix("MTL_") && !key.hasPrefix("SDL_") }
        let gst = layout.frameworks.appendingPathComponent("GStreamer.framework/Versions/1.0/lib")
        env["PATH"] = layout.engine.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env["WINEPREFIX"] = prefix.path
        env["WINEARCH"] = "win64"
        // MacGames' GTA V environment turns msync off; the game was tested that way.
        env["WINEMSYNC"] = "0"
        env["WINEESYNC"] = "0"
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=;mscoree,mshtml=;gameoverlayrenderer,gameoverlayrenderer64=;nvapi64,nvngx="
        // Wine searches the engine's own lib/wine first, so D3DMetal's dxgi, d3d11 and d3d12 are linked into it
        // (engineLinks); this path adds only what the engine lacks, D3DMetal's nvapi64 and nvngx (turned off by
        // the overrides above). The launcher takes WineD3D from system32 (native,builtin).
        env["WINEDLLPATH"] = layout.d3dmetal.appendingPathComponent("wine").path + ":" + layout.engine.appendingPathComponent("lib/wine").path
        env["WINEDEBUG"] = ProcessInfo.processInfo.environment["PORTNAUT_WINEDEBUG"] ?? "-all,err+all"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [layout.frameworks.path, gst.path, "/usr/lib"].joined(separator: ":")
        env["GST_PLUGIN_PATH"] = gst.appendingPathComponent("gstreamer-1.0").path
        env["GST_REGISTRY"] = cache.appendingPathComponent("gstreamer-registry-\(rawValue).bin").path
        env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = layout.d3dmetal.appendingPathComponent("external/libd3dshared.dylib").path
        env["ROSETTA_ADVERTISE_AVX"] = "1"
        env["MTL_HUD_ENABLED"] = bottle.options.performanceHUD ? "1" : "0"
        env["D3DM_ENABLE_METALFX"] = "0"
        // Read by the engine's patches: Social Club's browser draws on the CPU.
        env["GTM_ROCKSTAR_SWIFTSHADER"] = "1"
        // The Windows user MacGames' engine expects; the launcher signs in as it. Every program of the bottle
        // runs under it, so the prefix has this one user whoever runs Portnaut.
        env["USER"] = "crossover"
        env["LOGNAME"] = "crossover"
        return env
    }

    /// Registry values written after the bottle's own, so the profile's per-program overrides win over a
    /// game's: the game on D3DMetal's builtins, the launcher and Social Club on WineD3D from system32
    /// without Direct3D 12. Portnaut's own Social Club switches are removed; this engine draws it itself.
    var registry: String {
        switch self {
        case .gta5Enhanced:
            let key = "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\"
            var lines: [String] = []
            lines += ["[\(key)GTA5_Enhanced.exe\\DllOverrides]"] + ["dxgi", "d3d11", "d3d10core", "d3d12", "atidxx64"].map { "\"\($0)\"=\"builtin\"" } + [""]
            for program in ["Launcher.exe", "LauncherPatcher.exe", "SocialClubHelper.exe"] {
                lines += ["[\(key)\(program)\\DllOverrides]"] + ["dxgi", "d3d11", "d3d10core"].map { "\"\($0)\"=\"native,builtin\"" } + ["\"d3d12\"=\"\""]
                if program == "SocialClubHelper.exe" { lines.append("\"vulkan-1\"=\"native\"") }
                lines.append("")
            }
            lines += ["[\(key)SocialClubHelper.exe]", "\"CommandLineAppend\"=-", ""]
            // Keeps the cursor from flickering in fullscreen (Wine captures the display instead of covering it).
            lines += ["[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]", "\"CaptureDisplaysForFullscreen\"=\"y\"", ""]
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Files copied into the prefix's system32, later ones replacing earlier ones: D3DMetal's dxgi, d3d11
    /// and d3d12 and the template's atidxx64, then the engine release's WineD3D d3d11, dxgi and d3d10core.
    func systemCopies(layout: Layout) -> [(from: URL, name: String)] {
        let d3dmetal = layout.d3dmetal.appendingPathComponent("wine/x86_64-windows")
        let template = layout.frameworks.appendingPathComponent("renderer/d3dmetal/wine/x86_64-windows")
        let wined3d = layout.launcherWineD3D
        return ["dxgi", "d3d11", "d3d12"].map { (d3dmetal.appendingPathComponent("\($0).dll"), "\($0).dll") }
            + [(template.appendingPathComponent("atidxx64.dll"), "atidxx64.dll")]
            + ["d3d11", "dxgi", "d3d10core"].map { (wined3d.appendingPathComponent("\($0).dll"), "\($0).dll") }
    }

    /// The game's arguments live in commandline.txt: the launcher starts GTA5_Enhanced.exe with
    /// @commandline.txt. Without -disableSpatialAudioClient voices and most effects are silent under
    /// Wine; -nobattleye skips BattlEye, which is for GTA Online only (tested).
    static let gameFolder = "Program Files/Rockstar Games/Grand Theft Auto V Enhanced"
    static let gameArguments = ["-disableSpatialAudioClient", "-nobattleye"]

    /// The commandline.txt contents with the required arguments added to the user's, each once.
    static func commandLine(merging existing: String?) -> String {
        var lines = (existing ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let present = Set(lines.flatMap { $0.split(separator: " ").map { $0.lowercased() } })
        lines += gameArguments.filter { !present.contains($0.lowercased()) }
        return lines.joined(separator: "\n") + "\n"
    }
}
