import SwiftUI
import PortnautCore

/// Portnaut › Settings… (⌘,): app-wide choices. Each bottle's own settings stay in Bottles.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                UpdatesCard(updater: model.appUpdater)
                newBottles
                performance
                coverArt
                dataFolder
            }.padding(24)
        }
        .frame(width: 560, height: 640)
        .background(Palette.background)
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
    }

    private var newBottles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New bottles").font(.system(size: 15, weight: .semibold))
            Picker("Windows version", selection: setting(\.newBottleWindowsVersion)) {
                ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
            }.frame(maxWidth: 320)
            OldWindowsNote(version: model.settings.newBottleWindowsVersion)
            Toggle("Record performance in new bottles", isOn: setting(\.recordPerformanceInNewBottles)).toggleStyle(.switch)
            note("New bottles and Install from File start with these. Each bottle can change them in Bottles.")
        }.card(padding: 18)
    }

    private var performance: some View {
        let bottles = model.library.bottles
        let recording = bottles.filter(\.options.recordPerformance).count
        return VStack(alignment: .leading, spacing: 10) {
            Text("Performance recording").font(.system(size: 15, weight: .semibold))
            note("When a bottle records performance, Portnaut notes each game session’s frame rate in its log and shows it in the Performance panel. It stays on your Mac. \(bottles.isEmpty ? "You have no bottles yet." : "\(recording) of \(bottles.count) bottles record it now.")")
            HStack(spacing: 8) {
                Button("Turn Off in All Bottles") { model.setRecordingInAllBottles(false) }
                    .buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 28).disabled(recording == 0)
                Button("Turn On in All Bottles") { model.setRecordingInAllBottles(true) }
                    .buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 28).disabled(recording == bottles.count)
            }
        }.card(padding: 18)
    }

    private var coverArt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cover art").font(.system(size: 15, weight: .semibold))
            note("Steam games show the cover art Steam keeps on your Mac.")
            Toggle("Download missing cover art from Steam", isOn: setting(\.downloadSteamArtwork)).toggleStyle(.switch)
            note("Fetches a Steam game’s images from Steam’s image server when Steam has none on your Mac. Valve then sees which games’ images were asked for, so it’s off unless you turn it on.")
        }.card(padding: 18)
    }

    private var dataFolder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Data folder").font(.system(size: 15, weight: .semibold))
            Text(verbatim: model.service.paths.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
            note("Bottles, the Windows runtime, downloads, snapshots and logs. Save backups are in Documents › Portnaut Backups.")
            Button("Show in Finder") { model.reveal(model.service.paths.root) }
                .buttonStyle(PortnautButtonStyle(primary: false)).frame(height: 28)
        }.card(padding: 18)
    }

    private func setting<Value>(_ key: WritableKeyPath<PortnautSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: key] }, set: { value in model.changeSettings { $0[keyPath: key] = value } })
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
}
