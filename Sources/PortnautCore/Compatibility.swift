import Foundation

/// What is known about a game on Apple silicon, from Highball's public database
/// (https://github.com/gauthierpiarrette/highball-db): curated games (CC0), predictions computed
/// from ProtonDB's Linux reports (ODbL) and an anti-cheat map from Are We Anti-Cheat Yet? (MIT).
/// Portnaut ships a copy and refreshes it with Component Updates; games are matched on the Mac,
/// so nothing about what someone plays leaves it.
public struct CompatibilityReport: Equatable, Sendable, Identifiable {
    public enum Status: Int, Comparable, Sendable {
        /// Kernel anti-cheat, or the publisher stops the game on macOS: it cannot run.
        case blocked
        /// Predicted from Linux reports to fail.
        case unlikely
        /// Predicted from mixed Linux reports.
        case maybe
        /// Predicted from Linux reports to work; not tested on a Mac.
        case likely
        /// Reported working on a Mac, by players or in a Wine release's notes; not verified.
        case reported
        /// Played on Apple silicon by Highball, or by Portnaut.
        case tested
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String
    public var title: String
    public var steamAppID: Int?
    public var status: Status
    /// The renderer the game was tested or reported on.
    public var renderer: Renderer?
    /// Anti-cheat the game ships; it may block online play even when the status is good.
    public var antiCheat: [String] = []
    public var notes: String?
    /// The game's page on Highball's site, when it has one.
    public var url: URL?

    public var headline: String {
        switch status {
        case .blocked: "Won’t run"
        case .unlikely: "Unlikely to run"
        case .maybe: "Might run"
        case .likely: "Likely to run"
        case .reported: "Players report it runs"
        case .tested: "Tested on Apple silicon"
        }
    }
    /// One sentence for the interface.
    public var explanation: String {
        let cheat = antiCheat.isEmpty ? "" : " It uses \(Self.list(antiCheat)), which may block online play."
        switch status {
        case .blocked:
            return antiCheat.isEmpty ? "Its publisher stops it from running on a Mac." : "It uses \(Self.list(antiCheat)), kernel-level anti-cheat that cannot run under Wine."
        case .unlikely: return "Linux players report it failing under Wine; it has not been tested on a Mac." + cheat
        case .maybe: return "Linux players report mixed results under Wine; it has not been tested on a Mac." + cheat
        case .likely: return "Linux players report it working under Wine; it has not been tested on a Mac yet." + cheat
        case .reported: return "Mac players report it working" + (renderer.map { " on \($0.title)" } ?? "") + "; not verified yet." + cheat
        case .tested: return (renderer.map { "Runs on \($0.title), verified on a Mac." } ?? "Verified on a Mac.") + cheat
        }
    }
    public static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

/// The three files of Highball's database, read into one index.
public struct CompatibilityDatabase: Sendable {
    public var reports: [CompatibilityReport]
    /// The newest "generated" date of the files, for choosing between copies.
    public var generated: String
    var bySteamID: [Int: Int] = [:]
    var byTitle: [String: Int] = [:]
    var searchTitles: [String] = []

    public static let files = ["games.json", "derived.json", "anticheat.json"]

    /// Reads a folder holding games.json, derived.json and anticheat.json. Missing or unreadable
    /// files are left out; nil when none can be read.
    public init?(folder: URL) {
        func object(_ name: String) -> [String: Any]? {
            (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        let curated = object("games.json"), predictions = object("derived.json"), cheats = object("anticheat.json")
        guard curated != nil || predictions != nil || cheats != nil else { return nil }
        self.init(curated: curated, predictions: predictions, antiCheat: cheats)
    }

    init(curated: [String: Any]?, predictions: [String: Any]?, antiCheat: [String: Any]?) {
        var reports: [CompatibilityReport] = []
        var bySteamID: [Int: Int] = [:], byTitle: [String: Int] = [:]
        func index(of steam: Int?, _ title: String) -> Int? {
            steam.flatMap { bySteamID[$0] } ?? byTitle[Self.normalized(title)]
        }
        func remember(_ report: CompatibilityReport) {
            reports.append(report)
            if let steam = report.steamAppID { bySteamID[steam] = reports.count - 1 }
            let key = Self.normalized(report.title)
            if byTitle[key] == nil { byTitle[key] = reports.count - 1 }
        }
        // Curated games first: they are tested or reported on a Mac.
        for game in curated?["games"] as? [[String: Any]] ?? [] {
            guard let id = game["id"] as? String, let title = game["title"] as? String, let status = game["status"] as? String else { continue }
            let mapped: CompatibilityReport.Status
            switch status {
            // Only Highball's own play on a Mac counts as tested; a Wine release's notes are a report.
            case "verified-local": mapped = .tested
            case "community", "reported-upstream": mapped = .reported
            case "blocked-anticheat", "blocked-publisher": mapped = .blocked
            default: continue
            }
            let cheat = game["anticheat"] as? [String: Any]
            var report = CompatibilityReport(id: id, title: title, steamAppID: Self.int(game["steam_appid"]), status: mapped,
                                             renderer: (game["renderer"] as? String).flatMap(Renderer.init(rawValue:)),
                                             antiCheat: cheat?["names"] as? [String] ?? [], notes: game["notes"] as? String,
                                             url: (game["url"] as? String).flatMap(URL.init(string:)))
            if cheat?["macVerdict"] as? String == "blocked" { report.status = .blocked }
            remember(report)
        }
        // Anti-cheat: blocked games become blocked; others gain the anti-cheat names.
        for (slug, value) in (antiCheat?["games"] as? [String: Any]) ?? [:] {
            guard let game = value as? [String: Any], let title = game["title"] as? String else { continue }
            let steam = Self.int(game["steam_appid"]), names = game["anticheats"] as? [String] ?? []
            let blocked = game["macVerdict"] as? String == "blocked"
            if let existing = index(of: steam, title) {
                if reports[existing].antiCheat.isEmpty { reports[existing].antiCheat = names }
                if blocked { reports[existing].status = .blocked }
            } else if blocked {
                remember(CompatibilityReport(id: slug, title: title, steamAppID: steam, status: .blocked, antiCheat: names))
            } else {
                // Only anti-cheat is known: what matters is the game's own prediction, added below.
                remember(CompatibilityReport(id: slug, title: title, steamAppID: steam, status: .maybe, antiCheat: names))
            }
        }
        // Predictions from Linux reports, for Steam games the curated list does not cover.
        for (key, value) in (predictions?["games"] as? [String: Any]) ?? [:] {
            guard let game = value as? [String: Any], let title = game["title"] as? String, let steam = Int(key) else { continue }
            let mapped: CompatibilityReport.Status
            switch game["macPrediction"] as? String {
            case "likely": mapped = .likely
            case "maybe": mapped = .maybe
            case "unlikely": mapped = .unlikely
            default: continue
            }
            if let existing = index(of: steam, title) {
                // Anti-cheat-only entries take the prediction; curated and blocked entries keep theirs.
                if reports[existing].status == .maybe, reports[existing].notes == nil, reports[existing].url == nil { reports[existing].status = mapped }
                if reports[existing].steamAppID == nil { reports[existing].steamAppID = steam; bySteamID[steam] = existing }
            } else {
                remember(CompatibilityReport(id: "steam-\(steam)", title: title, steamAppID: steam, status: mapped))
            }
        }
        self.reports = reports
        self.bySteamID = bySteamID
        self.byTitle = byTitle
        searchTitles = reports.map { Self.normalized($0.title) }
        generated = [curated, predictions, antiCheat].compactMap { $0?["generated"] as? String }.max() ?? ""
    }

    static func int(_ value: Any?) -> Int? { (value as? Int) ?? (value as? String).flatMap(Int.init) }

    /// Lower case, letters and digits only, "&" as "and", without trademark signs.
    public static func normalized(_ title: String) -> String {
        // Apostrophes join words ("Assassin's" is "assassins"); other punctuation separates them.
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        let words = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(words).split(separator: " ").joined(separator: " ")
    }
    /// Editions that name the same game.
    static let editionSuffixes = ["game of the year edition", "goty edition", "goty", "definitive edition", "complete edition", "enhanced edition", "deluxe edition", "standard edition"]

    /// The report for a game, by Steam app id when there is one, else by title.
    public func report(steamAppID: Int? = nil, title: String) -> CompatibilityReport? {
        if let steamAppID, let index = bySteamID[steamAppID] { return reports[index] }
        var key = Self.normalized(title)
        if let index = byTitle[key] { return reports[index] }
        for suffix in Self.editionSuffixes where key.hasSuffix(" " + suffix) {
            key = String(key.dropLast(suffix.count + 1))
            if let index = byTitle[key] { return reports[index] }
        }
        return nil
    }

    /// Titles matching a search, best first: whole title, then start, then any word, preferring
    /// games tested on a Mac.
    public func search(_ query: String, limit: Int = 30) -> [CompatibilityReport] {
        let wanted = Self.normalized(query)
        guard wanted.count >= 2 else { return [] }
        var scored: [(Int, Int)] = []
        for (index, title) in searchTitles.enumerated() {
            let rank: Int
            if title == wanted { rank = 0 }
            else if title.hasPrefix(wanted) { rank = 1 }
            else if title.contains(" " + wanted) { rank = 2 }
            else if title.contains(wanted) { rank = 3 }
            else { continue }
            scored.append((rank, index))
        }
        return scored.sorted { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            let x = reports[a.1], y = reports[b.1]
            let curatedX = x.url != nil || x.notes != nil, curatedY = y.url != nil || y.notes != nil
            if curatedX != curatedY { return curatedX }
            return x.title.count < y.title.count
        }.prefix(limit).map { reports[$0.1] }
    }
}

extension PortnautPaths {
    /// Compatibility data downloaded with Component Updates; newer than the copy inside the app.
    public var compatibility: URL { root.appendingPathComponent("Compatibility") }
}

extension WineService {
    /// The copy inside the app: Contents/Resources/Compatibility, found from the app or from its
    /// helper in Contents/Helpers.
    public static var bundledCompatibility: URL? {
        let bundle = Bundle.main.bundleURL
        return [bundle.appendingPathComponent("Contents/Resources/Compatibility"), bundle.deletingLastPathComponent().appendingPathComponent("Resources/Compatibility")]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("games.json").path) }
    }

    /// The newer of the downloaded and the bundled database.
    public func compatibilityDatabase(bundled: URL? = WineService.bundledCompatibility) -> CompatibilityDatabase? {
        let copies = [paths.compatibility, bundled].compactMap { $0 }.compactMap(CompatibilityDatabase.init(folder:))
        return copies.max { $0.generated < $1.generated }
    }

    /// Downloads the database's three files and their licences into the data folder. A file is
    /// replaced only when the new one reads as the database's format, so a failed or odd download
    /// keeps the previous copy.
    public func refreshCompatibility() async throws {
        let raw = "https://raw.githubusercontent.com/gauthierpiarrette/highball-db/main/db"
        let sources: [(String, String)] = [("https://gethighball.com/data/games.json", "games.json"), ("\(raw)/derived/derived.json", "derived.json"),
                                           ("\(raw)/anticheat.json", "anticheat.json"), ("\(raw)/LICENSE", "LICENSE-games-CC0.txt"),
                                           ("\(raw)/derived/LICENSE", "LICENSE-derived-ODbL.txt"), ("\(raw)/anticheat.LICENSE", "LICENSE-anticheat-MIT.txt")]
        let folder = paths.compatibility
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (address, name) in sources {
            guard let url = URL(string: address) else { continue }
            let staged = folder.appendingPathComponent(".\(name).download")
            defer { try? FileManager.default.removeItem(at: staged) }
            try await download(url, to: staged)
            if name.hasSuffix(".json") {
                guard let object = (try? Data(contentsOf: staged)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                      let games = object["games"], (games as? [Any])?.count ?? (games as? [String: Any])?.count ?? 0 > 100 else {
                    throw PortnautError("The compatibility list (\(name)) did not download correctly. The previous copy is kept.")
                }
            }
            let target = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: target)
            }
        }
    }
}
