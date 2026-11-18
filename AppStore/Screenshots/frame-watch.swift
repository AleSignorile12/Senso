// frame-watch.swift
// Puts each page of the Watch design PDF, untouched, in a drawn Apple Watch frame. Every page becomes a
// one-page PDF in Watch-PDF/ and, because App Store Connect accepts only PNG or JPEG, an opaque
// 422 × 514 PNG in Watch/.
//
// Usage: swift frame-watch.swift <WATCH.pdf> <AppStore/Screenshots folder>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let page = CGSize(width: 844, height: 1028)
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

func draw(_ screen: CGPDFPage, in context: CGContext) {
    context.interpolationQuality = .high
    context.setFillColor(color(0xD9F1FD))   // The app's Sky Mist.
    context.fill(CGRect(origin: .zero, size: page))

    let source = screen.getBoxRect(.mediaBox)
    let height: CGFloat = 700
    let width = height * source.width / source.height
    let display = CGRect(x: (page.width - width) / 2 - 10, y: (page.height - height) / 2, width: width, height: height)
    let bezel = display.insetBy(dx: -22, dy: -22)
    let body = bezel.insetBy(dx: -14, dy: -14)

    fill(context, CGRect(x: body.midX - 250, y: 0, width: 500, height: page.height), radius: 0, 0x1C1E22)   // Band.

    let crown = CGRect(x: body.maxX - 3, y: body.midY + 92, width: 30, height: 116)
    fill(context, crown, radius: 10, 0x3A3C42)
    context.setStrokeColor(color(0x24262A))
    context.setLineWidth(3)
    for y in stride(from: crown.minY + 12, to: crown.maxY - 8, by: 13) {
        context.move(to: CGPoint(x: crown.minX + 6, y: y))
        context.addLine(to: CGPoint(x: crown.maxX - 3, y: y))
    }
    context.strokePath()
    fill(context, CGRect(x: body.maxX - 3, y: body.midY - 215, width: 15, height: 170), radius: 6, 0x34363B)

    fill(context, body, radius: 184, 0x4A4D54)
    fill(context, body.insetBy(dx: 3, dy: 3), radius: 181, 0x2A2C31)
    fill(context, bezel, radius: 170, 0x000000)

    context.saveGState()
    // Matches the corners of the design's blue shapes, so no white shows around them.
    context.addPath(CGPath(roundedRect: display, cornerWidth: 148, cornerHeight: 148, transform: nil))
    context.clip()
    context.setFillColor(color(0xFFFFFF))
    context.fill(display)
    context.translateBy(x: display.minX, y: display.minY)
    context.scaleBy(x: display.width / source.width, y: display.height / source.height)
    context.translateBy(x: -source.minX, y: -source.minY)
    context.drawPDFPage(screen)
    context.restoreGState()
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("usage: frame-watch.swift <WATCH.pdf> <Screenshots folder>") }
let design = CGPDFDocument(URL(fileURLWithPath: arguments[1]) as CFURL)!
let names = ["1-fill-up", "2-52-percent", "3-100-percent"]
precondition(design.numberOfPages == names.count, "expected one page per screen")
let output = URL(fileURLWithPath: arguments[2])
let pngFolder = output.appending(path: "Watch"), pdfFolder = output.appending(path: "Watch-PDF")
try FileManager.default.createDirectory(at: pngFolder, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: pdfFolder, withIntermediateDirectories: true)

for (index, name) in names.enumerated() {
    let screen = design.page(at: index + 1)!

    var box = CGRect(origin: .zero, size: page)
    let pdf = CGContext(pdfFolder.appending(path: "\(name).pdf") as CFURL, mediaBox: &box, nil)!
    pdf.beginPDFPage(nil)
    draw(screen, in: pdf)
    pdf.endPDFPage()
    pdf.closePDF()

    let bitmap = CGContext(data: nil, width: 422, height: 514, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    bitmap.scaleBy(x: 0.5, y: 0.5)
    draw(screen, in: bitmap)
    let png = CGImageDestinationCreateWithURL(pngFolder.appending(path: "\(name).png") as CFURL,
                                              UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(png, bitmap.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(png), "could not write \(name).png")
}
