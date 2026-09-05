import AppKit
import Foundation

// Native SF Symbol composition. Run from the repository root.
let output = URL(fileURLWithPath: "Dashi/Dashi/Assets.xcassets/AppIcon.appiconset")
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        let rect = NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.55, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.22, blue: 0.3, alpha: 1))!.draw(in: NSBezierPath(roundedRect: rect, xRadius: p * 0.2, yRadius: p * 0.2), angle: -90)
        let symbol = NSImage(systemSymbolName: "rectangle.3.group.fill", accessibilityDescription: nil)!.withSymbolConfiguration(.init(paletteColors: [.white]))!
        symbol.draw(in: NSRect(x: p * 0.22, y: p * 0.28, width: p * 0.56, height: p * 0.44))
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
