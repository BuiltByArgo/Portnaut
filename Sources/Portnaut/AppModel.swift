import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GameController
import PortnautCore

enum Page: String, CaseIterable {
    case library = "Library", bottles = "Bottles", setup = "Setup", diagnostics = "Diagnostics", about = "About"
}

/// An installer the user chose or dropped, waiting for a bottle.
struct PendingInstall: Identifiable {
    let id = UUID()
    var file: URL
    /// The bottle to suggest; nil suggests the selected one.
    var bottleID: String?
}

enum InstallTarget: Equatable {
    case existing(String)
    case new(name: String, renderer: Renderer, windows: WindowsVersion)
}

/// Programs found in a bottle, offered for the library with their analyses.
struct ProgramChoice: Identifiable {
    let id = UUID()
    var bottleID: String
    var programs: [DetectedProgram]
    var analyses: [String: GraphicsAnalysis]
    /// Shown right after an installer finished.
    var afterInstall: Bool
}

/// A controller connected to the Mac, from the GameController framework.
struct MacController: Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String
    var battery: String?
}

/// A game together with the bottle it lives in.
struct LibraryEntry: Identifiable, Equatable {
    var game: Game
    var bottle: Bottle
    var id: String { "\(bottle.id)/\(game.id)" }
}

@MainActor
final class AppModel: ObservableObject {
    let service = WineService()
    @Published var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "PortnautInitialPage") ?? "") ?? .library
    @Published var library = Library()
    @Published var selectedBottleID: String? = UserDefaults.standard.string(forKey: "PortnautInitialBottle")
    @Published var selectedEntryID: String?
    @Published var busy = false
    @Published var progress = 0.0
    @Published var message = "A few steps to your first game."
    @Published var error: String?
    /// Bottles with a Windows session running.
    @Published var sessions: Set<String> = []
    @Published var runtimeReady = false
    @Published var runtimeOutdated = false
    @Published var readyBottles: Set<String> = []
    @Published var installedLaunchers: Set<String> = []
    @Published var recommendations: [String: Recommendation] = [:]
    /// Keyed by LibraryEntry.id; read from the game's files once per executable path.
    @Published var analyses: [String: GraphicsAnalysis] = [:]
    @Published var logText = "No activity yet. Prepare Portnaut to get started."
    @Published var freeSpace = ""
    @Published var showingNewBottle = false
    @Published var pendingInstall: PendingInstall?
    @Published var programChoice: ProgramChoice?
    @Published var editingGame: LibraryEntry?
    @Published var editingEnvironment: Bottle?
    @Published var macControllers: [MacController] = []
    @Published var snapshots: [String: [Snapshot]] = [:]
    @Published var showingUpdates = false
    @Published var updateCheck: UpdateCheck?
    @Published var checkingUpdates = false
    @Published var updateCheckError: String?
    @Published var installedRuntime: InstalledRuntime?
    @Published var previousRuntime: InstalledRuntime?
    /// Kept in Portnaut's data folder, shared with portnaut-doctor.
    @Published var updateChannel: UpdateChannel = .stable { didSet { service.updateChannel = updateChannel } }
    @Published var saveBackups: [String: [SaveBackup]] = [:]
    /// The bottle a snapshot is being named for.
    @Published var namingSnapshot: Bottle?
    @Published var snapshotName = ""
    @Published var bottlePendingRemoval: Bottle?
    /// Highball's compatibility database, read once in the background and after Component Updates.
    @Published var compatibility: CompatibilityDatabase?
    /// Keyed by LibraryEntry.id.
    @Published var reports: [String: CompatibilityReport] = [:]
    @Published var showingWillItRun = false
    @Published var willItRunQuery = ""
    /// A Steam download of a game that cannot run, named once per game.
    @Published var downloadWarning: String?
    /// Couch mode: the library full screen, for a controller and a TV.
    @Published var couchMode = false
    @Published var couchIndex = 0
    /// Y pressed once while a game runs; a second press within three seconds stops the session.
    @Published var couchStopArmed = false
    var couchKeyMonitor: Any?
    /// Bottles whose running session is a best-setup round.
    @Published var roundSessions: Set<String> = []
    var couchStick = StickRepeat()
    var couchEnteredFullScreen = false
    private var analyzedPaths: [String: String] = [:]
    private var stopRequested: Set<String> = []
    /// Detection retries stop after one failure so the alert is not repeated every refresh.
    private var autoRegistrationFailed = false

    var entries: [LibraryEntry] {
        library.bottles.flatMap { bottle in bottle.games.map { LibraryEntry(game: $0, bottle: bottle) } }
            .sorted { ($0.game.lastPlayedAt ?? .distantPast, $1.game.name) > ($1.game.lastPlayedAt ?? .distantPast, $0.game.name) }
    }
    var selectedEntry: LibraryEntry? { entries.first { $0.id == selectedEntryID } ?? entries.first }
    var selectedBottle: Bottle? { library.bottles.first { $0.id == selectedBottleID } ?? library.bottles.first }
    func sessionActive(_ bottle: Bottle) -> Bool { sessions.contains(bottle.id) }
    func ready(_ bottle: Bottle) -> Bool { readyBottles.contains(bottle.id) }

    init() {
        refresh()
        loadCompatibility()
        updateChannel = service.updateChannel
        // Launch argument for checking the window: -PortnautShowUpdates YES
        if UserDefaults.standard.bool(forKey: "PortnautShowUpdates") { openComponentUpdates() }
        // Launch argument for checking the sheet: -PortnautShowWillItRun "<title>"
        if let query = UserDefaults.standard.string(forKey: "PortnautShowWillItRun") { willItRunQuery = query; showingWillItRun = true }
        // Launch argument for checking the sheet: -PortnautShowNewBottle YES
        showingNewBottle = UserDefaults.standard.bool(forKey: "PortnautShowNewBottle")
        // Launch argument for checking the sheet: -PortnautInitialGameSettings <game id>
        if let id = UserDefaults.standard.string(forKey: "PortnautInitialGameSettings") { editingGame = entries.first { $0.game.id == id } }
        updateControllers()
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateControllers() }
            }
        }
        for controller in GCController.controllers() { attachCouchControls(controller) }
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.controllerConnected(controller) }
        }
        // Launch argument for checking the view: -PortnautCouchMode YES
        if UserDefaults.standard.bool(forKey: "PortnautCouchMode") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in MainActor.assumeIsolated { self?.enterCouchMode() } }
        }
        // Reattach to sessions that survived closing Portnaut. -w never starts Wine.
        if runtimeReady {
            for bottle in library.bottles where ready(bottle) { watchSession(bottle) }
        }
    }

    func refresh() {
        let paths = service.paths
        runtimeReady = paths.runtimeReady
        runtimeOutdated = paths.runtimeOutdated
        if let loaded = try? paths.loadLibrary() { library = loaded }
        readyBottles = Set(library.bottles.filter { paths.bottle($0).ready }.map(\.id))
        installedLaunchers = Set(library.bottles.filter { service.launcherInstalled($0) }.map(\.id))
        if runtimeReady, !autoRegistrationFailed {
            for bottle in library.bottles where ready(bottle) {
                do { try service.addInstalledGames(in: bottle) } catch { autoRegistrationFailed = true; self.error = error.localizedDescription }
            }
            if let reloaded = try? paths.loadLibrary() { library = reloaded }
        }
        for entry in entries where analyzedPaths[entry.id] != entry.game.executable {
            analyzedPaths[entry.id] = entry.game.executable
            analyses[entry.id] = service.analyze(entry.game, in: entry.bottle)
        }
        recommendations = Dictionary(uniqueKeysWithValues: library.bottles.map { bottle in
            (bottle.id, GraphicsAdvisor.recommendation(for: bottle, analyses: bottle.games.compactMap { analyses["\(bottle.id)/\($0.id)"] }))
        })
        installedRuntime = service.installedRuntime()
        previousRuntime = service.previousRuntime()
        snapshots = Dictionary(uniqueKeysWithValues: library.bottles.map { ($0.id, service.snapshots(of: $0)) })
        saveBackups = Dictionary(uniqueKeysWithValues: library.bottles.map { ($0.id, service.saveBackups(of: $0)) })
        updateReports()
        warnAboutSteamDownloads()
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()), let free = attributes[.systemFreeSize] as? NSNumber {
            freeSpace = ByteCountFormatter.string(fromByteCount: free.int64Value, countStyle: .file)
        }
    }
    func update(_ value: SetupProgress) { progress = value.fraction; message = value.message }

    // MARK: - Compatibility

    /// Reads the newer of the bundled and downloaded databases off the main thread.
    func loadCompatibility() {
        Task {
            compatibility = await Task.detached { [service] in service.compatibilityDatabase() }.value
            updateReports()
        }
    }
    private func updateReports() {
        reports = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            service.compatibilityReport(for: entry.game, in: entry.bottle, database: compatibility).map { (entry.id, $0) }
        })
    }
    /// Steam writes a game's manifest when its download starts: a game that cannot run is named
    /// then, once, rather than after the download.
    private func warnAboutSteamDownloads() {
        guard let compatibility, downloadWarning == nil else { return }
        var warned = Set(UserDefaults.standard.array(forKey: "PortnautWarnedDownloads") as? [Int] ?? [])
        for bottle in library.bottles where bottle.launcher == .steam && ready(bottle) {
            for download in ProgramScanner.steamDownloads(drive: service.paths.bottle(bottle).drive) where !warned.contains(download.appID) {
                guard let report = compatibility.report(steamAppID: download.appID, title: download.name), report.status == .blocked else { continue }
                warned.insert(download.appID)
                UserDefaults.standard.set(Array(warned), forKey: "PortnautWarnedDownloads")
                downloadWarning = "Steam is downloading \(download.name) in \(bottle.name). \(report.explanation) You can cancel the download in Steam’s Downloads page."
                return
            }
        }
    }

    /// Runs a setup task with the progress bar; refreshes afterwards.
    private func perform(_ status: String, _ work: @escaping () async throws -> String) {
        guard !busy else { return }
        busy = true; progress = 0; message = status
        Task {
            do { message = try await work() }
            catch { self.error = error.localizedDescription; message = "That needs attention. You can retry safely." }
            busy = false; refresh()
        }
    }

    // MARK: - Runtime and bottles

    func prepare() {
        guard sessions.isEmpty else { error = "Stop the running Windows sessions first."; return }
        perform("Preparing Portnaut…") { [self] in
            try await service.prepare { [self] value in await update(value) }
            autoRegistrationFailed = false
            return library.bottles.isEmpty ? "Portnaut is ready. Create a bottle for your first launcher or game." : "Portnaut is up to date. Your bottles, games and sign-ins were kept."
        }
    }
    func createBottle(name: String, launcher: Launcher?, renderer: Renderer, windowsVersion: WindowsVersion, easyMode: Bool) {
        perform("Creating \(name)…") { [self] in
            let bottle = try await service.createBottle(name: name, launcher: launcher, renderer: renderer, windowsVersion: windowsVersion, easyMode: easyMode)
            selectedBottleID = bottle.id
            page = .bottles
            return launcher.map { "\(bottle.name) is ready. Next, install \($0.title)." } ?? "\(bottle.name) is ready. Add a game or run an installer in it."
        }
    }
    /// Saves a changed bottle; the registry part applies to programs started afterwards.
    func save(_ bottle: Bottle) {
        guard let old = library.bottle(bottle.id), old != bottle else { return }
        if old.renderer != bottle.renderer, sessionActive(bottle) {
            error = "Stop \(bottle.name)’s Windows session before switching its renderer."
            return
        }
        library.update(bottle)
        perform("Saving \(bottle.name)…") { [self] in
            try await service.update(bottle)
            return sessionActive(bottle) ? "Saved. Restart \(bottle.name)’s programs to apply it." : "Saved. Applies the next time a program starts in \(bottle.name)."
        }
    }
    func removeBottle(_ bottle: Bottle) {
        perform("Moving \(bottle.name) to the Trash…") { [self] in
            try await service.removeBottle(bottle)
            selectedBottleID = nil
            return "\(bottle.name) is in the Trash. Its games and saves can be restored from there."
        }
    }

    // MARK: - Sessions

    private func watchSession(_ bottle: Bottle) {
        sessions.insert(bottle.id)
        Task {
            do { try await service.waitForSessionEnd(bottle) } catch { self.error = error.localizedDescription }
            sessions.remove(bottle.id); refresh()
        }
    }
    private func startSession(_ bottle: Bottle, _ status: String, _ run: @escaping () async throws -> Void) {
        guard !busy, !sessionActive(bottle) else { return }
        stopRequested.remove(bottle.id)
        sessions.insert(bottle.id)
        message = status
        Task {
            do {
                try await run()
                message = "Session ended. \(bottle.name) is ready for next time."
            } catch {
                if !stopRequested.contains(bottle.id) { self.error = error.localizedDescription }
            }
            sessions.remove(bottle.id); roundSessions.remove(bottle.id); refresh(); readLog()
            // Back to the couch library when the game closes.
            if couchMode { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
    }
    func installLauncher(_ bottle: Bottle) {
        guard let launcher = bottle.launcher, !busy, !sessionActive(bottle) else { return }
        busy = true; progress = 0
        Task {
            do {
                _ = try await service.fetchInstaller(for: bottle) { [self] value in await update(value) }
                busy = false
                let status = launcher.installerArguments.contains("/S") ? "Installing \(launcher.title)…" : "Continue in the \(launcher.title) installer."
                startSession(bottle, status) { [service] in try await service.launchInstaller(bottle) }
            } catch { self.error = error.localizedDescription; busy = false }
            refresh()
        }
    }
    func openLauncher(_ bottle: Bottle) {
        startSession(bottle, "Continue in the \(bottle.launcher?.title ?? "launcher") window.") { [service] in try await service.launchLauncher(bottle) }
    }
    func play(_ entry: LibraryEntry) {
        // A best-setup round must start the session itself: Portnaut switches the renderer and records it.
        if entry.game.setupTrial?.next != nil, sessionActive(entry.bottle) {
            error = "Close \(entry.bottle.launcher?.title ?? entry.bottle.name) first, or stop its session. A round starts the session itself, so Portnaut can switch the renderer and record it."
            return
        }
        // A game the launcher starts can be handed to the launcher already open.
        if sessionActive(entry.bottle), entry.game.launcherArguments != nil, let launcher = entry.bottle.launcher {
            message = "Asked \(launcher.title) to start \(entry.game.name)."
            Task {
                do { try await service.launchGame(entry.game, in: entry.bottle, waitForSession: false) } catch { self.error = error.localizedDescription }
                refresh()
            }
            return
        }
        let database = compatibility
        var status = "Starting \(entry.game.name)…"
        if let trial = entry.game.setupTrial, let round = trial.next {
            status = "Best setup, round \(trial.round) of \(trial.renderers.count): starting \(entry.game.name) on \(round.title)…"
        } else if entry.bottle.easyMode, let choice = service.easyModeChoice(for: entry.game, in: entry.bottle, report: reports[entry.id]), choice.renderer != entry.bottle.renderer {
            status = "Switching \(entry.bottle.name) to \(choice.renderer.title) for \(entry.game.name), then starting it…"
        }
        if entry.game.setupTrial?.next != nil { roundSessions.insert(entry.bottle.id) }
        startSession(entry.bottle, status) { [service] in try await service.launchGame(entry.game, in: entry.bottle, compatibility: database) }
    }
    /// Play stays available while the bottle runs if its launcher can take the game.
    func canPlay(_ entry: LibraryEntry) -> Bool {
        !busy && runtimeReady && (!sessionActive(entry.bottle) || (entry.game.launcherArguments != nil && installedLaunchers.contains(entry.bottle.id)))
    }

    // MARK: - Find my best setup

    func startBestSetup(_ entry: LibraryEntry) {
        do {
            let trial = try service.startSetupTrial(for: entry.game, in: entry.bottle)
            message = "\(entry.game.name): \(trial.renderers.count) rounds, on \(CompatibilityReport.list(trial.renderers.map(\.title)))."
        } catch { self.error = error.localizedDescription }
        refresh()
    }
    func cancelBestSetup(_ entry: LibraryEntry) {
        do { try service.cancelSetupTrial(for: entry.game, in: entry.bottle) } catch { self.error = error.localizedDescription }
        refresh()
    }
    func keepBestSetup(_ entry: LibraryEntry) {
        perform("Keeping \(entry.game.name)’s best setup…") { [self] in
            let best = try await service.keepSetupTrial(for: entry.game, in: entry.bottle)
            return entry.bottle.easyMode ? "\(entry.game.name) will start on \(best.renderer.title)." : "\(entry.bottle.name) now uses \(best.renderer.title), fastest for \(entry.game.name)."
        }
    }

    // MARK: - Settings, components and controllers

    func saveGame(_ game: Game, in bottle: Bottle) {
        Task {
            do {
                try await service.updateGame(game, in: bottle)
                message = sessionActive(bottle) ? "Saved \(game.name)’s settings. They apply the next time it starts." : "Saved \(game.name)’s settings."
            } catch { self.error = error.localizedDescription }
            refresh()
        }
    }
    func installComponent(_ component: WindowsComponent, in bottle: Bottle) {
        let alongside = sessionActive(bottle)
        perform("Installing \(component.title)…") { [self] in
            try await service.installComponent(component, in: bottle, waitForSession: !alongside) { [self] value in await update(value) }
            return "\(component.title) is installed in \(bottle.name)."
        }
    }
    func openControllerPanel(_ bottle: Bottle) {
        if sessionActive(bottle) {
            Task { do { try await service.openControllerPanel(bottle, waitForSession: false) } catch { self.error = error.localizedDescription } }
        } else {
            startSession(bottle, "Opened Windows Game Controllers in \(bottle.name).") { [service] in try await service.openControllerPanel(bottle) }
        }
    }
    private func updateControllers() {
        macControllers = GCController.controllers().map { controller in
            let level = controller.battery.map { $0.batteryState == .unknown ? nil : Int(($0.batteryLevel * 100).rounded()) } ?? nil
            return MacController(id: String(UInt(bitPattern: ObjectIdentifier(controller).hashValue)), name: controller.vendorName ?? controller.productCategory,
                                 kind: controller.productCategory, battery: level.map { "\($0)%" })
        }
    }

    // MARK: - Component updates

    /// The menu command: shows the window and checks GitHub unless a check is under ten minutes old.
    func openComponentUpdates() {
        showingUpdates = true
        if updateCheck.map({ Date().timeIntervalSince($0.checkedAt) > 600 }) ?? true { checkForUpdates() }
    }
    /// Refreshes the compatibility database with the component check; a failed download keeps the copy.
    private func refreshCompatibility() {
        Task {
            try? await service.refreshCompatibility()
            loadCompatibility()
        }
    }
    func checkForUpdates() {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        Task {
            refreshCompatibility()
            do { updateCheck = try await RuntimeUpdates.check(); updateCheckError = nil }
            catch { updateCheckError = "Couldn’t check for updates: \(error.localizedDescription)" }
            checkingUpdates = false
        }
    }
    func installComponentUpdates() {
        guard sessions.isEmpty else { error = "Stop the running Windows sessions first."; return }
        guard let set = updateCheck?.set(for: updateChannel) else { return }
        perform("Updating components…") { [self] in
            try await service.installRuntime(set) { [self] value in await update(value) }
            return "Components updated to \(set.label). The previous set is kept for rolling back."
        }
    }
    func rollBackComponents() {
        guard sessions.isEmpty else { error = "Stop the running Windows sessions first."; return }
        perform("Rolling back components…") { [self] in
            try await service.rollBackRuntime { [self] value in await update(value) }
            return "Back on \(installedRuntime?.set.label ?? "the previous components"). The newer set is kept for switching again."
        }
    }

    // MARK: - Snapshots and backups

    func beginSnapshot(_ bottle: Bottle) {
        snapshotName = "Snapshot \(Date().formatted(date: .abbreviated, time: .shortened))"
        namingSnapshot = bottle
    }
    func takeSnapshot(_ bottle: Bottle, label: String) {
        guard !sessionActive(bottle) else { error = "Stop \(bottle.name)’s session first, so no files are being written while Portnaut takes the snapshot."; return }
        let name = label.trimmingCharacters(in: .whitespaces).isEmpty ? "Snapshot" : label.trimmingCharacters(in: .whitespaces)
        perform("Taking a snapshot of \(bottle.name)…") { [self] in
            try service.takeSnapshot(of: bottle, label: name)
            return "Snapshot “\(name)” taken. It shares space with \(bottle.name) until files change."
        }
    }
    func restoreSnapshot(_ snapshot: Snapshot, of bottle: Bottle) {
        perform("Restoring \(bottle.name)…") { [self] in
            try await service.restoreSnapshot(snapshot, of: bottle)
            return "\(bottle.name) is back as it was on \(snapshot.date.formatted(date: .abbreviated, time: .shortened)). Its state before the restore is kept as a snapshot."
        }
    }
    func deleteSnapshot(_ snapshot: Snapshot, of bottle: Bottle) {
        do { try service.deleteSnapshot(snapshot, of: bottle); message = "Moved “\(snapshot.label)” to the Trash."; refresh() }
        catch { self.error = error.localizedDescription }
    }
    func backUpSaves(_ bottle: Bottle) {
        perform("Backing up \(bottle.name)’s saves…") { [self] in
            let backup = try await service.backUpSaves(of: bottle)
            return "Backed up \(backup.files) files (\(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file))) to Documents › Portnaut Backups."
        }
    }
    func restoreSaves(_ backup: SaveBackup, to bottle: Bottle) {
        perform("Restoring saves in \(bottle.name)…") { [self] in
            try await service.restoreSaves(backup, to: bottle)
            return "Restored the saves from \(backup.date.formatted(date: .abbreviated, time: .shortened)). A snapshot from just before is kept."
        }
    }
    func switchRenderer(of bottle: Bottle, to renderer: Renderer) {
        guard var updated = library.bottle(bottle.id) else { return }
        updated.renderer = renderer
        save(updated)
    }

    // MARK: - Installers and programs

    func chooseInstaller(for bottle: Bottle? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Install a Windows program"
        panel.message = "Choose a Windows installer (.exe or .msi). Portnaut runs it in a bottle and then lists the programs it installed."
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = ["exe", "msi"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginInstall(url, in: bottle)
    }
    /// Also the target for installers dropped on the window.
    @discardableResult
    func beginInstall(_ file: URL, in bottle: Bottle? = nil) -> Bool {
        guard runtimeReady else { error = runtimeOutdated ? "Update Portnaut in the Library first." : "Prepare Portnaut in the Library first."; return false }
        guard ["exe", "msi"].contains(file.pathExtension.lowercased()) else { error = "\(file.lastPathComponent) is not a Windows installer. Choose an .exe or .msi file."; return false }
        pendingInstall = PendingInstall(file: file, bottleID: bottle?.id)
        return true
    }
    func install(_ file: URL, into target: InstallTarget) {
        guard !busy else { return }
        Task {
            var bottle: Bottle
            switch target {
            case .existing(let id):
                guard let existing = library.bottle(id) else { return }
                bottle = existing
            case .new(let name, let renderer, let windows):
                busy = true; progress = 0; message = "Creating \(name)…"
                do { bottle = try await service.createBottle(name: name, launcher: nil, renderer: renderer, windowsVersion: windows) }
                catch { self.error = error.localizedDescription; busy = false; message = "That needs attention. You can retry safely."; return }
                busy = false; refresh()
            }
            selectedBottleID = bottle.id
            // Alongside a running launcher, wait for the installer only; otherwise for the whole session.
            let alongside = sessionActive(bottle)
            if !alongside { sessions.insert(bottle.id) }
            message = "Continue in the installer window. \(file.lastPathComponent)’s folder is drive H: until it finishes."
            do {
                let added = try await service.runInstaller(file, in: bottle, waitForSession: !alongside)
                if !alongside { sessions.remove(bottle.id) }
                refresh()
                if added.isEmpty {
                    message = "The installer finished without adding programs Portnaut can find. Use Add Game… to choose one."
                } else {
                    message = "Installed. Choose what to add to your library."
                    offer(added, in: library.bottle(bottle.id) ?? bottle, afterInstall: true)
                }
            } catch {
                if !alongside { sessions.remove(bottle.id) }
                self.error = error.localizedDescription
                refresh()
            }
        }
    }
    /// Find Programs: everything installed in the bottle that is not in the library.
    func findPrograms(in bottle: Bottle) {
        let found = service.detectPrograms(in: bottle)
        if found.isEmpty { message = "No programs outside the library in \(bottle.name). Use Add Game… to choose one."; return }
        offer(found, in: bottle, afterInstall: false)
    }
    private func offer(_ programs: [DetectedProgram], in bottle: Bottle, afterInstall: Bool) {
        let drive = service.paths.bottle(bottle).drive
        Task {
            // Reading large programs takes a moment; keep it off the main thread.
            let analyses = await Task.detached {
                Dictionary(uniqueKeysWithValues: programs.map { ($0.id, GraphicsAdvisor.analyze(drive.appendingPathComponent($0.executable))) })
            }.value
            programChoice = ProgramChoice(bottleID: bottle.id, programs: programs, analyses: analyses, afterInstall: afterInstall)
        }
    }
    func addPrograms(_ programs: [DetectedProgram], to bottle: Bottle, renderer: Renderer?) {
        do {
            let games = try service.addPrograms(programs, to: bottle)
            refresh()
            if let game = games.first { selectedEntryID = "\(bottle.id)/\(game.id)" }
            message = "Added \(games.count) program\(games.count == 1 ? "" : "s") to your library."
            if let renderer, var updated = library.bottle(bottle.id), updated.renderer != renderer {
                updated.renderer = renderer
                save(updated)
            }
        } catch { self.error = error.localizedDescription }
    }
    func stop(_ bottle: Bottle) {
        stopRequested.insert(bottle.id)
        Task {
            do { try await service.stop(bottle); message = "Stopped \(bottle.name)’s Windows session." }
            catch { stopRequested.remove(bottle.id); self.error = error.localizedDescription }
        }
    }

    // MARK: - Games

    func addGame(to bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.title = "Add a game to \(bottle.name)"
        panel.message = "Choose the game’s .exe inside this bottle’s Windows drive."
        panel.directoryURL = service.paths.bottle(bottle).drive
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let game = try service.addGame(url, to: bottle)
            message = "\(game.name) is in your library."
            refresh()
            selectedEntryID = "\(bottle.id)/\(game.id)"
        } catch { self.error = error.localizedDescription }
    }
    func removeGame(_ entry: LibraryEntry) {
        do { try service.removeGame(entry.game, from: entry.bottle); message = "\(entry.game.name) was removed from the library. Its files stay in \(entry.bottle.name)."; refresh() }
        catch { self.error = error.localizedDescription }
    }
    /// Copies an existing Assassin's Creed III folder into a Ubisoft Connect bottle.
    func importExisting(into bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.title = "Copy existing game files"
        panel.message = "Choose the Assassin’s Creed III Remastered folder containing ACIII.exe. Portnaut creates its own space-saving copy."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url, !sessionActive(bottle) else { return }
        perform("Creating an independent, space-saving copy…") { [self] in
            _ = try await service.importGame(from: source, into: bottle)
            return "Files copied. In Ubisoft Connect, use Locate installed game and select C:\\Games\\Assassin's Creed III Remastered."
        }
    }

    // MARK: - Diagnostics

    func reveal(_ url: URL) { NSWorkspace.shared.open(url) }
    func readLog() {
        let urls = [service.paths.setupLog, service.paths.sessionLog]
        logText = urls.compactMap { url -> String? in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return "— \(url.lastPathComponent) —\n" + content.split(separator: "\n", omittingEmptySubsequences: false).suffix(150).joined(separator: "\n")
        }.joined(separator: "\n\n")
        if logText.isEmpty { logText = runtimeReady ? "No activity yet." : "No activity yet. Prepare Portnaut to get started." }
    }
    func exportDiagnostics() {
        readLog()
        let panel = NSSavePanel()
        panel.message = "For help, attach this file to an email to \(Publisher.supportEmail). Paths in your home folder are shortened and passwords and tokens are removed; review it before you send it."
        panel.nameFieldStringValue = "Portnaut-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        var header = "Portnaut \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        header += "Runtime: \(installedRuntime?.summary ?? "not prepared")\nRenderers: \(Renderer.allCases.map(\.title).joined(separator: ", "))\nRuntime ready: \(runtimeReady)\n"
        for bottle in library.bottles {
            header += "Bottle \(bottle.id): \(bottle.renderer.title), recommended \(recommendations[bottle.id]?.renderer.title ?? "?"); \(bottle.windowsVersion.title); High Resolution \(bottle.highResolution ? "on" : "off"); MSync \(bottle.msync ? "on" : "off"); frame limit \(bottle.options.frameRateLimit.map { "\($0) fps" } ?? "off"); HUD and latency log \(bottle.options.performanceHUD ? "on" : "off"); frame queue \(bottle.options.reduceFrameQueue ? "reduced" : "default"); games \(bottle.games.map(\.name).joined(separator: ", "))\n"
        }
        var report = (header + "\n" + logText).replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if let pattern = try? NSRegularExpression(pattern: "(?i)(token|password|authorization|sessionid|ticket)([=: ]+)([^\\s,;]+)") {
            report = pattern.stringByReplacingMatches(in: report, range: NSRange(report.startIndex..., in: report), withTemplate: "$1$2[REDACTED]")
        }
        do { try report.write(to: destination, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}
