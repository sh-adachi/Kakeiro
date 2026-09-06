#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Original vector construction. Run from the repository root; no external assets.
let destination = CommandLine.arguments.dropFirst().first
    ?? "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
}
func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func line(from start: NSPoint, to end: NSPoint, width: CGFloat, stroke: NSColor) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineWidth = width
    path.lineCapStyle = .round
    stroke.setStroke()
    path.stroke()
}

let cream = color(0.965, 0.953, 0.917)
let teal = color(0.075, 0.420, 0.416)
let mint = color(0.740, 0.831, 0.758)
let coral = color(0.891, 0.459, 0.357)
cream.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

// Two offset sheets give the ledger a quiet sense of depth.
NSGraphicsContext.saveGraphicsState()
let rotation = AffineTransform(translationByX: 535, byY: 520)
(rotation as NSAffineTransform).concat()
let tilt = AffineTransform(rotationByDegrees: -11)
(tilt as NSAffineTransform).concat()
rounded(NSRect(x: -238, y: -280, width: 476, height: 560), radius: 64, fill: mint)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = teal.withAlphaComponent(0.16)
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.shadowBlurRadius = 28
shadow.set()
rounded(NSRect(x: 237, y: 193, width: 476, height: 588), radius: 68, fill: teal)
NSGraphicsContext.restoreGraphicsState()

// Ledger rules; the coral entry is a small everyday purchase.
for y: CGFloat in [625, 508, 391] {
    rounded(NSRect(x: 304, y: y, width: 37, height: 37), radius: 12,
            fill: y == 508 ? coral : cream)
    line(from: NSPoint(x: 390, y: y + 18), to: NSPoint(x: 570, y: y + 18),
         width: 25, stroke: cream)
}
line(from: NSPoint(x: 321, y: 286), to: NSPoint(x: 514, y: 286),
     width: 15, stroke: mint)

// A coin and growing leaf represent assets alongside the daily ledger.
coral.setFill()
NSBezierPath(ovalIn: NSRect(x: 571, y: 183, width: 213, height: 213)).fill()
line(from: NSPoint(x: 678, y: 242), to: NSPoint(x: 678, y: 337), width: 24, stroke: cream)
line(from: NSPoint(x: 630, y: 289), to: NSPoint(x: 725, y: 289), width: 24, stroke: cream)

let leaf = NSBezierPath()
leaf.move(to: NSPoint(x: 666, y: 650))
leaf.curve(to: NSPoint(x: 834, y: 792), controlPoint1: NSPoint(x: 661, y: 755), controlPoint2: NSPoint(x: 748, y: 801))
leaf.curve(to: NSPoint(x: 666, y: 650), controlPoint1: NSPoint(x: 830, y: 677), controlPoint2: NSPoint(x: 750, y: 635))
leaf.close()
mint.setFill()
leaf.fill()
line(from: NSPoint(x: 659, y: 628), to: NSPoint(x: 766, y: 739), width: 17, stroke: cream)

NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: destination)
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(writer, context.makeImage()!, nil)
guard CGImageDestinationFinalize(writer) else { fatalError("PNG encoding failed") }
print("Wrote \(output.path)")
