#!/usr/bin/env swift
//
// Renders the Sensorstorm app icon to a 1024×1024 PNG.
//
//   swift Tools/make_icon.swift Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// Kept as code rather than a binary blob so the icon can be tweaked and regenerated
// without a design tool, and so the light/dark/tinted renditions stay in sync.

import AppKit
import CoreGraphics
import Foundation

let size = 1024.0
let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 ? arguments[1] : "icon-1024.png"
let variant = arguments.count > 2 ? arguments[2] : "dark"

guard let context = CGContext(
    data: nil,
    width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("could not create bitmap context")
}

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let accent = color(0.29, 0.78, 0.94)
let hot = color(0.98, 0.28, 0.32)

// MARK: - Background

switch variant {
case "light":
    context.setFillColor(color(1, 1, 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
case "tinted":
    context.setFillColor(color(0, 0, 0, 0))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
default:
    // A vertical gradient from deep blue to near-black: reads as an instrument face.
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [color(0.06, 0.10, 0.17), color(0.02, 0.03, 0.05)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
}

let isTinted = variant == "tinted"
let strokeBase = variant == "light" ? color(0.10, 0.16, 0.24) : color(1, 1, 1)

// MARK: - Concentric rings — the "sensor" half of the mark

let center = CGPoint(x: size / 2, y: size / 2)
for step in 0..<4 {
    let radius = 150.0 + Double(step) * 96
    let alpha = 0.30 - Double(step) * 0.06
    context.setStrokeColor(isTinted ? strokeBase.copy(alpha: alpha)!
                                    : accent.copy(alpha: alpha)!)
    context.setLineWidth(6)
    context.addArc(center: center, radius: radius,
                   startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.strokePath()
}

// MARK: - Waveforms — the "storm" half

/// Three stacked traces of decreasing amplitude, clipped to the icon's safe circle.
func drawWave(amplitude: Double, frequency: Double, phase: Double,
              yOffset: Double, width: Double, stroke: CGColor) {
    context.saveGState()
    context.setStrokeColor(stroke)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let path = CGMutablePath()
    let left = 150.0
    let right = size - 150
    var x = left
    var isFirst = true

    while x <= right {
        let t = (x - left) / (right - left)
        // Taper the ends so the trace fades into the rings instead of being cut off.
        let envelope = sin(t * .pi)
        let y = center.y + yOffset
            + sin(t * frequency * .pi * 2 + phase) * amplitude * envelope
            + sin(t * frequency * 2.7 * .pi * 2 + phase * 1.7) * amplitude * 0.25 * envelope

        if isFirst {
            path.move(to: CGPoint(x: x, y: y))
            isFirst = false
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
        x += 2
    }

    context.addPath(path)
    context.strokePath()
    context.restoreGState()
}

if isTinted {
    drawWave(amplitude: 60, frequency: 1.6, phase: 0.4, yOffset: 96, width: 16,
             stroke: strokeBase.copy(alpha: 0.45)!)
    drawWave(amplitude: 100, frequency: 2.3, phase: 2.1, yOffset: 0, width: 26,
             stroke: strokeBase)
    drawWave(amplitude: 70, frequency: 1.9, phase: 4.0, yOffset: -104, width: 16,
             stroke: strokeBase.copy(alpha: 0.45)!)
} else {
    drawWave(amplitude: 60, frequency: 1.6, phase: 0.4, yOffset: 96, width: 16,
             stroke: accent.copy(alpha: 0.55)!)
    drawWave(amplitude: 100, frequency: 2.3, phase: 2.1, yOffset: 0, width: 28,
             stroke: variant == "light" ? color(0.10, 0.16, 0.24) : color(1, 1, 1))
    drawWave(amplitude: 70, frequency: 1.9, phase: 4.0, yOffset: -104, width: 16,
             stroke: hot.copy(alpha: 0.75)!)
}

// MARK: - Write

guard let image = context.makeImage() else { fatalError("could not render image") }
let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try data.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(variant))")
