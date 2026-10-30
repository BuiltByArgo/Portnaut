import Foundation
import Darwin

/// A whole bottle at one moment: an APFS clone of its Windows environment plus its settings and games.
/// Clones share storage with the bottle, so a snapshot costs space only as either side changes.
public struct Snapshot: Codable, Equatable, Sendable, Identifiable {
    /// Also the folder name under Snapshots/<bottle>/.
    public var id: String
    public var label: String
    public var date: Date
    /// Taken by Portnaut before a change; the three newest of these are kept.
    public var automatic: Bool
    public var bottle: Bottle
}

/// A copy of the folders where Windows games keep their saves, in ~/Documents/Portnaut Backups.
public struct SaveBackup: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var date: Date
    public var bottleName: String
    /// Relative to drive_c.
    public var folders: [String]
    public var bytes: Int64
    public var files: Int
}

extension PortnautPaths {
    public func snapshots(of bottle: Bottle) -> URL { snapshots.appendingPathComponent(bottle.id) }
}

public enum SaveLocations {
    /// Where games keep saves, relative to drive_c. "*" is every Windows user of the bottle.
    static let folders = ["users/*/Documents", "users/*/Saved Games", "users/*/AppData/Roaming", "users/*/AppData/Local", "users/*/AppData/LocalLow",
                          "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/savegames", "Program Files (x86)/Steam/userdata"]
    /// Caches, logs and Windows' own folders, compared without letter case.
    static let skipped: Set<String> = ["temp", "tmp", "cache", "caches", "gpucache", "code cache", "shadercache", "dxcache", "d3dscache", "htmlcache",
                                       "crashdumps", "crashes", "crashpad", "logs", "microsoft", "packages", "nvidia", "steam", "ubisoft game launcher",
                                       "ea desktop", "origin", "cef", "webcache", "inetcache", "wine", "wine_gecko"]
    static func isSkipped(_ name: String) -> Bool { skipped.contains(name.lowercased()) }

    /// The save folders that exist in a bottle.
    public static func existing(in drive: URL) -> [String] {
        let fm = FileManager.default
        let users = ((try? fm.contentsOfDirectory(atPath: drive.appendingPathComponent("users").path)) ?? []).filter { !$0.hasPrefix(".") }
        return folders.flatMap { pattern -> [String] in
            pattern.contains("*") ? users.map { pattern.replacingOccurrences(of: "*", with: $0) } : [pattern]
        }.filter { relative in
            var directory: ObjCBool = false
            return fm.fileExists(atPath: drive.appendingPathComponent(relative).path, isDirectory: &directory) && directory.boolValue
                && (try? drive.appendingPathComponent(relative).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        }
    }
}

extension WineService {
    // MARK: - Snapshots

    public func snapshots(of bottle: Bottle) -> [Snapshot] {
        let folder = paths.snapshots(of: bottle)
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap { item in
            (try? Data(contentsOf: item.appendingPathComponent("snapshot.json"))).flatMap { try? Self.json.decoder.decode(Snapshot.self, from: $0) }
        }.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// Clones the bottle's Windows environment. Stop its session first, or files being written are caught halfway.
    @discardableResult
    public func takeSnapshot(of bottle: Bottle, label: String, automatic: Bool = false) throws -> Snapshot {
        let fm = FileManager.default
        let source = paths.bottle(bottle).prefix
        guard fm.fileExists(atPath: source.path) else { throw PortnautError("\(bottle.name) has no Windows environment to snapshot yet.") }
        let date = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var id = formatter.string(from: date), suffix = 2
        while fm.fileExists(atPath: paths.snapshots(of: bottle).appendingPathComponent(id).path) { id = formatter.string(from: date) + "-\(suffix)"; suffix += 1 }
        let folder = paths.snapshots(of: bottle).appendingPathComponent(id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard clonefile(source.path, folder.appendingPathComponent("prefix").path, 0) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: folder)
            throw PortnautError("Portnaut could not snapshot \(bottle.name) (\(reason)). Snapshots need Portnaut’s data folder on an APFS disk.")
        }
        let snapshot = Snapshot(id: id, label: label, date: date, automatic: automatic, bottle: (try? self.bottle(bottle.id)) ?? bottle)
        try Self.json.encoder.encode(snapshot).write(to: folder.appendingPathComponent("snapshot.json"), options: .atomic)
        if automatic { pruneAutomaticSnapshots(of: bottle) }
        return snapshot
    }

    /// Portnaut's own safety snapshots: the newest three stay, older ones are deleted.
    func pruneAutomaticSnapshots(of bottle: Bottle, keep: Int = 3) {
        for old in snapshots(of: bottle).filter(\.automatic).dropFirst(keep) {
            try? FileManager.default.removeItem(at: paths.snapshots(of: bottle).appendingPathComponent(old.id))
        }
    }

    /// Puts the bottle back as it was, settings and games included. Its current state is kept as an
    /// automatic snapshot first, so a restore can itself be undone.
    public func restoreSnapshot(_ snapshot: Snapshot, of bottle: Bottle) async throws {
        let fm = FileManager.default
        let source = paths.snapshots(of: bottle).appendingPathComponent(snapshot.id).appendingPathComponent("prefix")
        guard fm.fileExists(atPath: source.path) else { throw PortnautError("That snapshot is no longer in Portnaut’s data folder.") }
        try? await stop(bottle)
        let prefix = paths.bottle(bottle).prefix
        if fm.fileExists(atPath: prefix.path) {
            try takeSnapshot(of: bottle, label: "Before restoring “\(snapshot.label)”", automatic: true)
            try fm.removeItem(at: prefix)
        }
        guard clonefile(source.path, prefix.path, 0) == 0 else { throw PortnautError("Portnaut could not restore the snapshot (\(String(cString: strerror(errno)))).") }
        var restored = snapshot.bottle
        restored.id = bottle.id
        restored.name = (try? self.bottle(bottle.id).name) ?? bottle.name
        // Performance records are history, not state: keep the newer ones.
        let current = (try? self.bottle(bottle.id))?.games ?? []
        for index in restored.games.indices {
            if let now = current.first(where: { $0.id == restored.games[index].id }) { restored.games[index].performance = now.performance }
        }
        try save(restored)
    }

    /// Moves a snapshot to the Trash.
    public func deleteSnapshot(_ snapshot: Snapshot, of bottle: Bottle) throws {
        try FileManager.default.trashItem(at: paths.snapshots(of: bottle).appendingPathComponent(snapshot.id), resultingItemURL: nil)
    }

    // MARK: - Save backups

    public func saveBackups(of bottle: Bottle) -> [SaveBackup] {
        let folder = paths.saveBackups.appendingPathComponent(bottle.id)
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap { item in
            (try? Data(contentsOf: item.appendingPathComponent("backup.json"))).flatMap { try? Self.json.decoder.decode(SaveBackup.self, from: $0) }
        }.sorted { $0.date > $1.date }
    }

    /// Copies the bottle's save folders, without caches, logs and Windows' own data. On the same
    /// disk the files are APFS clones; Time Machine backs them up like other documents.
    @discardableResult
    public func backUpSaves(of bottle: Bottle) async throws -> SaveBackup {
        let drive = paths.bottle(bottle).drive
        let folders = SaveLocations.existing(in: drive)
        guard !folders.isEmpty else { throw PortnautError("\(bottle.name) has no save folders yet.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let date = Date()
        let destination = paths.saveBackups.appendingPathComponent(bottle.id).appendingPathComponent(formatter.string(from: date))
        let (files, bytes) = try await Task.detached { () -> (Int, Int64) in
            var files = 0, bytes: Int64 = 0
            for folder in folders {
                let counted = try Self.copyTree(from: drive.appendingPathComponent(folder), to: destination.appendingPathComponent("drive_c").appendingPathComponent(folder), skipping: SaveLocations.isSkipped)
                files += counted.0; bytes += counted.1
            }
            return (files, bytes)
        }.value
        let backup = SaveBackup(id: destination.lastPathComponent, date: date, bottleName: bottle.name, folders: folders, bytes: bytes, files: files)
        try Self.json.encoder.encode(backup).write(to: destination.appendingPathComponent("backup.json"), options: .atomic)
        return backup
    }

    /// Copies a backup's files back over the bottle's, after an automatic snapshot. Files the backup
    /// does not have are left alone.
    public func restoreSaves(_ backup: SaveBackup, to bottle: Bottle) async throws {
        let source = paths.saveBackups.appendingPathComponent(bottle.id).appendingPathComponent(backup.id).appendingPathComponent("drive_c")
        guard FileManager.default.fileExists(atPath: source.path) else { throw PortnautError("That backup is no longer in Portnaut Backups.") }
        try? await stop(bottle)
        try takeSnapshot(of: bottle, label: "Before restoring saves from \(backup.id)", automatic: true)
        let drive = paths.bottle(bottle).drive
        _ = try await Task.detached { try Self.copyTree(from: source, to: drive, skipping: { _ in false }, overwrite: true) }.value
    }

    /// Copies a folder tree file by file (as clones where the disk allows), skipping folders by name
    /// and never following symlinks. Returns files and bytes copied.
    static func copyTree(from source: URL, to destination: URL, skipping skip: (String) -> Bool, overwrite: Bool = false) throws -> (Int, Int64) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: keys, options: []) else { return (0, 0) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let base = source.standardizedFileURL.path
        var files = 0, bytes: Int64 = 0
        for case let item as URL in walker {
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            let relative = String(item.standardizedFileURL.path.dropFirst(base.count + 1))
            let target = destination.appendingPathComponent(relative)
            if values.isDirectory == true {
                if skip(item.lastPathComponent) { walker.skipDescendants() } else { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
                continue
            }
            if fm.fileExists(atPath: target.path) {
                guard overwrite else { continue }
                try fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: item, to: target)
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }

    static let json: (encoder: JSONEncoder, decoder: JSONDecoder) = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Fractions of a second keep snapshots taken in the same second in order.
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (encoder, decoder)
    }()
}
