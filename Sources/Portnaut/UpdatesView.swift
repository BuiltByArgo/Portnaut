import SwiftUI
import PortnautCore

/// Portnaut › Check for Component Updates…: Wine, DXMT, the template's renderers and libraries, and
/// MoltenVK, on the Stable or Latest channel.
struct ComponentUpdatesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let installed = model.installedRuntime
        let offered = model.updateCheck?.set(for: model.updateChannel)
        let changes = offered.flatMap { set in installed.map { set.changes(from: $0.set) } } ?? []
        let parts = RuntimePart.allCases.filter { installed?.set.release($0) != nil || offered?.release($0) != nil }
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Component Updates").font(.system(size: 22, weight: .medium, design: .rounded))
                Text("Wine, the renderers and the libraries they use. Portnaut builds the new set beside the current one, takes a snapshot of every bottle, then switches, keeping the current set so you can roll back.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Picker("Channel", selection: $model.updateChannel) {
                    ForEach(UpdateChannel.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Text(model.updateChannel == .stable
                     ? "Highball’s tested set\(model.updateCheck.map { " (\($0.stable.label.replacingOccurrences(of: "Highball ", with: "")))" } ?? "")."
                     : "The newest build of each part, not yet tested together.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                if model.checkingUpdates { ProgressView().controlSize(.small) }
                Button("Check Again") { model.checkForUpdates() }.buttonStyle(.link).font(.system(size: 12)).disabled(model.checkingUpdates)
            }
            if let error = model.updateCheckError {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Palette.accent)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    ForEach(["Component", "Installed", model.updateChannel.title, ""], id: \.self) {
                        Text($0.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.1).foregroundStyle(Palette.muted)
                    }
                }
                ForEach(parts) { part in
                    let current = installed?.set.release(part), next = offered?.release(part)
                    GridRow(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(part.title).font(.system(size: 12, weight: .medium))
                            if part == .support, let details = installed?.details {
                                Text(["D3DMetal", "DXVK", "D9VK"].compactMap { key in details[key].map { "\(key) \($0)" } }.joined(separator: " · "))
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                        }.frame(width: 210, alignment: .leading)
                        Text(label(current, part) ?? (part == .moltenvk ? "the template’s" : "–")).font(.system(size: 11)).frame(width: 220, alignment: .leading)
                        Text(label(next, part) ?? (offered == nil ? "…" : part == .moltenvk ? "the template’s" : "–")).font(.system(size: 11))
                            .foregroundStyle(changes.contains(part) ? Palette.accent : Color.primary).frame(width: 220, alignment: .leading)
                        if offered != nil {
                            Tag(text: changes.contains(part) ? (next?.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Update") : "Up to date",
                                tint: changes.contains(part) ? Palette.accent : Palette.cyan)
                        }
                    }
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("MetalFX").font(.system(size: 12, weight: .medium)).frame(width: 210, alignment: .leading)
                    Text("Part of macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)")
                        .font(.system(size: 11)).frame(width: 220, alignment: .leading)
                    Text("Updates with macOS; DXMT and D3DMetal use it.").font(.system(size: 11)).foregroundStyle(Palette.muted).gridCellColumns(2)
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("Wine Mono and Gecko").font(.system(size: 12, weight: .medium)).frame(width: 210, alignment: .leading)
                    Text("Come with Wine").font(.system(size: 11)).foregroundStyle(Palette.muted).gridCellColumns(3)
                }
            }.card(padding: 16)

            if model.updateChannel == .stable, let notes = model.updateCheck?.stable.notes {
                Text("Highball’s note: \(notes)").font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            if model.updateChannel == .latest {
                Text((["Latest takes Highball’s newest Wine and DXMT builds (not the ones marked trial), Sikarugir’s newest template, whose D3DMetal may be an Apple beta, and upstream MoltenVK only when it is newer than Highball’s patched build. Each download is checked against the SHA-256 GitHub publishes for it."]
                      + (model.updateCheck?.latestNotes ?? [])).joined(separator: " "))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !model.sessions.isEmpty {
                Label("Stop running Windows sessions before updating.", systemImage: "pause.circle").font(.system(size: 11)).foregroundStyle(Palette.accent)
            }

            HStack(spacing: 12) {
                if let previous = model.previousRuntime {
                    ConfirmingButton(title: "Roll Back…", prompt: "Go back to \(previous.set.label)?",
                                     detail: "Portnaut switches back to the components from before the last update, after a snapshot of every bottle. The current ones are kept for switching again.",
                                     action: "Roll Back") { model.rollBackComponents() }
                        .disabled(model.busy || !model.sessions.isEmpty)
                }
                if model.busy { ProgressView(value: model.progress).frame(width: 140); Text(model.message).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(changes.isEmpty ? "Up to Date" : "Update · \(ByteCountFormatter.string(fromByteCount: offered.flatMap { set in installed.map { set.downloadSize(from: $0.set) } } ?? 0, countStyle: .file))") {
                    model.installComponentUpdates()
                }.keyboardShortcut(.defaultAction).disabled(changes.isEmpty || model.busy || !model.sessions.isEmpty || installed == nil)
            }
        }.padding(26).frame(width: 820).background(Palette.background)
    }

    /// The template row names Sikarugir's template version; its D3DMetal and DXVK are listed below it.
    private func label(_ release: ComponentRelease?, _ part: RuntimePart) -> String? {
        release.map { part == .support ? "Sikarugir template \($0.version)" : $0.version }
    }
}
