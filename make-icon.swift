import AppKit

let source = NSImage(contentsOfFile: "Resources/logo-source.png")!
let rep = source.representations[0]
let pixels = CGFloat(rep.pixelsWide)
let crop = NSRect(x: pixels * 0.17, y: pixels * 0.17, width: pixels * 0.66, height: pixels * 0.66)
let cropInPoints = NSRect(x: crop.minX * source.size.width / pixels, y: crop.minY * source.size.height / pixels,
                          width: crop.width * source.size.width / pixels, height: crop.height * source.size.height / pixels)

func render(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.imageInterpolation = .high
    let s = CGFloat(size)
    let plate = NSRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8046, height: s * 0.8046)
    let path = NSBezierPath(roundedRect: plate, xRadius: s * 0.18, yRadius: s * 0.18)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSShadow().set()
    path.addClip()
    source.draw(in: plate.insetBy(dx: s * 0.14, dy: s * 0.14), from: cropInPoints, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let dir = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
}

func renderMark(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: cropInPoints, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

try renderMark(20).write(to: URL(fileURLWithPath: "Resources/TitleMark.png"))
try renderMark(40).write(to: URL(fileURLWithPath: "Resources/TitleMark@2x.png"))
