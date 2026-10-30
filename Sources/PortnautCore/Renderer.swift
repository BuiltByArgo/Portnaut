import Foundation

/// How Direct3D reaches Metal. Each renderer is a copy of the same Wine runtime (an APFS clone, so it
/// costs no disk space) with its own graphics modules installed as Wine builtins. Per-program DLL
/// overrides cannot choose between them: Wine always substitutes its own builtin for a DLL with the
/// builtin marker, and every module here carries it.
public enum Renderer: String, Codable, CaseIterable, Sendable, Identifiable {
    case dxmt, d3dmetal, dxvk, wined3d
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dxmt: "DXMT"
        case .d3dmetal: "D3DMetal"
        case .dxvk: "DXVK"
        case .wined3d: "Wine (wined3d)"
        }
    }

    public var detail: String {
        switch self {
        case .dxmt: "DirectX 10 and 11 straight to Metal. 64-bit programs only; 32-bit ones use Wine’s own Direct3D."
        case .d3dmetal: "Apple’s Direct3D 11 and 12 translation from the Game Porting Toolkit. 64-bit programs only; 32-bit ones use Wine’s own Direct3D."
        case .dxvk: "DirectX 9, 10 and 11 through Vulkan and MoltenVK (DXVK for macOS and D9VK), for 32- and 64-bit programs."
        case .wined3d: "Wine’s own Direct3D 1–11 over OpenGL. Widest compatibility, slowest for modern games."
        }
    }

    /// Shown wherever D3DMetal can be chosen.
    public var licenseNote: String? {
        self == .d3dmetal ? "D3DMetal is Apple’s, from the Game Porting Toolkit. Its licence covers non-commercial use for developing, testing and evaluating games on Apple hardware." : nil
    }

    /// Folder under the runtime's renderers/; wined3d is the unmodified engine.
    var variantFolder: String? { self == .wined3d ? nil : rawValue }

    /// Builtin overrides added to Portnaut's base list for this renderer's modules.
    var dllOverrides: String {
        switch self {
        case .d3dmetal: "d3d11,dxgi,d3d10core,d3d12=b"
        case .dxvk: "d3d11,dxgi,d3d10core,d3d9=b"
        case .dxmt, .wined3d: "d3d11,dxgi,d3d10core=b"
        }
    }

    /// Files copied over the engine clone, found in the unpacked archives under `sources`: "dxmt/" is
    /// Highball's DXMT archive, "renderer/" the template's renderer folder. D3DMetal's file set changes
    /// between versions (4.0 adds d3d12core and d3d10), so its modules are whatever its folders hold.
    /// Throws when a file the renderer needs is missing.
    func installation(from sources: URL) throws -> [(source: String, target: String)] {
        let fm = FileManager.default
        func exists(_ relative: String) -> Bool { (try? sources.appendingPathComponent(relative).checkResourceIsReachable()) == true
            || (try? fm.destinationOfSymbolicLink(atPath: sources.appendingPathComponent(relative).path)) != nil }
        func files(in folder: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: sources.appendingPathComponent(folder).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }
        var entries: [(String, String)] = []
        let required: [String]
        switch self {
        case .dxmt:
            // DXMT for 64-bit Direct3D only: 32-bit programs (Ubisoft Connect) stay on wined3d. nvapi64 and
            // nvngx bridge DLSS to MetalFX; Wine keeps them disabled unless a bottle turns DLSS on.
            entries = ["d3d11", "dxgi", "d3d10core", "winemetal", "nvapi64", "nvngx"].map { ("dxmt/highball/x86_64-windows/\($0).dll", "lib/wine/x86_64-windows/\($0).dll") }
                + [("dxmt/highball/i386-windows/winemetal.dll", "lib/wine/i386-windows/winemetal.dll"),
                   ("dxmt/highball/x86_64-unix/winemetal.so", "lib/wine/x86_64-unix/winemetal.so")]
            required = ["d3d11.dll", "dxgi.dll", "winemetal.dll", "winemetal.so"]
        case .d3dmetal:
            // Apple's layout: every unix module is a symlink to ../../external/libd3dshared.dylib, which
            // loads D3DMetal.framework from beside itself (@loader_path).
            entries = files(in: "renderer/d3dmetal/wine/x86_64-windows").filter { $0.hasSuffix(".dll") }
                .map { ("renderer/d3dmetal/wine/x86_64-windows/\($0)", "lib/wine/x86_64-windows/\($0)") }
                + files(in: "renderer/d3dmetal/wine/x86_64-unix").filter { $0.hasSuffix(".so") }
                .map { ("renderer/d3dmetal/wine/x86_64-unix/\($0)", "lib/wine/x86_64-unix/\($0)") }
                + [("renderer/d3dmetal/external/libd3dshared.dylib", "lib/external/libd3dshared.dylib"),
                   ("renderer/d3dmetal/external/D3DMetal.framework", "lib/external/D3DMetal.framework"),
                   ("renderer/d3dmetal/License.rtf", "D3DMetal-License.rtf")]
            required = ["d3d11.dll", "d3d12.dll", "dxgi.dll", "libd3dshared.dylib", "D3DMetal.framework"]
        case .dxvk:
            entries = ["x86_64-windows", "i386-windows"].flatMap { arch in
                ["d3d11", "d3d10core"].map { ("renderer/dxvk/wine/\(arch)/\($0).dll", "lib/wine/\(arch)/\($0).dll") }
                    + [("renderer/d9vk/wine/\(arch)/d3d9.dll", "lib/wine/\(arch)/d3d9.dll")]
            }
            required = ["d3d11.dll"]
        case .wined3d:
            return []
        }
        let present = entries.filter { exists($0.0) }
        let missing = required.filter { name in !present.contains { ($0.0 as NSString).lastPathComponent == name } }
        guard missing.isEmpty else { throw PortnautError("The downloaded \(title) files are incomplete (\(missing.joined(separator: ", ")) missing). Portnaut kept the runtime it has.") }
        return present
    }
}

/// A renderer suggestion with the reason shown beside it.
public struct Recommendation: Equatable, Sendable {
    public var renderer: Renderer
    public var reason: String
    public init(renderer: Renderer, reason: String) {
        self.renderer = renderer
        self.reason = reason
    }
}
