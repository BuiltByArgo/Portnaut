import Foundation

/// App-wide choices from the Settings window, in settings.json in Portnaut's data folder, so
/// portnaut-doctor uses them too.
public struct PortnautSettings: Codable, Equatable, Sendable {
    /// The Windows version new bottles start with.
    public var newBottleWindowsVersion: WindowsVersion = .win10
    /// Whether new bottles record each game session's frame rate (each bottle can change it).
    public var recordPerformanceInNewBottles = true
    /// Whether Portnaut may download cover art for Steam games from Steam's image server, when
    /// Steam has none on the Mac. Off unless the user turns it on: it tells Valve which games are
    /// in the library.
    public var downloadSteamArtwork = false

    public init() {}

    enum CodingKeys: String, CodingKey { case newBottleWindowsVersion, recordPerformanceInNewBottles, downloadSteamArtwork }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        newBottleWindowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .newBottleWindowsVersion) ?? .win10
        recordPerformanceInNewBottles = try c.decodeIfPresent(Bool.self, forKey: .recordPerformanceInNewBottles) ?? true
        downloadSteamArtwork = try c.decodeIfPresent(Bool.self, forKey: .downloadSteamArtwork) ?? false
    }
}

extension PortnautPaths {
    public var settings: URL { root.appendingPathComponent("settings.json") }
}

extension WineService {
    /// Missing or unreadable settings give the defaults.
    public var settings: PortnautSettings {
        get { (try? Data(contentsOf: paths.settings)).flatMap { try? JSONDecoder().decode(PortnautSettings.self, from: $0) } ?? PortnautSettings() }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try? encoder.encode(newValue).write(to: paths.settings, options: .atomic)
        }
    }
}
