// Converts a square PNG into a macOS .icns.
//
// Source art typically arrives as opaque RGB on a white background. macOS icons
// need transparency outside the rounded square, or the Dock shows a white tile.
// So this floods the background out from the image border (rather than keying on
// white globally, which would also punch holes in white details inside the art),
// crops to what's left, and lays it into the standard 1024 canvas at the
// proportions Apple uses.
//
//   swift Tools/makeicon.swift <input.png> <output.icns>

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: makeicon <input.png> <output.icns>")
    exit(1)
}
let inputPath = args[1]
let outputPath = args[2]

guard let source = NSImage(contentsOfFile: inputPath),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    print("Couldn't read image at \(inputPath)")
    exit(1)
}

let width = sourceCG.width
let height = sourceCG.height

// Redraw into a known RGBA layout so pixel access is predictable.
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(
    data: &pixels,
    width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("Couldn't create bitmap context")
    exit(1)
}
context.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))

// MARK: - Knock out the background

/// How close to white counts as background. Generous, because the art's white
/// surround is usually not pure #ffffff after compression.
let whiteThreshold: UInt8 = 226

func isNearWhite(_ index: Int) -> Bool {
    pixels[index] >= whiteThreshold
        && pixels[index + 1] >= whiteThreshold
        && pixels[index + 2] >= whiteThreshold
}

// Flood fill inward from every border pixel. Starting from the border is what
// preserves white details *inside* the artwork — a global white key would erase
// the drive's indicator light along with the background.
var isBackground = [Bool](repeating: false, count: width * height)
var queue: [Int] = []

for x in 0..<width {
    for y in [0, height - 1] {
        let p = y * width + x
        if isNearWhite(p * 4), !isBackground[p] { isBackground[p] = true; queue.append(p) }
    }
}
for y in 0..<height {
    for x in [0, width - 1] {
        let p = y * width + x
        if isNearWhite(p * 4), !isBackground[p] { isBackground[p] = true; queue.append(p) }
    }
}

var head = 0
while head < queue.count {
    let p = queue[head]
    head += 1
    let x = p % width
    let y = p / width

    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
        let nx = x + dx
        let ny = y + dy
        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
        let np = ny * width + nx
        guard !isBackground[np], isNearWhite(np * 4) else { continue }
        isBackground[np] = true
        queue.append(np)
    }
}

for p in 0..<(width * height) where isBackground[p] {
    pixels[p * 4 + 3] = 0
    pixels[p * 4] = 0
    pixels[p * 4 + 1] = 0
    pixels[p * 4 + 2] = 0
}

// MARK: - Crop to the artwork

var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else {
    print("Image appears to be entirely background — nothing to crop to")
    exit(1)
}

guard let masked = context.makeImage() else {
    print("Couldn't rebuild image")
    exit(1)
}

// Square the crop around the content's centre rather than cropping tight.
//
// A tight bbox is rarely square — a drop shadow extends past the artwork on one
// side and survives the flood fill because it isn't near-white. Drawing a
// non-square crop into a square canvas would stretch the icon, so instead take
// the larger dimension and centre it.
let contentWidth = maxX - minX + 1
let contentHeight = maxY - minY + 1
let side = max(contentWidth, contentHeight)
let centerX = (minX + maxX) / 2
let centerY = (minY + maxY) / 2

var originX = centerX - side / 2
var originY = centerY - side / 2
originX = max(0, min(originX, width - side))
originY = max(0, min(originY, height - side))
let clampedSide = min(side, min(width, height))

// The bitmap's y runs opposite CGImage's, so flip the crop rect.
let cropRect = CGRect(
    x: originX,
    y: height - originY - clampedSide,
    width: clampedSide, height: clampedSide
)
guard let cropped = masked.cropping(to: cropRect) else {
    print("Crop failed")
    exit(1)
}

let transparentPercent = Int(
    100.0 * Double(isBackground.filter { $0 }.count) / Double(width * height)
)
print("  background removed: \(transparentPercent)% of the image")
print("  cropped to \(Int(cropRect.width))x\(Int(cropRect.height))")

// MARK: - Render the iconset

/// macOS draws app icons with the artwork inset from the canvas — the rounded
/// square body is 824pt on a 1024pt canvas. Since this art already carries its
/// own rounded-square shape, matching that ratio makes it sit the same size as
/// every other icon in the Dock.
let bodyRatio = 824.0 / 1024.0

func renderPNG(size: Int) -> Data? {
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    let inset = (Double(size) * (1 - bodyRatio)) / 2
    ctx.draw(cropped, in: CGRect(
        x: inset, y: inset,
        width: Double(size) - inset * 2,
        height: Double(size) - inset * 2
    ))

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "DriveMapper-\(UUID().uuidString).iconset")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

// The exact set of names iconutil expects.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = renderPNG(size: variant.size) else {
        print("Failed rendering \(variant.name)")
        exit(1)
    }
    try data.write(to: iconsetURL.appending(path: "\(variant.name).png"))
}

// MARK: - Pack

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputPath]
try process.run()
process.waitUntilExit()

try? FileManager.default.removeItem(at: iconsetURL)

guard process.terminationStatus == 0 else {
    print("iconutil failed with status \(process.terminationStatus)")
    exit(1)
}
print("  wrote \(outputPath)")
