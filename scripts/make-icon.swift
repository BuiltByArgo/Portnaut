// Draws Portnaut's app icon set from Icon/portnaut-icon.svg (a 1024 px canvas on Apple's macOS icon
// grid). Run: swift scripts/make-icon.swift <icon.svg> <output .iconset folder>
import AppKit

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let drawing = NSImage(contentsOf: source) else { fatalError("Can't read \(source.path)") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func png(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawing.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for points in [16, 32, 128, 256, 512] {
    try png(points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
