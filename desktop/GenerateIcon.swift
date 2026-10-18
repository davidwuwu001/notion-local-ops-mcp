import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(pixels) * 0.03, dy: CGFloat(pixels) * 0.03), xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22).fill()
        if let symbol = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: CGFloat(pixels) * 0.60, weight: .medium)) {
            symbol.draw(in: rect.insetBy(dx: CGFloat(pixels) * 0.18, dy: CGFloat(pixels) * 0.18), from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSColor(calibratedRed: 0.25, green: 0.87, blue: 0.63, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: CGFloat(pixels) * 0.72, y: CGFloat(pixels) * 0.16, width: CGFloat(pixels) * 0.14, height: CGFloat(pixels) * 0.14)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
