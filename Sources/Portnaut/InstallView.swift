import SwiftUI
import AppKit
import PortnautCore

/// Value "new" stands for a new bottle.
final class InstallDraft: ObservableObject {
    @Published var target: String
    @Published var name: String
    @Published var renderer = GraphicsAdvisor.recommendation(for: Bottle(id: "", name: "", renderer: .dxmt), analyses: []).renderer
    @Published var windows = WindowsVersion.win10
    init(target: String, file: URL) {
        self.target = target
        name = Library.suggestedBottleName(forInstaller: file.lastPathComponent)
    }
}

/// Install from File: an installer from the Mac, run in an existing or a new bottle.
struct InstallSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: InstallDraft
    let file: URL

    init(install: PendingInstall, defaultBottle: String?) {
        file = install.file
        _draft = StateObject(wrappedValue: InstallDraft(target: install.bottleID ?? defaultBottle ?? "new", file: install.file))
    }

    var body: some View {
        let creating = draft.target == "new"
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let chosen = model.library.bottle(draft.target)
        let general = GraphicsAdvisor.recommendation(for: Bottle(id: "", name: "", renderer: .dxmt), analyses: [])
        VStack(alignment: .leading, spacing: 18) {
            Text("Install a Windows Program").font(.system(size: 22, weight: .medium, design: .rounded))
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(file.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                }
            }.card(padding: 14)
            Picker("Install into", selection: $draft.target) {
                ForEach(model.library.bottles.filter { model.ready($0) }) { Text($0.name).tag($0.id) }
                Divider()
                Text("New Bottle").tag("new")
            }.frame(maxWidth: 360)
            if creating {
                TextField("Bottle name", text: $draft.name).textFieldStyle(.roundedBorder)
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Renderer", selection: $draft.renderer) { ForEach(Renderer.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    Text("Recommended for now: \(general.renderer.title). An installer does not show which graphics API its game uses; once it has finished, Portnaut reads the installed programs and recommends a renderer for each.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    if let note = draft.renderer.licenseNote { Text(note).font(.system(size: 11)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true) }
                }
                Picker("Windows version", selection: $draft.windows) { ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 300)
            } else if let chosen {
                Text("\(chosen.name) uses \(chosen.renderer.title)\(model.sessionActive(chosen) ? " and is running; the installer runs alongside its programs" : "").")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Text("While the installer runs, its folder appears to Windows as drive H:, so installers with extra files beside them work. Portnaut then lists the programs it installed.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") {
                    model.install(file, into: creating ? .new(name: name, renderer: draft.renderer, windows: draft.windows) : .existing(draft.target))
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(model.busy || (creating ? name.isEmpty : chosen == nil))
            }
        }.padding(26).frame(width: 540).background(Palette.background)
    }
}

final class ProgramSelection: ObservableObject {
    @Published var chosen: Set<String>
    @Published var switchRenderer: Bool
    init(chosen: Set<String>, switchRenderer: Bool) { self.chosen = chosen; self.switchRenderer = switchRenderer }
}

/// The programs found in a bottle, each with its renderer recommendation, to add to the library.
struct ProgramPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var selection: ProgramSelection
    let choice: ProgramChoice

    init(choice: ProgramChoice, bottleHasGames: Bool) {
        self.choice = choice
        // A fresh bottle follows its programs' recommendation unless the user says otherwise.
        _selection = StateObject(wrappedValue: ProgramSelection(chosen: Set(choice.programs.map(\.id)), switchRenderer: !bottleHasGames))
    }

    var body: some View {
        if let bottle = model.library.bottle(choice.bottleID) { content(bottle) }
    }

    private func content(_ bottle: Bottle) -> some View {
        let picked = choice.programs.filter { selection.chosen.contains($0.id) }
        let existing = bottle.games.compactMap { model.analyses["\(bottle.id)/\($0.id)"] }
        let suggestion = GraphicsAdvisor.recommendation(for: Bottle(id: bottle.id, name: bottle.name, renderer: bottle.renderer),
                                                        analyses: existing + picked.compactMap { choice.analyses[$0.id] })
        let running = model.sessionActive(bottle)
        return VStack(alignment: .leading, spacing: 16) {
            Text(choice.afterInstall ? "Installed in \(bottle.name)" : "Programs in \(bottle.name)").font(.system(size: 22, weight: .medium, design: .rounded))
            Text("Choose what goes in your library. Each program shows the renderer Portnaut recommends for it.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(choice.programs) { program in row(program, bottle: bottle) }
                }
            }.frame(maxHeight: 320)
            if !picked.isEmpty, suggestion.renderer != bottle.renderer {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Switch \(bottle.name) to \(suggestion.renderer.title)", isOn: $selection.switchRenderer).toggleStyle(.switch).disabled(running)
                    Text(running ? "Stop \(bottle.name)’s session first to switch its renderer." : suggestion.reason)
                        .font(.system(size: 11)).foregroundStyle(running ? Palette.accent : Palette.muted).fixedSize(horizontal: false, vertical: true)
                    if let note = suggestion.renderer.licenseNote { Text(note).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
                }.card(padding: 14)
            }
            HStack {
                Spacer()
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(picked.count) to Library") {
                    model.addPrograms(picked, to: bottle, renderer: selection.switchRenderer && !running && suggestion.renderer != bottle.renderer ? suggestion.renderer : nil)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }.padding(26).frame(width: 620).background(Palette.background)
    }

    private func row(_ program: DetectedProgram, bottle: Bottle) -> some View {
        let analysis = choice.analyses[program.id]
        let apis = (analysis.map { $0.imported.isEmpty ? $0.mentioned : $0.imported } ?? []).map(\.title).joined(separator: ", ")
        return Toggle(isOn: Binding(get: { selection.chosen.contains(program.id) },
                                    set: { if $0 { selection.chosen.insert(program.id) } else { selection.chosen.remove(program.id) } })) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(program.name).font(.system(size: 13, weight: .medium))
                    Text("C:\\" + program.executable.replacingOccurrences(of: "/", with: "\\")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                    Text([program.launcherArguments != nil ? "Starts through \(bottle.launcher?.title ?? "its launcher")" : nil, program.source.rawValue,
                          analysis.map { "\($0.is64Bit ? "64-bit" : "32-bit") · \(apis.isEmpty ? "no graphics API found" : apis)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                RendererBadge(current: bottle.renderer, recommended: analysis?.recommendation)
            }
        }.toggleStyle(.checkbox).padding(.vertical, 8).padding(.horizontal, 10).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
    }
}
