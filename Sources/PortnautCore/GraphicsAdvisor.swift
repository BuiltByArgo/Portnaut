import Foundation

public enum GraphicsAPI: String, CaseIterable, Sendable, Comparable {
    case d3d12, d3d11, d3d10, d3d9, d3d8, ddraw, vulkan, opengl
    public var title: String {
        switch self {
        case .d3d12: "DirectX 12"
        case .d3d11: "DirectX 11"
        case .d3d10: "DirectX 10"
        case .d3d9: "DirectX 9"
        case .d3d8: "DirectX 8"
        case .ddraw: "DirectDraw"
        case .vulkan: "Vulkan"
        case .opengl: "OpenGL"
        }
    }
    /// The DLLs that reveal each API. dxgi alone also means DirectX 10 or later.
    var modules: [String] {
        switch self {
        case .d3d12: ["d3d12.dll"]
        case .d3d11: ["d3d11.dll", "dxgi.dll"]
        case .d3d10: ["d3d10.dll", "d3d10_1.dll", "d3d10core.dll"]
        case .d3d9: ["d3d9.dll"]
        case .d3d8: ["d3d8.dll"]
        case .ddraw: ["ddraw.dll"]
        case .vulkan: ["vulkan-1.dll"]
        case .opengl: ["opengl32.dll"]
        }
    }
    public static func < (a: GraphicsAPI, b: GraphicsAPI) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// Games Portnaut has run, with the renderer that worked.
public struct KnownGame: Sendable {
    public var id: String
    public var title: String
    public var executable: String
    public var recommendation: Recommendation
    /// The 0.1.x environment folder this game lived in.
    var legacyBottleID: String

    public static let ac3 = KnownGame(
        id: "ac3-remastered", title: "Assassin’s Creed III Remastered", executable: "ACIII.exe",
        recommendation: Recommendation(renderer: .dxmt, reason: "Tested in Portnaut: plays through missions on DXMT at 60 fps. Portnaut’s Metal shim fixes its dual-source blending crash."),
        legacyBottleID: "ac3-remastered")
    public static let all = [ac3]
    public static func matching(_ executable: URL) -> KnownGame? {
        all.first { $0.executable.caseInsensitiveCompare(executable.lastPathComponent) == .orderedSame }
    }
}

public struct GraphicsAnalysis: Equatable, Sendable {
    public var architecture: String?
    /// Imported directly or delay-loaded by the program or a module beside it.
    public var imported: [GraphicsAPI]
    /// Only named in the program's data, which engines that load Direct3D at runtime do.
    public var mentioned: [GraphicsAPI]
    public var recommendation: Recommendation
    public var is64Bit: Bool { architecture == "x86_64-windows" }
}

public enum GraphicsAdvisor {
    /// Reads the program's import table and those of the DLLs beside it, then recommends a renderer.
    /// Known games override the rules.
    public static func analyze(_ executable: URL) -> GraphicsAnalysis {
        let info = try? PEImage.inspect(executable)
        var imported = apis(in: info?.imports ?? [])
        // Only when the program itself imports none, as when an engine keeps the renderer in a DLL.
        if imported.isEmpty {
            for module in siblingModules(of: executable) {
                if let sibling = try? PEImage.inspect(module) { imported.formUnion(apis(in: sibling.imports)) }
            }
        }
        let mentioned = imported.isEmpty ? mentionedAPIs(in: executable) : []
        let architecture = info?.architecture
        let rule = recommend(imported: imported, mentioned: mentioned, is64Bit: architecture == "x86_64-windows")
        return GraphicsAnalysis(architecture: architecture, imported: imported.sorted(), mentioned: mentioned.sorted(),
                                recommendation: KnownGame.matching(executable)?.recommendation ?? rule)
    }

    static func apis(in imports: [String]) -> Set<GraphicsAPI> {
        let names = Set(imports.map { $0.lowercased() })
        return Set(GraphicsAPI.allCases.filter { api in api.modules.contains { names.contains($0) } })
    }

    static func recommend(imported: Set<GraphicsAPI>, mentioned: Set<GraphicsAPI>, is64Bit: Bool) -> Recommendation {
        let apis = imported.isEmpty ? mentioned : imported
        let hedge = imported.isEmpty && !mentioned.isEmpty ? " The program loads it at runtime, so this is a best guess." : ""
        if apis.contains(.d3d12) {
            if is64Bit { return Recommendation(renderer: .d3dmetal, reason: "Uses DirectX 12, which D3DMetal translates. DXMT and DXVK here cover DirectX 11 at most." + hedge) }
            return Recommendation(renderer: .wined3d, reason: "A 32-bit DirectX 12 program: none of Portnaut’s fast renderers covers it." + hedge)
        }
        if apis.contains(.d3d11) || apis.contains(.d3d10) {
            if is64Bit { return Recommendation(renderer: .dxmt, reason: "A 64-bit DirectX 10/11 program: DXMT is the most direct path to Metal. Try D3DMetal if it misbehaves." + hedge) }
            return Recommendation(renderer: .dxvk, reason: "A 32-bit DirectX 10/11 program: DXMT and D3DMetal only cover 64-bit, so DXVK is the fast option." + hedge)
        }
        if apis.contains(.d3d9) {
            return Recommendation(renderer: .wined3d, reason: "Uses DirectX 9: Wine’s own Direct3D is the most compatible. DXVK (D9VK) is faster in some games." + hedge)
        }
        if apis.contains(.vulkan) {
            return Recommendation(renderer: .wined3d, reason: "Uses Vulkan, which runs on MoltenVK whatever the Direct3D renderer, so the default is fine." + hedge)
        }
        if apis.contains(.opengl) || apis.contains(.d3d8) || apis.contains(.ddraw) {
            return Recommendation(renderer: .wined3d, reason: "An OpenGL or older DirectX program: Wine’s own implementation handles these." + hedge)
        }
        return Recommendation(renderer: .wined3d, reason: "No graphics API found in the program’s files; Wine’s own Direct3D is the safe default.")
    }

    /// Overlays, browsers and helpers import every API to hook or wrap it; they say nothing about the game.
    static let unrelatedModules = ["overlay", "hook", "libcef", "libegl", "libglesv2", "d3dcompiler", "dxcompiler", "amd_ags", "nvapi", "nvngx",
                                   "steam_api", "gameoverlay", "gfnruntime", "discord", "bink", "vk_swiftshader", "vulkan-1", "uplay", "eos", "galaxy"]

    /// DLLs next to the program, where engines such as Unity keep their renderer.
    static func siblingModules(of executable: URL) -> [URL] {
        let folder = executable.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { file in
            let name = file.lastPathComponent.lowercased()
            return file.pathExtension.lowercased() == "dll" && !unrelatedModules.contains { name.hasPrefix($0) || name.contains($0) }
                && ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max) < 300_000_000
        }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(60).map { $0 }
    }

    /// Module names in the program's data, in any letter case, ASCII or UTF-16, for programs that
    /// load Direct3D themselves. One pass over the mapped file.
    static func mentionedAPIs(in executable: URL) -> Set<GraphicsAPI> {
        guard let data = try? Data(contentsOf: executable, options: .alwaysMapped) else { return [] }
        let patterns = GraphicsAPI.allCases.flatMap { api in api.modules.map { (api, Array($0.utf8)) } }
        let firstBytes = Set(patterns.map { $0.1[0] })
        func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5a ? byte | 0x20 : byte }
        var found = Set<GraphicsAPI>()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            func matches(_ start: Int, _ pattern: [UInt8], wide: Bool) -> Bool {
                let step = wide ? 2 : 1
                guard start + pattern.count * step <= bytes.count else { return false }
                for (k, expected) in pattern.enumerated() {
                    let index = start + k * step
                    if lower(bytes[index]) != expected || (wide && bytes[index + 1] != 0) { return false }
                }
                return true
            }
            for i in 0..<bytes.count where firstBytes.contains(lower(bytes[i])) {
                for (api, pattern) in patterns where !found.contains(api) && pattern[0] == lower(bytes[i]) {
                    if matches(i, pattern, wide: false) || matches(i, pattern, wide: true) { found.insert(api) }
                }
                if found.count == GraphicsAPI.allCases.count { break }
            }
        }
        return found
    }

    /// Renderers that can run a program at all, best first, for trying alternatives.
    public static func candidates(for analysis: GraphicsAnalysis) -> [Renderer] {
        let apis = Set(analysis.imported.isEmpty ? analysis.mentioned : analysis.imported)
        if apis.contains(.d3d12) { return analysis.is64Bit ? [.d3dmetal] : [.wined3d] }
        if apis.contains(.d3d11) || apis.contains(.d3d10) { return analysis.is64Bit ? [.dxmt, .d3dmetal, .dxvk] : [.dxvk, .wined3d] }
        if apis.contains(.d3d9) { return [.wined3d, .dxvk] }
        return [.wined3d]
    }

    /// For a bottle: the launcher's renderer if it has one, else what most of its games want.
    public static func recommendation(for bottle: Bottle, analyses: [GraphicsAnalysis]) -> Recommendation {
        if let launcher = bottle.launcher, analyses.isEmpty { return launcher.recommendation }
        let wanted = analyses.map(\.recommendation)
        guard let first = wanted.first else {
            return Recommendation(renderer: .dxmt, reason: "Most current Windows games are 64-bit DirectX 11, which DXMT handles best. Add games to get a specific recommendation.")
        }
        let counts = Dictionary(grouping: wanted, by: \.renderer)
        let top = counts.max { a, b in a.value.count < b.value.count }!.key
        if counts.count == 1 { return first }
        return Recommendation(renderer: top, reason: "Most games here run best on \(top.title); the others recommend \(Set(wanted.map(\.renderer)).subtracting([top]).map(\.title).sorted().joined(separator: ", ")). A separate bottle lets each use its own renderer.")
    }
}
