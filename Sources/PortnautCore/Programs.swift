import Foundation

/// A program found inside a bottle that is not in the library yet.
public struct DetectedProgram: Equatable, Sendable, Identifiable {
    public enum Source: String, Sendable {
        case shortcut = "Start Menu or Desktop shortcut", steam = "Steam library", ea = "EA app library", ubisoft = "Ubisoft Connect games folder", known = "Known game"
        case epic = "Epic Games library", gog = "GOG game record", amazon = "Amazon Games library", rockstar = "Rockstar Games folder"
    }
    public var name: String
    /// Relative to drive_c.
    public var executable: String
    public var arguments: [String] = []
    public var launcherArguments: [String]?
    public var source: Source
    /// From a launcher's own record or a known game, so safe to add without asking.
    public var reliable = false
    public var id: String { executable.lowercased() + (launcherArguments.map { " " + $0.joined(separator: " ") } ?? "") }
    public init(name: String, executable: String, arguments: [String] = [], launcherArguments: [String]? = nil, source: Source) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.launcherArguments = launcherArguments
        self.source = source
    }
}

/// Finds a bottle's installed programs: from shortcuts that installers create, and from the
/// launchers' own records of the games they installed.
public enum ProgramScanner {
    /// Every program found in the drive, without duplicates. Launchers themselves are left out:
    /// a bottle starts its launcher from its own button. `reliableOnly` skips shortcuts and guesses,
    /// and Steam apps already in the library, for the cheap scan Portnaut repeats while it runs.
    public static func scan(drive: URL, reliableOnly: Bool = false, steamAppsInLibrary: Set<String> = []) -> [DetectedProgram] {
        var seen = Set<String>(), found: [DetectedProgram] = []
        let candidates = steamGames(drive: drive, excluding: steamAppsInLibrary) + eaGames(drive: drive, listedOnly: reliableOnly)
            + ubisoftGames(drive: drive, knownOnly: reliableOnly) + epicGames(drive: drive) + gogGames(drive: drive) + amazonGames(drive: drive)
            + (reliableOnly ? [] : rockstarGames(drive: drive) + shortcuts(drive: drive))
        for program in candidates where Launcher.owning(program.executable) == nil && seen.insert(program.executable.lowercased()).inserted {
            found.append(program)
        }
        return found
    }

    // MARK: Shortcuts

    static func shortcutFolders(drive: URL) -> [URL] {
        var folders = [drive.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")]
        for user in (try? FileManager.default.contentsOfDirectory(at: drive.appendingPathComponent("users"), includingPropertiesForKeys: nil)) ?? [] {
            folders.append(user.appendingPathComponent("Desktop"))
            folders.append(user.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
        }
        return folders
    }

    /// Programs behind the .lnk files in the Start Menu and on the Desktops, helpers left out.
    public static func shortcuts(drive: URL, includeHelpers: Bool = false) -> [DetectedProgram] {
        var found: [DetectedProgram] = []
        for folder in shortcutFolders(drive: drive) {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in walker {
                if walker.level > 4 { walker.skipDescendants(); continue }
                guard file.pathExtension.lowercased() == "lnk", let data = try? Data(contentsOf: file), let link = ShellLink(data) else { continue }
                let name = file.deletingPathExtension().lastPathComponent
                guard let target = link.target(relativeTo: file, drive: drive), target.lowercased().hasSuffix(".exe"),
                      !target.lowercased().hasPrefix("windows/"), FileManager.default.fileExists(atPath: drive.appendingPathComponent(target).path),
                      includeHelpers || !(isHelper(name) || isHelper((target as NSString).lastPathComponent)) else { continue }
                found.append(DetectedProgram(name: name, executable: target, arguments: link.arguments.map(splitCommandLine) ?? [], source: .shortcut))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Launcher libraries

    static let steamRoot = "Program Files (x86)/Steam"

    /// Installed Steam apps from steamapps/appmanifest_*.acf in every library folder on drive C:.
    /// They start through Steam, which handles launch options and DRM.
    public static func steamGames(drive: URL, excluding appIDs: Set<String> = []) -> [DetectedProgram] {
        var libraries = [steamRoot]
        if let vdf = try? String(contentsOf: drive.appendingPathComponent(steamRoot + "/steamapps/libraryfolders.vdf"), encoding: .utf8) {
            for path in values(of: "path", in: vdf) {
                if let relative = relativePath(fromWindows: path.replacingOccurrences(of: "\\\\", with: "\\")), !libraries.contains(where: { $0.caseInsensitiveCompare(relative) == .orderedSame }) {
                    libraries.append(relative)
                }
            }
        }
        var found: [DetectedProgram] = []
        for library in libraries {
            let apps = drive.appendingPathComponent(library + "/steamapps")
            for manifest in (try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? []
            where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8), let app = SteamApp(manifest: text) else { continue }
                // 228980 is Steamworks Common Redistributables. StateFlags 4 is fully installed.
                guard app.id != "228980", app.installed, !appIDs.contains(app.id) else { continue }
                let folder = apps.appendingPathComponent("common/\(app.installDirectory)")
                guard let executable = mainExecutable(in: folder, name: app.name), let relative = try? BottlePaths.relative(executable, drive: drive) else { continue }
                var program = DetectedProgram(name: app.name, executable: relative, launcherArguments: ["-applaunch", app.id], source: .steam)
                program.reliable = true
                found.append(program)
            }
        }
        return found
    }

    /// Steam apps queued or downloading, not installed yet: Steam writes an app's manifest when its
    /// download starts, so a game that cannot run can be named before it finishes.
    public static func steamDownloads(drive: URL) -> [(appID: Int, name: String)] {
        var libraries = [steamRoot]
        if let vdf = try? String(contentsOf: drive.appendingPathComponent(steamRoot + "/steamapps/libraryfolders.vdf"), encoding: .utf8) {
            libraries += values(of: "path", in: vdf).compactMap { relativePath(fromWindows: $0.replacingOccurrences(of: "\\\\", with: "\\")) }
        }
        var found: [(Int, String)] = [], seen = Set<Int>()
        for library in libraries {
            let apps = drive.appendingPathComponent(library + "/steamapps")
            for manifest in (try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? []
            where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8), let app = SteamApp(manifest: text),
                      !app.installed, app.id != "228980", let id = Int(app.id), seen.insert(id).inserted else { continue }
                found.append((id, app.name))
            }
        }
        return found
    }

    struct SteamApp {
        var id: String, name: String, installDirectory: String, installed: Bool
        init?(manifest: String) {
            guard let id = ProgramScanner.values(of: "appid", in: manifest).first, let name = ProgramScanner.values(of: "name", in: manifest).first,
                  let folder = ProgramScanner.values(of: "installdir", in: manifest).first, !folder.contains("..") else { return nil }
            self.id = id; self.name = name; self.installDirectory = folder
            installed = (Int(ProgramScanner.values(of: "StateFlags", in: manifest).first ?? "") ?? 0) & 4 != 0
        }
    }

    /// Values of a key in Valve's text format: "key"  "value".
    static func values(of key: String, in text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s+\"((?:[^\"\\\\]|\\\\.)*)\"", options: [.caseInsensitive]) else { return [] }
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    /// Games the EA app installed, from each game's __Installer/installerdata.xml.
    public static func eaGames(drive: URL, listedOnly: Bool = false) -> [DetectedProgram] {
        var found: [DetectedProgram] = []
        for root in Launcher.ea.gameFolders {
            for folder in (try? FileManager.default.contentsOfDirectory(at: drive.appendingPathComponent(root), includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                let manifest = (try? String(contentsOf: folder.appendingPathComponent("__Installer/installerdata.xml"), encoding: .utf8)).flatMap(EAManifest.init)
                let name = manifest?.title ?? folder.lastPathComponent
                let listed = manifest?.executable.map { folder.appendingPathComponent($0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                guard let executable = listed ?? (listedOnly ? nil : mainExecutable(in: folder, name: name)),
                      let relative = try? BottlePaths.relative(executable, drive: drive) else { continue }
                var program = DetectedProgram(name: name, executable: relative, source: .ea)
                program.reliable = listed != nil
                found.append(program)
            }
        }
        return found
    }

    struct EAManifest {
        var title: String?
        /// Relative to the game's folder, with the registry prefix removed.
        var executable: String?
        init?(_ xml: String) {
            func first(_ pattern: String, in text: String) -> String? {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            title = (first("<gameTitle[^>]*locale=\"en_US\"[^>]*>(.*?)</gameTitle>", in: xml) ?? first("<gameTitle[^>]*>(.*?)</gameTitle>", in: xml)).map(Self.unescape)
            let runtime = first("<runtime>(.*?)</runtime>", in: xml) ?? xml
            if let path = first("<filePath>(.*?)</filePath>", in: runtime).map(Self.unescape) {
                let file = path.replacingOccurrences(of: "^\\[[^\\]]*\\]", with: "", options: .regularExpression).replacingOccurrences(of: "\\", with: "/")
                if !file.isEmpty, !file.contains(":"), !file.split(separator: "/").contains("..") { executable = file }
            }
            if title == nil && executable == nil { return nil }
        }
        static func unescape(_ text: String) -> String {
            [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")].reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        }
    }

    /// Ubisoft Connect keeps no plain record of a game's program: known games are found by their
    /// program, the others in its games folder get the heuristic.
    public static func ubisoftGames(drive: URL, knownOnly: Bool = false) -> [DetectedProgram] {
        var found: [DetectedProgram] = []
        for (index, root) in Launcher.ubisoft.gameFolders.enumerated() {
            for folder in (try? FileManager.default.contentsOfDirectory(at: drive.appendingPathComponent(root), includingPropertiesForKeys: nil)) ?? [] {
                if let known = KnownGame.all.first(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.executable).path) }),
                   let relative = try? BottlePaths.relative(folder.appendingPathComponent(known.executable), drive: drive) {
                    var program = DetectedProgram(name: known.title, executable: relative, source: .known)
                    program.reliable = true
                    found.append(program)
                } else if !knownOnly, index == 0, let executable = mainExecutable(in: folder, name: folder.lastPathComponent),
                          let relative = try? BottlePaths.relative(executable, drive: drive) {
                    found.append(DetectedProgram(name: folder.lastPathComponent, executable: relative, source: .ubisoft))
                }
            }
        }
        return found
    }

    /// Games the Epic Games Launcher installed, from its manifests. They start through the launcher,
    /// which signs the game in to Epic's online services.
    public static func epicGames(drive: URL) -> [DetectedProgram] {
        let manifests = drive.appendingPathComponent("ProgramData/Epic/EpicGamesLauncher/Data/Manifests")
        var found: [DetectedProgram] = []
        for file in ((try? FileManager.default.contentsOfDirectory(at: manifests, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
        where file.pathExtension.lowercased() == "item" {
            guard let data = try? Data(contentsOf: file), let item = EpicManifest(data) else { continue }
            let folder = drive.appendingPathComponent(item.installFolder)
            guard let executable = item.executable.map({ folder.appendingPathComponent($0) }) ?? mainExecutable(in: folder, name: item.name),
                  FileManager.default.fileExists(atPath: executable.path), let relative = try? BottlePaths.relative(executable, drive: drive) else { continue }
            var program = DetectedProgram(name: item.name, executable: relative, launcherArguments: [item.launchURI], source: .epic)
            program.reliable = true
            found.append(program)
        }
        return found
    }

    struct EpicManifest {
        var name: String, installFolder: String, executable: String?, launchURI: String
        init?(_ data: Data) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["DisplayName"] as? String, let location = (json["InstallLocation"] as? String).flatMap(ProgramScanner.relativePath(fromWindows:)),
                  let app = json["AppName"] as? String, let namespace = json["CatalogNamespace"] as? String, let item = json["CatalogItemId"] as? String,
                  json["bIsIncompleteInstall"] as? Bool != true else { return nil }
            // Add-ons have manifests of their own, naming the game they belong to.
            if let main = json["MainGameAppName"] as? String, !main.isEmpty, main != app { return nil }
            self.name = name
            installFolder = location
            let launch = (json["LaunchExecutable"] as? String)?.replacingOccurrences(of: "\\", with: "/")
            executable = launch.flatMap { $0.isEmpty || $0.contains(":") || $0.split(separator: "/").contains("..") ? nil : $0 }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            func encoded(_ part: String) -> String { part.addingPercentEncoding(withAllowedCharacters: allowed) ?? part }
            launchURI = "com.epicgames.launcher://apps/\(encoded(namespace))%3A\(encoded(item))%3A\(encoded(app))?action=launch&silent=true"
        }
    }

    /// GOG games, installed by GOG Galaxy or GOG's offline installers, from their goggame-*.info
    /// records. They are DRM-free and start directly.
    public static func gogGames(drive: URL) -> [DetectedProgram] {
        var found: [DetectedProgram] = []
        for root in Launcher.gog.gameFolders {
            for folder in (try? FileManager.default.contentsOfDirectory(at: drive.appendingPathComponent(root), includingPropertiesForKeys: nil)) ?? [] {
                let records = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.lowercased().hasPrefix("goggame-") && $0.lowercased().hasSuffix(".info") }
                guard let record = records.sorted().lazy.compactMap({ (try? Data(contentsOf: folder.appendingPathComponent($0))).flatMap(GOGRecord.init) }).first,
                      FileManager.default.fileExists(atPath: folder.appendingPathComponent(record.executable).path),
                      let relative = try? BottlePaths.relative(folder.appendingPathComponent(record.executable), drive: drive) else { continue }
                var program = DetectedProgram(name: record.name, executable: relative, arguments: record.arguments, source: .gog)
                program.reliable = true
                found.append(program)
            }
        }
        return found
    }

    struct GOGRecord {
        var name: String, executable: String, arguments: [String]
        init?(_ data: Data) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = json["name"] as? String,
                  let tasks = json["playTasks"] as? [[String: Any]] else { return nil }
            let files = tasks.filter { ($0["type"] as? String ?? "FileTask") == "FileTask" && $0["path"] is String }
            guard let task = files.first(where: { $0["isPrimary"] as? Bool == true }) ?? files.first,
                  let path = (task["path"] as? String)?.replacingOccurrences(of: "\\", with: "/"),
                  path.lowercased().hasSuffix(".exe"), !path.contains(":"), !path.split(separator: "/").contains("..") else { return nil }
            self.name = name
            executable = path
            arguments = (task["arguments"] as? String).map(ProgramScanner.splitCommandLine) ?? []
        }
    }

    /// Games the Amazon Games app installed, from each game's fuel.json.
    public static func amazonGames(drive: URL) -> [DetectedProgram] {
        var found: [DetectedProgram] = []
        for root in Launcher.amazon.gameFolders {
            for folder in (try? FileManager.default.contentsOfDirectory(at: drive.appendingPathComponent(root), includingPropertiesForKeys: nil)) ?? [] {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("fuel.json")),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let main = json["Main"] as? [String: Any],
                      let command = (main["Command"] as? String)?.replacingOccurrences(of: "\\", with: "/"),
                      command.lowercased().hasSuffix(".exe"), !command.contains(":"), !command.split(separator: "/").contains(".."),
                      FileManager.default.fileExists(atPath: folder.appendingPathComponent(command).path),
                      let relative = try? BottlePaths.relative(folder.appendingPathComponent(command), drive: drive) else { continue }
                var program = DetectedProgram(name: folder.lastPathComponent, executable: relative, arguments: main["Args"] as? [String] ?? [], source: .amazon)
                program.reliable = true
                found.append(program)
            }
        }
        return found
    }

    /// Rockstar keeps no plain record of its games: each folder beside the launcher's own gets the
    /// heuristic. Rockstar's games start the launcher themselves when they need it.
    public static func rockstarGames(drive: URL) -> [DetectedProgram] {
        var found: [DetectedProgram] = []
        for root in Launcher.rockstar.gameFolders {
            for folder in (try? FileManager.default.contentsOfDirectory(at: drive.appendingPathComponent(root), includingPropertiesForKeys: nil)) ?? []
            where !["launcher", "social club"].contains(folder.lastPathComponent.lowercased()) {
                guard let executable = mainExecutable(in: folder, name: folder.lastPathComponent),
                      let relative = try? BottlePaths.relative(executable, drive: drive) else { continue }
                found.append(DetectedProgram(name: folder.lastPathComponent, executable: relative, source: .rockstar))
            }
        }
        return found
    }

    // MARK: Heuristics

    /// File and shortcut names of uninstallers, redistributables, crash reporters and launcher helpers.
    static let helperMarkers = ["unins", "uninstall", "setup", "redist", "vcredist", "vc_redist", "dxsetup", "dxwebsetup", "dotnet", "ndp4", "physx",
                                "prereq", "crashhandler", "crashreport", "crashpad", "crash_reporter", "crashsender", "bugreport", "reporter", "updater", "autoupdate", "easyanticheat", "eac_launcher", "beservice", "battleye",
                                "cefprocess", "qtwebengineprocess", "steamwebhelper", "steamerrorreporter", "unitycrashhandler", "touchup", "cleanup",
                                "activation", "readme", "manual", "website", "support", "register", "dxdiag", "vulkan", "oalinst"]
    public static func isHelper(_ name: String) -> Bool {
        let lower = name.lowercased()
        return helperMarkers.contains { lower.contains($0) }
    }
    /// Folders that hold installers and runtimes rather than the game.
    static let skippedFolders: Set<String> = ["redist", "_commonredist", "commonredist", "redistributables", "directx", "dotnet", "vcredist", "__installer",
                                              "installer", "installers", "prereqs", "prerequisites", "easyanticheat", "battleye", "thirdparty", "support", "crashreportclient"]

    /// The program a game folder most likely starts: an Unreal shipping binary, then a name like the
    /// game's, then the largest, preferring shallow 64-bit programs. Looks at most four levels down.
    public static func mainExecutable(in folder: URL, name: String) -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let wanted = alphanumerics(name)
        var best: (score: Int, size: Int, url: URL)?
        var visited = 0
        for case let file as URL in walker {
            visited += 1
            if visited > 20_000 { break }
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if walker.level >= 4 || skippedFolders.contains(file.lastPathComponent.lowercased()) { walker.skipDescendants() }
                continue
            }
            let fileName = file.lastPathComponent.lowercased()
            guard fileName.hasSuffix(".exe"), !isHelper(fileName), let architecture = try? PEImage.wineArchitecture(of: file) else { continue }
            let stem = alphanumerics(file.deletingPathExtension().lastPathComponent)
            var score = 0
            if fileName.hasSuffix("-win64-shipping.exe") || fileName.hasSuffix("-wingdk-shipping.exe") { score += 40 }
            if file.path.lowercased().contains("/binaries/win64/") { score += 10 }
            if !wanted.isEmpty, !stem.isEmpty {
                if stem == wanted { score += 30 } else if min(stem.count, wanted.count) >= 3, stem.contains(wanted) || wanted.contains(stem) { score += 20 }
            }
            if fileName.contains("launcher") { score -= 8 }
            if architecture == "x86_64-windows" { score += 5 }
            score -= walker.level * 3
            let size = values?.fileSize ?? 0
            if best == nil || score > best!.score || (score == best!.score && size > best!.size) { best = (score, size, file) }
        }
        return best?.url
    }

    static func alphanumerics(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    /// "C:\Program Files\Game\game.exe" relative to drive_c; nil for other drives or escapes.
    public static func relativePath(fromWindows path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        guard trimmed.count > 3, trimmed.lowercased().hasPrefix("c:\\") || trimmed.lowercased().hasPrefix("c:/") else { return nil }
        let parts = trimmed.dropFirst(3).split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }

    /// The reverse of `splitCommandLine`, for showing arguments as one line.
    public static func joinCommandLine(_ arguments: [String]) -> String {
        arguments.map { $0.isEmpty || $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// Splits arguments as Windows programs do: spaces separate, double quotes group.
    public static func splitCommandLine(_ line: String) -> [String] {
        var result: [String] = [], current = "", quoted = false, started = false
        for character in line {
            if character == "\"" { quoted.toggle(); started = true }
            else if character == " " && !quoted { if started { result.append(current); current = ""; started = false } }
            else { current.append(character); started = true }
        }
        if started { result.append(current) }
        return result
    }
}

/// The parts of a Windows shortcut (MS-SHLLINK) Portnaut needs: target path and arguments.
public struct ShellLink: Equatable {
    public var localPath: String?
    public var relativePath: String?
    public var workingDirectory: String?
    public var arguments: String?

    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int? { offset + 2 <= bytes.count ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 : nil }
        func u32(_ offset: Int) -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            return (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        func ansi(_ offset: Int) -> String? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            return String(bytes: bytes[offset..<end], encoding: .windowsCP1252)
        }
        func wide(_ offset: Int) -> String? {
            var units: [UInt16] = [], index = offset
            while let unit = u16(index), unit != 0 { units.append(UInt16(unit)); index += 2 }
            return u16(index) == nil ? nil : String(decoding: units, as: UTF16.self)
        }
        // Header size and the shell link class ID 00021401-0000-0000-C000-000000000046.
        guard u32(0) == 0x4C, bytes.count >= 0x4C, Array(bytes[4..<20]) == [0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46],
              let flags = u32(0x14) else { return nil }
        var offset = 0x4C
        if flags & 0x1 != 0 {
            guard let size = u16(offset) else { return nil }
            offset += 2 + size
        }
        if flags & 0x2 != 0 {
            guard let size = u32(offset), let headerSize = u32(offset + 4), let infoFlags = u32(offset + 8) else { return nil }
            if infoFlags & 0x1 != 0 {
                let suffix = u32(offset + 24).flatMap { ansi(offset + $0) } ?? ""
                if headerSize >= 0x24, let unicode = u32(offset + 28), unicode > 0, let path = wide(offset + unicode) {
                    localPath = path + (u32(offset + 32).flatMap { $0 > 0 ? wide(offset + $0) : nil } ?? "")
                } else if let base = u32(offset + 16).flatMap({ ansi(offset + $0) }) {
                    localPath = base + suffix
                }
            }
            offset += size
        }
        let unicode = flags & 0x80 != 0
        func string() -> String? {
            guard let count = u16(offset) else { return nil }
            let length = count * (unicode ? 2 : 1)
            guard offset + 2 + length <= bytes.count else { return nil }
            let slice = Array(bytes[(offset + 2)..<(offset + 2 + length)])
            offset += 2 + length
            if unicode { return String(decoding: stride(from: 0, to: slice.count, by: 2).map { UInt16(slice[$0]) | UInt16(slice[$0 + 1]) << 8 }, as: UTF16.self) }
            return String(bytes: slice, encoding: .windowsCP1252)
        }
        if flags & 0x4 != 0 { _ = string() }
        if flags & 0x8 != 0 { relativePath = string() }
        if flags & 0x10 != 0 { workingDirectory = string() }
        if flags & 0x20 != 0 { arguments = string() }
        if localPath == nil && relativePath == nil { return nil }
    }

    /// The target relative to drive_c: the local path, else the relative path from the shortcut's folder.
    public func target(relativeTo shortcut: URL, drive: URL) -> String? {
        if let localPath, let relative = ProgramScanner.relativePath(fromWindows: localPath) { return relative }
        guard let relativePath else { return nil }
        let url = shortcut.deletingLastPathComponent().appendingPathComponent(relativePath.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL
        return try? BottlePaths.relative(url, drive: drive)
    }
}
