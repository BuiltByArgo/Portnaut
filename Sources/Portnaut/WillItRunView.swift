import SwiftUI
import PortnautCore

/// One game's verdict from the compatibility database.
struct CompatibilityRow: View {
    var report: CompatibilityReport
    var showTitle = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: report.symbol).font(.system(size: 14)).foregroundStyle(report.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                if showTitle {
                    Text(report.title).font(.system(size: 13, weight: .semibold))
                }
                HStack(spacing: 6) {
                    Text(report.headline).font(.system(size: 12, weight: .semibold)).foregroundStyle(report.tint)
                    if let url = report.url { Link("Details ↗", destination: url).font(.system(size: 11)) }
                }
                Text(report.explanation).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

extension CompatibilityReport {
    var symbol: String {
        switch status {
        case .blocked: "xmark.octagon"
        case .unlikely: "exclamationmark.triangle"
        case .maybe: "questionmark.circle"
        case .likely: "chart.line.uptrend.xyaxis"
        case .reported: "person.2"
        case .tested: "checkmark.seal"
        }
    }
    var tint: Color {
        switch status {
        case .blocked, .unlikely: Palette.accent
        case .maybe: Palette.muted
        case .likely, .reported, .tested: Palette.cyan
        }
    }
}

/// Search the database before buying or downloading a game.
struct WillItRunSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let results = model.compatibility?.search(model.willItRunQuery) ?? []
        VStack(alignment: .leading, spacing: 14) {
            Text("Will It Run?").font(.system(size: 22, weight: .medium, design: .rounded))
            Text("Check a game before you buy or download it: \(model.compatibility.map { "\($0.reports.count.formatted()) games" } ?? "the list") with Mac reports, anti-cheat and Linux players’ results.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            TextField("Game title", text: $model.willItRunQuery).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.compatibility == nil {
                        Text("The compatibility list could not be read.").font(.system(size: 12)).foregroundStyle(Palette.accent)
                    } else if model.willItRunQuery.trimmingCharacters(in: .whitespaces).count >= 2 && results.isEmpty {
                        Text("No reports for “\(model.willItRunQuery)” yet. Most games without anti-cheat are worth a try.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    ForEach(results) { CompatibilityRow(report: $0, showTitle: true) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.frame(height: 360)
            Text("From Highball’s compatibility database (CC0), with anti-cheat data from Are We Anti-Cheat Yet? (MIT) and predictions from ProtonDB’s Linux reports (ODbL). Portnaut checks it on your Mac; it never sends what you search or play.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 560).background(Palette.background)
    }
}
