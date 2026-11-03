import AppKit
import SwiftUI
import PortnautCore

struct SetupPage: View {
    @EnvironmentObject var model: AppModel
    /// What the installed runtime was built from, with the versions read from its files.
    private var components: [(String, String, String)] {
        let installed = model.installedRuntime
        let details = installed?.details ?? [:]
        func version(_ part: RuntimePart) -> String { installed?.set.release(part)?.version ?? "not installed" }
        return [
            ("Wine", version(.wine), "Highball’s build of CodeWeavers’ published Wine sources (LGPL)"),
            ("DXMT", version(.dxmt), "DirectX 10/11 to Metal, Highball’s fork (LGPL)"),
            ("D3DMetal", details["D3DMetal"].map { "\($0) (template \(version(.support)))" } ?? version(.support), "Apple’s DirectX 11/12 translation (Apple licence)"),
            ("DXVK", details["DXVK"] ?? "template \(version(.support))", "DirectX 9–11 over Vulkan, with D9VK (zlib)"),
            ("MoltenVK", installed?.set.release(.moltenvk)?.version ?? "the template’s", "Vulkan on Metal (Apache 2.0)"),
            ("MetalFX", "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)", "Apple’s upscaling; updates with macOS"),
            ("Portnaut Metal shim", "bundled", "Dual-source blending fix, latency trace, frame queue"),
        ]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(title: "A familiar setup.", subtitle: "One Wine runtime with a copy per renderer, shared by all your bottles.")
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.runtimeReady ? "Runtime ready" : model.runtimeOutdated ? "Update needed" : "Not set up").font(.system(size: 17, weight: .semibold))
                    Text("Downloads are checked against pinned SHA-256 hashes before anything is installed. Renderer copies are APFS clones of one engine, so they use almost no extra space.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: model.prepare) {
                    Text(model.runtimeOutdated ? "Update Portnaut" : model.runtimeReady ? "Repair All Bottles" : "Prepare Portnaut").frame(minWidth: 150, minHeight: 36)
                }.buttonStyle(PortnautButtonStyle(primary: !model.runtimeReady)).disabled(model.busy || !model.sessions.isEmpty)
            }.card()
            VStack(spacing: 0) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    HStack(alignment: .firstTextBaseline) {
                        Text(component.0).frame(width: 150, alignment: .leading)
                        Text(component.1).fontWeight(.medium)
                        Spacer()
                        Text(component.2).foregroundStyle(Palette.muted)
                    }.font(.system(size: 12)).padding(.horizontal, 22).padding(.vertical, 14)
                    if index < components.count - 1 { Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, 22) }
                }
            }.background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                Button { model.openComponentUpdates() } label: { Label("Check for Component Updates…", systemImage: "arrow.triangle.2.circlepath").frame(height: 30) }
                    .buttonStyle(PortnautButtonStyle(primary: false)).disabled(!model.runtimeReady || model.busy)
                Text("Also in the Portnaut menu. Stable follows Highball’s tested set; Latest takes the newest build of each part.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            if let note = Renderer.d3dmetal.licenseNote {
                Label(note, systemImage: "doc.text").font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button("Open Portnaut Data Folder") { model.reveal(model.service.paths.root) }.buttonStyle(.bordered)
                Button("Open Runtime Folder") { model.reveal(model.service.paths.runtime) }.buttonStyle(.bordered).disabled(!model.runtimeReady)
                Link("Trouble signing in? Ubisoft Help ↗", destination: URL(string: "https://www.ubisoft.com/en-us/help")!).font(.system(size: 12))
            }
        }
    }
}

struct DiagnosticsPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "A clear view under the hood.", subtitle: "Local logs and environment checks.")
                .onAppear { model.readLog() }
            HStack(spacing: 12) {
                badge("Runtime", ready: model.runtimeReady)
                ForEach(model.library.bottles) { badge($0.name, ready: model.ready($0)) }
            }
            HStack {
                Button("Refresh log", action: model.readLog).buttonStyle(.bordered)
                Button("Open log folder") { model.reveal(model.service.paths.logs) }.buttonStyle(.bordered)
                Spacer()
                Button("Export diagnostics…", action: model.exportDiagnostics).buttonStyle(.bordered)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(model.logText).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            // The newest lines, from their start; long lines scroll sideways.
            .defaultScrollAnchor(.bottomLeading)
            .frame(height: 380).background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Text("Logs stay on this Mac. For help, email \(Publisher.supportEmail) with an exported report attached; review it before you send it.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Link("Email Support ↗", destination: Publisher.supportMail).font(.system(size: 12))
            }
        }
    }
    private func badge(_ label: String, ready: Bool) -> some View {
        HStack(spacing: 8) { Image(systemName: ready ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(ready ? Palette.cyan : Palette.muted); Text(label).font(.system(size: 12)).lineLimit(1) }
            .padding(12).frame(maxWidth: .infinity).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AboutPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 84, height: 84).padding(.top, 24)
            PageHeading(title: "Windows games, cleared for launch.", subtitle: "Portnaut \(Publisher.version) · A free Windows game launcher for Mac.")
            VStack(alignment: .leading, spacing: 8) {
                Text(Publisher.name).font(.system(size: 15, weight: .semibold))
                Text("Questions, problems or ideas: email \(Publisher.supportEmail). For a problem, attach a report from Diagnostics › Export diagnostics… and say what you were doing.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Link("Email Support ↗", destination: Publisher.supportMail).font(.system(size: 13))
            }.card(padding: 18)
            Text("Built around Wine with DXMT, D3DMetal and DXVK renderers, with each launcher or game in a bottle of its own. Portnaut is free, open-source software under the MIT licence. It is an independent project, not affiliated with or endorsed by Apple, Ubisoft, Valve, Electronic Arts, Epic Games, Blizzard Entertainment, Rockstar Games, GOG, Amazon, CodeWeavers, Highball or Sikarugir.")
                .font(.system(size: 14)).foregroundStyle(Palette.muted).lineSpacing(5)
            VStack(alignment: .leading, spacing: 12) {
                Link("Wine & the Highball runtime ↗", destination: URL(string: "https://github.com/gauthierpiarrette/highball-engine")!)
                Link("DXMT graphics translation ↗", destination: URL(string: "https://github.com/3Shain/dxmt")!)
                Link("DXVK for macOS ↗", destination: URL(string: "https://github.com/Gcenx/DXVK-macOS")!)
                Link("Apple Game Porting Toolkit ↗", destination: URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!)
                Link("Compatibility data: Highball’s database ↗", destination: URL(string: "https://github.com/gauthierpiarrette/highball-db")!)
                if let notices = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") {
                    Button("Component licenses & sources") { model.reveal(notices) }.buttonStyle(.link)
                }
            }.font(.system(size: 13))
            Text("Runtime components are downloaded from their maintainers and checked against pinned SHA-256 hashes. Launchers are downloaded directly from their publishers.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
        }
    }
}
