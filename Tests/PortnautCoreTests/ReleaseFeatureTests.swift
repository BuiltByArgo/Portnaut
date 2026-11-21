import Foundation
import Testing
@testable import PortnautCore

/// 0.13.0: problem reports in Will It Run?, clearer logs, Settings and cover art.
@Suite
final class ReleaseFeatureTests {
    var root: URL!
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("portnaut-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    // MARK: - Will It Run? problem reports (opening sentences of Highball's notes, November 2026)

    @Test func testNotesThatSayAGameFailsAreProblems() {
        #expect(CompatibilityReport.reportsProblems("Does not start. Steam starts the game and it hangs inside its own startup with no window. Two walls were found in turn."))
        #expect(CompatibilityReport.reportsProblems("Direct3D 12, so D3DMetal. A detailed report on an M4 gets past startup, the Xbox sign-in and into free roam and the benchmark on both Wine 11 engines, but the game is not playable: every piece of scenery draws tilted."))
        #expect(CompatibilityReport.reportsProblems("Launches, not playable. The game's pre-launcher (settings.exe, 32-bit) shows, and Play rarely brings the main window."))
        #expect(CompatibilityReport.reportsProblems("NCSOFT's MMO, with NCGuard anti-cheat. Doesn't launch in the one report so far, on the default engine with DXMT."))
    }

    @Test func testNotesThatSayAGameRunsAreNotProblems() {
        #expect(!CompatibilityReport.reportsProblems("Reported playable with minor issues on D3DMetal after a session of 43 minutes; the reporter adds that it needed Direct3D 12."))
        #expect(!CompatibilityReport.reportsProblems("Runs on Wine 11 with D3DMetal by outside reports, and fails to start on Wine 10."))
        #expect(!CompatibilityReport.reportsProblems("On M1 and M2 Macs it does not run in Highball, play GTA V Legacy instead, which runs there with DXMT."))
        #expect(!CompatibilityReport.reportsProblems("Playable in a 2 minute report on an M5 on the default engine's r14, with some keybinds not working correctly."))
        #expect(!CompatibilityReport.reportsProblems(nil))
        #expect(!CompatibilityReport.reportsProblems(""))
    }

    @Test func testProblemGamesAreLabelledAndNeverDriveTheRenderer() {
        let database = CompatibilityDatabase(curated: ["games": [
            ["id": "fh4", "title": "Forza Horizon 4", "status": "community", "steam_appid": 1293830, "renderer": "d3dmetal", "reportsProblems": true],
            ["id": "fh5", "title": "Forza Horizon 5", "status": "community", "steam_appid": 1551360, "renderer": "d3dmetal",
             "notes": "Direct3D 12, so D3DMetal. A detailed report gets into free roam, but the game is not playable."],
            ["id": "ok", "title": "Working Game", "status": "community", "steam_appid": 42, "renderer": "dxmt", "notes": "Playable with minor issues."]]],
            predictions: nil, antiCheat: nil)
        let fh4 = database.report(steamAppID: 1293830, title: "")
        #expect(fh4?.status == .problems)
        #expect(fh4?.headline == "Players report problems")
        #expect(fh4?.explanation.contains("not starting or not playable") == true)
        #expect(database.report(steamAppID: 1551360, title: "")?.status == .problems)
        #expect(database.report(steamAppID: 42, title: "")?.status == .reported)
        // The Mac renderer of a problem game is no recommendation.
        #expect(CompatibilityReport.Status.problems < .reported)
    }

    // MARK: - Logs and hints

    /// Shaped like a real report: the program's line, then MoltenVK's list of extensions.
    @Test func testLogTailLeavesOutTheVulkanExtensionList() {
        var lines = ["[2026-11-19T23:43:39Z] wine H:\\setup.exe", "[mvk-info] MoltenVK version 1.4.1, supporting Vulkan version 1.4.334."]
        lines += (0..<140).map { "\tVK_KHR_extension_\($0) v\($0 % 9 + 1)" }
        lines += ["[mvk-info] GPU device:", "\tmodel: Apple M4", "\tGPU Family Metal 3", "[2026-11-19T23:44:05Z] exited with code 1 after 26 seconds"]
        let tail = Diagnostics.tail(of: lines.joined(separator: "\n"))
        #expect(tail.contains("wine H:\\setup.exe"))
        #expect(tail.contains("model: Apple M4"))
        #expect(tail.contains("exited with code 1 after 26 seconds"))
        #expect(!tail.contains("VK_KHR_extension"))
        // Ordinary lines that mention Vulkan stay.
        #expect(!Diagnostics.isNoise("VK_ERROR_DEVICE_LOST v2"))
        #expect(!Diagnostics.isNoise("\tVK_ERROR_INITIALIZATION_FAILED from vkCreateDevice"))
    }

    @Test func testRunnerLogsHowAProgramEnded() async throws {
        let log = root.appendingPathComponent("exit.log")
        _ = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/false"), [], log: log, allowFailure: true)
        let content = try String(contentsOf: log, encoding: .utf8)
        #expect(content.contains("exited with code 1 after 0 seconds"))
    }

    @Test func testQuickInstallerExitSuggestsWindows10OnlyForOldVersions() {
        let old = Diagnostics.installerEndedEarlyHint(seconds: 4.2, windowsVersion: .win7)
        #expect(old?.hasPrefix("The installer closed after 4 seconds.") == true)
        #expect(old?.contains("Windows 10") == true)
        let current = Diagnostics.installerEndedEarlyHint(seconds: 1, windowsVersion: .win10)
        #expect(current?.contains("1 second.") == true && current?.contains("Windows 10") == false)
        #expect(Diagnostics.installerEndedEarlyHint(seconds: 45, windowsVersion: .win7) == nil)
        #expect(WindowsVersion.win81.isOld && !WindowsVersion.win11.isOld)
    }

    // MARK: - Settings

    @Test func testSettingsDefaultsSaveAndOlderFiles() throws {
        let service = WineService(paths: PortnautPaths(root: root))
        #expect(service.settings == PortnautSettings())
        #expect(service.settings.newBottleWindowsVersion == .win10 && service.settings.recordPerformanceInNewBottles && !service.settings.downloadSteamArtwork)
        var changed = PortnautSettings()
        changed.newBottleWindowsVersion = .win11
        changed.recordPerformanceInNewBottles = false
        service.settings = changed
        #expect(WineService(paths: PortnautPaths(root: root)).settings == changed)
        // A file from a version that knew only some settings keeps the defaults for the rest.
        try Data("{\"recordPerformanceInNewBottles\": false}".utf8).write(to: service.paths.settings)
        #expect(service.settings.recordPerformanceInNewBottles == false && service.settings.newBottleWindowsVersion == .win10)
    }

    // MARK: - Cover art

    @Test func testSteamAppIDComesFromTheLaunchArguments() {
        var game = Game(id: "g", name: "Game", executable: "Program Files (x86)/Steam/steamapps/common/G/g.exe")
        #expect(game.steamAppID == nil)
        game.launcherArguments = ["-applaunch", "271590", "-windowed"]
        #expect(game.steamAppID == 271590)
    }

    @Test func testCoverArtUsesSteamsCacheThenDownloads() throws {
        let service = WineService(paths: PortnautPaths(root: root))
        var bottle = Bottle(id: "steam", name: "Steam", renderer: .d3dmetal)
        bottle.launcher = .steam
        var game = Game(id: "g", name: "Game", executable: "g.exe")
        game.launcherArguments = ["-applaunch", "10"]
        let cache = service.paths.bottle(bottle).drive.appendingPathComponent("Program Files (x86)/Steam/appcache/librarycache")
        let fm = FileManager.default
        #expect(service.coverArt(for: game, in: bottle, kind: .card) == nil)
        // Newer Steam: one folder per game, sometimes one more level down.
        try fm.createDirectory(at: cache.appendingPathComponent("10/abc123"), withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: cache.appendingPathComponent("10/abc123/library_hero.jpg"))
        #expect(service.coverArt(for: game, in: bottle, kind: .hero)?.lastPathComponent == "library_hero.jpg")
        // Older Steam: <appid>_header.jpg.
        try Data("jpg".utf8).write(to: cache.appendingPathComponent("10_header.jpg"))
        #expect(service.coverArt(for: game, in: bottle, kind: .card)?.lastPathComponent == "10_header.jpg")
        // A download Steam had no image for leaves an empty marker: tried, but nothing to show.
        game.launcherArguments = ["-applaunch", "20"]
        try fm.createDirectory(at: service.paths.artwork, withIntermediateDirectories: true)
        fm.createFile(atPath: service.paths.artwork.appendingPathComponent("20-card.jpg").path, contents: Data())
        #expect(service.coverArtDownloadTried(appID: 20, kind: .card))
        #expect(service.coverArt(for: game, in: bottle, kind: .card) == nil)
        try Data("jpg".utf8).write(to: service.paths.artwork.appendingPathComponent("20-card.jpg"))
        #expect(service.coverArt(for: game, in: bottle, kind: .card)?.lastPathComponent == "20-card.jpg")
        // Only Steam games: the same game in another kind of bottle gets none.
        bottle.launcher = .epic
        #expect(service.coverArt(for: game, in: bottle, kind: .card) == nil)
        #expect(CoverArt.steamURL(appID: 271590, kind: .hero).absoluteString == "https://cdn.cloudflare.steamstatic.com/steam/apps/271590/library_hero.jpg")
    }
}
