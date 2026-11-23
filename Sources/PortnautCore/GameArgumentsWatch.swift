import CoreServices
import Foundation

/// Watches a profile bottle's prefix while a program Portnaut started there runs, so the game's arguments are in
/// place before the game can start, even when the launcher installs it during that session (its first Play) or
/// in a folder the user chose. The producer is the bottle's Wine: the launcher's installer creating the game's
/// executable, anything rewriting commandline.txt, and the Wine server saving system.reg (where the launcher
/// records the install folder). `changed` gets every folder seen so far to hold the game's executable, after each
/// batch that names the executable, commandline.txt or system.reg, or creates or moves in a folder (an installer
/// can move a whole tree into place: its subtree is searched for the executable), and after a batch whose events
/// were dropped or coalesced (the whole prefix is searched once); it runs on the watch's own serial queue. The
/// stream's latency is 0: Portnaut writes as soon as it is told.
final class GameArgumentsWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var seen: [URL] = []
    private let queue = DispatchQueue(label: "Portnaut.GameArgumentsWatch")
    private let changed: ([URL]) -> Void
    private let prefix: URL

    /// Every folder seen to hold the game's executable during the watch.
    var folders: [URL] { lock.withLock { seen } }

    init(prefix: URL, changed: @escaping ([URL]) -> Void) throws {
        self.changed = changed
        // As FSEvents reports paths (/var is /private/var), so a folder found by a search is the same one an event names.
        self.prefix = prefix.resolvingSymlinksInPath()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watch = Unmanaged<GameArgumentsWatch>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watch.handle(list, Array(UnsafeBufferPointer(start: flags, count: count)))
        }, &context, [prefix.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, flags) else {
            throw PortnautError("Portnaut could not watch \(prefix.lastPathComponent) for the game's files.")
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw PortnautError("Portnaut could not watch \(prefix.lastPathComponent) for the game's files.")
        }
        self.stream = stream
    }

    /// Delivers the events that occurred so far, then ends the watch; no `changed` runs once it returns. Later
    /// calls do nothing. Never called on the watch's queue.
    func stop() {
        guard let stream = lock.withLock({ () -> FSEventStreamRef? in
            defer { self.stream = nil }
            return self.stream
        }) else { return }
        FSEventStreamFlushSync(stream)
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // A delivery already handed to the queue still runs: wait for it, so none outlives the watch.
        queue.sync {}
    }
    deinit { stop() }

    /// A folder created, or moved in or out, in the prefix.
    static let folderArrivalFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)
    static let folderMoveFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
    /// Events whose paths say nothing reliable: everything below them has to be looked at again.
    static let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)

    private func handle(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        var relevant = false
        var candidates: [URL] = []
        if flags.contains(where: { $0 & Self.rescanFlags != 0 }) {
            // What was lost is not bounded by the event's path: search the whole prefix, once.
            relevant = true
            candidates += Self.gameFolders(below: prefix)
        }
        for (path, flag) in zip(paths, flags) where flag & Self.rescanFlags == 0 {
            let url = URL(fileURLWithPath: path)
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                // Only a folder that arrives can bring the game; a folder's other events are not a file's.
                if flag & Self.folderArrivalFlags == Self.folderArrivalFlags || flag & Self.folderMoveFlags == Self.folderMoveFlags {
                    relevant = true
                    candidates += Self.gameFolders(below: url)
                }
                continue
            }
            switch url.lastPathComponent.lowercased() {
            case EngineProfile.gameExecutable.lowercased(), "commandline.txt":
                candidates.append(url.deletingLastPathComponent())
                relevant = true
            case "system.reg":
                relevant = true
            default:
                break
            }
        }
        guard relevant else { return }
        let found = candidates.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(EngineProfile.gameExecutable).path) }
        let all = lock.withLock {
            for folder in found where !seen.contains(where: { $0.path == folder.path }) { seen.append(folder) }
            return seen
        }
        changed(all)
    }

    /// The folders below `root` (itself included) that hold the game's executable. Links are not followed, so
    /// drive Z: (a link to /) is not searched.
    static func gameFolders(below root: URL) -> [URL] {
        let name = EngineProfile.gameExecutable.lowercased()
        var folders: [URL] = []
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(EngineProfile.gameExecutable).path) { folders.append(root) }
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return folders }
        for case let file as URL in files where file.lastPathComponent.lowercased() == name {
            folders.append(file.deletingLastPathComponent())
        }
        return folders
    }
}
