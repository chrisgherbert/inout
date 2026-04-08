#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: render_dmg_background.swift /path/to/output.png\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let width: CGFloat = 680
let height: CGFloat = 420
let canvasSize = NSSize(width: width, height: height)

let image = NSImage(size: canvasSize)
image.lockFocus()

let backgroundGradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.992, green: 0.993, blue: 0.996, alpha: 1.0),
        NSColor(calibratedRed: 0.972, green: 0.977, blue: 0.987, alpha: 1.0)
    ]
)
backgroundGradient?.draw(in: NSRect(origin: .zero, size: canvasSize), angle: 90)

let titleStyle = NSMutableParagraphStyle()
titleStyle.alignment = .center
titleStyle.lineBreakMode = .byWordWrapping

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.07, green: 0.16, blue: 0.39, alpha: 1.0),
    .paragraphStyle: titleStyle
]

let arrowAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 68, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.11, green: 0.24, blue: 0.60, alpha: 1.0),
    .paragraphStyle: titleStyle
]

("Drag In/Out into your\nApplications folder" as NSString).draw(
    in: NSRect(x: 120, y: 232, width: 440, height: 110),
    withAttributes: titleAttributes
)

("→" as NSString).draw(
    in: NSRect(x: 290, y: 78, width: 100, height: 90),
    withAttributes: arrowAttributes
)

image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to render DMG background image.\n", stderr)
    exit(1)
}

do {
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try pngData.write(to: outputURL, options: .atomic)
} catch {
    fputs("Failed to write DMG background image: \(error.localizedDescription)\n", stderr)
    exit(1)
}
