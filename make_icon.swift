import AppKit
import Foundation

// 程序化生成两套 macOS 应用图标（.iconset）。
// 设计：squircle（圆角方块）渐变背景 + 居中白色图案。
//   主程序（ShutScreenDown） —— 蓝紫渐变 + monitor.svg 转绘（显示器关屏）
//   恢复内置屏（RecoveryScreen） —— 绿色渐变 + SF Symbol laptopcomputer（屏幕恢复）

func tintedSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    let size = base.size
    let out = NSImage(size: size)
    out.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: size))
    color.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

// MARK: - monitor.svg 转绘（矢量转矢量，任意尺寸锐利）
// 原图 viewBox 48x48、线条 4 宽。坐标系已翻转（SVG y 向下 → AppKit y 向上）。

/// 每个路径附带「是否填充」标记：true 填充，false 描边。
func monitorPaths() -> [(path: NSBezierPath, isFill: Bool)] {
    func strokePath(_ build: (NSBezierPath) -> Void) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = 4
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        build(p)
        return p
    }

    var paths: [(path: NSBezierPath, isFill: Bool)] = []

    // 显示器外框：圆角矩形 x5-43, y6-34（翻转后 y14-42），圆角 1.104
    paths.append((strokePath { $0.appendRoundedRect(NSRect(x: 5, y: 14, width: 38, height: 28),
                                                    xRadius: 1.104, yRadius: 1.104) }, false))
    // 屏幕下部「熄灭区」描边：圆角矩形 x5-43, y24-34（翻转后 y14-24），圆角 2
    paths.append((strokePath { $0.appendRoundedRect(NSRect(x: 5, y: 14, width: 38, height: 10),
                                                    xRadius: 2, yRadius: 2) }, false))
    // 两条短斜杠（关闭标记）
    paths.append((strokePath { p in p.move(to: NSPoint(x: 22, y: 36)); p.line(to: NSPoint(x: 18, y: 31)) }, false))
    paths.append((strokePath { p in p.move(to: NSPoint(x: 28, y: 34)); p.line(to: NSPoint(x: 25, y: 30)) }, false))
    // 电源小圆点（填充）
    paths.append((NSBezierPath(ovalIn: NSRect(x: 22, y: 17, width: 4, height: 4)), true))
    // 底座
    paths.append((strokePath { p in
        p.move(to: NSPoint(x: 17, y: 14))
        p.line(to: NSPoint(x: 14, y: 6))
        p.line(to: NSPoint(x: 34, y: 6))
        p.line(to: NSPoint(x: 31, y: 14))
    }, false))
    return paths
}

/// 在 rect 内居中绘制 monitor 图案（白色）。
func drawMonitorArt(in rect: NSRect) {
    let paths = monitorPaths()
    // 渲染后的真实包围盒（含线宽一半的出血）：x 3..45、y 4..44，即 42x40，
    // 其中心正是设计原点 (24, 24) —— 以该中心为锚点缩放平移，才能保证视觉居中。
    let scale = min(rect.width / 42.0, rect.height / 40.0)
    let t = NSAffineTransform()
    t.translateX(by: rect.midX - 24 * scale, yBy: rect.midY - 24 * scale)
    t.scale(by: scale)

    NSGraphicsContext.saveGraphicsState()
    t.concat()
    NSColor.white.setStroke()
    NSColor.white.setFill()
    for (p, isFill) in paths {
        if isFill { p.fill() } else { p.stroke() }
    }
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - 图标渲染

enum IconArt {
    case symbol(String)
    case monitorCustom
}

func drawIcon(pixel: Int, art: IconArt, top: NSColor, bottom: NSColor) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixel, height: pixel)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let p = CGFloat(pixel)
    let inset = p * 0.085                                   // 四周留白（macOS 图标规范）
    let rect = NSRect(x: inset, y: inset, width: p - 2*inset, height: p - 2*inset)
    let radius = rect.width * 0.2237                        // squircle 圆角近似
    let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    clip.addClip()

    if let grad = NSGradient(starting: top, ending: bottom) {
        grad.draw(in: rect, angle: -90)                    // top 在上、bottom 在下
    }
    // 顶部一层很淡的高光，增加质感
    NSColor(white: 1, alpha: 0.10).setFill()
    NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.midY,
                                     width: rect.width, height: rect.height/2),
                 xRadius: radius, yRadius: radius).fill()

    switch art {
    case .symbol(let name):
        if let sym = tintedSymbol(name, pointSize: p * 0.40, color: .white) {
            let s = sym.size
            let r = NSRect(x: (p - s.width)/2, y: (p - s.height)/2, width: s.width, height: s.height)
            sym.draw(in: r)
        }
    case .monitorCustom:
        let side = p * 0.46
        let r = NSRect(x: (p - side)/2, y: (p - side)/2, width: side, height: side)
        drawMonitorArt(in: r)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

struct IconSpec { let dir: String; let art: IconArt; let top: NSColor; let bottom: NSColor }

let specs = [
    IconSpec(dir: "AppIcon.iconset", art: .monitorCustom,
             top: NSColor(srgbRed: 0.40, green: 0.45, blue: 0.98, alpha: 1),
             bottom: NSColor(srgbRed: 0.16, green: 0.14, blue: 0.45, alpha: 1)),
    IconSpec(dir: "RestoreIcon.iconset", art: .symbol("laptopcomputer"),
             top: NSColor(srgbRed: 0.26, green: 0.84, blue: 0.40, alpha: 1),
             bottom: NSColor(srgbRed: 0.06, green: 0.46, blue: 0.20, alpha: 1)),
]

let root = (CommandLine.arguments.count > 1) ? CommandLine.arguments[1]
                                             : FileManager.default.currentDirectoryPath
for spec in specs {
    let dir = "\(root)/\(spec.dir)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, px) in sizes {
        if let data = drawIcon(pixel: px, art: spec.art, top: spec.top, bottom: spec.bottom) {
            try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        }
    }
    print("generated \(dir)")
}
