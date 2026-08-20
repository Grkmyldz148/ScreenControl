import AppKit

// Basit ama düzgün bir uygulama ikonu üretir: koyu zemin üzerine güneş sembolü.
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data? {
    let dimension = CGFloat(size)
    // lockFocus yerine doğrudan bitmap context: ekran ölçeğinden bağımsız,
    // tam olarak istediğimiz piksel boyutunu verir.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let inset = dimension * 0.06
    let rect = NSRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: dimension * 0.225, yRadius: dimension * 0.225)

    NSGradient(colors: [
        NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.21, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 1),
    ])?.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: dimension * 0.54, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config),
       let context = NSGraphicsContext.current?.cgContext {
        let target = NSRect(
            x: (dimension - symbol.size.width) / 2,
            y: (dimension - symbol.size.height) / 2,
            width: symbol.size.width, height: symbol.size.height
        )
        // Sembolü ayrı bir şeffaflık katmanına çizip gradyanı sadece onun
        // alfası üzerine uyguluyoruz; yoksa gradyan bütün kareyi boyar.
        context.beginTransparencyLayer(in: target, auxiliaryInfo: nil)
        symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        context.setBlendMode(.sourceAtop)
        NSGradient(colors: [
            NSColor(calibratedRed: 1.00, green: 0.86, blue: 0.36, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.14, alpha: 1),
        ])?.draw(in: target, angle: -90)
        context.setBlendMode(.normal)
        context.endTransparencyLayer()
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = render(size) else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(size)x\(size).png"))
    if size <= 512, let retina = render(size * 2) {
        try? retina.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(size)x\(size)@2x.png"))
    }
}
print("iconset yazildi")
