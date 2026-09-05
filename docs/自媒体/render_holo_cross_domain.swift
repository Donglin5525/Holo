import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvasWidth: CGFloat = 1080
let canvasHeight: CGFloat = 1440

let projectRoot = "/Users/tangyuxuan/Desktop/Claude/HOLO"
let outputDirectory = projectRoot + "/docs/自媒体/Holo小红书第二篇-HoloAI跨域深度分析"
let userAnalysisPath = projectRoot + "/docs/自媒体/Holo小红书第二篇-HoloAI跨域深度分析/source/IMG_5179.PNG"

let background = NSColor(calibratedRed: 1.00, green: 0.973, blue: 0.949, alpha: 1)
let navy = NSColor(calibratedRed: 0.090, green: 0.137, blue: 0.227, alpha: 1)
let slate = NSColor(calibratedRed: 0.360, green: 0.402, blue: 0.478, alpha: 1)
let coral = NSColor(calibratedRed: 1.00, green: 0.365, blue: 0.235, alpha: 1)
let paleCoral = NSColor(calibratedRed: 1.00, green: 0.875, blue: 0.820, alpha: 1)
let green = NSColor(calibratedRed: 0.110, green: 0.710, blue: 0.395, alpha: 1)
let paleGreen = NSColor(calibratedRed: 0.840, green: 0.965, blue: 0.890, alpha: 1)
let blue = NSColor(calibratedRed: 0.190, green: 0.510, blue: 0.955, alpha: 1)
let paleBlue = NSColor(calibratedRed: 0.855, green: 0.925, blue: 1.00, alpha: 1)
let white = NSColor.white
let border = NSColor(calibratedRed: 0.900, green: 0.890, blue: 0.875, alpha: 1)

func topRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
    CGRect(x: x, y: canvasHeight - y - height, width: width, height: height)
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("无法读取图片：\(path)")
    }
    return image
}

func makeContext() -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: Int(canvasWidth),
        height: Int(canvasHeight),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("无法创建画布")
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setFillColor(background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
    return context
}

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawRoundedFill(
    _ context: CGContext,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    radius: CGFloat,
    color: NSColor
) {
    context.addPath(roundedPath(topRect(x: x, y: y, width: width, height: height), radius: radius))
    context.setFillColor(color.cgColor)
    context.fillPath()
}

func drawRoundedStroke(
    _ context: CGContext,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    radius: CGFloat,
    color: NSColor,
    lineWidth: CGFloat = 2
) {
    context.addPath(roundedPath(topRect(x: x, y: y, width: width, height: height), radius: radius))
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(lineWidth)
    context.strokePath()
}

func drawText(
    _ context: CGContext,
    _ text: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = navy,
    alignment: NSTextAlignment = .left,
    lineHeight: CGFloat? = nil
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byCharWrapping
    if let lineHeight {
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
    }
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSString(string: text).draw(
        in: topRect(x: x, y: y, width: width, height: height),
        withAttributes: attributes
    )
    NSGraphicsContext.restoreGraphicsState()
}

func drawCircle(_ context: CGContext, x: CGFloat, y: CGFloat, diameter: CGFloat, color: NSColor) {
    context.setFillColor(color.cgColor)
    context.fillEllipse(in: topRect(x: x, y: y, width: diameter, height: diameter))
}

func drawLine(_ context: CGContext, points: [CGPoint], color: NSColor, width: CGFloat = 4) {
    guard let first = points.first else { return }
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: first.x, y: canvasHeight - first.y))
    for point in points.dropFirst() {
        context.addLine(to: CGPoint(x: point.x, y: canvasHeight - point.y))
    }
    context.strokePath()
}

func drawPill(
    _ context: CGContext,
    _ text: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    color: NSColor,
    textColor: NSColor
) {
    drawRoundedFill(context, x: x, y: y, width: width, height: 48, radius: 24, color: color)
    drawText(context, text, x: x, y: y + 9, width: width, height: 30, size: 21, weight: .semibold, color: textColor, alignment: .center)
}

func drawHeader(_ context: CGContext, page: Int) {
    drawRoundedFill(context, x: 72, y: 54, width: 194, height: 42, radius: 21, color: navy)
    drawText(context, "一次真实复盘", x: 72, y: 62, width: 194, height: 28, size: 19, weight: .semibold, color: white, alignment: .center)
    drawText(context, "\(page)/6", x: 900, y: 58, width: 108, height: 34, size: 23, weight: .bold, color: slate, alignment: .right)
}

func drawShadowedCard(
    _ context: CGContext,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    radius: CGFloat,
    color: NSColor = white
) {
    let rect = topRect(x: x, y: y, width: width, height: height)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.10).cgColor)
    context.addPath(roundedPath(rect, radius: radius))
    context.setFillColor(color.cgColor)
    context.fillPath()
    context.restoreGState()
}

func drawImageAspectFill(
    _ context: CGContext,
    image: CGImage,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    radius: CGFloat,
    focusY: CGFloat
) {
    let frame = topRect(x: x, y: y, width: width, height: height)
    let imageWidth = CGFloat(image.width)
    let imageHeight = CGFloat(image.height)
    let scale = max(width / imageWidth, height / imageHeight)
    let drawWidth = imageWidth * scale
    let drawHeight = imageHeight * scale
    let overflowX = max(0, drawWidth - width)
    let overflowY = max(0, drawHeight - height)
    let drawX = x - overflowX / 2
    let drawY = y - overflowY * min(max(focusY, 0), 1)
    let destination = topRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight)

    context.saveGState()
    context.addPath(roundedPath(frame, radius: radius))
    context.clip()
    context.draw(image, in: destination)
    context.restoreGState()
    drawRoundedStroke(context, x: x, y: y, width: width, height: height, radius: radius, color: border, lineWidth: 2)
}

func drawFactCard(
    _ context: CGContext,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    title: String,
    body: String,
    symbol: String,
    color: NSColor,
    paleColor: NSColor
) {
    drawShadowedCard(context, x: x, y: y, width: width, height: height, radius: 30)
    drawCircle(context, x: x + 28, y: y + 34, diameter: 72, color: paleColor)
    drawText(context, symbol, x: x + 28, y: y + 49, width: 72, height: 40, size: 27, weight: .black, color: color, alignment: .center)
    drawText(context, title, x: x + 132, y: y + 32, width: width - 160, height: 42, size: 29, weight: .bold, color: navy)
    drawText(context, body, x: x + 132, y: y + 92, width: width - 168, height: 40, size: 26, weight: .semibold, color: color)
}

func slide1(_ context: CGContext) {
    drawHeader(context, page: 1)
    drawText(context, "一个里程碑的", x: 72, y: 148, width: 920, height: 86, size: 72, weight: .black)
    drawRoundedFill(context, x: 66, y: 256, width: 590, height: 98, radius: 18, color: paleCoral)
    drawText(context, "八月", x: 84, y: 248, width: 540, height: 106, size: 84, weight: .black, color: coral)
    drawText(context, "我以为这个月只发生了一件大事", x: 76, y: 400, width: 900, height: 50, size: 34, weight: .semibold, color: slate)

    drawShadowedCard(context, x: 72, y: 522, width: 936, height: 470, radius: 38)
    drawPill(context, "截图里的真实记录", x: 112, y: 566, width: 248, color: paleCoral, textColor: coral)
    drawText(context, "Holo 过审", x: 126, y: 678, width: 360, height: 64, size: 48, weight: .bold, color: navy)
    drawText(context, "记账也到了 500 笔", x: 126, y: 756, width: 590, height: 52, size: 35, weight: .semibold, color: slate)
    drawRoundedFill(context, x: 758, y: 668, width: 178, height: 150, radius: 30, color: navy)
    drawText(context, "+17%", x: 758, y: 698, width: 178, height: 56, size: 43, weight: .black, color: white, alignment: .center)
    drawText(context, "支出较上月", x: 758, y: 768, width: 178, height: 30, size: 21, weight: .medium, color: paleCoral, alignment: .center)
    drawText(context, "项目、消费、习惯和想法，被放回同一个月里", x: 126, y: 892, width: 808, height: 42, size: 28, weight: .semibold, color: coral)

    drawRoundedFill(context, x: 104, y: 1084, width: 872, height: 176, radius: 32, color: navy)
    drawText(context, "不是功能清单", x: 150, y: 1122, width: 360, height: 48, size: 35, weight: .bold, color: white)
    drawText(context, "是一次把生活放回时间里的复盘", x: 150, y: 1184, width: 780, height: 44, size: 30, weight: .semibold, color: paleCoral)
    drawText(context, "真实界面 · 用户截图", x: 72, y: 1332, width: 300, height: 30, size: 21, weight: .medium, color: slate)
}

func slide2(_ context: CGContext) {
    drawHeader(context, page: 2)
    drawText(context, "我原本只记得，", x: 72, y: 144, width: 900, height: 84, size: 69, weight: .black)
    drawText(context, "项目做成了", x: 72, y: 234, width: 900, height: 92, size: 76, weight: .black, color: coral)
    drawText(context, "但一个月不会只剩这一件事", x: 76, y: 358, width: 900, height: 44, size: 32, weight: .semibold, color: slate)

    drawFactCard(context, x: 72, y: 470, width: 936, height: 164, title: "项目", body: "Holo 过审", symbol: "✓", color: coral, paleColor: paleCoral)
    drawFactCard(context, x: 72, y: 662, width: 936, height: 164, title: "记录", body: "记账到了 500 笔", symbol: "500", color: blue, paleColor: paleBlue)
    drawFactCard(context, x: 72, y: 854, width: 936, height: 164, title: "消费", body: "支出 2.8 万，比上月多约 17%", symbol: "¥", color: coral, paleColor: paleCoral)

    drawRoundedFill(context, x: 104, y: 1092, width: 872, height: 190, radius: 32, color: navy)
    drawText(context, "这些不是三份报告", x: 150, y: 1128, width: 700, height: 46, size: 35, weight: .bold, color: white)
    drawText(context, "它们发生在同一个八月", x: 150, y: 1190, width: 700, height: 48, size: 34, weight: .semibold, color: paleCoral)
    drawText(context, "再往下看，变化还在继续", x: 104, y: 1332, width: 872, height: 30, size: 22, weight: .medium, color: slate, alignment: .center)
}

func slide3(_ context: CGContext, analysisImage: CGImage) {
    drawHeader(context, page: 3)
    drawText(context, "这是 HoloAI 的", x: 72, y: 138, width: 900, height: 82, size: 64, weight: .black)
    drawText(context, "月度深度分析", x: 72, y: 228, width: 900, height: 92, size: 74, weight: .black, color: coral)
    drawText(context, "我没有改界面，直接放上真实截图", x: 76, y: 350, width: 900, height: 42, size: 30, weight: .semibold, color: slate)

    drawShadowedCard(context, x: 176, y: 430, width: 728, height: 900, radius: 42)
    drawImageAspectFill(context, image: analysisImage, x: 200, y: 454, width: 680, height: 852, radius: 30, focusY: 0.06)
    drawPill(context, "真实界面 · 原图局部", x: 72, y: 1330, width: 272, color: paleCoral, textColor: coral)
    drawText(context, "一个里程碑的八月", x: 408, y: 1336, width: 600, height: 30, size: 24, weight: .bold, color: navy, alignment: .right)
}

func drawTimelineNode(
    _ context: CGContext,
    x: CGFloat,
    y: CGFloat,
    title: String,
    body: String,
    color: NSColor,
    paleColor: NSColor,
    number: String
) {
    drawCircle(context, x: x, y: y, diameter: 64, color: paleColor)
    drawText(context, number, x: x, y: y + 14, width: 64, height: 34, size: 24, weight: .black, color: color, alignment: .center)
    drawText(context, title, x: x + 96, y: y + 1, width: 710, height: 38, size: 30, weight: .bold, color: navy)
    drawText(context, body, x: x + 96, y: y + 52, width: 710, height: 38, size: 26, weight: .semibold, color: color)
}

func slide4(_ context: CGContext) {
    drawHeader(context, page: 4)
    drawText(context, "它把一个月", x: 72, y: 138, width: 900, height: 82, size: 68, weight: .black)
    drawRoundedFill(context, x: 66, y: 236, width: 650, height: 90, radius: 16, color: paleCoral)
    drawText(context, "串成了一条线", x: 80, y: 230, width: 670, height: 96, size: 70, weight: .black, color: coral)

    drawShadowedCard(context, x: 72, y: 398, width: 936, height: 780, radius: 38)
    drawLine(context, points: [CGPoint(x: 176, y: 530), CGPoint(x: 176, y: 1038)], color: coral.withAlphaComponent(0.35), width: 6)
    drawTimelineNode(context, x: 144, y: 482, title: "项目落地", body: "Holo 过审，记账到了 500 笔", color: coral, paleColor: paleCoral, number: "01")
    drawTimelineNode(context, x: 144, y: 654, title: "情绪和消费跟着动", body: "支出冲到 2.8 万，比上月多约 17%", color: coral, paleColor: paleCoral, number: "02")
    drawTimelineNode(context, x: 144, y: 826, title: "习惯留下了痕迹", body: "戒烟松了几天，英语断链满 30 天", color: green, paleColor: paleGreen, number: "03")
    drawTimelineNode(context, x: 144, y: 998, title: "项目之后还在继续", body: "你还在想怎么用它", color: blue, paleColor: paleBlue, number: "04")

    drawRoundedFill(context, x: 104, y: 1216, width: 872, height: 122, radius: 30, color: navy)
    drawText(context, "不是四份摘要，是一次月度复盘", x: 140, y: 1253, width: 800, height: 44, size: 32, weight: .bold, color: white, alignment: .center)
}

func drawQuoteCard(
    _ context: CGContext,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    quote: String,
    note: String,
    color: NSColor,
    paleColor: NSColor
) {
    drawShadowedCard(context, x: x, y: y, width: width, height: height, radius: 34)
    drawCircle(context, x: x + 32, y: y + 30, diameter: 58, color: paleColor)
    drawText(context, "「」", x: x + 32, y: y + 34, width: 58, height: 50, size: 24, weight: .black, color: color, alignment: .center)
    drawText(context, quote, x: x + 122, y: y + 34, width: width - 154, height: 84, size: 32, weight: .bold, color: navy, lineHeight: 44)
    drawText(context, note, x: x + 122, y: y + height - 60, width: width - 154, height: 30, size: 23, weight: .medium, color: color)
}

func slide5(_ context: CGContext) {
    drawHeader(context, page: 5)
    drawText(context, "最戳我的，", x: 72, y: 138, width: 900, height: 82, size: 68, weight: .black)
    drawText(context, "不是项目做成了", x: 72, y: 228, width: 900, height: 92, size: 72, weight: .black, color: coral)
    drawText(context, "而是它把项目之后的我也留下来了", x: 76, y: 350, width: 900, height: 42, size: 30, weight: .semibold, color: slate)

    drawQuoteCard(context, x: 72, y: 472, width: 936, height: 210, quote: "项目之后，你还在想怎么用它", note: "这句比项目完成了更像我", color: coral, paleColor: paleCoral)
    drawQuoteCard(context, x: 72, y: 722, width: 936, height: 210, quote: "月底，你把自己接住了", note: "我没有马上相信，先回去看记录", color: green, paleColor: paleGreen)

    drawRoundedFill(context, x: 104, y: 1004, width: 872, height: 240, radius: 36, color: navy)
    drawText(context, "我喜欢的不是它替我总结", x: 150, y: 1050, width: 780, height: 48, size: 35, weight: .bold, color: white, alignment: .center)
    drawText(context, "而是它先把散落的记录摆到一起", x: 150, y: 1120, width: 780, height: 48, size: 32, weight: .semibold, color: paleCoral, alignment: .center)
    drawText(context, "判断还是我自己的", x: 150, y: 1188, width: 780, height: 42, size: 31, weight: .bold, color: white, alignment: .center)
    drawText(context, "真实截图里的两句洞察", x: 72, y: 1328, width: 500, height: 30, size: 21, weight: .medium, color: slate)
}

func drawBoundaryCard(
    _ context: CGContext,
    y: CGFloat,
    title: String,
    body: String,
    symbol: String,
    color: NSColor,
    paleColor: NSColor
) {
    drawShadowedCard(context, x: 104, y: y, width: 872, height: 222, radius: 34)
    drawCircle(context, x: 142, y: y + 42, diameter: 72, color: paleColor)
    drawText(context, symbol, x: 142, y: y + 53, width: 72, height: 48, size: 32, weight: .bold, color: color, alignment: .center)
    drawText(context, title, x: 242, y: y + 48, width: 260, height: 44, size: 30, weight: .bold, color: color)
    drawText(context, body, x: 242, y: y + 112, width: 650, height: 76, size: 29, weight: .semibold, color: navy, lineHeight: 40)
}

func slide6(_ context: CGContext) {
    drawHeader(context, page: 6)
    drawText(context, "看见一起变化，", x: 72, y: 138, width: 900, height: 84, size: 66, weight: .black)
    drawRoundedFill(context, x: 66, y: 238, width: 620, height: 90, radius: 16, color: paleCoral)
    drawText(context, "不替我编原因", x: 80, y: 232, width: 660, height: 96, size: 68, weight: .black, color: coral)

    drawBoundaryCard(context, y: 408, title: "可以说", body: "这些变化，在同一个八月\n一起出现", symbol: "✓", color: green, paleColor: paleGreen)
    drawBoundaryCard(context, y: 672, title: "不能说", body: "项目落地导致了\n戒烟松动或英语断链", symbol: "×", color: coral, paleColor: paleCoral)

    drawRoundedFill(context, x: 104, y: 956, width: 872, height: 196, radius: 36, color: navy)
    drawText(context, "相关 ≠ 因果", x: 104, y: 1002, width: 872, height: 76, size: 58, weight: .black, color: white, alignment: .center)
    drawText(context, "它把线索放在一起，判断留给我", x: 140, y: 1084, width: 800, height: 38, size: 27, weight: .semibold, color: paleCoral, alignment: .center)

    drawRoundedFill(context, x: 146, y: 1210, width: 788, height: 112, radius: 28, color: paleCoral)
    drawText(context, "这点克制，反而让我愿意继续用", x: 164, y: 1245, width: 752, height: 44, size: 30, weight: .bold, color: coral, alignment: .center)
    drawText(context, "一次真实的月度复盘", x: 104, y: 1360, width: 872, height: 32, size: 22, weight: .medium, color: slate, alignment: .center)
}

let analysisImage = loadImage(userAnalysisPath)

try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

let slides: [(String, (CGContext) -> Void)] = [
    ("01-cover.png", { slide1($0) }),
    ("02-single-domain-limit.png", { slide2($0) }),
    ("03-check-before-answer.png", { slide3($0, analysisImage: analysisImage) }),
    ("04-cross-domain-relation.png", { slide4($0) }),
    ("05-evidence.png", { slide5($0) }),
    ("06-correlation-boundary.png", { slide6($0) })
]

for (filename, renderer) in slides {
    let context = makeContext()
    renderer(context)
    guard let image = context.makeImage() else { fatalError("无法生成 \(filename)") }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(filename) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("无法保存 \(filename)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("无法完成 \(filename)") }
    print(URL(fileURLWithPath: outputDirectory).appendingPathComponent(filename).path)
}
