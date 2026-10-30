import SwiftUI
import PortnautCore

struct LibraryPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            if !model.runtimeReady { runtimePrompt }
            else if let entry = model.selectedEntry {
                FeaturedGame(entry: entry)
                if model.entries.count > 1 {
                    SectionTitle(title: "All games", symbol: "square.grid.2x2")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                        ForEach(model.entries) { GameCard(entry: $0) }
                    }
                }
            } else { emptyLibrary }
        }
    }

    private var runtimePrompt: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.runtimeOutdated ? "Update Portnaut" : "Set up Portnaut").font(.system(size: 24, weight: .medium, design: .rounded))
                Text(model.runtimeOutdated
                     ? "Portnaut now keeps a copy of Wine per renderer (DXMT, D3DMetal, DXVK and Wine’s own) and organises games into bottles. Update once; your Windows environment, games and sign-ins are kept."
                     : "Portnaut downloads Wine and its renderers once, checks them against pinned hashes, and keeps everything in its own data folder.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if !WineService.rosettaInstalled {
                    Text(WineService.rosettaMissing).font(.system(size: 12)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: model.prepare) { Label(model.runtimeOutdated ? "Update Portnaut" : "Prepare Portnaut", systemImage: "arrow.down.circle").frame(minWidth: 170, minHeight: 42) }
                .buttonStyle(PortnautButtonStyle(primary: true)).disabled(model.busy)
        }.card(padding: 26)
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading(title: "Your library is empty.", subtitle: "Create a bottle for Steam, the EA app or Ubisoft Connect, or install any Windows program.")
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "New bottle", symbol: "shippingbox")
                    Text("A separate Windows environment with its own renderer and settings, for a launcher or your own games.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Button("New Bottle…") { model.showingNewBottle = true }.buttonStyle(PortnautButtonStyle(primary: true)).frame(height: 32)
                }.card()
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Install from file", symbol: "square.and.arrow.down.on.square")
                    Text("Run a Windows installer (.exe or .msi), or drop one on this window. Portnaut then recommends a renderer for what it installed.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Button("Install from File…") { model.chooseInstaller() }.buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 32)
                }.card()
                if let bottle = model.library.bottles.first {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Add a game", symbol: "plus.square")
                        Text("Choose a game’s .exe inside \(bottle.name).").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Button("Add Game…") { model.addGame(to: bottle) }.buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 32)
                    }.card()
                }
            }
        }
    }
}

/// The selected or most recently played game, large.
struct FeaturedGame: View {
    @EnvironmentObject var model: AppModel
    var entry: LibraryEntry
    var body: some View {
        let analysis = model.analyses[entry.id]
        let running = model.sessionActive(entry.bottle)
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .leading) {
                if entry.game.id == KnownGame.ac3.id { FrontierScene() } else { SpaceScene(seed: entry.game.name) }
                LinearGradient(colors: [Palette.background.opacity(0.96), Palette.background.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Circle().fill(Palette.accent).frame(width: 5, height: 5)
                        Text(entry.game.lastPlayedAt == nil ? "READY TO PLAY" : "CONTINUE PLAYING").font(.system(size: 9, weight: .bold)).tracking(2.3)
                    }.foregroundStyle(Palette.accent).padding(.bottom, 20)
                    Text(entry.game.name).font(.system(size: 38, weight: .medium, design: .rounded)).tracking(-1.2).lineLimit(2).frame(maxWidth: 520, alignment: .leading)
                    HStack(spacing: 8) {
                        Tag(text: entry.bottle.name)
                        if entry.game.launcherArguments != nil, let launcher = entry.bottle.launcher { Tag(text: launcher.title) }
                        if let analysis, let api = analysis.imported.first ?? analysis.mentioned.first { Tag(text: api.title) }
                        RendererBadge(current: entry.bottle.renderer, recommended: analysis?.recommendation)
                    }.padding(.top, 22)
                }.padding(30)
            }.frame(height: 270).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))

            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(running ? "\(entry.bottle.name) is running" : "Ready").font(.system(size: 17, weight: .semibold))
                    Text(analysis?.recommendation.reason ?? "The game’s files are not at their saved location.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if running {
                    Button { model.stop(entry.bottle) } label: { Label("Stop session", systemImage: "stop.fill").frame(width: 145, height: 39) }
                        .buttonStyle(PortnautButtonStyle(primary: false))
                }
                Button { model.editingGame = entry } label: { Image(systemName: "slider.horizontal.3").frame(width: 42, height: 42) }
                    .buttonStyle(PortnautButtonStyle(primary: false)).help("Game Settings")
                // A game its launcher starts can be played while the launcher is open.
                if !running || model.canPlay(entry) {
                    Button { model.play(entry) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 150, minHeight: 42) }
                        .buttonStyle(PortnautButtonStyle(primary: true)).disabled(!model.canPlay(entry) || analysis == nil)
                }
            }
            PerformanceCard(entry: entry)
            if let analysis, analysis.recommendation.renderer != entry.bottle.renderer {
                HStack(spacing: 10) {
                    Image(systemName: "lightbulb").foregroundStyle(Palette.accent)
                    Text("\(entry.game.name) recommends \(analysis.recommendation.renderer.title); \(entry.bottle.name) uses \(entry.bottle.renderer.title). Change it in the bottle’s settings, or give the game its own bottle.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Bottle Settings") { model.selectedBottleID = entry.bottle.id; model.page = .bottles }.buttonStyle(.link)
                }.card(padding: 14)
            }
        }
    }
}

struct GameCard: View {
    @EnvironmentObject var model: AppModel
    var entry: LibraryEntry
    var body: some View {
        let analysis = model.analyses[entry.id]
        Button { model.selectedEntryID = entry.id } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    if entry.game.id == KnownGame.ac3.id { FrontierScene() } else { SpaceScene(seed: entry.game.name) }
                    LinearGradient(colors: [.clear, Palette.background.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    Text(entry.game.name).font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(2).padding(12)
                }.frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 9))
                HStack(spacing: 6) {
                    Text(entry.bottle.name).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer()
                    RendererBadge(current: entry.bottle.renderer, recommended: analysis?.recommendation)
                }
            }.padding(10).background(model.selectedEntry?.id == entry.id ? Color.white.opacity(0.08) : Palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.selectedEntry?.id == entry.id ? Palette.accent.opacity(0.6) : .clear))
        }.buttonStyle(.plain)
        .contextMenu {
            Button("Play") { model.play(entry) }.disabled(!model.canPlay(entry))
            Button("Show in Finder") { if let url = model.service.paths.bottle(entry.bottle).url(for: entry.game.executable) { model.reveal(url.deletingLastPathComponent()) } }
            Button("Game Settings…") { model.editingGame = entry }
            Button("Bottle Settings") { model.selectedBottleID = entry.bottle.id; model.page = .bottles }
            Divider()
            Button("Remove from Library") { model.removeGame(entry) }
        }
    }
}
