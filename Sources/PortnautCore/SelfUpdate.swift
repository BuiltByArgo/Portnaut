import Foundation

/// Rules for Portnaut's own updates, which Sparkle downloads and installs. The app target makes the
/// Sparkle calls; the decisions are here so they can be tested.
public enum SelfUpdate {
    /// Where released builds look for new versions: appcast.xml attached to the newest GitHub release
    /// (scripts/make-appcast.sh). Pre-releases and drafts are not "latest", so nobody is offered them.
    public static let feedURL = "https://github.com/BuiltByArgo/Portnaut/releases/latest/download/appcast.xml"

    /// Sparkle refuses to start without a feed and an EdDSA public key, and would then show an alert at
    /// every launch. Portnaut starts it only when both are there: a build without a key has no updater.
    public static func isConfigured(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return false }
        guard let key = info["SUPublicEDKey"] as? String, let data = Data(base64Encoded: key), data.count == 32 else { return false }
        return true
    }

    /// An update replaces Portnaut.app, the Metal shim that running games load included, so it waits
    /// while any bottle has a session or Portnaut is installing or updating something.
    public static func mayInstallNow(runningBottles: Int, busy: Bool) -> Bool {
        runningBottles == 0 && !busy
    }
}
