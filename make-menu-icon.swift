import AppKit

let source = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: "Resources/logo-source.png")))!
let pixels = source.pixelsWide
let cropX = 0.19, cropY = 0.172, cropSize = 0.62

func render(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let samples = 6
    for y in 0..<size {
        for x in 0..<size {
            var covered = 0
            for sy in 0..<samples {
                for sx in 0..<samples {
                    let u = cropX + cropSize * (Double(x) + (Double(sx) + 0.5) / Double(samples)) / Double(size)
                    let v = cropY + cropSize * (Double(y) + (Double(sy) + 0.5) / Double(samples)) / Double(size)
                    guard let color = source.colorAt(x: Int(u * Double(pixels)), y: Int(v * Double(pixels)))?
                        .usingColorSpace(.deviceRGB) else { continue }
                    let isInk = color.alphaComponent > 0.5
                        && min(color.redComponent, color.greenComponent, color.blueComponent) < 0.9
                    if isInk { covered += 1 }
                }
            }
            let alpha = CGFloat(covered) / CGFloat(samples * samples)
            bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: alpha), atX: x, y: y)
        }
    }
    return bitmap.representation(using: .png, properties: [:])!
}

try render(18).write(to: URL(fileURLWithPath: "Resources/MenuIcon.png"))
try render(36).write(to: URL(fileURLWithPath: "Resources/MenuIcon@2x.png"))
