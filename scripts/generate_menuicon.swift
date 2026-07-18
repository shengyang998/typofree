#!/usr/bin/env swift
//
// generate_menuicon.swift — produces TypoFree/menuicon.tiff (a template-style
// glyph, for the FUTURE tsInputMethodIconFileKey wiring — NOT wired into
// Info.plist yet, tasks.md §M8 scope item 9: "wire tsInputMethodIconFileKey is
// NOT needed yet") and TypoFree/Assets.xcassets/AppIcon.appiconset (a
// placeholder app icon at every required macOS size).
//
// Pure CoreGraphics drawing directly into exact-pixel-size `NSBitmapImageRep`s
// (NOT `NSImage.lockFocus()`, which silently doubles output on a Retina host —
// it follows the CALLING MACHINE's screen backing scale, not the pixel size you
// asked for; caught by inspecting output with `sips` during authoring). No
// external assets, deterministic, no network.
//
// Run from the labs/typofree directory:
//   swift scripts/generate_menuicon.swift
//
// DESIGN.md §7 icon row: "图标 | Assets.xcassets + menuicon.tiff | 待产（M8）".
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let typoFreeDir = root.appendingPathComponent("TypoFree")

// MARK: - Exact-pixel-size bitmap drawing (screen-scale-independent)

func makeBitmap(pixelsWide: Int, pixelsHigh: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext)
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Shared glyph: a rounded "key" outline with a small correction dot,
// evoking "keyboard + LLM correction" (slot#1's ✦ landed marker, echoed at icon
// scale). Deliberately simple geometry — legible at 18x18 menu-bar scale.

func drawGlyph(cgContext ctx: CGContext, pixels: Int, strokeColor: NSColor, fillBackground: NSColor?) {
    let size = CGSize(width: pixels, height: pixels)
    ctx.clear(CGRect(origin: .zero, size: size))
    if let fillBackground {
        let bgInset = size.width * 0.04
        let bgRect = CGRect(x: bgInset, y: bgInset, width: size.width - 2 * bgInset, height: size.height - 2 * bgInset)
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: size.width * 0.22, cornerHeight: size.width * 0.22, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(fillBackground.cgColor)
        ctx.fillPath()
    }

    let inset = size.width * 0.20
    let keyRect = CGRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
    let keyPath = CGPath(roundedRect: keyRect, cornerWidth: size.width * 0.14, cornerHeight: size.width * 0.14, transform: nil)
    ctx.addPath(keyPath)
    ctx.setStrokeColor(strokeColor.cgColor)
    ctx.setLineWidth(max(1, size.width * 0.075))
    ctx.strokePath()

    let dotSize = size.width * 0.16
    let dotRect = CGRect(x: size.width / 2 - dotSize / 2, y: size.height / 2 - dotSize / 2, width: dotSize, height: dotSize)
    ctx.setFillColor(strokeColor.cgColor)
    ctx.fillEllipse(in: dotRect)
}

// MARK: - menuicon.tiff: a template image (black + alpha only — AppKit auto-tints
// template images for light/dark menu bars). Multi-representation TIFF (@1x/@2x
// at the standard 18pt menu-bar glyph size, each rep's `size` set to the POINT
// size so both represent "the same 18x18pt image" at different densities).

func makeMenuIconTIFF() throws {
    let reps: [NSBitmapImageRep] = [1, 2].compactMap { scale -> NSBitmapImageRep? in
        let px = 18 * scale
        guard let rep = makeBitmap(pixelsWide: px, pixelsHigh: px, draw: { ctx in
            drawGlyph(cgContext: ctx, pixels: px, strokeColor: .black, fillBackground: nil)
        }) else { return nil }
        rep.size = NSSize(width: 18, height: 18) // same POINT size at both pixel densities
        return rep
    }
    guard reps.count == 2,
          let multiRepData = NSBitmapImageRep.representationOfImageReps(in: reps, using: .tiff, properties: [:])
    else {
        throw NSError(domain: "generate_menuicon", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to build multi-rep TIFF"])
    }
    let outURL = typoFreeDir.appendingPathComponent("menuicon.tiff")
    try multiRepData.write(to: outURL)
    print("wrote \(outURL.path) (\(multiRepData.count) bytes, \(reps.count) reps)")
}

// MARK: - Assets.xcassets/AppIcon.appiconset — placeholder app icon, all 10
// required macOS idiom/scale/size combinations.

struct IconSpec { let sizePoints: Int; let scale: Int; var pixels: Int { sizePoints * scale } }
let iconSpecs: [IconSpec] = [
    IconSpec(sizePoints: 16, scale: 1), IconSpec(sizePoints: 16, scale: 2),
    IconSpec(sizePoints: 32, scale: 1), IconSpec(sizePoints: 32, scale: 2),
    IconSpec(sizePoints: 128, scale: 1), IconSpec(sizePoints: 128, scale: 2),
    IconSpec(sizePoints: 256, scale: 1), IconSpec(sizePoints: 256, scale: 2),
    IconSpec(sizePoints: 512, scale: 1), IconSpec(sizePoints: 512, scale: 2),
]

func filename(for spec: IconSpec) -> String {
    "icon_\(spec.sizePoints)x\(spec.sizePoints)" + (spec.scale == 2 ? "@2x.png" : ".png")
}

func makeAppIconAssets() throws {
    let assetsDir = typoFreeDir.appendingPathComponent("Assets.xcassets")
    let iconSetDir = assetsDir.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: iconSetDir, withIntermediateDirectories: true)

    let topLevelContents = """
    {
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
    try topLevelContents.write(to: assetsDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

    // Placeholder colors: a simple tinted background + white-ish glyph so it
    // reads as an app icon (distinct from the black-only menu-bar template).
    let background = NSColor(calibratedRed: 0.16, green: 0.32, blue: 0.62, alpha: 1.0)
    let glyphColor = NSColor.white

    var imageEntries: [String] = []
    for spec in iconSpecs {
        guard let rep = makeBitmap(pixelsWide: spec.pixels, pixelsHigh: spec.pixels, draw: { ctx in
            drawGlyph(cgContext: ctx, pixels: spec.pixels, strokeColor: glyphColor, fillBackground: background)
        }), let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "generate_menuicon", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "failed to render \(spec.pixels)px icon"])
        }
        let name = filename(for: spec)
        try pngData.write(to: iconSetDir.appendingPathComponent(name))
        imageEntries.append("""
                { "idiom" : "mac", "scale" : "\(spec.scale)x", "size" : "\(spec.sizePoints)x\(spec.sizePoints)", "filename" : "\(name)" }
        """)
    }

    let iconSetContents = """
    {
      "images" : [
    \(imageEntries.joined(separator: ",\n"))
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
    try iconSetContents.write(to: iconSetDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("wrote \(iconSetDir.path) (\(iconSpecs.count) images)")
}

// MARK: - Run

do {
    guard FileManager.default.fileExists(atPath: typoFreeDir.path) else {
        throw NSError(domain: "generate_menuicon", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "run from labs/typofree — TypoFree/ not found under \(root.path)"])
    }
    try makeMenuIconTIFF()
    try makeAppIconAssets()
    print("done.")
} catch {
    FileHandle.standardError.write(Data("generate_menuicon: \(error)\n".utf8))
    exit(1)
}
