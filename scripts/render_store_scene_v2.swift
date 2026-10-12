import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 商店分场景素材：真实界面作为完整图片嵌入，只排版外层文案与品牌元素。
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let base = root.appendingPathComponent("docs/app-store/screenshots/zh-Hans/v7-ai-finance")
let fm = FileManager.default
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let ink = color(0x292925), orange = color(0xD87548), muted = color(0x77766E)
func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont(name: weight == .semibold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
}
func text(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat, height: CGFloat, weight: NSFont.Weight = .regular, tint: NSColor = ink) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font(size, weight), .foregroundColor: tint]
    let measured = (value as NSString).size(withAttributes: attrs)
    (value as NSString).draw(at: NSPoint(x: x, y: height - top - measured.height), withAttributes: attrs)
}
func round(_ rect: CGRect, radius: CGFloat, fill: NSColor) {
    fill.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func save(_ image: CGImage, to path: URL) throws {
    try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    // 输出不带透明通道的 RGB，符合商店素材要求。
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let dest = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "StoreScene", code: 1) }
}
func canvas(width: Int, height: Int, draw: (CGFloat, CGFloat) throws -> Void) throws -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(color(0xF7F4EC).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let old = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    defer { NSGraphicsContext.current = old }
    try draw(CGFloat(width), CGFloat(height))
    return ctx.makeImage()!
}
func orb(x: CGFloat, y: CGFloat, r: CGFloat) {
    let grad = NSGradient(starting: color(0xF7D6AB), ending: color(0xD87548))!
    grad.draw(in: NSBezierPath(ovalIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2)), angle: -45)
    let ellipse = NSBezierPath(ovalIn: CGRect(x: x-r*1.7, y: y-r*0.46, width: r*3.4, height: r*0.92))
    color(0xAE8667, 0.65).setStroke(); ellipse.lineWidth = max(1.3, r*0.04); ellipse.stroke()
}
struct Frame {
    let key: String
    let module: String
    let title: [String]
    let subtitle: String
    let accent: UInt32
    init(_ key: String, _ module: String, _ title: [String], _ subtitle: String, _ accent: UInt32 = 0xD87548) {
        self.key = key; self.module = module; self.title = title; self.subtitle = subtitle; self.accent = accent
    }
}
let input = Frame("input", "记账", ["记账少费劲", "花钱更清楚"], "输入金额、点选分类，一笔记清")
let ai = Frame("ai-finance", "HoloAI", ["HoloAI 深度分析", "看清花费怎么调整"], "结合账目与备注，给出有依据的建议")
let stats = Frame("stats", "统计", ["钱花在哪", "一眼看清"], "收支趋势与消费构成，回看更直观")
let budget = Frame("budget", "预算", ["预算还剩多少", "随时有数"], "用真实支出，掌握本月预算")
let habit = Frame("habits", "习惯", ["每一次坚持", "都看得见"], "留下记录，看到日常的积累", 0x799178)
let thought = Frame("thoughts", "想法", ["想到什么", "先留下来"], "随手写下，让灵感有处可回", 0x8A8299)
let memory = Frame("memory", "回看", ["平常的一天", "也值得留住"], "让零散日常，成为可以回看的记录", 0x988262)
let home = Frame("home", "Holo", ["你的日常", "在这里连起来"], "记账、习惯与想法，在一个 Holo 里")
let ledger = Frame("ledger", "账本", ["记过的每一笔", "都能找回来"], "日期、金额与分类，清楚留在账本里")
let category = Frame("category", "分类", ["从一笔花费", "看到消费构成"], "按分类回看，理解日常支出的去向")
let variant = Frame("input", "记账", ["记下每笔花费", "看清钱花在哪"], input.subtitle)
let sets: [(String, [Frame])] = [("default", [input, ai, stats, budget, habit, thought, memory, home]), ("finance-cpp", [input, ai, ledger, stats, budget, category]), ("ppo-title-b", [variant, ai, stats, budget, habit, thought, memory, home])]

func render(_ frame: Frame, index: Int, device: String, width: Int, height: Int, set: String) throws {
    // 大尺寸成片使用同一张真实 iPhone 界面，等比排版；不宣称大尺寸原生采集。
    let sourceDevice = device == "iphone-large" ? "iphone-medium" : device
    let path = base.appendingPathComponent("raw/\(sourceDevice)/\(frame.key).png")
    guard let shot = NSImage(contentsOf: path) else { throw NSError(domain: "StoreScene", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少真实截图：\(path.path)"]) }
    let isPad = device == "ipad-13"
    let result = try canvas(width: width, height: height) { w, h in
        let s = w / (isPad ? 2064 : 1206)
        let left: CGFloat = (isPad ? 145 : 105) * s
        let top: CGFloat = 76*s
        orb(x: left+20*s, y: h-top-18*s, r: 19*s)
        text("Holo", x: left+66*s, top: top-11*s, size: 40*s, height: h, weight: .semibold)
        text("/  \(frame.module)", x: left+185*s, top: top-2*s, size: 27*s, height: h, tint: muted)
        text(String(format: "%02d", index+1), x: w-left-50*s, top: top, size: 24*s, height: h, tint: muted)
        let headY: CGFloat = 180*s
        let titleSize: CGFloat = (isPad ? 95 : 91)*s
        for (i, line) in frame.title.enumerated() {
            text(line, x: left, top: headY+CGFloat(i)*116*s, size: titleSize, height: h, weight: .semibold)
        }
        text(frame.subtitle, x: left+3*s, top: headY+252*s, size: (isPad ? 39 : 34)*s, height: h, tint: muted)
        let strip = NSBezierPath(); strip.move(to: NSPoint(x: left, y: h-523*s)); strip.line(to: NSPoint(x: left+105*s, y: h-523*s))
        color(frame.accent).setStroke(); strip.lineWidth = 5*s; strip.stroke()
        let screenWidth = (isPad ? 1534 : 860)*s
        let screenHeight = screenWidth * shot.size.height / shot.size.width
        let available = h-658*s
        let scale = min(1, available / screenHeight)
        let rect = CGRect(x: (w-screenWidth*scale)/2, y: 94*s, width: screenWidth*scale, height: screenHeight*scale)
        let shell = rect.insetBy(dx: -14*s, dy: -14*s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = color(0x504B3C,0.18); shadow.shadowBlurRadius = 38*s; shadow.shadowOffset = NSSize(width: 0, height: -12*s); shadow.set()
        round(shell, radius: 62*s, fill: color(0x343430))
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 48*s, yRadius: 48*s).addClip()
        shot.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        text("记录日常 · 慢慢看清", x: left, top: h-48*s, size: 21*s, height: h, tint: muted)
    }
    try save(result, to: base.appendingPathComponent("upload/\(device)/\(set)/\(String(format: "%02d", index+1))-\(frame.key).png"))
}

let devices: [(String, Int, Int)] = [("iphone-medium", 1206, 2622), ("iphone-large", 1320, 2868), ("ipad-13", 2064, 2752)]
for (device, w, h) in devices {
    let sourceDevice = device == "iphone-large" ? "iphone-medium" : device
    if !fm.fileExists(atPath: base.appendingPathComponent("raw/\(sourceDevice)").path) { continue }
    for (set, frames) in sets {
        for (i, frame) in frames.enumerated() { try render(frame, index: i, device: device, width: w, height: h, set: set) }
    }
}

// 预览拼图只用于快速检查，上传时使用各目录中的独立 PNG。
for (set, frames) in sets {
    let tileWidth = 336, gap = 24
    let width = gap + frames.count * (tileWidth + gap)
    let preview = try canvas(width: width, height: 850) { w, h in
        for (i, frame) in frames.enumerated() {
            let path = base.appendingPathComponent("upload/iphone-medium/\(set)/\(String(format: "%02d", i+1))-\(frame.key).png")
            guard let shot = NSImage(contentsOf: path) else { continue }
            let x = CGFloat(gap + i * (tileWidth + gap))
            text("\(String(format: "%02d", i+1)) · \(frame.module)", x: x, top: 22, size: 22, height: h, tint: muted)
            shot.draw(in: CGRect(x: x, y: 50, width: CGFloat(tileWidth), height: CGFloat(tileWidth) * 2622 / 1206), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    try save(preview, to: base.appendingPathComponent("preview/\(set)-overview.png"))
}
if fm.fileExists(atPath: base.appendingPathComponent("raw/ipad-13").path) {
    for (set, frames) in sets {
        let tileWidth = 336, gap = 24
        let preview = try canvas(width: gap + frames.count * (tileWidth + gap), height: 565) { w, h in
            for (i, frame) in frames.enumerated() {
                let path = base.appendingPathComponent("upload/ipad-13/\(set)/\(String(format: "%02d", i+1))-\(frame.key).png")
                guard let shot = NSImage(contentsOf: path) else { continue }
                let x = CGFloat(gap + i * (tileWidth + gap))
                text("\(String(format: "%02d", i+1)) · \(frame.module)", x: x, top: 22, size: 22, height: h, tint: muted)
                shot.draw(in: CGRect(x: x, y: 40, width: CGFloat(tileWidth), height: 448), from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        try save(preview, to: base.appendingPathComponent("preview/ipad-\(set)-overview.png"))
    }
}

// 创意图与功能截图分开，品牌插画不冒充 App 内界面。
for style in ["brand", "finance"] {
    guard let art = NSImage(contentsOf: base.appendingPathComponent("source/\(style)-orbit.png")) else { continue }
    for (placement, w, h) in [("header",3840,1646),("search",1920,1280)] {
        let result = try canvas(width: w, height: h) { width, height in
            // 搜索图等比铺满；母版的核心元素在中央，裁切只影响两侧留白。
            let scale = placement == "search" ? max(width/art.size.width, height/art.size.height) : min(width/art.size.width, height/art.size.height)
            let rw = art.size.width*scale, rh = art.size.height*scale
            let rect = CGRect(x:(width-rw)/2,y:(height-rh)/2,width:rw,height:rh)
            art.draw(in: rect, from: .zero, operation:.sourceOver, fraction:1)
            if placement == "search" {
                let title = style == "finance" ? "记账少费劲，花钱更清楚" : "记下日常，慢慢看清"
                let size: CGFloat = 58
                let measured = (title as NSString).size(withAttributes: [.font: font(size, .semibold)])
                text(title,x:(width-measured.width)/2,top:45,size:size,height:height,weight:.semibold)
                text("Holo",x:width/2-49,top:height-103,size:44,height:height,weight:.semibold,tint:muted)
            }
        }
        try save(result,to:base.appendingPathComponent("creative/\(style)-\(placement)-\(w)x\(h).png"))
    }
}
print("已导出商店分场景素材：\(base.path)")
