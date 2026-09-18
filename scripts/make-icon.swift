// 生成 1024x1024 应用图标源图：蓝紫渐变 squircle + 双窗口叠加，前窗一条高亮内容行表示「选中窗口」。
// 用法: swift scripts/make-icon.swift <输出.png>
import AppKit

func drawIcon(_ cg: CGContext, size: CGFloat) {
    // MARK: 背景 squircle（macOS 图标规范：内容区 824/1024，圆角约 186）
    let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 186, cornerHeight: 186, transform: nil)
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedRed: 0.31, green: 0.49, blue: 1.00, alpha: 1).cgColor, // #4F7CFF
            NSColor(calibratedRed: 0.43, green: 0.30, blue: 0.96, alpha: 1).cgColor, // #6D4DF5
        ] as CFArray,
        locations: [0, 1]
    )!

    cg.saveGState()
    cg.addPath(bgPath)
    cg.clip()
    cg.drawLinearGradient(gradient, start: CGPoint(x: 180, y: 920), end: CGPoint(x: 850, y: 110), options: [])
    cg.restoreGState()

    // MARK: 双窗口：后窗为半透明剪影，前窗为白底带阴影
    let backWindow = CGRect(x: 322, y: 432, width: 520, height: 400)
    drawWindowBody(cg, rect: backWindow, alpha: 0.30, hasShadow: false)

    let frontWindow = CGRect(x: 222, y: 282, width: 520, height: 400)
    drawWindowBody(cg, rect: frontWindow, alpha: 0.95, hasShadow: true)
    drawTrafficLights(cg, in: frontWindow)
    drawContentBars(cg, in: frontWindow)
}

func drawWindowBody(_ cg: CGContext, rect: CGRect, alpha: CGFloat, hasShadow: Bool) {
    let path = CGPath(roundedRect: rect, cornerWidth: 24, cornerHeight: 24, transform: nil)

    cg.saveGState()
    if hasShadow {
        cg.setShadow(offset: CGSize(width: 0, height: -16), blur: 40,
                     color: NSColor.black.withAlphaComponent(0.28).cgColor)
    }
    cg.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
    cg.addPath(path)
    cg.fillPath()
    cg.restoreGState()

    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
    cg.setLineWidth(3)
    cg.addPath(path)
    cg.strokePath()
}

func drawTrafficLights(_ cg: CGContext, in window: CGRect) {
    let colors: [NSColor] = [
        NSColor(calibratedRed: 1.00, green: 0.37, blue: 0.34, alpha: 1), // #FF5F57
        NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.18, alpha: 1), // #FEBC2E
        NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.25, alpha: 1), // #28C840
    ]
    let y = window.maxY - 52
    for (index, color) in colors.enumerated() {
        let dot = CGRect(x: window.minX + 34 + CGFloat(index) * 30, y: y, width: 16, height: 16)
        cg.setFillColor(color.cgColor)
        cg.fillEllipse(in: dot)
    }
}

func drawContentBars(_ cg: CGContext, in window: CGRect) {
    let barWidth = window.width - 72
    let bars: [(rect: CGRect, color: NSColor)] = [
        // 第一条为选中高亮（accent 蓝），其余为灰
        (CGRect(x: window.minX + 36, y: 470, width: barWidth, height: 40),
         NSColor(calibratedRed: 0.29, green: 0.42, blue: 0.94, alpha: 1)), // #4A6BF0
        (CGRect(x: window.minX + 36, y: 400, width: barWidth, height: 40),
         NSColor(calibratedWhite: 0.82, alpha: 1)),
        (CGRect(x: window.minX + 36, y: 330, width: barWidth * 0.62, height: 40),
         NSColor(calibratedWhite: 0.88, alpha: 1)),
    ]

    for bar in bars {
        let path = CGPath(roundedRect: bar.rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        cg.setFillColor(bar.color.cgColor)
        cg.addPath(path)
        cg.fillPath()
    }
}

// MARK: - main

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("用法: swift scripts/make-icon.swift <输出.png>\n".data(using: .utf8)!)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CGFloat(1024)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("无法创建位图") }
rep.size = NSSize(width: size, height: size)

guard let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("无法创建绘图上下文") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
drawIcon(context.cgContext, size: size)
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 编码失败") }
try data.write(to: outputURL)
print("✓ 图标源图已生成: \(outputURL.path)")
