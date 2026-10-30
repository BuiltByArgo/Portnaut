import SwiftUI
import PortnautCore

/// Who makes Portnaut, and where support questions go.
enum Publisher {
    static let name = "Built by Argo"
    static let supportEmail = "builtbyargo@proton.me"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    /// A new email to support, with Portnaut's version in the subject.
    static var supportMail: URL {
        var mail = URLComponents()
        mail.scheme = "mailto"
        mail.path = supportEmail
        mail.queryItems = [URLQueryItem(name: "subject", value: "Portnaut \(version) support")]
        return mail.url!
    }
}

enum Palette {
    // Portnaut's brand colours (BRAND.md): deep space, night, nebula grey, rocket orange, visor cyan.
    static let background = Color(red: 0.043, green: 0.063, blue: 0.149)
    static let sidebar = Color(red: 0.031, green: 0.047, blue: 0.122)
    static let card = Color(red: 0.078, green: 0.106, blue: 0.227)
    static let muted = Color(red: 0.604, green: 0.639, blue: 0.780)
    static let accent = Color(red: 1.0, green: 0.541, blue: 0.239)
    static let cyan = Color(red: 0.373, green: 0.827, blue: 0.953)
    static let line = Color.white.opacity(0.07)
}

extension View {
    /// Portnaut's rounded card background.
    func card(padding: CGFloat = 21) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Tag: View {
    var text: String
    var tint: Color = .white
    var body: some View {
        Text(text.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(0.7).padding(.horizontal, 8).padding(.vertical, 5)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(tint.opacity(0.75))
    }
}

struct SectionTitle: View {
    var title: String
    var symbol: String
    var body: some View {
        HStack { Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.4); Spacer(); Image(systemName: symbol).font(.system(size: 13)) }
            .foregroundStyle(Palette.muted)
    }
}

struct PageHeading: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 28, weight: .medium, design: .rounded)); Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.muted) }
    }
}

/// The renderer a bottle uses, and whether it is the recommended one.
struct RendererBadge: View {
    var current: Renderer
    var recommended: Recommendation?
    var body: some View {
        HStack(spacing: 6) {
            Tag(text: current.title, tint: recommended?.renderer == current || recommended == nil ? Palette.cyan : Palette.accent)
            if let recommended, recommended.renderer != current { Text("Recommended: \(recommended.renderer.title)").font(.system(size: 10)).foregroundStyle(Palette.accent) }
        }
    }
}

/// Plain space scenery for games without their own artwork: a sky, stars and a faint ringed planet.
struct SpaceScene: View {
    var seed: String
    var body: some View {
        // hashValue changes every launch; this stays the same.
        let hash = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        let hue = 0.6 + Double(hash % 100) / 100 * 0.25
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.32), Color(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.12)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            Canvas { context, size in
                var state = UInt32(truncatingIfNeeded: hash) | 1
                func next() -> Double { state = state &* 1664525 &+ 1013904223; return Double(state >> 8) / Double(1 << 24) }
                for _ in 0..<40 {
                    let r = 0.6 + next() * next() * 1.8
                    let star = CGRect(x: next() * size.width, y: next() * size.height, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: star), with: .color(.white.opacity(0.25 + next() * 0.5)))
                }
                let d = min(size.width, size.height) * 0.5
                let c = CGPoint(x: size.width - d * 0.6, y: size.height - d * 0.5)
                let tilt = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: -0.25).translatedBy(x: -c.x, y: -c.y)
                context.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(.white.opacity(0.07)))
                context.stroke(Path(ellipseIn: CGRect(x: c.x - d * 0.95, y: c.y - d * 0.2, width: d * 1.9, height: d * 0.4)).applying(tilt),
                               with: .color(.white.opacity(0.09)), lineWidth: 3)
            }
        }
    }
}

struct PortnautButtonStyle: ButtonStyle {
    var primary: Bool
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primary ? Palette.background : Color.white.opacity(0.85))
            .padding(.horizontal, 12)
            .background(primary ? Palette.accent : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(primary ? .clear : Color.white.opacity(0.1)))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

/// Original vector scenery; no game artwork or downloaded assets.
struct FrontierScene: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(red: 0.18, green: 0.29, blue: 0.32), Color(red: 0.36, green: 0.43, blue: 0.40), Color(red: 0.18, green: 0.28, blue: 0.29)], startPoint: .topTrailing, endPoint: .bottomLeading)
                Circle().fill(Color(red: 0.93, green: 0.68, blue: 0.43).opacity(0.8)).frame(width: 74, height: 74).blur(radius: 0.5).position(x: geo.size.width * 0.77, y: 77)
                Canvas { context, size in
                    let w = size.width, h = size.height
                    for layer in 0..<4 {
                        var ridge = Path()
                        let base = h * (0.36 + Double(layer) * 0.14)
                        ridge.move(to: CGPoint(x: 0, y: h))
                        for index in 0...18 {
                            let x = w * Double(index) / 18
                            let variation = sin(Double(index) * 1.7 + Double(layer) * 2) * 25 + cos(Double(index) * 0.8) * 17
                            ridge.addLine(to: CGPoint(x: x, y: base + variation))
                        }
                        ridge.addLine(to: CGPoint(x: w, y: h)); ridge.closeSubpath()
                        context.fill(ridge, with: .color(Color(red: 0.13 - Double(layer) * 0.025, green: 0.25 - Double(layer) * 0.035, blue: 0.28 - Double(layer) * 0.04)))
                    }
                    for index in 0..<24 {
                        let x = w * (0.43 + Double(index) * 0.026)
                        let height = 30 + abs(sin(Double(index) * 4.7)) * 65
                        let base = h - 4 + sin(Double(index)) * 12
                        var tree = Path()
                        for tier in 0..<3 {
                            let top = base - height + Double(tier) * height * 0.22
                            let width = height * (0.16 + Double(tier) * 0.035)
                            tree.move(to: CGPoint(x: x, y: top))
                            tree.addLine(to: CGPoint(x: x - width, y: top + height * 0.46))
                            tree.addLine(to: CGPoint(x: x + width, y: top + height * 0.46))
                            tree.closeSubpath()
                        }
                        context.fill(tree, with: .color(Color(red: 0.06, green: 0.14, blue: 0.16)))
                    }
                    var birds = Path()
                    for index in 0..<3 {
                        let x = w * 0.67 + Double(index) * 22, y = 60 + Double(index % 2) * 12
                        birds.move(to: CGPoint(x: x - 5, y: y)); birds.addQuadCurve(to: CGPoint(x: x, y: y + 2), control: CGPoint(x: x - 1, y: y - 2)); birds.addQuadCurve(to: CGPoint(x: x + 5, y: y), control: CGPoint(x: x + 2, y: y - 2))
                    }
                    context.stroke(birds, with: .color(.black.opacity(0.3)), lineWidth: 1)
                }
            }
        }
    }
}
