import Foundation

/// Cover art for Steam games in the library. Steam keeps each game's library images on the Mac
/// already (appcache/librarycache in the bottle), so those come first and need no network. Only if
/// the user allows it in Settings does Portnaut download the missing ones from Steam's image server.
public enum CoverArt {
    public enum Kind: String, Sendable, CaseIterable {
        /// Wide, for the featured game: Steam's 1920 × 620 library hero.
        case hero
        /// For library cards and Couch Mode: Steam's 460 × 215 header.
        case card
        /// Steam's file names, newest layout first.
        var steamFiles: [String] {
            switch self {
            case .hero: ["library_hero.jpg"]
            case .card: ["header.jpg", "capsule_616x353.jpg"]
            }
        }
    }

    public static func steamURL(appID: Int, kind: Kind) -> URL {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/\(kind.steamFiles[0])")!
    }

    /// Steam's own copy in a bottle: librarycache/<appid>/<file> (also one folder deeper, as newer
    /// Steam versions keep some), or librarycache/<appid>_<file> as older ones did.
    public static func localSteamImage(appID: Int, kind: Kind, drive: URL) -> URL? {
        let cache = drive.appendingPathComponent("Program Files (x86)/Steam/appcache/librarycache")
        let fm = FileManager.default
        for file in kind.steamFiles {
            let flat = cache.appendingPathComponent("\(appID)_\(file)")
            if fm.fileExists(atPath: flat.path) { return flat }
            let folder = cache.appendingPathComponent(String(appID))
            let direct = folder.appendingPathComponent(file)
            if fm.fileExists(atPath: direct.path) { return direct }
            let nested = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            if let found = nested.sorted(by: { $0.path < $1.path }).map({ $0.appendingPathComponent(file) }).first(where: { fm.fileExists(atPath: $0.path) }) {
                return found
            }
        }
        return nil
    }
}

extension PortnautPaths {
    /// Downloaded cover art, as <appid>-<kind>.jpg; an empty file marks one Steam doesn't have.
    public var artwork: URL { root.appendingPathComponent("Artwork") }
}

extension WineService {
    /// The image to show for a game, if Steam or an earlier download has one.
    public func coverArt(for game: Game, in bottle: Bottle, kind: CoverArt.Kind) -> URL? {
        guard bottle.launcher == .steam, let appID = game.steamAppID else { return nil }
        if let local = CoverArt.localSteamImage(appID: appID, kind: kind, drive: paths.bottle(bottle).drive) { return local }
        let downloaded = paths.artwork.appendingPathComponent("\(appID)-\(kind.rawValue).jpg")
        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0 ? downloaded : nil
    }

    /// Whether a download was already tried, found or not.
    public func coverArtDownloadTried(appID: Int, kind: CoverArt.Kind) -> Bool {
        FileManager.default.fileExists(atPath: paths.artwork.appendingPathComponent("\(appID)-\(kind.rawValue).jpg").path)
    }

    /// Downloads one image from Steam's image server. A game without one gets an empty marker
    /// file, so Portnaut doesn't ask again.
    public func downloadCoverArt(appID: Int, kind: CoverArt.Kind) async {
        let target = paths.artwork.appendingPathComponent("\(appID)-\(kind.rawValue).jpg")
        try? FileManager.default.createDirectory(at: paths.artwork, withIntermediateDirectories: true)
        do { try await download(CoverArt.steamURL(appID: appID, kind: kind), to: target) }
        catch { FileManager.default.createFile(atPath: target.path, contents: Data()) }
    }
}
