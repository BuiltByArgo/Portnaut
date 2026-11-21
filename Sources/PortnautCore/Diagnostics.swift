import Foundation

/// Making Portnaut's logs and messages more useful when something goes wrong.
public enum Diagnostics {
    /// Log lines that carry no information about a problem: MoltenVK's list of Vulkan extensions,
    /// about 130 lines every time a program starts Vulkan. In an exported report they pushed out the
    /// lines that matter, such as the program Portnaut started.
    public static func isNoise(_ line: Substring) -> Bool {
        let trimmed = line.drop { $0 == "\t" || $0 == " " }
        guard trimmed.count < line.count, trimmed.hasPrefix("VK_") else { return false }
        // "\tVK_KHR_swapchain v70": an extension name and its version.
        let parts = trimmed.split(separator: " ")
        return parts.count == 2 && parts[1].hasPrefix("v") && parts[1].dropFirst().allSatisfy(\.isNumber)
    }

    /// A log's last lines for the Diagnostics page and exported reports, without the noise.
    public static func tail(of log: String, lines count: Int = 150) -> String {
        log.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isNoise($0) }
            .suffix(count).joined(separator: "\n")
    }

    /// The line ProcessRunner adds when a program ends, so a report shows how it ended.
    public static func exitLine(status: Int32, seconds: TimeInterval, date: Date = Date()) -> String {
        // On a line of its own, like the command line ProcessRunner writes before it.
        "\n[\(ISO8601DateFormatter().string(from: date))] exited with code \(status) after \(formatted(seconds))\n"
    }

    /// Something to try when an installer closes within half a minute without installing anything.
    /// A suggestion, not a diagnosis: the log says what really happened.
    public static func installerEndedEarlyHint(seconds: TimeInterval, windowsVersion: WindowsVersion) -> String? {
        guard seconds < 30 else { return nil }
        let opening = "The installer closed after \(formatted(seconds))."
        if windowsVersion.isOld {
            return "\(opening) This bottle is set to \(windowsVersion.title), and many current installers need Windows 10 or later: try again in a bottle set to Windows 10."
        }
        return "\(opening) If that was unexpected, Diagnostics › Export Diagnostics… shows what it did."
    }

    static func formatted(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded())
        return rounded == 1 ? "1 second" : "\(rounded) seconds"
    }
}

extension WindowsVersion {
    /// Windows 7 and 8.1: many current games and installers refuse to run on them.
    public var isOld: Bool { self == .win7 || self == .win81 }
    /// Shown beside the Windows version pickers when an old version is chosen.
    public static let oldVersionNote = "Most current games and installers need Windows 10 or 11. Choose an older version only for a program that asks for it."
}
