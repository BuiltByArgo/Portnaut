import SwiftUI
import PortnautCore

struct BottlesPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Bottles", symbol: "shippingbox").padding(.horizontal, 6).padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 4) { ForEach(model.library.bottles) { row($0) } }
                }
                Button { model.showingNewBottle = true } label: { Label("New Bottle…", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 32) }
                    .buttonStyle(PortnautButtonStyle(primary: false)).disabled(!model.runtimeReady || model.busy)
            }.padding(16).frame(width: 260).background(Palette.sidebar.opacity(0.55))
            Rectangle().fill(Palette.line).frame(width: 1)
            if let bottle = model.selectedBottle {
                ScrollViewReader { proxy in
                    ScrollView { BottleDetail(bottleID: bottle.id).padding(30).frame(maxWidth: 900, alignment: .leading) }
                        .onAppear {
                            // Launch argument for checking a section: -PortnautInitialSection controllers|components|environment|snapshots
                            guard let section = UserDefaults.standard.string(forKey: "PortnautInitialSection") else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { proxy.scrollTo(section, anchor: .top) }
                        }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox").font(.system(size: 40)).foregroundStyle(Palette.muted)
                    Text(model.runtimeReady ? "Create a bottle to get started." : "Prepare Portnaut in the Library first.").foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func row(_ bottle: Bottle) -> some View {
        let selected = model.selectedBottle?.id == bottle.id
        return Button { model.selectedBottleID = bottle.id } label: {
            HStack(spacing: 10) {
                Image(systemName: bottle.launcher?.symbol ?? "shippingbox").frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bottle.name).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                    Text("\(bottle.renderer.title) · \(bottle.games.count) game\(bottle.games.count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if model.sessionActive(bottle) { Circle().fill(Palette.accent).frame(width: 6, height: 6) }
            }.padding(.horizontal, 10).frame(height: 46).foregroundStyle(selected ? Color.white : Palette.muted)
                .background(selected ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}

/// View state lives in observable objects: @State is a macro whose plugin ships only with Xcode,
/// and Portnaut builds with the Command Line Tools.
struct BottleDetail: View {
    @EnvironmentObject var model: AppModel
    var bottleID: String

    /// Edits save immediately; the renderer only while no session runs.
    private func binding<T>(_ keyPath: WritableKeyPath<Bottle, T>, fallback bottle: Bottle) -> Binding<T> {
        Binding(get: { (model.library.bottle(bottleID) ?? bottle)[keyPath: keyPath] },
                set: { value in
                    guard var updated = model.library.bottle(bottleID) else { return }
                    updated[keyPath: keyPath] = value
                    model.save(updated)
                })
    }

    var body: some View {
        if let bottle = model.library.bottle(bottleID) { content(bottle) }
    }

    private func content(_ bottle: Bottle) -> some View {
        let running = model.sessionActive(bottle)
        let recommendation = model.recommendations[bottle.id]
        let paths = model.service.paths.bottle(bottle)
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(bottle.name).font(.system(size: 28, weight: .medium, design: .rounded))
                    Tag(text: running ? "Running" : model.ready(bottle) ? "Ready" : "Not prepared", tint: running ? Palette.accent : Palette.cyan)
                }
                Text("\(bottle.launcher?.title ?? "General bottle") · \(paths.prefix.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
            actions(bottle, running: running)

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Graphics", symbol: "cpu")
                Picker("Renderer", selection: binding(\.renderer, fallback: bottle)) {
                    ForEach(Renderer.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().disabled(running || model.busy)
                Text(bottle.renderer.detail).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if let recommendation {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: recommendation.renderer == bottle.renderer ? "checkmark.seal" : "lightbulb")
                            .foregroundStyle(recommendation.renderer == bottle.renderer ? Palette.cyan : Palette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Recommended: \(recommendation.renderer.title)").font(.system(size: 12, weight: .semibold))
                            Text(recommendation.reason).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if recommendation.renderer != bottle.renderer {
                            Button("Use \(recommendation.renderer.title)") { binding(\.renderer, fallback: bottle).wrappedValue = recommendation.renderer }
                                .buttonStyle(PortnautButtonStyle(primary: true)).frame(height: 28).disabled(running || model.busy)
                        }
                    }.padding(12).background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
                }
                if let note = [bottle.renderer, recommendation?.renderer].compactMap({ $0?.licenseNote }).first {
                    Label(note, systemImage: "doc.text").font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                if running { Text("Stop the session to switch renderer.").font(.system(size: 11)).foregroundStyle(Palette.accent) }
                if bottle.renderer == .dxmt {
                    let display = MainDisplay.description
                    Toggle("MetalFX upscaling", isOn: binding(\.options.metalFXUpscaling, fallback: bottle)).toggleStyle(.switch).disabled(model.busy)
                    Text("Games render at \(display.points), the Mac’s point resolution with a quarter of the pixels, and MetalFX upscales the picture to \(display.pixels). Leave the game’s resolution at the highest it offers. Its HUD is upscaled too; for a sharper HUD, lower the game’s own resolution scale instead. Applies to every program in the bottle from its next session.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                if bottle.renderer == .dxmt || bottle.renderer == .d3dmetal {
                    Toggle("DLSS through MetalFX", isOn: binding(\.options.dlss, fallback: bottle)).toggleStyle(.switch).disabled(model.busy)
                    Text("For games that offer DLSS: turn DLSS on in the game and MetalFX does the upscaling\(bottle.renderer == .d3dmetal ? " (Apple’s D3DMetal)" : " (DXMT’s bridge)"). Games then see an NVIDIA graphics card, so turn this off if one misbehaves.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(bottle.games) { game in
                    if let analysis = model.analyses["\(bottle.id)/\(game.id)"] {
                        HStack {
                            Text(game.name).font(.system(size: 12, weight: .medium))
                            Text("\(analysis.is64Bit ? "64-bit" : "32-bit") · \((analysis.imported.isEmpty ? analysis.mentioned : analysis.imported).map(\.title).joined(separator: ", ").isEmpty ? "no graphics API found" : (analysis.imported.isEmpty ? analysis.mentioned : analysis.imported).map(\.title).joined(separator: ", "))")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Spacer()
                            RendererBadge(current: bottle.renderer, recommended: analysis.recommendation)
                        }
                    }
                }
            }.card()

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Windows", symbol: "macwindow")
                Picker("Windows version", selection: binding(\.windowsVersion, fallback: bottle)) {
                    ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
                }.frame(maxWidth: 320)
                Toggle("High Resolution Mode", isOn: binding(\.highResolution, fallback: bottle)).toggleStyle(.switch).disabled(bottle.metalFXActive)
                if bottle.metalFXActive { Text("Off while MetalFX upscaling is on: games render at point resolution and MetalFX supplies the Retina detail.").font(.system(size: 11)).foregroundStyle(Palette.accent) }
                Text("Renders at the Mac’s full Retina resolution, 192 DPI. Off renders a quarter of the pixels: much faster, softer image. Applies to programs started afterwards; a game may need its resolution chosen again.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Toggle("MSync", isOn: binding(\.msync, fallback: bottle)).toggleStyle(.switch)
                Text("Faster Windows synchronization through Mach semaphores. Turn off only to rule it out when a program hangs.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }.card().disabled(model.busy)

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Performance & input lag", symbol: "speedometer")
                Picker("Frame rate limit", selection: Binding(get: { bottle.options.frameRateLimit ?? 0 },
                                                              set: { binding(\.options.frameRateLimit, fallback: bottle).wrappedValue = $0 == 0 ? nil : $0 })) {
                    Text("Off").tag(0)
                    ForEach(GraphicsProfile.frameRateLimits, id: \.self) { Text("\($0) fps").tag($0) }
                }.frame(maxWidth: 280).disabled(bottle.renderer != .dxmt)
                Toggle("Show Metal performance HUD", isOn: binding(\.options.performanceHUD, fallback: bottle)).toggleStyle(.switch)
                Toggle("Record performance", isOn: binding(\.options.recordPerformance, fallback: bottle)).toggleStyle(.switch)
                Toggle("Reduce frame queue", isOn: binding(\.options.reduceFrameQueue, fallback: bottle)).toggleStyle(.switch)
                Toggle("Advertise AVX instructions", isOn: binding(\.options.advertiseAVX, fallback: bottle)).toggleStyle(.switch)
                Text("The frame limit is DXMT’s and, like the game’s VSync, holds each frame until its slot, about one frame of extra delay. For the least delay: VSync off in the game, no limit, Reduce frame queue on. The HUD is Apple’s Metal overlay. Record performance writes a PortnautLatency summary to the session log every 5 seconds and keeps a record of each game session, for comparing renderers on the game’s page. Advertise AVX lets games that require AVX or AVX2 start: Rosetta translates those instructions but reports them only when asked. All apply when the bottle’s next session starts.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }.card().disabled(model.busy)

            controllers(bottle)
            components(bottle)

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Environment variables", symbol: "terminal")
                Text(bottle.environment.isEmpty ? "None. Portnaut sets what Wine and the renderer need." : bottle.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
                    .font(.system(size: 11, design: bottle.environment.isEmpty ? .default : .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                Button("Edit Variables…") { model.editingEnvironment = bottle }.buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 28).disabled(model.busy)
            }.card().id("environment")

            if let note = launcherNote(bottle.launcher) {
                Label(note, systemImage: bottle.launcher?.symbol ?? "info.circle").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true).card(padding: 16)
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Games", symbol: "gamecontroller")
                if bottle.games.isEmpty { Text("No games yet. Install them through the launcher or Install from File…, then Find Programs; or add a program’s .exe.").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                ForEach(bottle.games) { game in
                    let entry = LibraryEntry(game: game, bottle: bottle)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(game.name).font(.system(size: 13, weight: .medium))
                            Text((game.launcherArguments != nil ? "Through \(bottle.launcher?.title ?? "the launcher") · " : "") + "C:\\" + game.executable.replacingOccurrences(of: "/", with: "\\"))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Play") { model.play(entry) }.buttonStyle(PortnautButtonStyle(primary: true)).frame(height: 28).disabled(!model.canPlay(entry))
                        Button("Settings…") { model.editingGame = entry }.buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 28)
                        Button("Remove") { model.removeGame(entry) }.buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 28)
                    }
                }
            }.card()

            SnapshotsCard(bottle: bottle)

            HStack {
                Spacer()
                Button("Move Bottle to Trash…", role: .destructive) { model.bottlePendingRemoval = bottle }.buttonStyle(.bordered).disabled(running || model.busy)
            }
            .confirmationDialog("Move \(bottle.name) to the Trash?", isPresented: Binding(get: { model.bottlePendingRemoval?.id == bottle.id },
                                                                                          set: { if !$0 { model.bottlePendingRemoval = nil } })) {
                Button("Move to Trash", role: .destructive) { model.removeBottle(bottle); model.bottlePendingRemoval = nil }
            } message: { Text("Its Windows drive, installed games and saves go to the Trash, where you can restore them until you empty it.") }
        }
    }

    private func controllers(_ bottle: Bottle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Controllers", symbol: "gamecontroller")
            if model.macControllers.isEmpty {
                Text("No controllers connected to this Mac. Pair one in System Settings → Bluetooth, or connect it with a cable.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            ForEach(model.macControllers) { controller in
                HStack(spacing: 10) {
                    Image(systemName: "gamecontroller.fill").foregroundStyle(Palette.cyan)
                    Text(controller.name).font(.system(size: 13, weight: .medium))
                    if controller.kind != controller.name { Text(controller.kind).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    Spacer()
                    if let battery = controller.battery { Label(battery, systemImage: "battery.75").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                }
            }
            Toggle("Recognise controllers with SDL", isOn: binding(\.controllers.sdl, fallback: bottle)).toggleStyle(.switch)
            Toggle("Show controllers as Xbox controllers (XInput)", isOn: binding(\.controllers.xinput, fallback: bottle)).toggleStyle(.switch)
            Text("SDL, included in Portnaut’s runtime, knows the layouts of Xbox, PlayStation, Switch and most other controllers. Off, Wine reads macOS HID devices directly. With Xbox mode on, games see a standard Xbox controller, which most expect; off, they see each controller as it is (DirectInput). Both apply when the bottle’s next session starts. Steam games can also use Steam Input on top.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Button { model.openControllerPanel(bottle) } label: { Label("Test in Windows…", systemImage: "dot.radiowaves.left.and.right").frame(height: 28) }
                .buttonStyle(PortnautButtonStyle(primary: false)).disabled(model.busy || !model.runtimeReady || !model.ready(bottle))
        }.card().disabled(model.busy).id("controllers")
    }

    private func components(_ bottle: Bottle) -> some View {
        let usable = model.runtimeReady && model.ready(bottle)
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Windows components", symbol: "puzzlepiece.extension")
            ForEach(WindowsComponent.allCases) { component in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(component.title).font(.system(size: 13, weight: .medium))
                            if let date = bottle.components[component.rawValue] { Tag(text: "Installed \(date.formatted(date: .abbreviated, time: .omitted))", tint: Palette.cyan) }
                        }
                        Text(component.detail).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    // Microsoft's installers run silently, so the user accepts Microsoft's terms here instead.
                    ConfirmingButton(title: bottle.components[component.rawValue] == nil ? "Install · \(component.downloadSize)" : "Reinstall",
                                     prompt: "Install \(component.title) in \(bottle.name)?",
                                     detail: "\(component.title) is Microsoft software under Microsoft’s licence terms. Portnaut downloads it from Microsoft and installs it without showing Microsoft’s installer, so by installing it you accept those terms.",
                                     action: "Accept and Install") { model.installComponent(component, in: bottle) }
                        .fixedSize().disabled(model.busy || !usable)
                }
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            Text("BUILT INTO WINE").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(Palette.muted)
            ForEach(BuiltInComponent.allCases, id: \.title) { part in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(Palette.cyan)
                    Text(part.title).font(.system(size: 12, weight: .medium))
                    Text(part.detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            Text("Installers come from Microsoft. Fixed versions are checked against the hashes winetricks pins; the Visual C++ 2015–2022 and .NET 8 links always fetch Microsoft’s latest release. Most games install what they need themselves.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }.card().id("components")
    }

    private func launcherNote(_ launcher: Launcher?) -> String? {
        switch launcher {
        case .steam: "Games Steam installs join your library as soon as they finish downloading and start through Steam, also while Steam is open. Steam’s window is drawn in software: on Wine’s Mac driver its browser cannot draw from a separate GPU process."
        case .ea: "Games the EA app installs join your library once their install record is written; Find Programs lists any others. Games with EA’s kernel anti-cheat do not run under Wine."
        case .ubisoft, nil: nil
        }
    }

    private func actions(_ bottle: Bottle, running: Bool) -> some View {
        // Programs need the current runtime; an outdated one is updated from the Library first.
        let usable = model.runtimeReady && model.ready(bottle)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let launcher = bottle.launcher {
                    if model.installedLaunchers.contains(bottle.id) {
                        Button { model.openLauncher(bottle) } label: { Label("Open \(launcher.title)", systemImage: "play.fill").frame(height: 30) }
                            .buttonStyle(PortnautButtonStyle(primary: true)).disabled(running || model.busy || !usable)
                    } else {
                        Button { model.installLauncher(bottle) } label: { Label("Install \(launcher.title)", systemImage: "arrow.down.circle").frame(height: 30) }
                            .buttonStyle(PortnautButtonStyle(primary: true)).disabled(running || model.busy || !usable)
                    }
                }
                Button { model.chooseInstaller(for: bottle) } label: { Label("Install from File…", systemImage: "square.and.arrow.down.on.square").frame(height: 30) }
                    .buttonStyle(PortnautButtonStyle(primary: bottle.launcher == nil)).disabled(model.busy || !usable)
                Menu {
                    Button("Find Programs") { model.findPrograms(in: bottle) }
                    Button("Add Game…") { model.addGame(to: bottle) }
                    if bottle.launcher == .ubisoft, !bottle.games.contains(where: { $0.id == KnownGame.ac3.id }) {
                        Button("Copy Existing AC III…") { model.importExisting(into: bottle) }.disabled(running || model.busy)
                    }
                    Divider()
                    Button("Open C: Drive in Finder") { model.reveal(model.service.paths.bottle(bottle).drive) }
                } label: { Label("Programs", systemImage: "square.grid.2x2") }
                    .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 12).frame(height: 30)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.1))).disabled(!usable)
                if running {
                    Button { model.stop(bottle) } label: { Label("Stop Session", systemImage: "stop.fill").frame(height: 30) }.buttonStyle(PortnautButtonStyle(primary: false))
                }
            }
            if !model.runtimeReady {
                Text(model.runtimeOutdated ? "Update Portnaut in the Library first." : "Prepare Portnaut in the Library first.").font(.system(size: 11)).foregroundStyle(Palette.accent)
            }
        }
    }
}

final class NewBottleDraft: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case ubisoft = "Ubisoft Connect", steam = "Steam", ea = "EA app", general = "Empty bottle"
        var id: String { rawValue }
        var launcher: Launcher? {
            switch self {
            case .ubisoft: .ubisoft
            case .steam: .steam
            case .ea: .ea
            case .general: nil
            }
        }
        var recommendation: Recommendation { launcher?.recommendation ?? GraphicsAdvisor.recommendation(for: Bottle(id: "", name: "", renderer: .dxmt), analyses: []) }
        var defaultName: String { self == .general ? "Games" : rawValue }
    }
    /// Choosing a type resets the name and renderer to that type's defaults.
    @Published var kind = Kind.ubisoft { didSet { name = kind.defaultName; renderer = kind.recommendation.renderer } }
    @Published var name = Kind.ubisoft.defaultName
    @Published var renderer = Kind.ubisoft.recommendation.renderer
    @Published var windows = WindowsVersion.win10
}

struct NewBottleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = NewBottleDraft()

    var body: some View {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 18) {
            Text("New Bottle").font(.system(size: 22, weight: .medium, design: .rounded))
            Picker("Type", selection: $draft.kind) { ForEach(NewBottleDraft.Kind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 8) {
                Picker("Renderer", selection: $draft.renderer) { ForEach(Renderer.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Text("Recommended: \(draft.kind.recommendation.renderer.title). \(draft.kind.recommendation.reason)").font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if let note = draft.renderer.licenseNote { Text(note).font(.system(size: 11)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true) }
            }
            Picker("Windows version", selection: $draft.windows) { ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 300)
            Text("The renderer, Windows version and other settings can be changed later in the bottle’s settings.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.createBottle(name: name, launcher: draft.kind.launcher, renderer: draft.renderer, windowsVersion: draft.windows)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || model.busy)
            }
        }.padding(26).frame(width: 520).background(Palette.background)
    }
}
