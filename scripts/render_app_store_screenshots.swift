#!/usr/bin/env swift

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MarketingFrame {
    let input: String
    let output: String
    let title: [String]
    let subtitle: String
}

private let arguments = Array(CommandLine.arguments.dropFirst())
private let root = URL(fileURLWithPath: arguments.first ?? FileManager.default.currentDirectoryPath)
private let isIPad = arguments.dropFirst().first == "ipad"
private let canvasWidth = isIPad ? 2064 : 1320
private let canvasHeight = isIPad ? 2752 : 2868
private let deviceDirectory = isIPad ? "ipad-13" : "iphone-6.9"
private let rawDirectory = root.appendingPathComponent("docs/app-store/screenshots/zh-Hans/\(deviceDirectory)/raw")
private let outputDirectory = root.appendingPathComponent("docs/app-store/screenshots/zh-Hans/\(deviceDirectory)/final")

private let frames: [MarketingFrame] = [
    MarketingFrame(
        input: "01-home.png",
        output: "01-one-holo.png",
        title: ["把散落的生活", "放进同一个 Holo"],
        subtitle: "任务、想法、财务、健康与习惯，一处管理"
    ),
    MarketingFrame(
        input: "02-ai-actions.png",
        output: "02-one-sentence.png",
        title: ["说一句", "三件事都办好"],
        subtitle: "记账、建待办、完成打卡，一次说清"
    ),
    MarketingFrame(
        input: "03-ai-analysis.png",
        output: "03-ask-your-data.png",
        title: ["问自己的数据", "得到真正有用的回答"],
        subtitle: "从记录里看见趋势，而不只是得到一段泛泛回复"
    ),
    MarketingFrame(
        input: "04-memory-calendar.png",
        output: "04-life-calendar.png",
        title: ["用一张日历", "复盘每天发生了什么"],
        subtitle: "账单、习惯、待办和想法，自动汇成生活时间线"
    ),
    MarketingFrame(
        input: "05-finance-stats.png",
        output: "05-see-the-change.png",
        title: ["看见消费变化", "也看见生活节奏"],
        subtitle: "用清晰的统计，把零散记录变成可理解的趋势"
    ),
    MarketingFrame(
        input: "06-memory-insight.png",
        output: "06-long-term-change.png",
        title: ["把今天的记录", "变成长期变化"],
        subtitle: "每周 AI 回放，帮你发现正在形成的习惯与节奏"
    )
]

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        deviceRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

private func font(_ name: String, size: CGFloat, fallbackWeight: NSFont.Weight) -> NSFont {
    NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: fallbackWeight)
}

private func drawText(
    _ text: String,
    at point: NSPoint,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .left
) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = .byClipping
    text.draw(
        at: point,
        withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
    )
}

private func drawBackground(in rect: NSRect, accent: NSColor) {
    let gradient = NSGradient(
        starting: color(0xFFF9F2),
        ending: color(0xF3F6FB)
    )!
    gradient.draw(in: rect, angle: -90)

    accent.withAlphaComponent(0.09).setFill()
    let leftCircle = isIPad
        ? NSRect(x: -180, y: 2050, width: 900, height: 900)
        : NSRect(x: -170, y: 2140, width: 700, height: 700)
    NSBezierPath(ovalIn: leftCircle).fill()
    color(0x6699FF, alpha: 0.055).setFill()
    let rightCircle = isIPad
        ? NSRect(x: 1450, y: 2250, width: 680, height: 680)
        : NSRect(x: 850, y: 2280, width: 520, height: 520)
    NSBezierPath(ovalIn: rightCircle).fill()
}

private func drawBrand(index: Int, accent: NSColor) {
    let leading: CGFloat = isIPad ? 150 : 110
    let topLine: CGFloat = isIPad ? 2670 : 2787
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: leading, y: topLine, width: isIPad ? 22 : 18, height: isIPad ? 22 : 18)).fill()
    drawText(
        "HOLO AI",
        at: NSPoint(x: leading + (isIPad ? 44 : 35), y: topLine - 9),
        font: font("PingFangSC-Semibold", size: isIPad ? 34 : 28, fallbackWeight: .semibold),
        color: color(0x596273)
    )
    drawText(
        String(format: "%02d", index + 1),
        at: NSPoint(x: isIPad ? 1830 : 1145, y: topLine - 9),
        font: font("SFProDisplay-Semibold", size: isIPad ? 34 : 28, fallbackWeight: .semibold),
        color: color(0x98A0AE)
    )
}

private func drawHeader(_ frame: MarketingFrame) {
    let headlineFont = font("PingFangSC-Semibold", size: isIPad ? 86 : 78, fallbackWeight: .bold)
    let headlineColor = color(0x172033)
    let firstBaseline: CGFloat = isIPad ? 2490 : 2648
    let lineStep: CGFloat = isIPad ? 112 : 102
    for (lineIndex, line) in frame.title.enumerated() {
        drawText(
            line,
            at: NSPoint(x: isIPad ? 150 : 110, y: firstBaseline - CGFloat(lineIndex) * lineStep),
            font: headlineFont,
            color: headlineColor
        )
    }

    drawText(
        frame.subtitle,
        at: NSPoint(x: isIPad ? 152 : 112, y: isIPad ? 2245 : 2435),
        font: font("PingFangSC-Regular", size: isIPad ? 36 : 31, fallbackWeight: .regular),
        color: color(0x687284)
    )
}

private func drawScreenshot(_ image: NSImage) {
    let screenRect = isIPad
        ? NSRect(x: 245, y: 55, width: 1574, height: 2099)
        : NSRect(x: 132, y: 65, width: 1056, height: 2294)
    let rounded = NSBezierPath(
        roundedRect: screenRect,
        xRadius: isIPad ? 58 : 72,
        yRadius: isIPad ? 58 : 72
    )

    let wideShadowRect = screenRect.insetBy(dx: -18, dy: -18).offsetBy(dx: 0, dy: -12)
    color(0x19243A, alpha: 0.035).setFill()
    NSBezierPath(
        roundedRect: wideShadowRect,
        xRadius: isIPad ? 72 : 88,
        yRadius: isIPad ? 72 : 88
    ).fill()

    let nearShadowRect = screenRect.insetBy(dx: -7, dy: -7).offsetBy(dx: 0, dy: -7)
    color(0x19243A, alpha: 0.07).setFill()
    NSBezierPath(
        roundedRect: nearShadowRect,
        xRadius: isIPad ? 64 : 79,
        yRadius: isIPad ? 64 : 79
    ).fill()

    color(0xFFFFFF).setFill()
    rounded.fill()

    NSGraphicsContext.saveGraphicsState()
    rounded.addClip()
    image.draw(
        in: screenRect,
        from: NSRect(origin: .zero, size: image.size),
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    color(0xFFFFFF, alpha: 0.7).setStroke()
    rounded.lineWidth = 2
    rounded.stroke()
}

private func render(_ frame: MarketingFrame, index: Int) throws {
    let inputURL = rawDirectory.appendingPathComponent(frame.input)
    let outputURL = outputDirectory.appendingPathComponent(frame.output)
    guard let source = NSImage(contentsOf: inputURL) else {
        throw NSError(domain: "HoloScreenshotRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取 \(inputURL.path)"])
    }

    guard let cgContext = CGContext(
        data: nil,
        width: canvasWidth,
        height: canvasHeight,
        bitsPerComponent: 8,
        bytesPerRow: canvasWidth * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "HoloScreenshotRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建画布"])
    }
    cgContext.setFillColor(color(0xFFF9F2).cgColor)
    cgContext.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

    let previousContext = NSGraphicsContext.current
    let drawingContext = NSGraphicsContext(cgContext: cgContext, flipped: false)
    NSGraphicsContext.current = drawingContext
    NSGraphicsContext.saveGraphicsState()
    let canvas = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
    let accent = color(0xFF6B48)
    drawBackground(in: canvas, accent: accent)
    drawHeader(frame)
    drawBrand(index: index, accent: accent)
    drawScreenshot(source)
    drawingContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.current = previousContext

    guard let renderedImage = cgContext.makeImage(),
          let flattenedContext = CGContext(
              data: nil,
              width: canvasWidth,
              height: canvasHeight,
              bitsPerComponent: 8,
              bytesPerRow: canvasWidth * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else {
        throw NSError(domain: "HoloScreenshotRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法压平画布"])
    }
    flattenedContext.setFillColor(NSColor.white.cgColor)
    flattenedContext.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
    flattenedContext.draw(renderedImage, in: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

    guard let image = flattenedContext.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              outputURL as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        throw NSError(domain: "HoloScreenshotRenderer", code: 4, userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "HoloScreenshotRenderer", code: 5, userInfo: [NSLocalizedDescriptionKey: "PNG 写入失败"])
    }
}

_ = NSApplication.shared
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for (index, frame) in frames.enumerated() {
    let inputURL = rawDirectory.appendingPathComponent(frame.input)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
        print("Skipped \(frame.input): raw screenshot missing")
        continue
    }
    try render(frame, index: index)
    print("Rendered \(frame.output)")
}
