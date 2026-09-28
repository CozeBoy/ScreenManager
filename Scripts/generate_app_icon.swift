import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate_app_icon.swift <iconset-directory>\n", stderr)
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let iconSizes: [(String, Int)] = [
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

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func renderIcon(pixelSize: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { return nil }

    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.scaleBy(x: CGFloat(pixelSize) / 1024, y: CGFloat(pixelSize) / 1024)

    let iconBounds = CGRect(x: 40, y: 40, width: 944, height: 944)
    let backgroundPath = roundedPath(iconBounds, radius: 218)
    context.addPath(backgroundPath)
    context.clip()

    let backgroundColors = [
        color(0.055, 0.12, 0.30),
        color(0.075, 0.30, 0.63),
        color(0.16, 0.52, 0.78)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: backgroundColors, locations: [0, 0.55, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 90, y: 80),
            end: CGPoint(x: 910, y: 940),
            options: []
        )
    }

    // A restrained highlight gives the icon depth without adding detail that disappears at menu size.
    context.setFillColor(color(1, 1, 1, 0.07))
    context.fillEllipse(in: CGRect(x: 160, y: 710, width: 710, height: 370))

    let screenFrame = CGRect(x: 185, y: 342, width: 654, height: 414)
    let screenPath = roundedPath(screenFrame, radius: 54)
    context.addPath(screenPath)
    context.setFillColor(color(0.88, 0.95, 1, 0.96))
    context.fillPath()

    let bezel = screenFrame.insetBy(dx: 17, dy: 17)
    let bezelPath = roundedPath(bezel, radius: 40)
    context.addPath(bezelPath)
    context.setFillColor(color(0.055, 0.105, 0.23))
    context.fillPath()

    let glass = bezel.insetBy(dx: 15, dy: 15)
    let glassPath = roundedPath(glass, radius: 29)
    context.addPath(glassPath)
    context.setFillColor(color(0.085, 0.16, 0.34))
    context.fillPath()

    // Crescent moon: screen-off state, cut cleanly from the single-color glass for crisp small-size rendering.
    let moon = CGRect(x: 430, y: 455, width: 166, height: 166)
    context.setFillColor(color(0.50, 0.88, 1))
    context.fillEllipse(in: moon)
    context.setFillColor(color(0.085, 0.16, 0.34))
    context.fillEllipse(in: moon.offsetBy(dx: 48, dy: 34))

    // Small glint paired with the moon, kept large enough to survive downsampling.
    context.setFillColor(color(0.77, 0.95, 1, 0.94))
    let glint = CGMutablePath()
    glint.move(to: CGPoint(x: 637, y: 579))
    glint.addLine(to: CGPoint(x: 650, y: 604))
    glint.addLine(to: CGPoint(x: 675, y: 617))
    glint.addLine(to: CGPoint(x: 650, y: 630))
    glint.addLine(to: CGPoint(x: 637, y: 655))
    glint.addLine(to: CGPoint(x: 624, y: 630))
    glint.addLine(to: CGPoint(x: 599, y: 617))
    glint.addLine(to: CGPoint(x: 624, y: 604))
    glint.closeSubpath()
    context.addPath(glint)
    context.fillPath()

    let standColor = color(0.88, 0.95, 1, 0.96)
    context.setFillColor(standColor)
    context.addPath(roundedPath(CGRect(x: 474, y: 230, width: 76, height: 125), radius: 26))
    context.fillPath()
    context.addPath(roundedPath(CGRect(x: 365, y: 202, width: 294, height: 42), radius: 21))
    context.fillPath()

    guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }
    return pngData
}

for (filename, size) in iconSizes {
    guard let data = renderIcon(pixelSize: size) else {
        fputs("Could not render \(filename)\n", stderr)
        exit(1)
    }
    try data.write(to: iconsetURL.appendingPathComponent(filename), options: .atomic)
}
