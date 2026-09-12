// Generates Resources/AppIcon.png (1024x1024) — a macOS-style rounded
// square with an EQ-bar glyph, one bar highlighted to suggest "the format
// that's locked in". Run with: swift scripts/generate_icon.swift
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let size = 1024
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// macOS-style squircle background (~22% corner radius), diagonal gradient.
let cornerRadius: CGFloat = CGFloat(size) * 0.225
let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(path)
ctx.clip()

let colors = [
    CGColor(red: 0.11, green: 0.16, blue: 0.44, alpha: 1), // deep indigo
    CGColor(red: 0.02, green: 0.62, blue: 0.71, alpha: 1), // teal/cyan
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0),
    options: []
)

// Subtle radial sheen near the top for depth, softly feathered (no hard edge).
ctx.saveGState()
let sheenColors = [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
] as CFArray
let sheenGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheenColors, locations: [0, 1])!
ctx.drawRadialGradient(
    sheenGradient,
    startCenter: CGPoint(x: CGFloat(size) * 0.5, y: CGFloat(size) * 0.78), startRadius: 0,
    endCenter: CGPoint(x: CGFloat(size) * 0.5, y: CGFloat(size) * 0.78), endRadius: CGFloat(size) * 0.65,
    options: []
)
ctx.restoreGState()

// EQ bars: 5 bars, varying heights, rounded caps, centered. Middle bar
// highlighted in a bright accent to read as "the matched/locked format".
let barCount = 5
let barWidth: CGFloat = CGFloat(size) * 0.09
let gap: CGFloat = CGFloat(size) * 0.055
let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
let startX = (CGFloat(size) - totalWidth) / 2
let centerY = CGFloat(size) / 2
// Heights as a fraction of canvas, short-tall-tallest(highlight)-tall-short.
let heightFractions: [CGFloat] = [0.28, 0.46, 0.62, 0.46, 0.28]
let accentColor = CGColor(red: 0.55, green: 0.98, blue: 0.55, alpha: 1) // bright lime
let whiteColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)

for i in 0..<barCount {
    let h = CGFloat(size) * heightFractions[i]
    let x = startX + CGFloat(i) * (barWidth + gap)
    let y = centerY - h / 2
    let barRect = CGRect(x: x, y: y, width: barWidth, height: h)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    ctx.addPath(barPath)
    ctx.setFillColor(i == 2 ? accentColor : whiteColor)
    ctx.fillPath()
}

guard let image = ctx.makeImage() else {
    fatalError("Failed to render icon")
}

let outputURL = URL(fileURLWithPath: "Resources/AppIcon.png")
guard let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Failed to create image destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    fatalError("Failed to write PNG")
}
print("Wrote \(outputURL.path)")
