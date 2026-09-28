// Usage: swift scripts/make-app-icon.swift design/app-icon-artwork.png Sources/SiliconCellarApp/Resources/AppIcon.png
// Puts full-bleed square artwork on the macOS 1024 px icon grid (824 px rounded square, drop shadow).
import AppKit

let artworkURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

let canvasSize = 1024
let shapeSize: CGFloat = 824
let cornerRadius: CGFloat = 185.4
let shapeOrigin = (CGFloat(canvasSize) - shapeSize) / 2
let shapeRect = CGRect(x: shapeOrigin, y: shapeOrigin, width: shapeSize, height: shapeSize)

guard let artwork = NSImage(contentsOf: artworkURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Cannot read \(artworkURL.path)")
}
guard
    let context = CGContext(
        data: nil, width: canvasSize, height: canvasSize, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else {
    fatalError("Cannot create bitmap context")
}
context.interpolationQuality = .high
let shapePath = CGPath(roundedRect: shapeRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
context.addPath(shapePath)
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(shapePath)
context.clip()
context.draw(artwork, in: shapeRect)
context.restoreGState()

context.addPath(shapePath)
context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
context.setLineWidth(2)
context.strokePath()

let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: outputURL)
print("Wrote \(outputURL.path)")
