import AppKit
import Combine
import SwiftUI
import Sparkle
import PortnautCore

/// Portnaut's own updates, through Sparkle's standard window. Users check from the sidebar's
/// Check for Updates button, the About page or the Portnaut menu, and Sparkle offers a daily check
/// on the second launch (also a switch on the About page). New versions come from GitHub Releases.
/// Sparkle only starts when the build carries a feed and a public key (SelfUpdate.isConfigured).
/// Installing waits while a game runs or Portnaut is working, because it replaces the Metal shim too.
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var checksAutomatically = false
    @Published private(set) var lastCheck: Date?
    let isAvailable: Bool
    /// Asked before installing: is a session running or Portnaut busy? AppModel sets it.
    var isOccupied: () -> Bool = { false }
    /// Called when a downloaded update is held back for that reason.
    var onWaiting: () -> Void = {}
    /// Called a few seconds before a held update installs, so Portnaut closing doesn't come as a surprise.
    var onInstallingSoon: () -> Void = {}
    private var installScheduled = false
    private var controller: SPUStandardUpdaterController?
    private var installWhenFree: (() -> Void)?
    private var observations: [AnyCancellable] = []

    override init() {
        isAvailable = SelfUpdate.isConfigured(Bundle.main.infoDictionary ?? [:])
        super.init()
        guard isAvailable else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.canCheckForUpdates = $0 },
            updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.checksAutomatically = $0 },
            updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main).sink { [weak self] in self?.lastCheck = $0 }
        ]
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// The About page's switch. Sparkle keeps the choice in Portnaut's preferences.
    func setChecksAutomatically(_ on: Bool) { controller?.updater.automaticallyChecksForUpdates = on }

    /// Called from AppModel's refresh: installs a held update once games and work have ended.
    func installIfFree() {
        guard let install = installWhenFree, !isOccupied(), !installScheduled else { return }
        installScheduled = true
        onInstallingSoon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.installScheduled = false
            // A game started again in those seconds: keep waiting.
            guard !self.isOccupied() else { return }
            self.installWhenFree = nil
            install()
        }
    }

    // MARK: - SPUUpdaterDelegate (Sparkle calls it on the main thread)

    /// Install and Relaunch: hold the relaunch, and so the install, while a game runs.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isOccupied() else { return false }
        installWhenFree = installHandler
        onWaiting()
        return true
    }
}

/// The Portnaut menu item. Builds without an update key have no updater, so no item.
struct CheckForPortnautUpdatesButton: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        if updater.isAvailable {
            Button("Check for Portnaut Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
        }
    }
}

/// Always in the sidebar, for people who never open the menu bar.
struct SidebarUpdateButton: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        if updater.isAvailable {
            Button { updater.checkForUpdates() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 15)).frame(width: 20)
                    Text("Check for Updates").font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }.foregroundStyle(Palette.muted).padding(.horizontal, 12).frame(height: 38).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 8)
            .disabled(!updater.canCheckForUpdates)
            .help("See whether a newer Portnaut is available, and install it")
        }
    }
}

/// The About page's Updates card: the version, the last check, the button and the daily check.
struct UpdatesCard: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        if updater.isAvailable {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Updates").font(.system(size: 15, weight: .semibold))
                        Text(status).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button { updater.checkForUpdates() } label: { Label("Check for Updates", systemImage: "arrow.down.circle").frame(height: 28) }
                        .buttonStyle(PortnautButtonStyle(primary: true)).disabled(!updater.canCheckForUpdates)
                }
                Toggle("Check for updates automatically every day", isOn: Binding(get: { updater.checksAutomatically }, set: { updater.setChecksAutomatically($0) }))
                    .toggleStyle(.switch).font(.system(size: 13))
                Text("Portnaut asks GitHub, where its releases are published, whether a newer version exists, and sends nothing about your Mac. Updates are signed by \(Publisher.name) and checked before they install, and an update waits until your games have closed.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }.card(padding: 18)
        }
    }
    private var status: String {
        let version = "Portnaut \(Publisher.version)"
        guard let lastCheck = updater.lastCheck else { return "\(version) · Not checked yet" }
        return "\(version) · Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))"
    }
}
