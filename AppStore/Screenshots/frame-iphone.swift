// frame-iphone.swift
// Puts each raw iPhone screenshot in a drawn black iPhone 17 frame. Every image becomes a one-page PDF in
// iPhone-PDF/ and, because App Store Connect accepts only PNG or JPEG, an opaque 1320 × 2868 PNG in iPhone-en/.
// Keep the raw screenshots in their own folder: framing a framed image would frame it twice.
//
// Usage: swift frame-iphone.swift <folder of raw 1320 × 2868 PNGs> <AppStore/Screenshots folder>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let page = CGSize(width: 1320, height: 2868)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat(hex >> 16 & 255) / 255, CGFloat(hex >> 8 & 255) / 255,
                                           CGFloat(hex & 255) / 255, 1])!
}

func fill(_ context: CGContext, _ rect: CGRect, radius: CGFloat, _ hex: UInt32) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(color(hex))
    context.fillPath()
}

func draw(_ screen: CGImage, in context: CGContext) {
    context.interpolationQuality = .high
    context.setFillColor(color(0xD9F1FD))   // The app's Sky Mist, as behind the Watch.
    context.fill(CGRect(origin: .zero, size: page))

    let height: CGFloat = 2480
    let width = height * CGFloat(screen.width) / CGFloat(screen.height)
    let display = CGRect(x: (page.width - width) / 2, y: (page.height - height) / 2, width: width, height: height)
    let bezel = display.insetBy(dx: -30, dy: -30)
    let body = bezel.insetBy(dx: -14, dy: -14)

    // Buttons, placed as fractions of the body's height measured from the top.
    func button(onLeft: Bool, from top: CGFloat, to bottom: CGFloat, _ hex: UInt32 = 0x232326) {
        let rect = CGRect(x: onLeft ? body.minX - 9 : body.maxX - 5, y: body.maxY - body.height * bottom,
                          width: 14, height: body.height * (bottom - top))
        fill(context, rect, radius: 5, hex)
    }
    button(onLeft: true, from: 0.170, to: 0.205)    // Action button.
    button(onLeft: true, from: 0.245, to: 0.305)    // Volume up.
    button(onLeft: true, from: 0.325, to: 0.385)    // Volume down.
    button(onLeft: false, from: 0.270, to: 0.365)   // Side button.
    button(onLeft: false, from: 0.590, to: 0.650, 0x2E2E32)   // Camera Control.

    fill(context, body, radius: 214, 0x3A3A3E)
    fill(context, body.insetBy(dx: 4, dy: 4), radius: 210, 0x18181A)
    fill(context, bezel, radius: 200, 0x000000)

    context.saveGState()
    context.addPath(CGPath(roundedRect: display, cornerWidth: 170, cornerHeight: 170, transform: nil))
    context.clip()
    context.draw(screen, in: display)
    context.restoreGState()

    // Dynamic Island: 126 × 37 pt, 11 pt below the top of a 402 pt wide screen.
    let scale = display.width / 402
    let island = CGSize(width: 126 * scale, height: 37 * scale)
    fill(context, CGRect(x: display.midX - island.width / 2, y: display.maxY - (11 * scale + island.height),
                         width: island.width, height: island.height), radius: island.height / 2, 0x000000)
}

/// Redrawn into plain sRGB first, so the PDF shows the same colours as the PNG.
func inSRGB(_ image: CGImage) -> CGImage {
    let bitmap = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                           bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bitmap.makeImage()!
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("usage: frame-iphone.swift <raw folder> <Screenshots folder>") }
let raw = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let pngFolder = output.appending(path: "iPhone-en"), pdfFolder = output.appending(path: "iPhone-PDF")
try FileManager.default.createDirectory(at: pngFolder, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: pdfFolder, withIntermediateDirectories: true)

for file in try FileManager.default.contentsOfDirectory(at: raw, includingPropertiesForKeys: nil)
    where file.pathExtension == "png" {
    let source = CGImageSourceCreateWithURL(file as CFURL, nil)!
    let screen = inSRGB(CGImageSourceCreateImageAtIndex(source, 0, nil)!)
    let name = file.deletingPathExtension().lastPathComponent

    var box = CGRect(origin: .zero, size: page)
    let pdf = CGContext(pdfFolder.appending(path: "\(name).pdf") as CFURL, mediaBox: &box, nil)!
    pdf.beginPDFPage(nil)
    draw(screen, in: pdf)
    pdf.endPDFPage()
    pdf.closePDF()

    let bitmap = CGContext(data: nil, width: Int(page.width), height: Int(page.height), bitsPerComponent: 8,
                           bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    draw(screen, in: bitmap)
    let png = CGImageDestinationCreateWithURL(pngFolder.appending(path: "\(name).png") as CFURL,
                                              UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(png, bitmap.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(png), "could not write \(name).png")
}
