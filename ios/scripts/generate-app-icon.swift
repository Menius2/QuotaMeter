import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: generate-app-icon.swift <iconset-directory> <preview-png>\n", stderr)
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let previewURL = URL(fileURLWithPath: CommandLine.arguments[2])
let fileManager = FileManager.default

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try fileManager.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)

func makeColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func drawRoundedRect(_ context: CGContext, rect: CGRect, radius: CGFloat, color: CGColor) {
    context.setFillColor(color)
    context.addPath(CGPath(
        roundedRect: rect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    ))
    context.fillPath()
}

func renderIcon(size: Int) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = size * 4
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fatalError("Unable to create icon context")
    }

    let canvas = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
    let unit = CGFloat(size)
    let backgroundPath = CGPath(
        roundedRect: canvas.insetBy(dx: unit * 0.02, dy: unit * 0.02),
        cornerWidth: unit * 0.22,
        cornerHeight: unit * 0.22,
        transform: nil
    )

    context.saveGState()
    context.addPath(backgroundPath)
    context.clip()
    let gradientColors = [
        makeColor(0.38, 0.23, 0.12, 1),
        makeColor(0.17, 0.17, 0.17, 1)
    ] as CFArray
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: gradientColors,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: unit * 0.12, y: unit * 0.92),
        end: CGPoint(x: unit * 0.88, y: unit * 0.08),
        options: []
    )
    context.restoreGState()

    let panelRect = canvas.insetBy(dx: unit * 0.13, dy: unit * 0.13)
    drawRoundedRect(
        context,
        rect: panelRect,
        radius: unit * 0.16,
        color: makeColor(0.08, 0.07, 0.06, 0.22)
    )

    let center = CGPoint(x: unit * 0.5, y: unit * 0.53)
    let radius = unit * 0.285
    context.saveGState()
    context.setLineCap(.round)
    context.setLineWidth(unit * 0.065)
    context.setStrokeColor(makeColor(1.0, 0.91, 0.73, 0.22))
    context.addArc(
        center: center,
        radius: radius,
        startAngle: CGFloat.pi * 0.18,
        endAngle: CGFloat.pi * 0.82,
        clockwise: false
    )
    context.strokePath()
    context.restoreGState()

    let barWidth = unit * 0.105
    let baseY = unit * 0.30
    let barX = [unit * 0.30, unit * 0.445, unit * 0.59]
    let barHeights = [unit * 0.18, unit * 0.30, unit * 0.44]
    let barColors = [
        makeColor(0.88, 0.67, 0.40, 1),
        makeColor(0.94, 0.93, 0.88, 1),
        makeColor(0.49, 0.72, 0.66, 1)
    ]

    for index in 0..<barX.count {
        let rect = CGRect(
            x: barX[index],
            y: baseY,
            width: barWidth,
            height: barHeights[index]
        )
        drawRoundedRect(
            context,
            rect: rect,
            radius: barWidth * 0.48,
            color: barColors[index]
        )
    }

    context.saveGState()
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(unit * 0.035)
    context.setStrokeColor(makeColor(1.0, 0.86, 0.56, 1))
    let trend = CGMutablePath()
    trend.move(to: CGPoint(x: unit * 0.275, y: unit * 0.42))
    trend.addLine(to: CGPoint(x: unit * 0.425, y: unit * 0.52))
    trend.addLine(to: CGPoint(x: unit * 0.57, y: unit * 0.60))
    trend.addLine(to: CGPoint(x: unit * 0.72, y: unit * 0.76))
    context.addPath(trend)
    context.strokePath()

    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: unit * 0.65, y: unit * 0.76))
    arrow.addLine(to: CGPoint(x: unit * 0.72, y: unit * 0.76))
    arrow.addLine(to: CGPoint(x: unit * 0.72, y: unit * 0.69))
    context.addPath(arrow)
    context.strokePath()
    context.restoreGState()

    let image = context.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: image)
    return bitmap.representation(using: .png, properties: [:])!
}

let iconSizes: [(name: String, pixels: Int)] = [
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

for icon in iconSizes {
    let data = renderIcon(size: icon.pixels)
    try data.write(to: iconsetURL.appendingPathComponent(icon.name))
}

try renderIcon(size: 512).write(to: previewURL)
