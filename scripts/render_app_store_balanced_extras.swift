import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let base = root.appendingPathComponent("docs/app-store/screenshots/zh-Hans/v8-balanced")
let raw = base.appendingPathComponent("raw/iphone-medium")
let output = base.appendingPathComponent("upload/iphone-medium/default")
let width = 1206
let height = 2622

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    let name = weight == .semibold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
    return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
}

func drawText(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat, canvasHeight: CGFloat, weight: NSFont.Weight = .regular, tint: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font(size, weight),
        .foregroundColor: tint
    ]
    let measured = (value as NSString).size(withAttributes: attributes)
    (value as NSString).draw(at: NSPoint(x: x, y: canvasHeight - top - measured.height), withAttributes: attributes)
}

func rounded(_ rect: CGRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawOrb(x: CGFloat, y: CGFloat, radius: CGFloat) {
    let gradient = NSGradient(starting: color(0xF7D6AB), ending: color(0xD87548))!
    gradient.draw(in: NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), angle: -45)
    let orbit = NSBezierPath(ovalIn: CGRect(x: x - radius * 1.7, y: y - radius * 0.46, width: radius * 3.4, height: radius * 0.92))
    color(0xAE8667, 0.65).setStroke()
    orbit.lineWidth = max(1.3, radius * 0.04)
    orbit.stroke()
}

struct Frame {
    let input: String
    let output: String
    let module: String
    let title: [String]
    let subtitle: String
    let accent: UInt32
    let number: Int
}

let frames = [
    Frame(
        input: "task-stats.png",
        output: "02-task-stats.png",
        module: "任务",
        title: ["让任务进度", "一眼看清"],
        subtitle: "新增、完成与按时率，掌握行动节奏",
        accent: 0xD87548,
        number: 2
    ),
    Frame(
        input: "task-heatmap.png",
        output: "03-task-heatmap.png",
        module: "任务",
        title: ["用热力图", "回看完成节奏"],
        subtitle: "近 12 周活跃记录与完成时段分布",
        accent: 0xD87548,
        number: 3
    ),
    Frame(
        input: "habits.png",
        output: "04-habits.png",
        module: "习惯",
        title: ["每一次坚持", "都看得见"],
        subtitle: "打卡与连续记录，让进步一眼可见",
        accent: 0xD87548,
        number: 4
    ),
    Frame(
        input: "health.png",
        output: "06-health.png",
        module: "健康",
        title: ["每天状态", "清楚看见"],
        subtitle: "睡眠、步数、运动与站立，一页回顾",
        accent: 0x6C92CE,
        number: 6
    )
]

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for frame in frames {
    let inputURL = raw.appendingPathComponent(frame.input)
    guard let shot = NSImage(contentsOf: inputURL) else {
        fatalError("缺少模拟器截图：\(inputURL.path)")
    }

    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(color(0xF7F4EC).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let previous = NSGraphicsContext.current
    let drawing = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.current = drawing
    NSGraphicsContext.saveGraphicsState()

    let left: CGFloat = 105
    let top: CGFloat = 76
    drawOrb(x: left + 20, y: CGFloat(height) - top - 18, radius: 19)
    drawText("Holo", x: left + 66, top: top - 11, size: 40, canvasHeight: CGFloat(height), weight: .semibold, tint: color(0x292925))
    drawText("/  \(frame.module)", x: left + 185, top: top - 2, size: 27, canvasHeight: CGFloat(height), tint: color(0x77766E))
    drawText(String(format: "%02d", frame.number), x: CGFloat(width) - left - 50, top: top, size: 24, canvasHeight: CGFloat(height), tint: color(0x77766E))

    for (line, value) in frame.title.enumerated() {
        drawText(value, x: left, top: 180 + CGFloat(line) * 116, size: 91, canvasHeight: CGFloat(height), weight: .semibold, tint: color(0x292925))
    }
    drawText(frame.subtitle, x: left + 3, top: 432, size: 34, canvasHeight: CGFloat(height), tint: color(0x77766E))
    let accent = NSBezierPath()
    accent.move(to: NSPoint(x: left, y: CGFloat(height) - 523))
    accent.line(to: NSPoint(x: left + 105, y: CGFloat(height) - 523))
    color(frame.accent).setStroke()
    accent.lineWidth = 5
    accent.stroke()

    let screenWidth: CGFloat = 860
    let screenHeight = screenWidth * shot.size.height / shot.size.width
    let available = CGFloat(height) - 658
    let scale = min(1, available / screenHeight)
    let screen = CGRect(x: (CGFloat(width) - screenWidth * scale) / 2, y: 94, width: screenWidth * scale, height: screenHeight * scale)
    let shell = screen.insetBy(dx: -14, dy: -14)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x504B3C, 0.18)
    shadow.shadowBlurRadius = 38
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    rounded(shell, radius: 62, fill: color(0x343430))
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: screen, xRadius: 48, yRadius: 48).addClip()
    shot.draw(in: screen, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    drawText("记录日常 · 慢慢看清", x: left, top: CGFloat(height) - 48, size: 21, canvasHeight: CGFloat(height), tint: color(0x77766E))

    drawing.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.current = previous

    let flattened = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    flattened.setFillColor(NSColor.white.cgColor)
    flattened.fill(CGRect(x: 0, y: 0, width: width, height: height))
    flattened.draw(context.makeImage()!, in: CGRect(x: 0, y: 0, width: width, height: height))

    let outputURL = output.appendingPathComponent(frame.output)
    let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, flattened.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("无法写入截图：\(outputURL.path)")
    }
    print("Rendered \(outputURL.path)")
}
