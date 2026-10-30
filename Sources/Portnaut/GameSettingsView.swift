import SwiftUI
import PortnautCore

struct VariableRow: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}

struct DllRow: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var mode: DllOverride
}

extension Array where Element == VariableRow {
    init(_ environment: [String: String]) { self = environment.sorted { $0.key < $1.key }.map { VariableRow(key: $0.key, value: $0.value) } }
    /// Rows with a name; nil when one is not allowed.
    var environment: [String: String]? {
        var result: [String: String] = [:]
        for row in self {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            guard EnvironmentPolicy.allows(key) else { return nil }
            result[key] = row.value
        }
        return result
    }
    var problem: String? {
        guard let bad = first(where: { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty && !EnvironmentPolicy.allows($0.key.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        return "\(bad.key) cannot be used: names are letters, digits and underscores, and Portnaut sets PATH, WINEPREFIX, WINEARCH, WINEDLLOVERRIDES, DYLD_ and PORTNAUT_ variables itself."
    }
}

final class GameSettingsDraft: ObservableObject {
    @Published var name: String
    @Published var arguments: String
    @Published var windowsVersion: WindowsVersion?
    @Published var dlls: [DllRow]
    @Published var variables: [VariableRow]
    init(_ game: Game) {
        name = game.name
        arguments = ProgramScanner.joinCommandLine(game.arguments)
        windowsVersion = game.windowsVersion
        dlls = game.dllOverrides.sorted { $0.key < $1.key }.map { DllRow(name: $0.key, mode: $0.value) }
        variables = [VariableRow](game.environment)
    }
    func applied(to game: Game) -> Game? {
        guard let environment = variables.environment else { return nil }
        var game = game
        game.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? game.name : name.trimmingCharacters(in: .whitespaces)
        game.arguments = ProgramScanner.splitCommandLine(arguments)
        game.windowsVersion = windowsVersion
        game.environment = environment
        game.dllOverrides = Dictionary(dlls.compactMap { row -> (String, DllOverride)? in
            let name = row.name.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ".dll", with: "")
            return name.isEmpty ? nil : (name, row.mode)
        }, uniquingKeysWith: { $1 })
        return game
    }
}

/// Environment variable rows with add and remove.
struct VariablesEditor: View {
    @Binding var rows: [VariableRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                HStack(spacing: 8) {
                    TextField("NAME", text: $row.key).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 220)
                    Text("=").foregroundStyle(Palette.muted)
                    TextField("value", text: $row.value).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                }
            }
            Button { rows.append(VariableRow(key: "", value: "")) } label: { Label("Add Variable", systemImage: "plus") }.buttonStyle(.link).font(.system(size: 12))
            if let problem = rows.problem { Text(problem).font(.system(size: 11)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A game's own settings: name, arguments, Windows version, DLL overrides and environment.
struct GameSettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: GameSettingsDraft
    let entry: LibraryEntry

    init(entry: LibraryEntry) {
        self.entry = entry
        _draft = StateObject(wrappedValue: GameSettingsDraft(entry.game))
    }

    var body: some View {
        let game = entry.game, bottle = entry.bottle
        let viaLauncher = game.launcherArguments != nil
        let sharing = bottle.games.filter { $0.id != game.id && $0.programName.caseInsensitiveCompare(game.programName) == .orderedSame }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(game.name) Settings").font(.system(size: 22, weight: .medium, design: .rounded))
                // Verbatim: a localized Text key would read the backslash before the path as an escape.
                Text(verbatim: "\(bottle.name) · C:\\\(game.executable.replacingOccurrences(of: "/", with: "\\"))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.middle)
            }.padding([.horizontal, .top], 26).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Name") { TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder) }
                    section("Launch arguments") {
                        TextField("e.g. -windowed -dx11", text: $draft.arguments).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        note(viaLauncher ? "Passed to the game through \(bottle.launcher?.title ?? "its launcher") (after -applaunch). Quotes group words." : "Quotes group words, as on Windows.")
                    }
                    section("Windows version") {
                        Picker("Windows version", selection: $draft.windowsVersion) {
                            Text("Same as bottle (\(bottle.windowsVersion.title))").tag(WindowsVersion?.none)
                            ForEach(WindowsVersion.allCases) { Text($0.title).tag(Optional($0)) }
                        }.labelsHidden().frame(maxWidth: 320)
                    }
                    section("DLL overrides") {
                        ForEach($draft.dlls) { $row in
                            HStack(spacing: 8) {
                                TextField("dinput8", text: $row.name).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 220)
                                Picker("Mode", selection: $row.mode) { ForEach(DllOverride.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 200)
                                Button { draft.dlls.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                            }
                        }
                        Button { draft.dlls.append(DllRow(name: "", mode: .nativeThenBuiltin)) } label: { Label("Add Override", systemImage: "plus") }.buttonStyle(.link).font(.system(size: 12))
                        note("For DLLs a game or mod ships beside its program, such as dinput8 or xinput1_3. Graphics DLLs (d3d11, dxgi, d3d12, d3d9) follow the bottle’s renderer: Wine ignores overrides for its own renderer modules.")
                    }
                    section("Environment variables") {
                        VariablesEditor(rows: $draft.variables)
                        note(viaLauncher ? "\(game.name) starts through \(bottle.launcher?.title ?? "its launcher"), which passes on its own environment, so these do not reach it. Set variables on the bottle instead." : "Added when Portnaut starts the game. Variables for every program go in the bottle’s settings.")
                    }
                    if !sharing.isEmpty {
                        Label("Windows version and DLL overrides apply to every program called \(game.programName) in \(bottle.name), including \(sharing.map(\.name).joined(separator: ", ")).", systemImage: "info.circle")
                            .font(.system(size: 11)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.horizontal, 26).padding(.bottom, 10)
            }
            HStack {
                Text(model.sessionActive(bottle) ? "Applies the next time the game starts." : "").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let updated = draft.applied(to: game) { model.saveGame(updated, in: bottle); dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(draft.variables.problem != nil)
            }.padding(26)
        }.frame(width: 640, height: 660).background(Palette.background)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(Palette.muted)
            content()
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
}

final class VariablesDraft: ObservableObject {
    @Published var rows: [VariableRow]
    init(_ environment: [String: String]) { rows = [VariableRow](environment) }
}

/// Environment variables for every program of a bottle.
struct EnvironmentSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: VariablesDraft
    let bottle: Bottle

    init(bottle: Bottle) {
        self.bottle = bottle
        _draft = StateObject(wrappedValue: VariablesDraft(bottle.environment))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(bottle.name) Environment").font(.system(size: 22, weight: .medium, design: .rounded))
            Text("Variables for every program in the bottle, launchers and the games they start included. They take effect when the bottle’s next session starts.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            VariablesEditor(rows: $draft.rows)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let environment = draft.rows.environment, var updated = model.library.bottle(bottle.id) else { return }
                    updated.environment = environment
                    model.save(updated)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(draft.rows.problem != nil)
            }
        }.padding(26).frame(width: 620).background(Palette.background)
    }
}
