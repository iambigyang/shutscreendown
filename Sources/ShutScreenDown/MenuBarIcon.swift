import AppKit

/// 菜单栏图标：monitor.svg 转绘（与 make_icon.swift 的 monitorPaths 同几何）。
/// 关 = 显示器 + 熄灭区 + 斜杠；开 = 显示器本体。
/// 模板图像（黑色绘制 + isTemplate），自动适配浅/深色菜单栏。
enum MenuBarIcon {

    /// 生成 18pt 图标（含 1x/2x 两个位图表示，Retina 清晰）。
    static func image(off: Bool) -> NSImage? {
        let img = NSImage()
        img.isTemplate = true
        for px in [18, 36] {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: px, height: px)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(pixel: CGFloat(px), off: off)
            NSGraphicsContext.restoreGraphicsState()
            img.addRepresentation(rep)
        }
        img.size = NSSize(width: 18, height: 18)
        return img
    }

    /// 在 px×px 画布上居中绘制（48 单位设计空间，含线宽出血包围盒 42x40，中心 24,24）。
    private static func draw(pixel: CGFloat, off: Bool) {
        let scale = min(pixel / 42.0, pixel / 40.0)
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: pixel / 2 - 24 * scale, yBy: pixel / 2 - 24 * scale)
        t.scale(by: scale)
        t.concat()
        NSColor.black.setStroke()
        NSColor.black.setFill()
        for (p, isFill) in paths(off: off) {
            if isFill { p.fill() } else { p.stroke() }
        }
        ctx.restoreGraphicsState()
    }

    /// monitor.svg 的路径（坐标系已翻转：SVG y 向下 → AppKit y 向上）。
    private static func paths(off: Bool) -> [(path: NSBezierPath, isFill: Bool)] {
        func strokePath(_ build: (NSBezierPath) -> Void) -> NSBezierPath {
            let p = NSBezierPath()
            p.lineWidth = 4
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            build(p)
            return p
        }

        var paths: [(NSBezierPath, Bool)] = []
        // 显示器外框
        paths.append((strokePath { $0.appendRoundedRect(NSRect(x: 5, y: 14, width: 38, height: 28),
                                                        xRadius: 1.104, yRadius: 1.104) }, false))
        // 底座
        paths.append((strokePath { p in
            p.move(to: NSPoint(x: 17, y: 14))
            p.line(to: NSPoint(x: 14, y: 6))
            p.line(to: NSPoint(x: 34, y: 6))
            p.line(to: NSPoint(x: 31, y: 14))
        }, false))
        // 电源小圆点（填充）
        paths.append((NSBezierPath(ovalIn: NSRect(x: 22, y: 17, width: 4, height: 4)), true))
        if off {
            // 熄灭区描边 + 两条斜杠（关屏标记）
            paths.append((strokePath { $0.appendRoundedRect(NSRect(x: 5, y: 14, width: 38, height: 10),
                                                            xRadius: 2, yRadius: 2) }, false))
            paths.append((strokePath { p in
                p.move(to: NSPoint(x: 22, y: 36)); p.line(to: NSPoint(x: 18, y: 31))
            }, false))
            paths.append((strokePath { p in
                p.move(to: NSPoint(x: 28, y: 34)); p.line(to: NSPoint(x: 25, y: 30))
            }, false))
        }
        return paths
    }
}
