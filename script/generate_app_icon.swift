import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetURL = root.appendingPathComponent("Sources/App/Resources/AppIcon.iconset", isDirectory: true)

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let iconEntries: [(filename: String, size: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for entry in iconEntries {
    let image = drawIcon(size: entry.size)
    let data = try pngData(for: image)
    try data.write(to: iconsetURL.appendingPathComponent(entry.filename))
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let background = NSGradient(colors: [
        NSColor(calibratedRed: 0.96, green: 0.90, blue: 0.78, alpha: 1),
        NSColor(calibratedRed: 0.82, green: 0.56, blue: 0.37, alpha: 1)
    ])
    let basePath = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.03, dy: size * 0.03), xRadius: size * 0.22, yRadius: size * 0.22)
    background?.draw(in: basePath, angle: -55)

    let vignette = NSGradient(colors: [
        NSColor.black.withAlphaComponent(0.0),
        NSColor.black.withAlphaComponent(0.18)
    ])
    vignette?.draw(in: basePath, relativeCenterPosition: NSPoint(x: 0.3, y: -0.3))

    let frameRect = NSRect(
        x: size * 0.16,
        y: size * 0.14,
        width: size * 0.68,
        height: size * 0.62
    )
    let framePath = NSBezierPath(roundedRect: frameRect, xRadius: size * 0.08, yRadius: size * 0.08)
    NSColor(calibratedRed: 0.16, green: 0.12, blue: 0.10, alpha: 0.88).setFill()
    framePath.fill()

    let screenInset = size * 0.03
    let screenRect = frameRect.insetBy(dx: screenInset, dy: screenInset)
    let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: size * 0.055, yRadius: size * 0.055)
    let screenGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.25, green: 0.19, blue: 0.15, alpha: 1),
        NSColor(calibratedRed: 0.12, green: 0.09, blue: 0.08, alpha: 1)
    ])
    screenGradient?.draw(in: screenPath, angle: 270)

    let cardRect = NSRect(
        x: size * 0.25,
        y: size * 0.28,
        width: size * 0.44,
        height: size * 0.28
    )
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: size * 0.04, yRadius: size * 0.04)
    NSColor(calibratedRed: 0.99, green: 0.96, blue: 0.90, alpha: 1).setFill()
    cardPath.fill()

    NSColor(calibratedRed: 0.73, green: 0.51, blue: 0.35, alpha: 1).setFill()
    let accentRect = NSRect(x: cardRect.minX, y: cardRect.maxY - size * 0.05, width: cardRect.width, height: size * 0.05)
    NSBezierPath(roundedRect: accentRect, xRadius: size * 0.03, yRadius: size * 0.03).fill()

    let lineColor = NSColor(calibratedRed: 0.39, green: 0.31, blue: 0.27, alpha: 0.95)
    lineColor.setStroke()
    for index in 0..<3 {
        let y = cardRect.minY + size * (0.07 + CGFloat(index) * 0.055)
        let path = NSBezierPath()
        path.lineWidth = max(1.2, size * 0.015)
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: cardRect.minX + size * 0.05, y: y))
        path.line(to: NSPoint(x: cardRect.maxX - size * 0.08, y: y))
        path.stroke()
    }

    let questionDotRect = NSRect(x: cardRect.maxX - size * 0.11, y: cardRect.maxY - size * 0.105, width: size * 0.055, height: size * 0.055)
    let dotPath = NSBezierPath(ovalIn: questionDotRect)
    NSColor(calibratedRed: 0.92, green: 0.74, blue: 0.54, alpha: 1).setFill()
    dotPath.fill()

    let playWidth = size * 0.09
    let playHeight = size * 0.11
    let playOrigin = NSPoint(x: frameRect.maxX - size * 0.17, y: frameRect.minY + size * 0.12)
    let playPath = NSBezierPath()
    playPath.move(to: playOrigin)
    playPath.line(to: NSPoint(x: playOrigin.x, y: playOrigin.y + playHeight))
    playPath.line(to: NSPoint(x: playOrigin.x + playWidth, y: playOrigin.y + (playHeight / 2)))
    playPath.close()
    NSColor(calibratedRed: 0.95, green: 0.84, blue: 0.66, alpha: 1).setFill()
    playPath.fill()

    let footerRect = NSRect(x: size * 0.18, y: size * 0.79, width: size * 0.64, height: size * 0.06)
    let footerPath = NSBezierPath(roundedRect: footerRect, xRadius: size * 0.03, yRadius: size * 0.03)
    NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.18).setFill()
    footerPath.fill()

    return image
}

func pngData(for image: NSImage) throws -> Data {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "generate_app_icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG."])
    }
    return data
}
