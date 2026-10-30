import Foundation
import PortnautCore

/// Headless setup, inspection and launching. Commands that act on a bottle take its id; with only
/// one bottle the id may be left out.
@main
struct PortnautDoctor {
    static let usage = """
    Commands:
      check                                   runtime state and every bottle
      prepare                                 build the runtime and prepare every bottle
      bottles                                 list bottles and games with renderer recommendations
      analyze <path/to/program.exe>           graphics APIs and the recommended renderer
      create <name> [launcher] [renderer]     new bottle; launcher: \(Launcher.allCases.map(\.rawValue).joined(separator: "|")); renderer: \(Renderer.allCases.map(\.rawValue).joined(separator: "|"))
      renderer [bottle] <renderer>            switch a bottle's renderer
      add-game [bottle] <path/to/program.exe> add a program inside the bottle as a game
      import [bottle] <folder>                copy an Assassin's Creed III installation into the bottle
      install <bottle> <installer.exe|.msi> [arguments…]  run an installer from the Mac, list the programs it added
      programs [bottle]                       installed programs not in the library, with recommendations
      add-programs [bottle]                   add every program `programs` lists
      shortcuts [bottle]                      every Start Menu and Desktop shortcut, helpers included
      fetch-installer [bottle] | launch-installer [bottle] | launch-launcher [bottle]
      launch-game [bottle] [game]             start a game (the first one when left out)
      run <bottle> <program> [arguments…]     run a Windows program in the bottle (PORTNAUT_WINEDEBUG to trace)
      env [bottle]                            the bottle's environment as shell exports
      frame-limit [bottle] off|<fps> | hud [bottle] on|off | frame-queue [bottle] reduced|default | avx [bottle] on|off
      record [bottle] on|off | metalfx [bottle] on|off | dlss [bottle] on|off   performance records, MetalFX 2× upscaling (DXMT), DLSS via MetalFX
      performance [bottle] [game]             recorded sessions compared by configuration
      performance-log <session.log> [bottle]  summarise a log's PortnautLatency lines as one session
      snapshots [bottle] | snapshot <bottle> [label] | restore-snapshot <bottle> <id> | delete-snapshot <bottle> <id>
      backups [bottle] | backup-saves [bottle] | restore-saves <bottle> <id>
      runtime-versions                        what the runtime was built from, and the previous one kept for rolling back
      check-updates                           what Stable (Highball's tested set) and Latest (newest builds) offer
      update-runtime stable|latest            install that channel's components (snapshots every bottle first)
      rollback-runtime                        go back to the runtime before the last update
      env-var <bottle> KEY=value|KEY=          set or clear a variable for every program of the bottle
      components [bottle]                     Windows components and whether Portnaut installed them
      install-component <bottle> <component>  component: \(WindowsComponent.allCases.map(\.rawValue).joined(separator: "|"))
      controllers <bottle> [sdl on|off] [xinput on|off]   how Windows sees game controllers
      controller-panel [bottle]               open Wine's Game Controllers panel
      game <bottle> <game> [version <v>|bottle] [dll <name> <mode>|remove] [env KEY=value|KEY=] [args "<line>"]
                                              per-game settings; mode: \(DllOverride.allCases.filter { $0 != .disabled }.map(\.rawValue).joined(separator: "|"))|disabled
      stop [bottle]
    """

    static func main() async {
        let override = ProcessInfo.processInfo.environment["PORTNAUT_HOME"].map { URL(fileURLWithPath: $0) }
        let service = WineService(paths: PortnautPaths(root: override))
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.isEmpty ? "check" : arguments.removeFirst()
        do {
            switch command {
            case "check": try check(service)
            case "prepare": try await service.prepare { print("\(Int($0.fraction * 100))% \($0.message)") }
            case "bottles": try listBottles(service)
            case "analyze":
                guard let path = arguments.first else { throw PortnautError(usage) }
                let analysis = GraphicsAdvisor.analyze(URL(fileURLWithPath: path))
                print("Architecture: \(analysis.architecture ?? "not a supported Windows program")")
                print("Imports: \(analysis.imported.map(\.title).joined(separator: ", ").nonEmpty ?? "none")")
                if !analysis.mentioned.isEmpty { print("Mentions: \(analysis.mentioned.map(\.title).joined(separator: ", "))") }
                print("Recommended: \(analysis.recommendation.renderer.title) — \(analysis.recommendation.reason)")
            case "create":
                guard let name = arguments.first else { throw PortnautError(usage) }
                let launcher = arguments.compactMap(Launcher.init(rawValue:)).first
                let renderer = arguments.compactMap(Renderer.init(rawValue:)).first ?? launcher?.recommendation.renderer ?? .dxmt
                let bottle = try await service.createBottle(name: name, launcher: launcher, renderer: renderer)
                print("Created \(bottle.id) on \(renderer.title)")
            case "renderer":
                guard let value = arguments.last, let renderer = Renderer(rawValue: value) else { throw PortnautError(usage) }
                var bottle = try target(service, arguments.dropLast())
                try? await service.stop(bottle)
                bottle.renderer = renderer
                try await service.update(bottle)
                print("\(bottle.name): \(renderer.title)")
            case "add-game":
                guard let path = arguments.last else { throw PortnautError(usage) }
                let game = try service.addGame(URL(fileURLWithPath: path), to: try target(service, arguments.dropLast()))
                print("Added \(game.name) (\(game.id))")
            case "import":
                guard let path = arguments.last else { throw PortnautError(usage) }
                let game = try await service.importGame(from: URL(fileURLWithPath: path), into: try target(service, arguments.dropLast()))
                print("Imported: \(game.executable)")
            case "fetch-installer": print(try await service.fetchInstaller(for: try target(service, arguments)).path)
            case "launch-installer": try await service.launchInstaller(try target(service, arguments))
            case "install":
                guard arguments.count >= 2 else { throw PortnautError(usage) }
                let bottle = try service.bottle(arguments[0])
                let added = try await service.runInstaller(URL(fileURLWithPath: arguments[1]), in: bottle, arguments: Array(arguments.dropFirst(2)))
                print(added.isEmpty ? "The installer added no programs." : "Added by the installer:")
                printPrograms(added, in: try service.bottle(bottle.id), service)
            case "programs":
                let bottle = try target(service, arguments)
                let found = service.detectPrograms(in: bottle)
                if found.isEmpty { print("No programs outside the library.") }
                printPrograms(found, in: bottle, service)
            case "add-programs":
                let bottle = try target(service, arguments)
                for game in try service.addPrograms(service.detectPrograms(in: bottle), to: bottle) { print("Added \(game.name) (\(game.id))") }
            case "shortcuts":
                let bottle = try target(service, arguments)
                for program in ProgramScanner.shortcuts(drive: service.paths.bottle(bottle).drive, includeHelpers: true) {
                    print("\(program.name): C:\\\(program.executable.replacingOccurrences(of: "/", with: "\\")) \(program.arguments.joined(separator: " "))")
                }
            case "launch-launcher": try await service.launchLauncher(try target(service, arguments))
            case "env":
                // Shell exports of a bottle's environment, for running Wine by hand.
                let bottle = try target(service, arguments)
                for (key, value) in service.environment(for: bottle).sorted(by: { $0.key < $1.key }) where key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    print("export \(key)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'")
                }
                print("# wine: \(service.paths.wine(for: bottle.renderer).path)")
            case "run":
                // run <bottle> <program> [arguments…]: a Windows program by name or C:\ path.
                guard arguments.count >= 2 else { throw PortnautError(usage) }
                let bottle = try service.bottle(arguments[0])
                let status = try await ProcessRunner.run(service.paths.wine(for: bottle.renderer), Array(arguments.dropFirst()), environment: service.environment(for: bottle),
                                                         directory: service.paths.bottle(bottle).drive, log: service.paths.sessionLog, timeout: 120, allowFailure: true)
                try await service.waitForSessionEnd(bottle)
                print("Exit code \(status); output is in \(service.paths.sessionLog.path)")
            case "launch-game":
                // The first argument is a bottle when one has that id, otherwise the game.
                let named = arguments.first.flatMap { try? service.bottle($0) }
                let bottle = try named ?? target(service, [String]())
                let wanted = arguments.dropFirst(named == nil ? 0 : 1).first
                guard let game = bottle.games.first(where: { wanted == nil || $0.id == wanted }) else { throw PortnautError("No such game in \(bottle.name).") }
                try await service.launchGame(game, in: bottle)
            case "env-var":
                guard arguments.count == 2, let equals = arguments[1].firstIndex(of: "=") else { throw PortnautError(usage) }
                var bottle = try service.bottle(arguments[0])
                let key = String(arguments[1][..<equals]), value = String(arguments[1][arguments[1].index(after: equals)...])
                guard EnvironmentPolicy.allows(key) else { throw PortnautError("Portnaut sets \(key) itself.") }
                bottle.environment[key] = value.isEmpty ? nil : value
                try await service.update(bottle)
                print("\(bottle.name): \(bottle.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ").nonEmpty ?? "no variables")")
            case "components":
                let bottle = try target(service, arguments)
                for component in WindowsComponent.allCases {
                    print("\(component.rawValue): \(component.title) — \(bottle.components[component.rawValue].map { "installed \($0)" } ?? "not installed") (\(component.downloadSize))")
                }
            case "install-component":
                guard arguments.count == 2, let component = WindowsComponent(rawValue: arguments[1]) else { throw PortnautError(usage) }
                print("\(component.title) is Microsoft software; installing it accepts Microsoft’s licence terms.")
                try await service.installComponent(component, in: try service.bottle(arguments[0])) { print("\(Int($0.fraction * 100))% \($0.message)") }
            case "controllers":
                guard let id = arguments.first else { throw PortnautError(usage) }
                var bottle = try service.bottle(id)
                for pair in stride(from: 1, to: arguments.count - 1, by: 2) {
                    switch (arguments[pair], arguments[pair + 1]) {
                    case ("sdl", let value): bottle.controllers.sdl = value == "on"
                    case ("xinput", let value): bottle.controllers.xinput = value == "on"
                    default: throw PortnautError(usage)
                    }
                }
                if arguments.count > 1 { try await service.update(bottle) }
                print("\(bottle.name): SDL \(bottle.controllers.sdl ? "on" : "off"); Xbox (XInput) mapping \(bottle.controllers.xinput ? "on" : "off")")
            case "controller-panel": try await service.openControllerPanel(try target(service, arguments))
            case "game":
                guard arguments.count >= 2 else { throw PortnautError(usage) }
                let bottle = try service.bottle(arguments[0])
                guard var game = bottle.games.first(where: { $0.id == arguments[1] }) else { throw PortnautError("No game \(arguments[1]) in \(bottle.name).") }
                var rest = Array(arguments.dropFirst(2))
                while !rest.isEmpty {
                    switch rest.removeFirst() {
                    case "version":
                        guard let value = rest.first else { throw PortnautError(usage) }
                        rest.removeFirst()
                        if value == "bottle" { game.windowsVersion = nil } else if let version = WindowsVersion(rawValue: value) { game.windowsVersion = version } else { throw PortnautError(usage) }
                    case "dll":
                        guard rest.count >= 2 else { throw PortnautError(usage) }
                        let name = rest.removeFirst().lowercased().replacingOccurrences(of: ".dll", with: ""), mode = rest.removeFirst()
                        if mode == "remove" { game.dllOverrides[name] = nil }
                        else if let value = mode == "disabled" ? DllOverride.disabled : DllOverride(rawValue: mode) { game.dllOverrides[name] = value }
                        else { throw PortnautError(usage) }
                    case "env":
                        guard let pair = rest.first, let equals = pair.firstIndex(of: "=") else { throw PortnautError(usage) }
                        rest.removeFirst()
                        let key = String(pair[..<equals]), value = String(pair[pair.index(after: equals)...])
                        guard EnvironmentPolicy.allows(key) else { throw PortnautError("Portnaut sets \(key) itself.") }
                        game.environment[key] = value.isEmpty ? nil : value
                    case "args":
                        guard let line = rest.first else { throw PortnautError(usage) }
                        rest.removeFirst()
                        game.arguments = ProgramScanner.splitCommandLine(line)
                    default: throw PortnautError(usage)
                    }
                }
                if arguments.count > 2 { try await service.updateGame(game, in: bottle) }
                print("\(game.name) (\(game.programName)): Windows \(game.windowsVersion?.title ?? "as bottle"); arguments \(game.arguments.joined(separator: " ").nonEmpty ?? "none"); DLLs \(game.dllOverrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue.nonEmpty ?? "disabled")" }.joined(separator: ", ").nonEmpty ?? "default"); environment \(game.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ").nonEmpty ?? "none")")
            case "performance":
                let bottle = try target(service, arguments.prefix(1))
                let games = bottle.games.filter { arguments.count < 2 || $0.id == arguments[1] }
                for game in games {
                    print("\(game.name): \(game.performance.count) recorded session\(game.performance.count == 1 ? "" : "s")")
                    for row in PerformanceLog.compare(game.performance) { print("  " + describe(row)) }
                }
            case "performance-log":
                guard let path = arguments.first else { throw PortnautError(usage) }
                let bottle = try target(service, arguments.dropFirst())
                let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
                guard let run = PerformanceLog.run(from: text, bottle: bottle) else { throw PortnautError("No 15 seconds of PortnautLatency lines in \(path).") }
                print(describe(PerformanceLog.compare([run])[0]))
                print("  frame time p95 \(String(format: "%.1f", run.frameTimeP95)) ms")
            case "snapshots":
                let bottle = try target(service, arguments)
                for snapshot in service.snapshots(of: bottle) { print("\(snapshot.id)  \(snapshot.automatic ? "auto " : "")\(snapshot.label) — \(snapshot.bottle.renderer.title), \(snapshot.bottle.games.count) games") }
            case "snapshot":
                guard let id = arguments.first else { throw PortnautError(usage) }
                let bottle = try service.bottle(id)
                try? await service.stop(bottle)
                let snapshot = try service.takeSnapshot(of: bottle, label: arguments.dropFirst().joined(separator: " ").nonEmpty ?? "Snapshot")
                print("Took \(snapshot.id): \(snapshot.label)")
            case "restore-snapshot", "delete-snapshot":
                guard arguments.count == 2 else { throw PortnautError(usage) }
                let bottle = try service.bottle(arguments[0])
                guard let snapshot = service.snapshots(of: bottle).first(where: { $0.id == arguments[1] }) else { throw PortnautError("No snapshot \(arguments[1]).") }
                if command == "restore-snapshot" { try await service.restoreSnapshot(snapshot, of: bottle); print("Restored \(snapshot.label)") }
                else { try service.deleteSnapshot(snapshot, of: bottle); print("Moved \(snapshot.id) to the Trash") }
            case "backups":
                let bottle = try target(service, arguments)
                for backup in service.saveBackups(of: bottle) { print("\(backup.id)  \(backup.files) files, \(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file)) — \(backup.folders.joined(separator: ", "))") }
            case "backup-saves":
                let bottle = try target(service, arguments)
                let backup = try await service.backUpSaves(of: bottle)
                print("Backed up \(backup.files) files (\(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file))) to \(service.paths.saveBackups.appendingPathComponent(bottle.id).appendingPathComponent(backup.id).path)")
            case "restore-saves":
                guard arguments.count == 2 else { throw PortnautError(usage) }
                let bottle = try service.bottle(arguments[0])
                guard let backup = service.saveBackups(of: bottle).first(where: { $0.id == arguments[1] }) else { throw PortnautError("No backup \(arguments[1]).") }
                try await service.restoreSaves(backup, to: bottle)
                print("Restored saves from \(backup.id)")
            case "runtime-versions":
                guard let installed = service.installedRuntime() else { throw PortnautError("Prepare Portnaut first.") }
                printSet(installed.set, title: "Installed (\(installed.installedAt.formatted(date: .abbreviated, time: .shortened)))")
                for (name, version) in installed.details.sorted(by: { $0.key < $1.key }) { print("  \(name): \(version)") }
                if let previous = service.previousRuntime() { printSet(previous.set, title: "Previous, for rolling back") }
            case "check-updates":
                let check = try await RuntimeUpdates.check()
                let current = service.installedRuntime()?.set
                for channel in UpdateChannel.allCases {
                    let set = check.set(for: channel)
                    let changes = current.map { set.changes(from: $0) } ?? RuntimePart.allCases
                    printSet(set, title: "\(channel.title): \(changes.isEmpty ? "up to date" : "\(changes.map(\.title).joined(separator: ", ")) differ, \(ByteCountFormatter.string(fromByteCount: current.map { set.downloadSize(from: $0) } ?? 0, countStyle: .file)) to download")")
                }
                for note in check.latestNotes { print("  note: \(note)") }
            case "update-runtime":
                guard let value = arguments.first, let channel = UpdateChannel(rawValue: value) else { throw PortnautError(usage) }
                let set = try await RuntimeUpdates.check().set(for: channel)
                service.updateChannel = channel
                try await service.installRuntime(set) { print("\(Int($0.fraction * 100))% \($0.message)") }
                printSet(service.installedRuntime()!.set, title: "Installed")
            case "rollback-runtime":
                try await service.rollBackRuntime { print("\(Int($0.fraction * 100))% \($0.message)") }
                printSet(service.installedRuntime()!.set, title: "Installed")
            case "frame-limit", "hud", "frame-queue", "avx", "record", "metalfx", "dlss":
                guard let value = arguments.last else { throw PortnautError(usage) }
                var bottle = try target(service, arguments.dropLast())
                switch (command, value) {
                case ("hud", "on"), ("hud", "off"): bottle.options.performanceHUD = value == "on"
                case ("frame-queue", "reduced"), ("frame-queue", "default"): bottle.options.reduceFrameQueue = value == "reduced"
                case ("avx", "on"), ("avx", "off"): bottle.options.advertiseAVX = value == "on"
                case ("record", "on"), ("record", "off"): bottle.options.recordPerformance = value == "on"
                case ("metalfx", "on"), ("metalfx", "off"): bottle.options.metalFXUpscaling = value == "on"
                case ("dlss", "on"), ("dlss", "off"): bottle.options.dlss = value == "on"
                case ("frame-limit", "off"): bottle.options.frameRateLimit = nil
                case ("frame-limit", let fps) where (Int(fps) ?? 0) > 0: bottle.options.frameRateLimit = Int(fps)
                default: throw PortnautError(usage)
                }
                try await service.update(bottle)
                print("\(bottle.name): frame limit \(bottle.options.frameRateLimit.map { "\($0) fps" } ?? "off"); HUD \(bottle.options.performanceHUD ? "on" : "off"); recording \(bottle.options.recordPerformance ? "on" : "off"); MetalFX \(bottle.metalFXActive ? "on" : "off"); DLSS \(bottle.dlssActive ? "on" : "off"); frame queue \(bottle.options.reduceFrameQueue ? "reduced" : "default")")
            case "stop": try await service.stop(try target(service, arguments))
            default: throw PortnautError(usage)
            }
        } catch {
            fputs("Portnaut: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    /// The bottle named in the arguments, or the only bottle.
    static func target(_ service: WineService, _ arguments: some Collection<String>) throws -> Bottle {
        let library = try service.library()
        if let id = arguments.first { return try service.bottle(id) }
        guard library.bottles.count == 1 else { throw PortnautError("Name a bottle: \(library.bottles.map(\.id).joined(separator: ", ").nonEmpty ?? "there are none yet").") }
        return library.bottles[0]
    }

    static func printSet(_ set: RuntimeSet, title: String) {
        print("\(title) — \(set.label)")
        for release in set.components { print("  \(release.part.title): \(release.version)  [\(release.fileName), \(release.sha256.prefix(12))…]") }
    }

    static func describe(_ row: PerformanceSummary) -> String {
        let latency = row.latencyMilliseconds.map { String(format: ", %.0f ms to screen", $0) } ?? ""
        return String(format: "%@: %.1f fps average, %.0f low, GPU %.1f ms/frame%@ — %d session%@, %d min", row.configuration, row.averageFPS, row.lowFPS,
                      row.gpuMilliseconds, latency, row.runs, row.runs == 1 ? "" : "s", row.seconds / 60)
    }

    static func printPrograms(_ programs: [DetectedProgram], in bottle: Bottle, _ service: WineService) {
        for program in programs {
            let analysis = GraphicsAdvisor.analyze(service.paths.bottle(bottle).drive.appendingPathComponent(program.executable))
            print("  \(program.name) — C:\\\(program.executable.replacingOccurrences(of: "/", with: "\\"))\(program.launcherArguments.map { " (via \(bottle.launcher?.title ?? "launcher") \($0.joined(separator: " ")))" } ?? "")")
            print("    \(program.source.rawValue); \(analysis.imported.map(\.title).joined(separator: ", ").nonEmpty ?? "no graphics API found") → \(analysis.recommendation.renderer.title)")
        }
    }
    static func check(_ service: WineService) throws {
        let paths = service.paths
        print("Portnaut root: \(paths.root.path)")
        print("Runtime ready: \(paths.runtimeReady)")
        print("Runtime needs update: \(paths.runtimeOutdated)")
        print("Rosetta installed: \(WineService.rosettaInstalled)")
        print("Metal shim: \(service.metalShim?.path ?? "not found")")
        try listBottles(service)
    }

    static func listBottles(_ service: WineService) throws {
        let library = try service.library()
        if library.bottles.isEmpty { print("Bottles: none") }
        for bottle in library.bottles {
            let recommended = service.recommendation(for: bottle)
            print("Bottle \(bottle.id) — \(bottle.name)\(bottle.launcher.map { " (\($0.title)\(service.launcherInstalled(bottle) ? "" : ", not installed"))" } ?? "")")
            print("  ready \(service.paths.bottle(bottle).ready); renderer \(bottle.renderer.title); recommended \(recommended.renderer.title); \(bottle.windowsVersion.title); High Resolution \(bottle.highResolution ? "on" : "off"); MSync \(bottle.msync ? "on" : "off")")
            print("  frame limit \(bottle.options.frameRateLimit.map { "\($0) fps" } ?? "off"); HUD \(bottle.options.performanceHUD ? "on" : "off"); recording \(bottle.options.recordPerformance ? "on" : "off"); MetalFX \(bottle.metalFXActive ? "on" : "off"); DLSS \(bottle.dlssActive ? "on" : "off"); frame queue \(bottle.options.reduceFrameQueue ? "reduced" : "default")")
            for game in bottle.games {
                let analysis = service.analyze(game, in: bottle)
                print("  Game \(game.id) — \(game.name): \(analysis.map { "\($0.imported.map(\.title).joined(separator: ", ")) → \($0.recommendation.renderer.title)" } ?? "missing at \(game.executable)")")
            }
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
