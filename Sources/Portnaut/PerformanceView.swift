import SwiftUI
import AppKit
import PortnautCore

/// A game's recorded sessions, one row per graphics configuration, and the renderers not tried yet.
struct PerformanceCard: View {
    @EnvironmentObject var model: AppModel
    var entry: LibraryEntry

    var body: some View {
        let rows = PerformanceLog.compare(entry.game.performance)
        let bottle = entry.bottle
        let tried = Set(rows.map(\.renderer))
        // Renderers the bottle's launcher does not start on are left out (DXVK for Ubisoft Connect).
        let untried = model.analyses[entry.id].map(GraphicsAdvisor.candidates)?.filter { !tried.contains($0) && bottle.launcher?.unsupportedRenderers.contains($0) != true } ?? []
        let best = rows.first?.configuration
        let candidates = model.analyses[entry.id].map { SetupTrial.candidates(for: $0, launcher: bottle.launcher) } ?? []
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Performance", symbol: "chart.bar.xaxis")
            if let best = entry.game.bestSetup {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(Palette.cyan)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Fastest on this Mac: \(best.renderer.title)").font(.system(size: 12, weight: .semibold))
                        Text("\(best.reason) Measured \(best.measuredAt.formatted(date: .abbreviated, time: .omitted)).").font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            if entry.game.setupTrial == nil, candidates.count >= 2 {
                HStack(spacing: 10) {
                    Text(entry.game.bestSetup == nil
                         ? "Not sure which renderer is fastest? Portnaut can play \(entry.game.name) on \(CompatibilityReport.list(candidates.map(\.title))) in turn and keep the fastest."
                         : "Measure again after a component update, or when a game update changes how it runs.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.startBestSetup(entry) } label: { Label(entry.game.bestSetup == nil ? "Find My Best Setup" : "Measure Again", systemImage: "gauge.with.dots.needle.67percent").frame(height: 28) }
                        .buttonStyle(PortnautButtonStyle(primary: entry.game.bestSetup == nil)).disabled(model.busy)
                }
            }
            if rows.isEmpty {
                Text(bottle.options.recordPerformance
                     ? "Portnaut records each session you start here: average and low frame rate, GPU time per frame, and the delay to the screen. Play a while on one renderer, then another, to compare them."
                     : "Turn on Record performance in \(bottle.name)’s settings to compare renderers.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        ForEach(["Configuration", "Average", "Low", "GPU / frame", "To screen", "Played"], id: \.self) {
                            Text($0.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.1).foregroundStyle(Palette.muted)
                        }
                    }
                    ForEach(rows) { row in
                        GridRow {
                            HStack(spacing: 6) {
                                Text(row.configuration).font(.system(size: 12, weight: .medium))
                                if row.configuration == best, rows.count > 1 { Tag(text: "Fastest", tint: Palette.cyan) }
                                if row.configuration == bottle.performanceLabel { Tag(text: "Current") }
                            }
                            Text(String(format: "%.0f fps", row.averageFPS)).font(.system(size: 12, design: .monospaced))
                            Text(String(format: "%.0f fps", row.lowFPS)).font(.system(size: 12, design: .monospaced))
                            Text(String(format: "%.1f ms", row.gpuMilliseconds)).font(.system(size: 12, design: .monospaced))
                            Text(row.latencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "–").font(.system(size: 12, design: .monospaced))
                            Text("\(row.runs)× · \(max(row.seconds / 60, 1)) min").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                }
                Text("Low is the slowest 5% of 5-second stretches. GPU time can pass the frame budget when frames overlap. Paused or background stretches are left out.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            // Find My Best Setup covers trying the others when there are two or more.
            if !untried.isEmpty, candidates.count < 2 {
                HStack(spacing: 8) {
                    Text("Not tried yet:").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    ForEach(untried) { renderer in
                        Button("Switch \(bottle.name) to \(renderer.title)") { model.switchRenderer(of: bottle, to: renderer) }
                            .buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 26).disabled(model.busy || model.sessionActive(bottle))
                    }
                }
                Text(bottle.launcher == .ubisoft
                     ? "The renderer applies to the whole bottle. Ubisoft Connect is 32-bit and stays on Wine’s own Direct3D with DXMT or D3DMetal, so sign-in is unaffected."
                     : "The renderer applies to the whole bottle and takes effect at its next session.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.card()
    }
}

/// Snapshots of the whole bottle, and backups of its saves.
struct SnapshotsCard: View {
    @EnvironmentObject var model: AppModel
    var bottle: Bottle

    var body: some View {
        let running = model.sessionActive(bottle)
        let snapshots = model.snapshots[bottle.id] ?? []
        let backups = model.saveBackups[bottle.id] ?? []
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Snapshots & backups", symbol: "clock.arrow.circlepath")
            Text("A snapshot is an APFS clone of the whole bottle: Windows, programs, settings and saves. It is taken at once and uses space only as files change afterwards. Portnaut takes one by itself before updating Portnaut, installing programs or components, and restoring; it keeps the three newest of those.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { model.beginSnapshot(bottle) } label: { Label("Take Snapshot…", systemImage: "camera.aperture").frame(height: 28) }
                    .buttonStyle(PortnautButtonStyle(primary: false)).disabled(running || model.busy || !model.ready(bottle))
                Button { model.backUpSaves(bottle) } label: { Label("Back Up Saves", systemImage: "externaldrive.badge.plus").frame(height: 28) }
                    .buttonStyle(PortnautButtonStyle(primary: false)).disabled(model.busy || !model.ready(bottle))
                if !backups.isEmpty {
                    Button("Show Backups") { model.reveal(model.service.paths.saveBackups.appendingPathComponent(bottle.id)) }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            if running { Text("Stop the session to take or restore a snapshot.").font(.system(size: 11)).foregroundStyle(Palette.accent) }
            ForEach(snapshots) { snapshot in
                HStack(spacing: 10) {
                    Image(systemName: snapshot.automatic ? "clock.badge.checkmark" : "camera.aperture").foregroundStyle(Palette.muted).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(snapshot.date.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.bottle.renderer.title) · \(snapshot.bottle.games.count) game\(snapshot.bottle.games.count == 1 ? "" : "s")")
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    ConfirmingButton(title: "Restore…", prompt: "Restore \(bottle.name) to “\(snapshot.label)”?",
                                     detail: "Its Windows drive, programs, settings and saves go back to \(snapshot.date.formatted(date: .abbreviated, time: .shortened)). Portnaut first keeps the current state as a snapshot.",
                                     action: "Restore") { model.restoreSnapshot(snapshot, of: bottle) }
                        .disabled(running || model.busy)
                    ConfirmingButton(title: "Delete", prompt: "Move “\(snapshot.label)” to the Trash?", detail: "You can restore it from the Trash until you empty it.", action: "Move to Trash", destructive: true) {
                        model.deleteSnapshot(snapshot, of: bottle)
                    }.disabled(model.busy)
                }
            }
            if !backups.isEmpty {
                Rectangle().fill(Palette.line).frame(height: 1)
                Text("SAVE BACKUPS").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(Palette.muted)
                ForEach(backups.prefix(5)) { backup in
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive").foregroundStyle(Palette.muted).frame(width: 18)
                        Text("\(backup.date.formatted(date: .abbreviated, time: .shortened)) · \(backup.files) files · \(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file))\(backup.automatic == true ? " · before a game" : "")")
                            .font(.system(size: 12))
                        Spacer()
                        ConfirmingButton(title: "Restore…", prompt: "Restore saves from \(backup.date.formatted(date: .abbreviated, time: .shortened))?",
                                         detail: "Files in the backup replace the bottle’s; files it does not have stay. Portnaut takes a snapshot first.", action: "Restore Saves") {
                            model.restoreSaves(backup, to: bottle)
                        }.disabled(running || model.busy)
                    }
                }
                Text("Backups hold Documents, Saved Games, AppData (without caches and launcher data), Ubisoft Connect’s savegames and Steam’s userdata, in Documents › Portnaut Backups.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.card().id("snapshots")
    }
}

final class Confirmation: ObservableObject {
    @Published var shown = false
}

/// A button that asks first; its dialog state lives in an object, as @State needs Xcode's macro plugin.
struct ConfirmingButton: View {
    @StateObject private var confirmation = Confirmation()
    var title: String
    var prompt: String
    var detail: String
    var action: String
    var destructive = false
    var perform: () -> Void

    init(title: String, prompt: String, detail: String, action: String, destructive: Bool = false, perform: @escaping () -> Void) {
        self.title = title; self.prompt = prompt; self.detail = detail; self.action = action; self.destructive = destructive; self.perform = perform
    }

    var body: some View {
        Button(title) { confirmation.shown = true }
            .buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 26)
            .confirmationDialog(prompt, isPresented: $confirmation.shown) {
                Button(action, role: destructive ? .destructive : nil, action: perform)
            } message: { Text(detail) }
    }
}

/// The Mac's main display in points and pixels, for describing MetalFX upscaling.
enum MainDisplay {
    static var description: (points: String, pixels: String) {
        guard let screen = NSScreen.main else { return ("the Mac’s point resolution", "full Retina resolution") }
        let size = screen.frame.size, scale = screen.backingScaleFactor
        return ("\(Int(size.width)) × \(Int(size.height))", "\(Int(size.width * scale)) × \(Int(size.height * scale))")
    }
}


/// "Find my best setup" while its rounds are played, and its result before it is kept.
struct BestSetupCard: View {
    @EnvironmentObject var model: AppModel
    var entry: LibraryEntry
    var trial: SetupTrial

    var body: some View {
        let running = model.sessionActive(entry.bottle)
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Find my best setup", symbol: "gauge.with.dots.needle.67percent")
            HStack(spacing: 8) {
                ForEach(Array(trial.renderers.enumerated()), id: \.offset) { index, renderer in
                    let done = trial.runs.contains { $0.renderer == renderer }
                    Tag(text: "\(index + 1). \(renderer.title)\(done ? " ✓" : "")", tint: done ? Palette.cyan : renderer == trial.next ? Palette.accent : .white)
                }
            }
            if let winner = trial.winner, trial.finished {
                ForEach(trial.runs) { run in
                    HStack(spacing: 14) {
                        Text(run.renderer.title).font(.system(size: 12, weight: .medium)).frame(width: 110, alignment: .leading)
                        Text(String(format: "%.0f fps average", run.averageFPS)).font(.system(size: 12, design: .monospaced))
                        Text(String(format: "%.0f fps low", run.lowFPS)).font(.system(size: 12, design: .monospaced))
                        Text(String(format: "%.1f ms GPU", run.gpuMilliseconds)).font(.system(size: 12, design: .monospaced))
                        if run.renderer == winner.renderer { Tag(text: "Fastest", tint: Palette.cyan) }
                    }
                }
                Text(winner.reason).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { model.keepBestSetup(entry) } label: { Label("Keep \(winner.renderer.title)", systemImage: "checkmark").frame(height: 30) }
                        .buttonStyle(PortnautButtonStyle(primary: true)).disabled(model.busy || running)
                    Button("Discard") { model.cancelBestSetup(entry) }.buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 30)
                    Text(entry.bottle.easyMode ? "Easy mode then starts \(entry.game.name) on \(winner.renderer.title)." : "\(entry.bottle.name) then switches to \(winner.renderer.title).")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            } else if let next = trial.next {
                if running, !model.roundSessions.contains(entry.bottle.id) {
                    Text("\(entry.bottle.launcher?.title ?? entry.bottle.name) is open from before. A round starts the session itself, so Portnaut can switch to \(next.title) and record it: close it first, or stop the session.")
                        .font(.system(size: 12)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
                    Button { model.stop(entry.bottle) } label: { Label("Stop Session", systemImage: "stop.fill").frame(height: 30) }
                        .buttonStyle(PortnautButtonStyle(primary: false))
                } else if running {
                    Text("Round \(trial.round) of \(trial.renderers.count) is running on \(next.title). Play for at least a minute, two is better: the same kind of play each round, such as a ride or a fight you know. Then save and quit the game\(entry.game.launcherArguments != nil ? " and \(entry.bottle.launcher?.title ?? "its launcher")" : ""), or end the round here.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button { model.stop(entry.bottle) } label: { Label("End Round", systemImage: "stop.fill").frame(height: 30) }
                            .buttonStyle(PortnautButtonStyle(primary: false))
                        Text("Ending the round closes the game: save first.").font(.system(size: 11)).foregroundStyle(Palette.accent)
                    }
                } else {
                    if trial.emptyRound == true {
                        Text("The last round recorded almost no play (under 15 seconds): the game may have closed at once, or not reached play. Play it again, for at least a minute of play.")
                            .font(.system(size: 12)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
                    } else if let short = trial.shortRun {
                        Text("The last round counted only \(short.seconds) seconds of play (loading and menus below 5 fps are left out). Play it again for at least a minute.")
                            .font(.system(size: 12)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Round \(trial.round) of \(trial.renderers.count): \(next.title). Portnaut switches \(entry.bottle.name) to \(next.title) and records the session. Play the same kind of stretch in every round for a fair comparison.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button { model.play(entry) } label: { Label("Play Round \(trial.round) on \(next.title)", systemImage: "play.fill").frame(height: 30) }
                            .buttonStyle(PortnautButtonStyle(primary: true)).disabled(!model.canPlay(entry))
                        Button("Cancel") { model.cancelBestSetup(entry) }.buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 30)
                    }
                }
            }
        }.card()
    }
}
