import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let base = root.appendingPathComponent("docs/app-store/screenshots/zh-Hans/v9-holoai")
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

func drawText(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, tint: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font(size, weight),
        .foregroundColor: tint
    ]
    let measured = (value as NSString).size(withAttributes: attributes)
    (value as NSString).draw(at: NSPoint(x: x, y: CGFloat(height) - top - measured.height), withAttributes: attributes)
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
        input: "01-home.png",
        output: "01-home.png",
        module: "生活",
        title: ["五个生活模块", "在一个 Holo 里连起来"],
        subtitle: "记账、任务、习惯、想法与健康，一处记录",
        accent: 0xD87548,
        number: 1
    ),
    Frame(
        input: "02-ai-mixed-actions.png",
        output: "02-ai-mixed-actions.png",
        module: "HoloAI",
        title: ["记账和待办，", "一句话一起安排"],
        subtitle: "从自然表达中整理出消费、提醒和任务",
        accent: 0xD87548,
        number: 2
    ),
    Frame(
        input: "03-task-heatmap.png",
        output: "03-task-heatmap.png",
        module: "任务",
        title: ["看见每周行动", "热力与完成时段"],
        subtitle: "近 12 周热力图与完成时段分布",
        accent: 0xD87548,
        number: 3
    ),
    Frame(
        input: "04-habits.png",
        output: "04-habits.png",
        module: "习惯",
        title: ["每一次坚持", "都看得见"],
        subtitle: "打卡与连续记录，让进步一眼可见",
        accent: 0xD87548,
        number: 4
    ),
    Frame(
        input: "05-thoughts.png",
        output: "05-thoughts.png",
        module: "想法",
        title: ["想到什么", "先留下来"],
        subtitle: "随手写下，让灵感有处可回",
        accent: 0x8F819B,
        number: 5
    ),
    Frame(
        input: "06-health.png",
        output: "06-health.png",
        module: "健康",
        title: ["每天状态", "清楚看见"],
        subtitle: "睡眠、步数、运动与站立，一页回顾",
        accent: 0x6C92CE,
        number: 6
    ),
    Frame(
        input: "07-cross-domain-analysis.png",
        output: "07-cross-domain-analysis.png",
        module: "HoloAI",
        title: ["从多模块记录", "看见生活线索"],
        subtitle: "综合分析近期变化，找到可以调整的地方",
        accent: 0xD87548,
        number: 7
    ),
    Frame(
        input: "08-memory.png",
        output: "08-memory.png",
        module: "回看",
        title: ["平常的一天", "也值得留下"],
        subtitle: "让零散日常，成为可以回看的记录",
        accent: 0xA58F70,
        number: 8
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
    drawText("Holo", x: left + 66, top: top - 11, size: 40, weight: .semibold, tint: color(0x292925))
    drawText("/  \(frame.module)", x: left + 185, top: top - 2, size: 27, tint: color(0x77766E))
    drawText(String(format: "%02d", frame.number), x: CGFloat(width) - left - 50, top: top, size: 24, tint: color(0x77766E))

    for (line, value) in frame.title.enumerated() {
        drawText(value, x: left, top: 180 + CGFloat(line) * 116, size: 86, weight: .semibold, tint: color(0x292925))
    }
    drawText(frame.subtitle, x: left + 3, top: 432, size: 32, tint: color(0x77766E))
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
    drawText("记录日常 · 慢慢看清", x: left, top: CGFloat(height) - 48, size: 21, tint: color(0x77766E))

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
