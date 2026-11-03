import Foundation

/// "Find my best setup": the game is played once on each renderer it can use, a minute or more of
/// the same kind of play each time, and the fastest on this Mac is kept. Easy mode then starts the
/// game there. The rounds are ordinary sessions that Portnaut records (PerformanceRun).
public struct SetupTrial: Codable, Equatable, Sendable {
    /// In round order, the recommended renderer first.
    public var renderers: [Renderer]
    /// One run per finished round.
    public var runs: [PerformanceRun] = []
    public var startedAt: Date
    /// The last session when it was too short to count; the round is played again.
    public var shortRun: PerformanceRun?
    /// The last session recorded almost nothing (under 15 seconds of play): the game never drew, or closed at once.
    public var emptyRound: Bool?

    /// Play shorter than this tells too little about a renderer.
    public static let minimumSeconds = 60

    public init(renderers: [Renderer], startedAt: Date = Date()) {
        self.renderers = renderers
        self.startedAt = startedAt
    }

    /// The renderer of the round to play now; nil when every round is done.
    public var next: Renderer? { renderers.first { renderer in !runs.contains { $0.renderer == renderer } } }
    public var round: Int { min(runs.count + 1, renderers.count) }
    public var finished: Bool { next == nil }

    /// Takes a session's run for the round it was played on. A run under a minute is kept aside
    /// so the round can be played again; a run on another renderer is not this trial's.
    @discardableResult
    public mutating func record(_ run: PerformanceRun) -> Bool {
        guard let next, run.renderer == next else { return false }
        emptyRound = nil
        guard run.seconds >= Self.minimumSeconds else { shortRun = run; return false }
        shortRun = nil
        runs.append(run)
        return true
    }
    /// Notes a round whose session recorded nothing, so it can be explained and played again.
    public mutating func recordNothing() {
        guard next != nil else { return }
        shortRun = nil
        emptyRound = true
    }

    /// The renderers worth comparing for a game: those its graphics API can use that the bottle's
    /// launcher starts on, the recommended one first. Fewer than two means nothing to compare.
    public static func candidates(for analysis: GraphicsAnalysis, launcher: Launcher?) -> [Renderer] {
        let allowed = GraphicsAdvisor.candidates(for: analysis).filter { launcher?.unsupportedRenderers.contains($0) != true }
        let first = (launcher?.adjusted(analysis.recommendation) ?? analysis.recommendation).renderer
        return allowed.filter { $0 == first } + allowed.filter { $0 != first }
    }

    public var winner: MeasuredSetup? { MeasuredSetup.best(of: runs) }
}

/// The renderer measured fastest for a game on this Mac.
public struct MeasuredSetup: Codable, Equatable, Sendable {
    public var renderer: Renderer
    public var averageFPS: Double
    public var lowFPS: Double
    public var measuredAt: Date
    /// Every renderer's run, for showing the comparison again.
    public var runs: [PerformanceRun]
    public var reason: String

    /// The average frame rate decides. Within 5 %, the higher low frame rate (fewer drops) decides;
    /// within 5 % again, the lower GPU time per frame, which matters when a game caps its frame rate.
    public static func best(of runs: [PerformanceRun], date: Date = Date()) -> MeasuredSetup? {
        guard runs.count >= 2 else { return nil }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 0.05 * max(a, b, 1) }
        func better(_ a: PerformanceRun, _ b: PerformanceRun) -> Bool {
            if !close(a.averageFPS, b.averageFPS) { return a.averageFPS > b.averageFPS }
            if !close(a.lowFPS, b.lowFPS) { return a.lowFPS > b.lowFPS }
            return a.gpuMilliseconds <= b.gpuMilliseconds
        }
        let winner = runs.dropFirst().reduce(runs[0]) { better($0, $1) ? $0 : $1 }
        let others = runs.filter { $0.renderer != winner.renderer }
        let second = others.dropFirst().reduce(others[0]) { better($0, $1) ? $0 : $1 }
        func fps(_ value: Double) -> String { String(format: "%.0f fps", value) }
        let against = others.map { "\(fps($0.averageFPS)) on \($0.renderer.title)" }
        let reason: String
        if !close(winner.averageFPS, second.averageFPS) {
            reason = "\(winner.renderer.title) averaged \(fps(winner.averageFPS)), against \(CompatibilityReport.list(against))."
        } else if !close(winner.lowFPS, second.lowFPS) {
            reason = "The averages were about the same (\(fps(winner.averageFPS))), but \(winner.renderer.title) dropped less: its low was \(fps(winner.lowFPS)), against \(fps(second.lowFPS)) on \(second.renderer.title)."
        } else {
            reason = "The frame rates were about the same (\(fps(winner.averageFPS))), as when a game caps its frame rate; \(winner.renderer.title) needed less GPU time per frame (\(String(format: "%.1f", winner.gpuMilliseconds)) ms, against \(String(format: "%.1f", second.gpuMilliseconds)) ms on \(second.renderer.title)), which leaves more room in busy scenes."
        }
        return MeasuredSetup(renderer: winner.renderer, averageFPS: winner.averageFPS, lowFPS: winner.lowFPS, measuredAt: date, runs: runs, reason: reason)
    }
}

extension WineService {
    /// Starts "Find my best setup" for a game: one round per renderer it can use in its bottle.
    @discardableResult
    public func startSetupTrial(for game: Game, in bottle: Bottle) throws -> SetupTrial {
        guard let analysis = analyze(game, in: bottle) else { throw PortnautError("\(game.name)’s files are not at their saved location.") }
        let renderers = SetupTrial.candidates(for: analysis, launcher: bottle.launcher)
        guard renderers.count >= 2 else {
            throw PortnautError("Only \(renderers.first?.title ?? "one renderer") can run \(game.name)\(bottle.launcher.map { " in a \($0.title) bottle" } ?? ""), so there is nothing to compare.")
        }
        let trial = SetupTrial(renderers: renderers)
        try changeGame(game.id, in: bottle) { $0.setupTrial = trial }
        return trial
    }

    public func cancelSetupTrial(for game: Game, in bottle: Bottle) throws {
        try changeGame(game.id, in: bottle) { $0.setupTrial = nil }
    }

    /// Keeps the trial's winner for the game. A bottle without easy mode switches to it now; an
    /// easy-mode bottle switches whenever the game starts.
    @discardableResult
    public func keepSetupTrial(for game: Game, in bottle: Bottle) async throws -> MeasuredSetup {
        guard let winner = try self.bottle(bottle.id).games.first(where: { $0.id == game.id })?.setupTrial?.winner else {
            throw PortnautError("Play every round of \(game.name)’s best setup first.")
        }
        try changeGame(game.id, in: bottle) { $0.bestSetup = winner; $0.setupTrial = nil }
        var updated = try self.bottle(bottle.id)
        if !updated.easyMode, updated.renderer != winner.renderer {
            updated.renderer = winner.renderer
            try await update(updated)
        }
        return winner
    }

    /// Adds a session's run to the game's trial when it was played on the round's renderer; a
    /// session that recorded nothing is noted.
    func recordSetupRound(_ run: PerformanceRun?, of game: Game, in bottle: Bottle) {
        try? changeGame(game.id, in: bottle) { game in
            guard var trial = game.setupTrial else { return }
            if let run { trial.record(run) } else { trial.recordNothing() }
            game.setupTrial = trial
        }
    }

    /// Changes one game in the saved library. Settings that need the bottle's profile go through
    /// updateGame instead.
    func changeGame(_ id: String, in bottle: Bottle, _ change: (inout Game) -> Void) throws {
        var updated = try self.bottle(bottle.id)
        guard let index = updated.games.firstIndex(where: { $0.id == id }) else { throw PortnautError("That game is no longer in \(bottle.name).") }
        change(&updated.games[index])
        try save(updated)
    }
}
