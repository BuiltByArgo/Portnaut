import Foundation

/// A file a Windows component is installed from.
public struct ComponentDownload: Sendable {
    public var url: URL
    public var fileName: String
    /// For files Microsoft no longer changes, checked like the runtime downloads (the same hashes
    /// winetricks pins). nil for Microsoft's "latest" links, which change with every release.
    public var sha256: String?
    /// The installer's silent arguments.
    public var arguments: [String]
}

/// Microsoft runtimes some programs need, installed the way winetricks does: the official
/// installers run silently, then Wine is told to prefer Microsoft's DLLs over its own.
public enum WindowsComponent: String, CaseIterable, Sendable, Identifiable {
    case vcrun2022, vcrun2013, vcrun2010, dotnetDesktop8, d3dx
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vcrun2022: "Visual C++ 2015–2022"
        case .vcrun2013: "Visual C++ 2013"
        case .vcrun2010: "Visual C++ 2010"
        case .dotnetDesktop8: ".NET Desktop Runtime 8"
        case .d3dx: "DirectX 9–11 helper libraries"
        }
    }
    public var detail: String {
        switch self {
        case .vcrun2022: "Microsoft’s C++ runtime (64- and 32-bit), latest release. For programs that misbehave with Wine’s own msvcp140 and vcruntime140."
        case .vcrun2013: "C++ runtime for games and tools built with Visual Studio 2013 (msvcp120, msvcr120)."
        case .vcrun2010: "C++ runtime for older games built with Visual Studio 2010 (msvcp100, msvcr100)."
        case .dotnetDesktop8: "For tools such as mod managers built on .NET 8 (WPF and Windows Forms), 64- and 32-bit. Older .NET Framework programs use Wine Mono, built in."
        case .d3dx: "D3DX 9, 10 and 11 and the D3DCompiler from the June 2010 DirectX package, for games that ship without them. Only these libraries are copied in, as winetricks does; audio and input stay Wine’s."
        }
    }
    public var downloadSize: String {
        switch self {
        case .vcrun2022: "38 MB"
        case .vcrun2013: "13 MB"
        case .vcrun2010: "10 MB"
        case .dotnetDesktop8: "107 MB"
        case .d3dx: "96 MB"
        }
    }

    public var downloads: [ComponentDownload] {
        let quiet = ["/install", "/quiet", "/norestart"]
        switch self {
        case .vcrun2022:
            return [ComponentDownload(url: URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!, fileName: "vc_redist.x64.exe", sha256: nil, arguments: quiet),
                    ComponentDownload(url: URL(string: "https://aka.ms/vs/17/release/vc_redist.x86.exe")!, fileName: "vc_redist.x86.exe", sha256: nil, arguments: quiet)]
        case .vcrun2013:
            return [ComponentDownload(url: URL(string: "https://download.microsoft.com/download/0/5/6/056dcda9-d667-4e27-8001-8a0c6971d6b1/vcredist_x64.exe")!, fileName: "vcredist2013_x64.exe",
                                      sha256: "20e2645b7cd5873b1fa3462b99a665ac8d6e14aae83ded9d875fea35ffdd7d7e", arguments: quiet),
                    ComponentDownload(url: URL(string: "https://download.microsoft.com/download/0/5/6/056dcda9-d667-4e27-8001-8a0c6971d6b1/vcredist_x86.exe")!, fileName: "vcredist2013_x86.exe",
                                      sha256: "89f4e593ea5541d1c53f983923124f9fd061a1c0c967339109e375c661573c17", arguments: quiet)]
        case .vcrun2010:
            return [ComponentDownload(url: URL(string: "https://download.microsoft.com/download/A/8/0/A80747C3-41BD-45DF-B505-E9710D2744E0/vcredist_x64.exe")!, fileName: "vcredist2010_x64.exe",
                                      sha256: "2fddbc3aaaab784c16bc673c3bae5f80929d5b372810dbc28649283566d33255", arguments: ["/q", "/norestart"]),
                    ComponentDownload(url: URL(string: "https://download.microsoft.com/download/5/B/C/5BC5DBB3-652D-4DCE-B14A-475AB85EEF6E/vcredist_x86.exe")!, fileName: "vcredist2010_x86.exe",
                                      sha256: "31d32fa39d52cac9a765a43660431f7a127eee784b54b2f5e2af3e2b763a1af8", arguments: ["/q", "/norestart"])]
        case .dotnetDesktop8:
            return [ComponentDownload(url: URL(string: "https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe")!, fileName: "windowsdesktop-runtime-8-win-x64.exe", sha256: nil, arguments: quiet),
                    ComponentDownload(url: URL(string: "https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x86.exe")!, fileName: "windowsdesktop-runtime-8-win-x86.exe", sha256: nil, arguments: quiet)]
        case .d3dx:
            return [ComponentDownload(url: URL(string: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe")!, fileName: "directx_Jun2010_redist.exe",
                                      sha256: "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b", arguments: [])]
        }
    }

    /// Wine prefers its own builtin for these; after installing, Microsoft's are used first.
    public var dllOverrides: [String] {
        switch self {
        case .vcrun2022: ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "vcamp140", "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1"]
        case .vcrun2013: ["atl120", "msvcp120", "msvcr120", "vcomp120"]
        case .vcrun2010: ["msvcp100", "msvcr100", "vcomp100", "atl100"]
        case .dotnetDesktop8: []
        case .d3dx: (24...43).map { "d3dx9_\($0)" } + ["d3dx10"] + (33...43).map { "d3dx10_\($0)" } + ["d3dx11_42", "d3dx11_43"] + (33...43).map { "d3dcompiler_\($0)" }
        }
    }

    /// Installers' success codes: done, done but a restart is due, or a newer version is already there.
    static let acceptedExitCodes: Set<Int32> = [0, 1638, 1641, 3010]

    /// Packages in the DirectX redistributable that `d3dx` copies, by name: the x64 ones go to
    /// system32, the x86 ones to syswow64.
    static func isD3DXPackage(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".cab") && (lower.contains("_d3dx9_") || lower.contains("_d3dx10_") || lower.contains("_d3dx11_") || lower.contains("_d3dcompiler_"))
            && (lower.hasSuffix("_x64.cab") || lower.hasSuffix("_x86.cab"))
    }
}

/// Parts of Windows that Wine provides itself, listed so it is clear nothing needs installing.
public enum BuiltInComponent: CaseIterable {
    case mono, gecko, media, audioInput, fonts
    public var title: String {
        switch self {
        case .mono: ".NET Framework 2.0–4.8"
        case .gecko: "Internet Explorer engine (MSHTML)"
        case .media: "Media Foundation and DirectShow video"
        case .audioInput: "XAudio2, XInput and DirectInput"
        case .fonts: "Fonts"
        }
    }
    public var detail: String {
        switch self {
        case .mono: "Wine Mono 10.4.1 runs most .NET Framework programs."
        case .gecko: "Wine Gecko 2.47.4, for installers and launchers that show web pages."
        case .media: "Played through GStreamer, included in Portnaut’s runtime."
        case .audioInput: "Wine’s own, with FAudio for XAudio2."
        case .fonts: "Your Mac’s fonts are available to Windows programs."
        }
    }
}
