#!/usr/bin/env swift
import AppKit

// Иконка: оранжевый скруглённый квадрат, белый планшет и стрелка, падающая на его экран.
func renderIcon(size: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size), pixelsHigh: Int(size),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState(); return nil
    }

    let space = CGColorSpaceCreateDeviceRGB()
    let top = NSColor(calibratedRed: 1.00, green: 0.64, blue: 0.22, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.93, green: 0.33, blue: 0.16, alpha: 1)

    // Фон.
    let inset = size * 0.055
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
    ctx.saveGState()
    shape.addClip()
    if let gradient = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    }
    ctx.restoreGState()

    // Корпус планшета (горизонтально).
    let body = CGRect(x: size * 0.17, y: size * 0.20, width: size * 0.66, height: size * 0.47)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: body, xRadius: size * 0.07, yRadius: size * 0.07).fill()

    // Экран — тот же градиент, чуть темнее.
    let screen = body.insetBy(dx: size * 0.045, dy: size * 0.045)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: size * 0.03, yRadius: size * 0.03)
    ctx.saveGState()
    screenPath.addClip()
    let deepTop = NSColor(calibratedRed: 0.96, green: 0.52, blue: 0.18, alpha: 1)
    let deepBottom = NSColor(calibratedRed: 0.85, green: 0.27, blue: 0.13, alpha: 1)
    if let gradient = CGGradient(colorsSpace: space, colors: [deepTop.cgColor, deepBottom.cgColor] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: screen.minX, y: screen.maxY),
                               end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    }
    ctx.restoreGState()

    // Глазок камеры на правой рамке — чтобы читалось как планшет.
    let dot = size * 0.022
    NSColor(calibratedRed: 0.93, green: 0.45, blue: 0.18, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: body.maxX - size * 0.0225 - dot / 2, y: body.midY - dot / 2,
                                width: dot, height: dot)).fill()

    // Стрелка вниз: начинается над планшетом и падает на экран.
    let cx = size * 0.5
    let tipY = screen.minY + screen.height * 0.22
    let headHalf = size * 0.12
    let headBase = tipY + size * 0.13

    let shaft = NSBezierPath()
    shaft.lineWidth = size * 0.085
    shaft.lineCapStyle = .round
    shaft.move(to: CGPoint(x: cx, y: size * 0.83))
    shaft.line(to: CGPoint(x: cx, y: headBase + size * 0.02))

    // Белая обводка цвета фона, чтобы стрелка «прорезала» рамку планшета.
    let halo = shaft.copy() as! NSBezierPath
    halo.lineWidth = size * 0.085 + size * 0.05
    ctx.saveGState()
    shape.addClip()
    NSColor(calibratedRed: 0.98, green: 0.52, blue: 0.20, alpha: 1).setStroke()
    let haloClip = NSBezierPath(rect: CGRect(x: 0, y: body.maxY - size * 0.05, width: size, height: size * 0.1))
    haloClip.addClip()
    halo.stroke()
    ctx.restoreGState()

    NSColor.white.setStroke()
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: CGPoint(x: cx, y: tipY))
    head.line(to: CGPoint(x: cx - headHalf, y: headBase))
    head.line(to: CGPoint(x: cx + headHalf, y: headBase))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = size * 0.02
    NSColor.white.setFill()
    head.fill()
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let data = renderIcon(size: CGFloat(size)) else { continue }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(size)x\(size).png")
    try? data.write(to: url)
}
print("icons → \(outDir)")
