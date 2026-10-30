import Foundation

/// One game session, summarised from the PortnautLatency lines Portnaut's Metal shim writes every 5 seconds.
public struct PerformanceRun: Codable, Equatable, Sendable, Identifiable {
    public var date: Date
    public var renderer: Renderer
    /// The bottle's graphics configuration at the time, e.g. "DXMT · MetalFX 2×".
    public var configuration: String
    /// Measured time, without stretches below 5 fps (paused, loading, or in the background).
    public var seconds: Int
    public var averageFPS: Double
    /// The 5th percentile of the 5-second stretches: how low it goes when it drops.
    public var lowFPS: Double
    /// Median of each stretch's 95th-percentile frame time.
    public var frameTimeP95: Double
    public var gpuMilliseconds: Double
    /// Median time from present to the frame reaching the screen; nil when Metal gave no screen times.
    public var latencyMilliseconds: Double?
    public var id: Date { date }
}

/// All runs of one configuration, for comparison.
public struct PerformanceSummary: Equatable, Sendable, Identifiable {
    public var configuration: String
    public var renderer: Renderer
    public var runs: Int
    public var seconds: Int
    public var averageFPS: Double
    public var lowFPS: Double
    public var gpuMilliseconds: Double
    public var latencyMilliseconds: Double?
    public var lastDate: Date
    public var id: String { configuration }
}

public enum PerformanceLog {
    struct Sample {
        var fps, frameP95, screenP50, gpuMs: Double
        var screenTimes: Bool
    }

    static let pattern = try! NSRegularExpression(pattern:
        #"PortnautLatency: fps ([\d.]+) \| frame ms p50 [\d.]+ p95 ([\d.]+) \| present to screen ms p50 ([\d.]+) p95 [\d.]+ \((\d+) frames without a screen time\).*?\| GPU ([\d.]+) ms/frame"#)

    static func samples(in text: String) -> [Sample] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            func value(_ group: Int) -> Double? { Range(match.range(at: group), in: text).flatMap { Double(text[$0]) } }
            guard let fps = value(1), let p95 = value(2), let screen = value(3), let missing = value(4), let gpu = value(5) else { return nil }
            return Sample(fps: fps, frameP95: p95, screenP50: screen, gpuMs: gpu, screenTimes: missing == 0 && screen > 0)
        }
    }

    /// The run in a stretch of session.log, if it holds at least 15 seconds of play.
    public static func run(from text: String, bottle: Bottle, date: Date = Date()) -> PerformanceRun? {
        let playing = samples(in: text).filter { $0.fps >= 5 }
        guard playing.count >= 3 else { return nil }
        let fps = playing.map(\.fps).sorted()
        let screen = playing.filter(\.screenTimes).map(\.screenP50)
        return PerformanceRun(date: date, renderer: bottle.renderer, configuration: bottle.performanceLabel, seconds: playing.count * 5,
                              averageFPS: fps.reduce(0, +) / Double(fps.count), lowFPS: percentile(fps, 0.05),
                              frameTimeP95: median(playing.map(\.frameP95)), gpuMilliseconds: median(playing.map(\.gpuMs)),
                              latencyMilliseconds: screen.isEmpty ? nil : median(screen))
    }

    /// One row per configuration, weighted by measured time, best average first.
    public static func compare(_ runs: [PerformanceRun]) -> [PerformanceSummary] {
        Dictionary(grouping: runs, by: \.configuration).map { configuration, group in
            let total = Double(group.map(\.seconds).reduce(0, +))
            func weighted(_ value: (PerformanceRun) -> Double) -> Double { group.map { value($0) * Double($0.seconds) }.reduce(0, +) / total }
            let latency = group.compactMap { run in run.latencyMilliseconds.map { ($0, Double(run.seconds)) } }
            return PerformanceSummary(configuration: configuration, renderer: group[0].renderer, runs: group.count, seconds: Int(total),
                                      averageFPS: weighted(\.averageFPS), lowFPS: weighted(\.lowFPS), gpuMilliseconds: weighted(\.gpuMilliseconds),
                                      latencyMilliseconds: latency.isEmpty ? nil : latency.map { $0.0 * $0.1 }.reduce(0, +) / latency.map(\.1).reduce(0, +),
                                      lastDate: group.map(\.date).max()!)
        }.sorted { $0.averageFPS > $1.averageFPS }
    }

    static func median(_ values: [Double]) -> Double { percentile(values.sorted(), 0.5) }
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[Int((p * Double(sorted.count - 1)).rounded())]
    }
}
