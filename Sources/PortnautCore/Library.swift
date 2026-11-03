import Foundation

/// Windows version a bottle reports to programs (Wine's "Version" value).
public enum WindowsVersion: String, Codable, CaseIterable, Sendable, Identifiable {
    case win11, win10, win81, win7
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .win11: "Windows 11"
        case .win10: "Windows 10"
        case .win81: "Windows 8.1"
        case .win7: "Windows 7"
        }
    }
}

/// Store launchers Portnaut knows how to install and start.
public enum Launcher: String, Codable, CaseIterable, Sendable, Identifiable {
    case ubisoft, steam, ea, epic, battlenet, rockstar, gog, amazon
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ubisoft: "Ubisoft Connect"
        case .steam: "Steam"
        case .ea: "EA app"
        case .epic: "Epic Games Launcher"
        case .battlenet: "Battle.net"
        case .rockstar: "Rockstar Games Launcher"
        case .gog: "GOG Galaxy"
        case .amazon: "Amazon Games"
        }
    }
    public var symbol: String {
        switch self {
        case .ubisoft: "gamecontroller"
        case .steam: "cloud"
        case .ea: "bolt.horizontal"
        case .epic: "sparkles"
        case .battlenet: "shield"
        case .rockstar: "star"
        case .gog: "circle.hexagongrid"
        case .amazon: "shippingbox"
        }
    }
    /// Relative to drive_c. `users/*/` matches any Windows user folder.
    public var executable: String {
        switch self {
        case .ubisoft: "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe"
        case .steam: "Program Files (x86)/Steam/steam.exe"
        case .ea: "Program Files/Electronic Arts/EA Desktop/EA Desktop/EALauncher.exe"
        case .epic: "Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"
        case .battlenet: "Program Files (x86)/Battle.net/Battle.net Launcher.exe"
        case .rockstar: "Program Files/Rockstar Games/Launcher/LauncherPatcher.exe"
        case .gog: "Program Files/GOG Galaxy/GalaxyClient.exe"
        case .amazon: "users/*/AppData/Local/Amazon Games/App/Amazon Games.exe"
        }
    }
    /// Steam draws its interface in software: its web helper's GPU process cannot draw into a window
    /// owned by another process on Wine's Mac driver. See `registry`.
    public var arguments: [String] {
        switch self {
        case .ubisoft: GraphicsProfile.connectBrowserArguments
        case .steam: ["-cef-disable-gpu"]
        case .ea, .epic, .battlenet, .rockstar, .gog, .amazon: []
        }
    }
    /// The publishers' own download links.
    public var installer: URL {
        switch self {
        case .ubisoft: URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!
        case .steam: URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!
        case .ea: URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!
        case .epic: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!
        case .battlenet: URL(string: "https://downloader.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live")!
        case .rockstar: URL(string: "https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe")!
        case .gog: URL(string: "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe")!
        case .amazon: URL(string: "https://download.amazongames.com/AmazonGamesSetup.exe")!
        }
    }
    public var installerName: String {
        switch self {
        case .ubisoft: "UbisoftConnectInstaller.exe"
        case .steam: "SteamSetup.exe"
        case .ea: "EAappInstaller.exe"
        case .epic: "EpicGamesLauncherInstaller.msi"
        case .battlenet: "Battle.net-Setup.exe"
        case .rockstar: "Rockstar-Games-Launcher.exe"
        case .gog: "GOG_Galaxy_2.0.exe"
        case .amazon: "AmazonGamesSetup.exe"
        }
    }
    /// The Epic Games Launcher comes as a Windows Installer package, run through msiexec.
    public var installerIsPackage: Bool { installerName.lowercased().hasSuffix(".msi") }
    /// Steam's installer runs silently; the EA app's does not start the app when it finishes. Epic's
    /// package shows only its progress: its one question is the folder, and the launcher must stay
    /// where Portnaut looks for it.
    public var installerArguments: [String] {
        switch self {
        case .ubisoft: []
        case .steam: ["/S"]
        case .ea: ["EAX_LAUNCH_CLIENT=0"]
        case .epic: ["/passive"]
        case .battlenet, .rockstar, .gog, .amazon: []
        }
    }
    /// Folders, relative to drive_c, where the launcher installs games by default.
    public var gameFolders: [String] {
        switch self {
        case .ubisoft: ["Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games", "Games"]
        case .steam: ["Program Files (x86)/Steam/steamapps/common"]
        case .ea: ["Program Files/EA Games", "Program Files (x86)/EA Games"]
        case .epic: ["Program Files/Epic Games"]
        // Battle.net gives every game its own folder in Program Files (x86); its shortcuts find them.
        case .battlenet: []
        case .rockstar: ["Program Files/Rockstar Games"]
        case .gog: ["Program Files/GOG Galaxy/Games", "Program Files (x86)/GOG Galaxy/Games", "GOG Games"]
        case .amazon: ["Amazon Games/Library"]
        }
    }
    public var recommendation: Recommendation {
        switch self {
        case .ubisoft:
            Recommendation(renderer: .dxmt, reason: "Ubisoft Connect is 32-bit and stays on Wine’s own Direct3D, which keeps its sign-in working (tested). 64-bit games get DXMT.")
        case .steam:
            Recommendation(renderer: .d3dmetal, reason: "Most Steam games are 64-bit DirectX 11 or 12, and D3DMetal runs both. Steam’s own window is drawn in software whatever the renderer. Once a game is installed, Portnaut reads it and suggests DXMT for DirectX 11 games.")
        case .ea:
            Recommendation(renderer: .d3dmetal, reason: "EA’s recent games are mostly 64-bit DirectX 11 or 12, and D3DMetal runs both. Games with EA’s kernel anti-cheat, such as EA Sports FC and Battlefield, do not run under Wine.")
        case .epic:
            Recommendation(renderer: .d3dmetal, reason: "Most Epic games are 64-bit Unreal Engine games on DirectX 11 or 12, and D3DMetal runs both. Once a game is installed, Portnaut reads it and suggests DXMT for DirectX 11 games.")
        case .battlenet:
            Recommendation(renderer: .d3dmetal, reason: "Blizzard’s current Windows games, such as Diablo IV and Overwatch 2, are 64-bit DirectX 11 or 12, and D3DMetal runs both.")
        case .rockstar:
            Recommendation(renderer: .dxmt, reason: "The Rockstar Games Launcher starts on DXMT and DXVK, not on D3DMetal (tested). DXMT runs DirectX 11 games such as GTA V; in Red Dead Redemption 2, choose Vulkan in its graphics settings, as its DirectX 12 mode needs D3DMetal.")
        case .gog:
            Recommendation(renderer: .dxvk, reason: "Many GOG games are older 32-bit DirectX 9 games, and DXVK is the fast renderer that covers them. Once a game is installed, Portnaut reads it and suggests a renderer for it.")
        case .amazon:
            Recommendation(renderer: .d3dmetal, reason: "Most Amazon Games titles are 64-bit DirectX 11 or 12, and D3DMetal runs both. Once a game is installed, Portnaut reads it and suggests a renderer for it.")
        }
    }
    /// Renderers the launcher does not start on. Its games inherit the launcher's Wine, so the whole
    /// bottle stays off them.
    public var unsupportedRenderers: Set<Renderer> {
        switch self {
        // The launcher draws with Direct2D, which goes through Wine's own Direct3D 10 on top of the
        // bottle's DXGI. D3DMetal replaces DXGI but not Direct3D 10, and the launcher reports that it
        // failed to initialize (tested; DXMT and DXVK replace both).
        case .rockstar: [.d3dmetal]
        // DXVK would draw Ubisoft Connect's 32-bit browser too, and its sign-in then fails (0.1.1).
        case .ubisoft: [.dxvk]
        // Galaxy's window stays white on Wine's own Direct3D (tested).
        case .gog: [.wined3d]
        case .steam, .ea, .epic, .battlenet, .amazon: []
        }
    }
    /// A recommendation for a game or bottle of this launcher, kept to renderers the launcher starts on.
    public func adjusted(_ recommendation: Recommendation) -> Recommendation {
        unsupportedRenderers.contains(recommendation.renderer) ? self.recommendation : recommendation
    }
    /// Registry values for the launcher's own programs, applied with the bottle's profile.
    public var registry: String {
        switch self {
        case .steam:
            // Portnaut's Wine build appends CommandLineAppend to the program's command line (kernelbase,
            // CreateProcessInternalW). This keeps the web helper's compositor in the process that owns
            // its window, so the interface is not black, without replacing Steam's files.
            return """
            [HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\steamwebhelper.exe]
            "CommandLineAppend"="\(GraphicsProfile.softwareBrowserSwitches)"

            """
        case .battlenet, .amazon, .rockstar:
            // Battle.net and Rockstar's Social Club (CEF) and Amazon Games (Electron) draw in Chromium like
            // Steam's web helper, with the same limit: without this their windows stay white (tested;
            // Amazon Games then quits at sign-in, and Social Club drew only when its GPU process failed).
            let program = switch self {
            case .battlenet: "Battle.net.exe"
            case .rockstar: "SocialClubHelper.exe"
            default: "Amazon Games UI.exe"
            }
            return """
            [HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\\(program)]
            "CommandLineAppend"="\(GraphicsProfile.softwareBrowserSwitches)"

            """
        case .ubisoft, .ea, .epic, .gog:
            return ""
        }
    }
    /// GOG Galaxy's system-wide settings and lock files, relative to drive_c.
    public static let galaxySettings = "ProgramData/GOG.com/Galaxy/config.json"
    public static let galaxyLockFiles = "ProgramData/GOG.com/Galaxy/lock-files"
    /// Galaxy's settings with Chromium's GPU turned off for its interface, or nil when the file
    /// cannot be read as settings. Galaxy draws in Qt WebEngine, which hands each page to Qt as a
    /// shared Direct3D texture that no Mac renderer provides, so the window stays grey (tested).
    /// Galaxy replaces QTWEBENGINE_CHROMIUM_FLAGS and ignores switches on its command line; its
    /// chromiumClientAppArguments setting, a map of switch to value, adds them.
    public static func galaxySettings(merging data: Data?) -> Data? {
        var settings: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            settings = read
        }
        var switches = settings["chromiumClientAppArguments"] as? [String: Any] ?? [:]
        switches["--disable-gpu"] = ""
        settings["chromiumClientAppArguments"] = switches
        return try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
    /// The launcher whose program this is, by file name.
    public static func owning(_ executable: String) -> Launcher? {
        let name = (executable as NSString).lastPathComponent
        return allCases.first { ($0.executable as NSString).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Frame pacing and measurement options; they apply to a whole Windows session.
public struct SessionOptions: Codable, Equatable, Sendable {
    /// DXMT's frame-rate limit; nil is unlimited.
    public var frameRateLimit: Int?
    /// Apple's Metal performance HUD.
    public var performanceHUD = false
    /// PortnautLatency summaries in session.log, from which Portnaut records each game session.
    public var recordPerformance = true
    /// DXMT only: the game renders at the Mac's point resolution and MetalFX upscales it 2× to Retina.
    public var metalFXUpscaling = false
    /// DXMT and D3DMetal: games that offer DLSS get MetalFX upscaling through it.
    public var dlss = false
    /// Two Metal drawables instead of three: one fewer frame can wait when the GPU is the limit.
    public var reduceFrameQueue = false
    /// Rosetta reports AVX and AVX2, which some recent games require (ROSETTA_ADVERTISE_AVX).
    public var advertiseAVX = false
    public init() {}

    enum CodingKeys: String, CodingKey { case frameRateLimit, performanceHUD, recordPerformance, metalFXUpscaling, dlss, reduceFrameQueue, advertiseAVX }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frameRateLimit = try c.decodeIfPresent(Int.self, forKey: .frameRateLimit)
        performanceHUD = try c.value(.performanceHUD, default: false)
        recordPerformance = try c.value(.recordPerformance, default: true)
        metalFXUpscaling = try c.value(.metalFXUpscaling, default: false)
        dlss = try c.value(.dlss, default: false)
        reduceFrameQueue = try c.value(.reduceFrameQueue, default: false)
        advertiseAVX = try c.value(.advertiseAVX, default: false)
    }
}

/// How Wine loads a DLL: Microsoft's file in the bottle ("native"), Wine's own ("builtin"), or not at all.
public enum DllOverride: String, Codable, CaseIterable, Sendable, Identifiable {
    case nativeThenBuiltin = "native,builtin", builtinThenNative = "builtin,native", native, builtin, disabled = ""
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .nativeThenBuiltin: "Native, then Wine’s"
        case .builtinThenNative: "Wine’s, then native"
        case .native: "Native only"
        case .builtin: "Wine’s only"
        case .disabled: "Disabled"
        }
    }
}

/// How the bottle's Windows sees game controllers (Wine's winebus driver).
public struct ControllerSettings: Codable, Equatable, Sendable {
    /// SDL recognises most controllers and their layouts; off, Wine reads macOS HID devices directly.
    public var sdl = true
    /// Controllers appear as Xbox controllers (XInput), which most games expect.
    public var xinput = true
    public init() {}
    enum CodingKeys: String, CodingKey { case sdl, xinput }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sdl = try c.value(.sdl, default: true)
        xinput = try c.value(.xinput, default: true)
    }
}

public struct Game: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Always relative to the bottle's drive_c. Never an external executable.
    public var executable: String
    public var arguments: [String] = []
    /// Starts the game through the bottle's launcher with these arguments, as Steam's -applaunch;
    /// nil starts the executable itself. The executable is still what Portnaut analyses.
    public var launcherArguments: [String]?
    /// Added to the bottle's environment when Portnaut starts the game itself. A game a launcher
    /// starts inherits the launcher's environment instead.
    public var environment: [String: String] = [:]
    /// Per-program DLL overrides (Wine's AppDefaults), keyed by DLL name without ".dll". They apply
    /// however the game is started.
    public var dllOverrides: [String: DllOverride] = [:]
    /// Per-program Windows version; nil uses the bottle's.
    public var windowsVersion: WindowsVersion?
    /// The latest recorded sessions, newest last.
    public var performance: [PerformanceRun] = []
    public var addedAt: Date?
    public var lastPlayedAt: Date?
    /// "Find my best setup" in progress.
    public var setupTrial: SetupTrial?
    /// The renderer measured fastest on this Mac; easy mode starts the game there.
    public var bestSetup: MeasuredSetup?
    public init(id: String, name: String, executable: String) {
        self.id = id
        self.name = name
        self.executable = executable
    }
    /// The file name Wine keys per-program settings by.
    public var programName: String { (executable as NSString).lastPathComponent }

    enum CodingKeys: String, CodingKey {
        case id, name, executable, arguments, launcherArguments, environment, dllOverrides, windowsVersion, performance, addedAt, lastPlayedAt
        case setupTrial, bestSetup
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.value(.arguments, default: [])
        launcherArguments = try c.decodeIfPresent([String].self, forKey: .launcherArguments)
        environment = try c.value(.environment, default: [:])
        dllOverrides = try c.value(.dllOverrides, default: [:])
        windowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion)
        performance = try c.value(.performance, default: [])
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        setupTrial = try c.decodeIfPresent(SetupTrial.self, forKey: .setupTrial)
        bestSetup = try c.decodeIfPresent(MeasuredSetup.self, forKey: .bestSetup)
    }
}

/// One Windows environment (a Wine prefix) with its own renderer and settings.
/// The renderer applies to the whole bottle: a launcher and the games it starts share one Wine runtime.
public struct Bottle: Codable, Equatable, Sendable, Identifiable {
    /// Also the folder name under Bottles/.
    public var id: String
    public var name: String
    public var launcher: Launcher?
    public var renderer: Renderer
    public var windowsVersion: WindowsVersion = .win10
    /// High Resolution Mode: Wine's Retina mode at 192 DPI.
    public var highResolution = true
    public var msync = true
    public var options = SessionOptions()
    /// Environment variables for every program of the bottle, launchers and the games they start included.
    public var environment: [String: String] = [:]
    public var controllers = ControllerSettings()
    /// Windows components Portnaut installed, by WindowsComponent id.
    public var components: [String: Date] = [:]
    public var games: [Game] = []
    public var createdAt: Date?
    /// Easy mode: before Portnaut starts a game, the bottle switches to the renderer the game was
    /// tested on, else the one its files suggest, within what the bottle's launcher starts on.
    public var easyMode = false
    /// Copies the bottle's saves to Portnaut Backups before every game Portnaut starts; the ten
    /// newest of these copies are kept.
    public var autoBackupSaves = false
    /// Wine's Retina mode: High Resolution Mode, except while MetalFX upscales to Retina instead.
    public var retinaMode: Bool { highResolution && !metalFXActive }
    public var metalFXActive: Bool { renderer == .dxmt && options.metalFXUpscaling }
    public var dlssActive: Bool { (renderer == .dxmt || renderer == .d3dmetal) && options.dlss }
    /// How a performance record names this bottle's graphics configuration.
    public var performanceLabel: String {
        [renderer.title, metalFXActive ? "MetalFX 2×" : nil, dlssActive ? "DLSS" : nil, !metalFXActive && !highResolution ? "High Resolution off" : nil,
         options.frameRateLimit.map { "\($0) fps limit" }].compactMap { $0 }.joined(separator: " · ")
    }
    public init(id: String, name: String, launcher: Launcher? = nil, renderer: Renderer) {
        self.id = id
        self.name = name
        self.launcher = launcher
        self.renderer = renderer
    }

    // Settings added in later versions are optional in the file, so older libraries still load.
    // Files from before 0.7.0 may hold connectGPUOverride, a removed Ubisoft Connect setting; it is ignored.
    enum CodingKeys: String, CodingKey {
        case id, name, launcher, renderer, windowsVersion, highResolution, msync, options, environment, controllers, components, games, createdAt
        case easyMode, autoBackupSaves
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        launcher = try c.decodeIfPresent(Launcher.self, forKey: .launcher)
        renderer = try c.decode(Renderer.self, forKey: .renderer)
        windowsVersion = try c.value(.windowsVersion, default: .win10)
        highResolution = try c.value(.highResolution, default: true)
        msync = try c.value(.msync, default: true)
        options = try c.value(.options, default: SessionOptions())
        environment = try c.value(.environment, default: [:])
        controllers = try c.value(.controllers, default: ControllerSettings())
        components = try c.value(.components, default: [:])
        games = try c.value(.games, default: [])
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        // Bottles from before 0.10.0 keep working as they did until the owner turns these on.
        easyMode = try c.value(.easyMode, default: false)
        autoBackupSaves = try c.value(.autoBackupSaves, default: false)
    }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) throws -> T { try decodeIfPresent(T.self, forKey: key) ?? fallback }
}

/// Environment variables Portnaut sets itself; a bottle or game cannot replace them.
public enum EnvironmentPolicy {
    static let protected: Set<String> = ["PATH", "WINEPREFIX", "WINEARCH", "WINEDLLOVERRIDES"]
    public static func allows(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first),
              key.unicodeScalars.allSatisfy({ $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) }) else { return false }
        let upper = key.uppercased()
        return !protected.contains(upper) && !upper.hasPrefix("DYLD_") && !upper.hasPrefix("PORTNAUT_")
    }
}

public struct Library: Codable, Sendable {
    public var schema = 2
    public var bottles: [Bottle] = []
    public init(bottles: [Bottle] = []) { self.bottles = bottles }

    public func bottle(_ id: String) -> Bottle? { bottles.first { $0.id == id } }
    public mutating func update(_ bottle: Bottle) {
        if let index = bottles.firstIndex(where: { $0.id == bottle.id }) { bottles[index] = bottle } else { bottles.append(bottle) }
    }
    /// Lowercase ASCII letters, digits and single hyphens, at most 40 characters.
    public static func slug(_ name: String, fallback: String) -> String {
        let base = name.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return base.isEmpty ? fallback : String(base.prefix(40))
    }
    /// A bottle name from an installer's file name: "setup_the_witcher_3_v4.04.exe" becomes "The Witcher 3",
    /// "setup_cyberpunk_2077_2.13_(78035).exe" "Cyberpunk 2077". The name ends where a version starts.
    public static func suggestedBottleName(forInstaller fileName: String) -> String {
        let noise: Set<String> = ["setup", "install", "installer", "x64", "x86", "win64", "win32", "windows", "gog", "full", "offline", "en", "multi"]
        let tokens = (fileName as NSString).deletingPathExtension.split(whereSeparator: { " _-.()[]".contains($0) }).map(String.init)
            .filter { !noise.contains($0.lowercased()) }
        var kept: [String] = []
        for (index, word) in tokens.enumerated() {
            let lower = word.lowercased()
            let numeric = lower.allSatisfy(\.isNumber)
            let nextNumeric = index + 1 < tokens.count && tokens[index + 1].allSatisfy(\.isNumber)
            // v4, 64bit, a build number, or the 2 of 2.13.
            let versionStarts = (lower.count > 1 && lower.first == "v" && lower.dropFirst().allSatisfy(\.isNumber)) || lower.hasSuffix("bit")
                || (numeric && (lower.count >= 5 || (lower.count <= 2 && nextNumeric)))
            if versionStarts { break }
            kept.append(word.prefix(1).uppercased() + word.dropFirst())
        }
        let name = kept.joined(separator: " ")
        return name.isEmpty ? "Programs" : String(name.prefix(40))
    }
    /// Folder-safe, unique among existing bottles.
    public func newBottleID(for name: String) -> String {
        let stem = Self.slug(name, fallback: "bottle")
        var candidate = stem, suffix = 2
        while bottles.contains(where: { $0.id == candidate }) { candidate = "\(stem)-\(suffix)"; suffix += 1 }
        return candidate
    }
}

/// Portnaut 0.1.x kept one game in one Windows environment, Bottles/ac3-remastered.
struct LegacyLibraryState: Codable {
    var schema: Int?
    var gameRelativePath: String?
    var importedAt: Date?
    var lastPlayedAt: Date?
    var frameRateLimit: Int?
    var performanceHUD: Bool?
    var reduceFrameQueue: Bool?

    /// The existing environment becomes a Ubisoft Connect bottle with its game, folder, and settings unchanged.
    func migrated() -> Library {
        var bottle = Bottle(id: KnownGame.ac3.legacyBottleID, name: "Ubisoft Connect", launcher: .ubisoft, renderer: .dxmt)
        bottle.options.frameRateLimit = frameRateLimit
        bottle.options.performanceHUD = performanceHUD ?? false
        bottle.options.reduceFrameQueue = reduceFrameQueue ?? false
        if let gameRelativePath {
            var game = Game(id: KnownGame.ac3.id, name: KnownGame.ac3.title, executable: gameRelativePath)
            game.addedAt = importedAt
            game.lastPlayedAt = lastPlayedAt
            bottle.games = [game]
        }
        return Library(bottles: [bottle])
    }
}
