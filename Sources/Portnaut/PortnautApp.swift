import SwiftUI
import AppKit
import PortnautCore

@main
struct PortnautApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            PortnautView().environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 760)
                .onAppear { NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1180, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bottle…") { model.showingNewBottle = true }.keyboardShortcut("n").disabled(!model.runtimeReady)
                Button("Install from File…") { model.chooseInstaller() }.keyboardShortcut("i").disabled(!model.runtimeReady || model.busy)
                Divider()
                Button("Will It Run?…") { model.showingWillItRun = true }.keyboardShortcut("k")
                Button(model.couchMode ? "Leave Couch Mode" : "Couch Mode") { model.couchMode ? model.exitCouchMode() : model.enterCouchMode() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Component Updates…") { model.openComponentUpdates() }.disabled(!model.runtimeReady)
                Divider()
                Button("Open Portnaut Data Folder") { model.reveal(model.service.paths.root) }
                Button("Export Diagnostics…") { model.exportDiagnostics() }
            }
            CommandGroup(replacing: .help) {
                Button("Email \(Publisher.name) Support…") { NSWorkspace.shared.open(Publisher.supportMail) }
                Button("Export Diagnostics…") { model.exportDiagnostics() }
            }
        }
    }
}

struct PortnautView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                HStack {
                    Text(model.page.rawValue).font(.system(size: 14, weight: .semibold))
                    if model.page == .bottles, let bottle = model.selectedBottle { crumb(bottle.name) }
                    if model.page == .library, let entry = model.selectedEntry { crumb(entry.game.name) }
                    Spacer()
                    if model.page == .library {
                        if !model.entries.isEmpty {
                            Button { model.enterCouchMode() } label: { Label("Couch Mode", systemImage: "tv").frame(height: 28) }
                                .buttonStyle(PortnautButtonStyle(primary: false)).padding(.trailing, 8).help("The library full screen, for a controller (⇧⌘T)")
                        }
                        Button { model.showingWillItRun = true } label: { Label("Will It Run?", systemImage: "magnifyingglass").frame(height: 28) }
                            .buttonStyle(PortnautButtonStyle(primary: false)).padding(.trailing, 8)
                    }
                    if model.runtimeReady, model.page == .library || model.page == .bottles {
                        Button { model.chooseInstaller() } label: { Label("Install from File…", systemImage: "square.and.arrow.down.on.square").frame(height: 28) }
                            .buttonStyle(PortnautButtonStyle(primary: false)).disabled(model.busy).padding(.trailing, 14)
                    }
                    Text("EARLY ACCESS  /  \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(Palette.muted)
                }.padding(.horizontal, 30).frame(height: 68)
                Rectangle().fill(Palette.line).frame(height: 1)
                Group {
                    switch model.page {
                    case .library: ScrollView { LibraryPage().padding(30).frame(maxWidth: 1180) }
                    case .bottles: BottlesPage()
                    case .setup: ScrollView { SetupPage().padding(30).frame(maxWidth: 1180) }
                    case .diagnostics: ScrollView { DiagnosticsPage().padding(30).frame(maxWidth: 1180) }
                    case .about: ScrollView { AboutPage().padding(30).frame(maxWidth: 1180) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                HStack(spacing: 7) {
                    Circle().fill(model.sessions.isEmpty ? Palette.cyan : Palette.accent).frame(width: 5, height: 5)
                    Text(statusText).font(.system(size: 11))
                    if model.busy { ProgressView(value: model.progress).frame(width: 120).tint(Palette.accent) }
                    Text(model.message).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text("\(model.freeSpace) available").font(.system(size: 11, design: .monospaced))
                }.foregroundStyle(Palette.muted).padding(.horizontal, 30).frame(height: 34)
            }
        }
        .background(Palette.background)
        // Couch mode covers the whole window, sidebar included.
        .overlay { if model.couchMode { CouchView() } }
        .tint(Palette.accent)
        .alert("Portnaut needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Open Diagnostics") { model.page = .diagnostics; model.readLog(); model.error = nil }
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showingNewBottle) { NewBottleSheet().environmentObject(model) }
        .background(EmptyView().sheet(isPresented: $model.showingWillItRun) { WillItRunSheet().environmentObject(model) })
        .alert("This game won’t run", isPresented: Binding(get: { model.downloadWarning != nil }, set: { if !$0 { model.downloadWarning = nil } })) {
            Button("OK", role: .cancel) { model.downloadWarning = nil }
        } message: { Text(model.downloadWarning ?? "") }
        // One sheet per view: the install and program sheets hang off their own empty views.
        .background(EmptyView().sheet(item: $model.pendingInstall) { InstallSheet(install: $0, defaultBottle: model.page == .bottles ? model.selectedBottle?.id : nil).environmentObject(model) })
        .background(EmptyView().sheet(item: $model.programChoice) { choice in
            ProgramPicker(choice: choice, bottleHasGames: !(model.library.bottle(choice.bottleID)?.games.isEmpty ?? true)).environmentObject(model)
        })
        .background(EmptyView().sheet(item: $model.editingGame) { GameSettingsSheet(entry: $0).environmentObject(model) })
        .background(EmptyView().sheet(isPresented: $model.showingUpdates) { ComponentUpdatesSheet().environmentObject(model) })
        .background(EmptyView().sheet(item: $model.editingEnvironment) { EnvironmentSheet(bottle: $0).environmentObject(model) })
        .alert("Take a Snapshot", isPresented: Binding(get: { model.namingSnapshot != nil }, set: { if !$0 { model.namingSnapshot = nil } })) {
            TextField("Name", text: $model.snapshotName)
            Button("Take Snapshot") { if let bottle = model.namingSnapshot { model.takeSnapshot(bottle, label: model.snapshotName) }; model.namingSnapshot = nil }
            Button("Cancel", role: .cancel) { model.namingSnapshot = nil }
        } message: { Text("Portnaut clones \(model.namingSnapshot?.name ?? "the bottle") as it is now.") }
        // Dropping a Windows installer on the window starts Install from File.
        .dropDestination(for: URL.self) { urls, _ in
            guard let file = urls.first, model.pendingInstall == nil, !model.busy else { return false }
            return model.beginInstall(file)
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var statusText: String {
        if !model.sessions.isEmpty {
            let names = model.library.bottles.filter { model.sessions.contains($0.id) }.map(\.name)
            return "Running: \(names.joined(separator: ", "))"
        }
        if model.busy { return "Working" }
        if model.runtimeOutdated { return "Update needed" }
        return model.runtimeReady ? "Ready" : "Ready to set up"
    }
    private func crumb(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.muted)
            Text(text).font(.system(size: 13)).foregroundStyle(Palette.muted)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 34, height: 34)
                Text("Portnaut").font(.system(size: 24, weight: .bold, design: .rounded)).tracking(-0.6)
            }.padding(.top, 52).padding(.bottom, 44).padding(.horizontal, 25)
            Text("YOUR SPACE").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(Palette.muted).padding(.horizontal, 26).padding(.bottom, 14)
            nav(.library, icon: "square.grid.2x2", count: model.entries.count)
            nav(.bottles, icon: "shippingbox", count: model.library.bottles.count)
            nav(.setup, icon: "slider.horizontal.3")
            nav(.diagnostics, icon: "waveform.path.ecg")
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                // Not Apple's logo: Apple does not allow it in other developers' apps.
                Image(systemName: "sparkles").font(.system(size: 16)).foregroundStyle(Palette.muted)
                Text("Native on your Mac.").font(.system(size: 12, weight: .medium))
                Text("Windows games,\ncleared for launch.").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.padding(24)
            Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, 20)
            nav(.about, icon: "info.circle").padding(.vertical, 15)
        }.background(Palette.sidebar)
    }
    private func nav(_ page: Page, icon: String, count: Int? = nil) -> some View {
        Button {
            model.page = page
            if page == .diagnostics { model.readLog() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                Text(page.rawValue).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                Spacer()
                if let count { Text("\(count)").font(.system(size: 10, design: .monospaced)).opacity(0.65) }
            }.foregroundStyle(model.page == page ? Color.white : Palette.muted)
                .padding(.horizontal, 14).frame(height: 43)
                .background(model.page == page ? Color.white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) { if model.page == page { Capsule().fill(Palette.accent).frame(width: 2, height: 18) } }
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
    }
}
