#!/usr/bin/env swift

import AppKit
import Foundation

private struct IconRepresentation {
    let pixels: Int
    let chunkType: String
}

private let representations = [
    IconRepresentation(pixels: 16, chunkType: "icp4"),
    IconRepresentation(pixels: 32, chunkType: "icp5"),
    IconRepresentation(pixels: 64, chunkType: "icp6"),
    IconRepresentation(pixels: 128, chunkType: "ic07"),
    IconRepresentation(pixels: 256, chunkType: "ic08"),
    IconRepresentation(pixels: 512, chunkType: "ic09"),
    IconRepresentation(pixels: 1_024, chunkType: "ic10"),
]

private func bigEndianBytes(_ value: Int) throws -> [UInt8] {
    guard value >= 0, value <= Int(UInt32.max) else {
        throw IconGenerationError.invalidLength(value)
    }
    let encoded = UInt32(value).bigEndian
    return withUnsafeBytes(of: encoded) { Array($0) }
}

private func pngData(for image: NSImage, pixels: Int) throws -> Data {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw IconGenerationError.cannotCreateBitmap(pixels)
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = NSImageInterpolation.high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard
        let data = bitmap.representation(
            using: NSBitmapImageRep.FileType.png,
            properties: [:]
        )
    else {
        throw IconGenerationError.cannotEncodePNG(pixels)
    }
    return data
}

private enum IconGenerationError: LocalizedError {
    case usage
    case cannotLoadSource(String)
    case cannotCreateBitmap(Int)
    case cannotEncodePNG(Int)
    case invalidLength(Int)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: generate-app-icon.swift SOURCE.svg OUTPUT.icns"
        case .cannotLoadSource(let path):
            "Could not load vector artwork at \(path)."
        case .cannotCreateBitmap(let pixels):
            "Could not create the \(pixels)x\(pixels) icon bitmap."
        case .cannotEncodePNG(let pixels):
            "Could not encode the \(pixels)x\(pixels) icon as PNG."
        case .invalidLength(let length):
            "ICNS data length \(length) is outside the 32-bit format limit."
        }
    }
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw IconGenerationError.usage
    }

    let sourcePath = CommandLine.arguments[1]
    let destinationPath = CommandLine.arguments[2]
    guard let sourceImage = NSImage(contentsOfFile: sourcePath) else {
        throw IconGenerationError.cannotLoadSource(sourcePath)
    }

    var chunks = Data()
    for representation in representations {
        let png = try pngData(for: sourceImage, pixels: representation.pixels)
        chunks.append(contentsOf: representation.chunkType.utf8)
        chunks.append(contentsOf: try bigEndianBytes(png.count + 8))
        chunks.append(png)
    }

    var archive = Data("icns".utf8)
    archive.append(contentsOf: try bigEndianBytes(chunks.count + 8))
    archive.append(chunks)
    try archive.write(to: URL(fileURLWithPath: destinationPath), options: .atomic)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
