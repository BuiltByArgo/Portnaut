import Foundation

/// The downloads Portnaut's runtime is built from.
public enum RuntimePart: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Highball's Wine 11 engine, built from CodeWeavers' published Wine sources, with Wine Mono and Wine Gecko.
    case wine
    /// Highball's DXMT build.
    case dxmt
    /// Sikarugir's template: D3DMetal, DXVK, D9VK, GStreamer, SDL and the other support libraries.
    case support
    /// Replaces the template's MoltenVK.
    case moltenvk
    /// Replaces the template's D3DMetal, when a set names one.
    case d3dmetal
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .wine: "Wine"
        case .dxmt: "DXMT"
        case .support: "D3DMetal & DXVK"
        case .moltenvk: "MoltenVK"
        case .d3dmetal: "D3DMetal (separate)"
        }
    }
}

public enum UpdateChannel: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Highball's newest tested set for its x64 Wine line, the one Highball gives every player.
    case stable
    /// The newest build of each part, not yet tested together.
    case latest
    public var id: String { rawValue }
    public var title: String { self == .stable ? "Stable" : "Latest" }
}

/// One download of a runtime part.
public struct ComponentRelease: Codable, Equatable, Sendable {
    public var part: RuntimePart
    /// Shown to the user, e.g. "11.0 · build 14 Oct 2026".
    public var version: String
    public var url: URL
    public var sha256: String
    public var size: Int64?
    /// The template's .app folder, or the path of D3DMetal's folder or MoltenVK's library in the archive.
    public var subpath: String?
    public var fileName: String { url.lastPathComponent }
    public init(part: RuntimePart, version: String, url: URL, sha256: String, size: Int64? = nil, subpath: String? = nil) {
        self.part = part; self.version = version; self.url = url; self.sha256 = sha256.lowercased(); self.size = size; self.subpath = subpath
    }
}

/// A complete set of parts to build a runtime from.
public struct RuntimeSet: Codable, Equatable, Sendable {
    public var label: String
    public var channel: UpdateChannel?
    /// Highball's note for its newest revision, for Stable.
    public var notes: String?
    public var components: [ComponentRelease]
    public init(label: String, channel: UpdateChannel?, notes: String? = nil, components: [ComponentRelease]) {
        self.label = label; self.channel = channel; self.notes = notes; self.components = components
    }
    // Before 0.7.0, a Stable set was labelled with Highball's manifest file name; it reads as "Highball r29" now.
    enum CodingKeys: String, CodingKey { case label, channel, notes, components }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try c.decode(String.self, forKey: .label)
        label = saved.hasPrefix("Highball x64-") ? RuntimeUpdates.stableLabel(String(saved.dropFirst("Highball ".count))) : saved
        channel = try c.decodeIfPresent(UpdateChannel.self, forKey: .channel)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        components = try c.decode([ComponentRelease].self, forKey: .components)
    }
    public func release(_ part: RuntimePart) -> ComponentRelease? { components.first { $0.part == part } }

    /// Parts that differ from another set, including parts one has and the other lacks.
    public func changes(from other: RuntimeSet) -> [RuntimePart] {
        RuntimePart.allCases.filter { release($0)?.sha256 != other.release($0)?.sha256 }
    }
    public func downloadSize(from other: RuntimeSet) -> Int64 {
        changes(from: other).compactMap { release($0)?.size }.reduce(0, +)
    }

    /// What Portnaut installs before any update: Highball's x64 r27 archives.
    public static let builtIn = RuntimeSet(label: "Portnaut’s built-in versions (Highball x64 r27)", channel: nil, components: [
        ComponentRelease(part: .wine, version: RuntimeUpdates.version(ofEngineTag: "engine-wine-11.0-20261014T003801Z-0024-app-packages-0023-spatial-mixer"),
                         url: DownloadArtifact.wine.url, sha256: DownloadArtifact.wine.sha256, size: 334_884_359),
        ComponentRelease(part: .dxmt, version: RuntimeUpdates.version(ofDXMTTag: "dxmt-highball-20260930T161516Z-a444716"),
                         url: DownloadArtifact.dxmt.url, sha256: DownloadArtifact.dxmt.sha256, size: 18_923_969),
        ComponentRelease(part: .support, version: "1.0.11", url: DownloadArtifact.support.url, sha256: DownloadArtifact.support.sha256,
                         size: 84_533_420, subpath: "Template-1.0.11.app"),
    ])
}

/// What a runtime was built from, kept beside it as components.json.
public struct InstalledRuntime: Codable, Equatable, Sendable {
    public var set: RuntimeSet
    public var installedAt: Date
    /// Versions read from the installed files, e.g. "D3DMetal": "3.0".
    public var details: [String: String]
    /// One line for diagnostics, e.g. "Highball r29: Wine 11.0 · build 14 Oct 2026 (…), DXMT a444716 · 30 Sep 2026,
    /// Sikarugir template 1.0.11 (D3DMetal 3.0), MoltenVK 1.4.2 with Highball’s fixes". The runtime folder keeps its first name across updates.
    public var summary: String {
        let parts = set.components.map { release in
            release.part == .support ? "Sikarugir template \(release.version)" + (details["D3DMetal"].map { " (D3DMetal \($0))" } ?? "") : "\(release.part.title) \(release.version)"
        }
        return "\(set.label): \(parts.joined(separator: ", "))"
    }
}

/// A check's result: what each channel offers now.
public struct UpdateCheck: Equatable, Sendable {
    public var stable: RuntimeSet
    public var latest: RuntimeSet
    /// Parts Latest could not take from their newest release (no checksum published), kept from Stable.
    public var latestNotes: [String]
    public var checkedAt: Date
    public func set(for channel: UpdateChannel) -> RuntimeSet { channel == .stable ? stable : latest }
}

public enum RuntimeUpdates {
    // MARK: Versions from release names

    /// "engine-wine-11.0-20261014T003801Z-0024-app-packages-0023-spatial-mixer" → "11.0 · build 14 Oct 2026 (0024-app-packages-0023-spatial-mixer)".
    public static func version(ofEngineTag tag: String) -> String {
        let parts = tag.split(separator: "-", maxSplits: 3).map(String.init)
        guard parts.count == 4, let wine = parts.dropFirst(2).first else { return tag }
        let rest = parts[3]
        let stamp = String(rest.prefix(8)), tail = rest.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
        return "\(wine) · build \(date(stamp) ?? stamp)" + (tail.map { " (\($0))" } ?? "")
    }
    /// "dxmt-highball-20260930T161516Z-a444716" → "a444716 · 30 Sep 2026".
    public static func version(ofDXMTTag tag: String) -> String {
        let parts = tag.split(separator: "-").map(String.init)
        guard parts.count >= 4 else { return tag }
        return "\(parts[3]) · \(date(String(parts[2].prefix(8))) ?? parts[2])"
    }
    static func date(_ stamp: String) -> String? {
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX"); input.dateFormat = "yyyyMMdd"; input.timeZone = TimeZone(identifier: "UTC")
        guard let date = input.date(from: stamp) else { return nil }
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_GB"); output.dateFormat = "d MMM yyyy"; output.timeZone = TimeZone(identifier: "UTC")
        return output.string(from: date)
    }
    /// Numeric parts of a version for ordering: "1.0.24" → [1, 0, 24]; "v1.4.2" → [1, 4, 2].
    static func numbers(_ version: String) -> [Int] { version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
    static func isNewer(_ a: String, than b: String) -> Bool { numbers(a).lexicographicallyPrecedes(numbers(b)) == false && numbers(a) != numbers(b) }

    // MARK: Stable: Highball's engine manifests

    /// Newest first among Highball's x64 Wine engine manifests, by Wine line and revision. The pattern
    /// is Highball's own file naming.
    public static func stableCandidates(_ names: [String]) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"^x64-crossover([\d.]+)-r(\d+)\.json$"#)
        let keyed: [(String, [Int])] = names.compactMap { name in
            guard let match = pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let line = Range(match.range(at: 1), in: name), let revision = Range(match.range(at: 2), in: name) else { return nil }
            return (name, numbers(String(name[line])) + [Int(name[revision]) ?? 0])
        }
        return keyed.sorted { $1.1.lexicographicallyPrecedes($0.1) }.map(\.0)
    }

    struct EngineManifest: Decodable {
        var id: String
        var channel: String?
        var notes: [String]?
        var components: [String: Component]
        struct Component: Decodable {
            var url: URL
            var sha256: String
            var size: Int64?
            var version: String?
            var extract: Extract?
            struct Extract: Decodable { var subpath: String? }
        }
    }

    /// The set a Highball engine manifest describes, or nil for one on a preview or beta channel
    /// or one without Wine, DXMT and the template. Highball-only parts are left out.
    public static func stableSet(fromManifest data: Data) throws -> RuntimeSet? {
        let manifest = try JSONDecoder().decode(EngineManifest.self, from: data)
        guard manifest.channel == nil, let wine = manifest.components["wine"], let dxmt = manifest.components["dxmt"],
              let template = manifest.components["runtime"] else { return nil }
        var parts = [
            ComponentRelease(part: .wine, version: version(ofEngineTag: wine.url.deletingLastPathComponent().lastPathComponent),
                             url: wine.url, sha256: wine.sha256, size: wine.size),
            ComponentRelease(part: .dxmt, version: version(ofDXMTTag: dxmt.url.deletingLastPathComponent().lastPathComponent),
                             url: dxmt.url, sha256: dxmt.sha256, size: dxmt.size),
            ComponentRelease(part: .support, version: templateVersion(template.url.lastPathComponent) ?? template.url.lastPathComponent,
                             url: template.url, sha256: template.sha256, size: template.size,
                             subpath: template.extract?.subpath?.split(separator: "/").first.map(String.init)),
        ]
        if let moltenvk = manifest.components["moltenvk"] {
            let base = moltenvk.version.map { String($0.split(separator: "+").first ?? Substring($0)) } ?? "?"
            parts.append(ComponentRelease(part: .moltenvk, version: "\(base) with Highball’s fixes", url: moltenvk.url, sha256: moltenvk.sha256,
                                          size: moltenvk.size, subpath: moltenvk.extract?.subpath ?? "libMoltenVK.dylib"))
        }
        if let d3dmetal = manifest.components["d3dmetal"] {
            parts.append(ComponentRelease(part: .d3dmetal, version: d3dmetal.version ?? "?", url: d3dmetal.url, sha256: d3dmetal.sha256,
                                          size: d3dmetal.size, subpath: d3dmetal.extract?.subpath ?? "renderers/d3dmetal"))
        }
        return RuntimeSet(label: stableLabel(manifest.id), channel: .stable, notes: manifest.notes?.first, components: parts)
    }

    /// A manifest id such as "x64-…-r29" shown as "Highball r29": the revision is what Highball's notes name.
    static func stableLabel(_ id: String) -> String {
        guard let revision = id.range(of: #"-r\d+$"#, options: .regularExpression) else { return "Highball \(id)" }
        return "Highball \(id[revision].dropFirst())"
    }

    static func templateVersion(_ fileName: String) -> String? {
        guard fileName.hasPrefix("Template-"), fileName.hasSuffix(".tar.xz") else { return nil }
        return String(fileName.dropFirst("Template-".count).dropLast(".tar.xz".count))
    }

    // MARK: Latest: GitHub releases

    struct Release: Decodable {
        var tag_name: String
        var draft: Bool
        var prerelease: Bool
        var published_at: String?
        var assets: [Asset]
        struct Asset: Decodable {
            var name: String
            var size: Int64
            var digest: String?
            var browser_download_url: URL
        }
    }

    static func sha256(of asset: Release.Asset) -> String? {
        guard let digest = asset.digest, digest.hasPrefix("sha256:") else { return nil }
        return String(digest.dropFirst("sha256:".count))
    }

    /// Newest x64 Wine and DXMT builds among Highball's engine releases. Builds marked "trial" are
    /// experiments for one problem and are skipped, as are arm64 engines.
    public static func latestHighball(fromReleases data: Data) throws -> [ComponentRelease] {
        let releases = try JSONDecoder().decode([Release].self, from: data).filter { !$0.draft }
        func newest(_ matches: (String) -> Bool) -> Release? {
            releases.filter { matches($0.tag_name) }.max { ($0.published_at ?? "") < ($1.published_at ?? "") }
        }
        var found: [ComponentRelease] = []
        if let wine = newest({ $0.hasPrefix("engine-wine-") && !$0.contains("trial") }),
           let asset = wine.assets.first(where: { $0.name.hasSuffix(".tar.gz") }), let sha = sha256(of: asset) {
            found.append(ComponentRelease(part: .wine, version: version(ofEngineTag: wine.tag_name), url: asset.browser_download_url, sha256: sha, size: asset.size))
        }
        if let dxmt = newest({ $0.hasPrefix("dxmt-highball-") }),
           let asset = dxmt.assets.first(where: { $0.name.hasSuffix(".tar.gz") }), let sha = sha256(of: asset) {
            found.append(ComponentRelease(part: .dxmt, version: version(ofDXMTTag: dxmt.tag_name), url: asset.browser_download_url, sha256: sha, size: asset.size))
        }
        return found
    }

    /// The highest-numbered Template-x.y.z among Sikarugir's release files.
    public static func latestTemplate(fromReleases data: Data) throws -> ComponentRelease? {
        let assets = try JSONDecoder().decode([Release].self, from: data).filter { !$0.draft }.flatMap(\.assets)
        let templates = assets.compactMap { asset -> (Release.Asset, String)? in templateVersion(asset.name).map { (asset, $0) } }
            .filter { !numbers($0.1).isEmpty }
        guard let best = templates.max(by: { numbers($0.1).lexicographicallyPrecedes(numbers($1.1)) }), let sha = sha256(of: best.0) else { return nil }
        return ComponentRelease(part: .support, version: best.1, url: best.0.browser_download_url, sha256: sha, size: best.0.size,
                                subpath: "Template-\(best.1).app")
    }

    /// Upstream MoltenVK's latest release, universal. Only offered when it is newer than the base
    /// of the MoltenVK Stable carries, which has Highball's fixes on top.
    public static func latestMoltenVK(fromRelease data: Data) throws -> ComponentRelease? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.prerelease, let asset = release.assets.first(where: { $0.name == "MoltenVK-macos.tar" }), let sha = sha256(of: asset) else { return nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        return ComponentRelease(part: .moltenvk, version: version, url: asset.browser_download_url, sha256: sha, size: asset.size,
                                subpath: "MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib")
    }

    /// Latest: Stable with each part replaced by its newest build where one is newer and published
    /// with a checksum. D3DMetal comes from the newest template.
    public static func latestSet(stable: RuntimeSet, highball: [ComponentRelease], template: ComponentRelease?, moltenvk: ComponentRelease?) -> (RuntimeSet, [String]) {
        var parts = stable.components.filter { $0.part != .d3dmetal }
        var notes: [String] = []
        func replace(_ release: ComponentRelease) { parts.removeAll { $0.part == release.part }; parts.append(release) }
        for part in [RuntimePart.wine, .dxmt] {
            if let newest = highball.first(where: { $0.part == part }) { replace(newest) } else { notes.append("\(part.title): no newer build with a published checksum, so Stable’s is used.") }
        }
        if let template { replace(template) } else { notes.append("Template: no release with a published checksum, so Stable’s is used.") }
        if let moltenvk, let current = stable.release(.moltenvk) {
            if isNewer(moltenvk.version, than: current.version) { replace(moltenvk) }
        } else if let moltenvk { replace(moltenvk) }
        parts.sort { RuntimePart.allCases.firstIndex(of: $0.part)! < RuntimePart.allCases.firstIndex(of: $1.part)! }
        return (RuntimeSet(label: "Newest builds", channel: .latest, components: parts), notes)
    }

    // MARK: Network

    static let api = URL(string: "https://api.github.com/repos/")!

    /// Asks GitHub what both channels offer now. About five requests, within GitHub's limit of 60
    /// an hour for unauthenticated clients.
    public static func check(session: URLSession = .shared) async throws -> UpdateCheck {
        func get(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Portnaut", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PortnautError("No response from GitHub.") }
            if http.statusCode == 403 || http.statusCode == 429 { throw PortnautError("GitHub is limiting requests from this network. Try again in an hour.") }
            guard http.statusCode == 200 else { throw PortnautError("GitHub answered \(http.statusCode) for \(url.lastPathComponent).") }
            return data
        }
        struct Entry: Decodable { var name: String; var download_url: URL? }
        let listing = try JSONDecoder().decode([Entry].self, from: try await get(api.appendingPathComponent("gauthierpiarrette/highball/contents/spike/engines")))
        var stable: RuntimeSet?
        for name in stableCandidates(listing.map(\.name)).prefix(6) {
            guard let url = listing.first(where: { $0.name == name })?.download_url else { continue }
            if let set = try stableSet(fromManifest: try await get(url)) { stable = set; break }
        }
        guard let stable else { throw PortnautError("Highball publishes no tested x64 set right now.") }
        let highball = (try? latestHighball(fromReleases: try await get(URL(string: "https://api.github.com/repos/gauthierpiarrette/highball-engine/releases?per_page=100")!))) ?? []
        let template = try? latestTemplate(fromReleases: try await get(URL(string: "https://api.github.com/repos/Sikarugir-App/Template/releases?per_page=10")!))
        let moltenvk = try? latestMoltenVK(fromRelease: try await get(api.appendingPathComponent("KhronosGroup/MoltenVK/releases/latest")))
        let (latest, notes) = latestSet(stable: stable, highball: highball, template: template ?? nil, moltenvk: moltenvk ?? nil)
        return UpdateCheck(stable: stable, latest: latest, latestNotes: notes, checkedAt: Date())
    }
}
