#!/usr/bin/env swift
import AppKit
import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let rootURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

let iconSetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("AutoDucking.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconSetURL)
try FileManager.default.createDirectory(at: iconSetURL, withIntermediateDirectories: true)

func tintedSymbol(named symbolName: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
    guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
        return nil
    }
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    guard let symbol = base.withSymbolConfiguration(configuration) else { return nil }

    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(
        in: NSRect(origin: .zero, size: symbol.size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    color.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Unable to create bitmap for \(size)px icon")
    }
    rep.size = NSSize(width: size, height: size)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Unable to create graphics context")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true

    let s = CGFloat(size) / 1024
    let inset = 88 * s
    let tileRect = NSRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 214 * s, yRadius: 214 * s)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -7 * s)
    shadow.set()

    let background = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.50, blue: 0.99, alpha: 1),
        NSColor(srgbRed: 0.48, green: 0.30, blue: 0.94, alpha: 1)
    ])!
    background.draw(in: tile, angle: -62)

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    tile.addClip()
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.24),
        NSColor.white.withAlphaComponent(0.0)
    ])!
    highlight.draw(
        in: NSRect(x: tileRect.minX, y: tileRect.midY, width: tileRect.width, height: tileRect.height / 2),
        angle: -90
    )
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let border = NSBezierPath(
        roundedRect: tileRect.insetBy(dx: 1.5 * s, dy: 1.5 * s),
        xRadius: 212 * s,
        yRadius: 212 * s
    )
    NSColor.white.withAlphaComponent(0.16).setStroke()
    border.lineWidth = 3 * s
    border.stroke()

    if let microphone = tintedSymbol(named: "mic.fill", pointSize: 430 * s, color: .white) {
        let height = 430 * s
        let width = height * (microphone.size.width / microphone.size.height)
        let rect = NSRect(
            x: 476 * s - width / 2,
            y: 516 * s - height / 2,
            width: width,
            height: height
        )
        microphone.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.99)
    }

    let barWidth = 44 * s
    let barHeights: [CGFloat] = [182, 124, 74]
    let barOrigins: [CGFloat] = [712, 796, 880]
    for index in barHeights.indices {
        let height = barHeights[index] * s
        let rect = NSRect(
            x: barOrigins[index] * s,
            y: 304 * s,
            width: barWidth,
            height: height
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        NSColor.white.withAlphaComponent(0.92 - CGFloat(index) * 0.14).setFill()
        path.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconNames: [(size: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

var cache: [Int: NSBitmapImageRep] = [:]
for entry in iconNames {
    let rep: NSBitmapImageRep
    if let cached = cache[entry.size] {
        rep = cached
    } else {
        rep = drawIcon(size: entry.size)
        cache[entry.size] = rep
    }
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode \(entry.name)")
    }
    try data.write(to: iconSetURL.appendingPathComponent(entry.name))
}

let previewURL = resourcesURL.appendingPathComponent("AppIcon-1024.png")
if let previewRep = cache[1024], let previewData = previewRep.representation(using: .png, properties: [:]) {
    try previewData.write(to: previewURL)
}

let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconSetURL.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}

print("Generated \(icnsURL.path)")
print("Generated \(previewURL.path)")
