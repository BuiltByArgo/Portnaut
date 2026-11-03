import SwiftUI
import AppKit
import GameController
import PortnautCore

// MARK: - Couch mode input

extension AppModel {
    /// Fills the screen with the library, for a controller. The arrow keys, Return and Escape work too.
    func enterCouchMode() {
        guard !couchMode else { return }
        couchMode = true
        couchStopArmed = false
        couchIndex = entries.firstIndex { $0.id == selectedEntry?.id } ?? 0
        NSCursor.setHiddenUntilMouseMoves(true)
        if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }), !window.styleMask.contains(.fullScreen) {
            couchEnteredFullScreen = true
            window.toggleFullScreen(nil)
        }
        couchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                // Alerts and sheets keep their own keys (Return, Escape).
                guard let self, self.couchMode, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      event.window?.attachedSheet == nil, event.window?.isSheet != true, NSApplication.shared.modalWindow == nil else { return false }
                switch event.keyCode {
                case 123: self.couchMove(-1)               // left arrow
                case 124: self.couchMove(1)                // right arrow
                case 36, 76, 49: self.couchPlay()          // return, enter, space
                case 53: self.exitCouchMode()              // escape
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    func exitCouchMode() {
        guard couchMode else { return }
        couchMode = false
        couchStopArmed = false
        if let monitor = couchKeyMonitor { NSEvent.removeMonitor(monitor) }
        couchKeyMonitor = nil
        if couchEnteredFullScreen, let window = NSApplication.shared.windows.first(where: { $0.styleMask.contains(.fullScreen) }) {
            window.toggleFullScreen(nil)
        }
        couchEnteredFullScreen = false
    }

    func couchMove(_ delta: Int) {
        guard couchMode, !entries.isEmpty else { return }
        couchIndex = min(max(couchIndex + delta, 0), entries.count - 1)
        selectedEntryID = entries[couchIndex].id
        couchStopArmed = false
    }

    var couchEntry: LibraryEntry? { entries.indices.contains(couchIndex) ? entries[couchIndex] : entries.first }

    func couchPlay() {
        guard couchMode, let entry = couchEntry else { return }
        if canPlay(entry) { play(entry) } else if sessionActive(entry.bottle) { message = "\(entry.bottle.name) is already running." }
    }

    /// Stops the selected game's session on the second press, so one stray press cannot end a game.
    func couchStop() {
        guard couchMode, let entry = couchEntry, sessionActive(entry.bottle) else { return }
        if couchStopArmed {
            couchStopArmed = false
            stop(entry.bottle)
        } else {
            couchStopArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in MainActor.assumeIsolated { self?.couchStopArmed = false } }
        }
    }

    /// A newly connected controller drives couch mode; with games in the library, Portnaut says how.
    func controllerConnected(_ controller: GCController) {
        attachCouchControls(controller)
        if !couchMode, !entries.isEmpty { message = "\(controller.vendorName ?? "A controller") connected. Couch Mode (⇧⌘T) plays your library from the sofa." }
    }

    /// Couch mode's buttons. GameController calls these on the main queue, and only while Portnaut
    /// is the active app, so they never reach a game that is playing.
    func attachCouchControls(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        func button(_ input: GCControllerButtonInput, _ action: @escaping @MainActor (AppModel) -> Void) {
            input.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated { if let self, self.couchMode { action(self) } }
            }
        }
        button(pad.dpad.left) { $0.couchMove(-1) }
        button(pad.dpad.right) { $0.couchMove(1) }
        button(pad.buttonA) { $0.couchPlay() }
        button(pad.buttonY) { $0.couchStop() }
        button(pad.buttonB) { $0.exitCouchMode() }
        button(pad.buttonMenu) { $0.exitCouchMode() }
        pad.leftThumbstick.xAxis.valueChangedHandler = { [weak self] _, value in
            MainActor.assumeIsolated {
                guard let self, self.couchMode else { return }
                let step = self.couchStick.step(value)
                if step != 0 { self.couchMove(step) }
            }
        }
    }
}

// MARK: - Couch mode view

/// The library, large, for a TV: a row of games, the selected one's details, and the buttons.
struct CouchView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let entries = model.entries
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 80).padding(.top, 50)
            if let entry = model.couchEntry {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 34) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                                tile(item, selected: index == model.couchIndex).id(index)
                                    .onTapGesture { model.couchMove(index - model.couchIndex); if index == model.couchIndex { model.couchPlay() } }
                            }
                        }.padding(.horizontal, 80).padding(.vertical, 40)
                    }
                    .onChange(of: model.couchIndex) { _, index in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) } }
                }
                details(entry).padding(.horizontal, 80)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No games yet").font(.system(size: 44, weight: .medium, design: .rounded))
                    Text("Add games on the Mac first: create a bottle for a launcher, or install a game with Install from File.").font(.system(size: 20)).foregroundStyle(Palette.muted)
                }.padding(80)
            }
            Spacer(minLength: 20)
            hints.padding(.horizontal, 80).padding(.bottom, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.background)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 52, height: 52)
            Text("Portnaut").font(.system(size: 30, weight: .medium, design: .rounded))
            Spacer()
            Label(model.macControllers.first?.name ?? "No controller: the arrow keys and Return work too", systemImage: "gamecontroller")
                .font(.system(size: 16)).foregroundStyle(Palette.muted)
            TimelineView(.everyMinute) { context in
                Text(context.date, style: .time).font(.system(size: 22, weight: .medium, design: .rounded))
            }.padding(.leading, 20)
        }
    }

    private func tile(_ entry: LibraryEntry, selected: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            if entry.game.id == KnownGame.ac3.id { FrontierScene() } else { SpaceScene(seed: entry.game.name) }
            LinearGradient(colors: [.clear, Palette.background.opacity(0.9)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 8) {
                Text(entry.game.name).font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(2)
                Spacer(minLength: 0)
                if model.sessionActive(entry.bottle) { couchTag("Playing", tint: Palette.accent) }
                else if model.reports[entry.id]?.status == .blocked { couchTag("Won’t run", tint: Palette.accent) }
            }.padding(18)
        }
        .frame(width: 400, height: 225)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Palette.accent : Color.white.opacity(0.08), lineWidth: selected ? 4 : 1))
        .shadow(color: selected ? Palette.accent.opacity(0.35) : .clear, radius: 24)
        .scaleEffect(selected ? 1.06 : 0.94)
        .opacity(selected ? 1 : 0.7)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    private func details(_ entry: LibraryEntry) -> some View {
        let report = model.reports[entry.id]
        let running = model.sessionActive(entry.bottle)
        return VStack(alignment: .leading, spacing: 14) {
            Text(entry.game.name).font(.system(size: 46, weight: .medium, design: .rounded)).lineLimit(1)
            HStack(spacing: 12) {
                couchTag(entry.bottle.name)
                // A launcher's bottle is usually named after it.
                if let launcher = entry.bottle.launcher, launcher.title.caseInsensitiveCompare(entry.bottle.name) != .orderedSame { couchTag(launcher.title) }
                if let report { couchTag(report.headline, tint: report.tint) }
                if let best = entry.game.bestSetup { couchTag("Fastest: \(best.renderer.title)", tint: Palette.cyan) }
                else if entry.bottle.easyMode { couchTag("Easy mode", tint: Palette.cyan) }
            }
            if let explanation = report?.explanation ?? model.analyses[entry.id]?.recommendation.reason {
                Text(explanation).font(.system(size: 18)).foregroundStyle(Palette.muted).lineLimit(2).frame(maxWidth: 1000, alignment: .leading)
            }
            Group {
                if model.couchStopArmed { Text("Press Y again to stop \(entry.game.name). Save in the game first.").foregroundStyle(Palette.accent) }
                else if running { Text("\(entry.game.name) is running. Press Y twice to stop it.").foregroundStyle(Palette.accent) }
                else if let trial = entry.game.setupTrial, let next = trial.next { Text("Find My Best Setup: round \(trial.round) of \(trial.renderers.count) plays on \(next.title).").foregroundStyle(Palette.cyan) }
                else if !model.message.isEmpty, model.busy { Text(model.message).foregroundStyle(Palette.muted) }
            }.font(.system(size: 18, weight: .medium))
        }
    }

    /// Tag, sized to read from a sofa.
    private func couchTag(_ text: String, tint: Color = .white) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(tint).background(tint.opacity(0.12), in: Capsule())
    }

    private var hints: some View {
        HStack(spacing: 34) {
            hint("a.circle.fill", "Play", "Return")
            hint("y.circle.fill", "Stop a game", nil)
            hint("b.circle.fill", "Leave couch mode", "Esc")
            hint("dpad", "Choose a game", "← →")
            Spacer()
        }
    }

    private func hint(_ symbol: String, _ title: String, _ key: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24))
            Text(title).font(.system(size: 17, weight: .medium))
            if let key { Text(key).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.muted) }
        }
    }
}
