import Foundation
import CoreGraphics
import ImageIO
import Vision
import AppKit

// 用法: analyze_layout <png路径> [--ocr]
// 输出: 12x8 网格的非背景覆盖率(%) + 内容包围盒 + 可选OCR文本行位置

func loadCGImage(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func rgbaBuffer(_ image: CGImage, maxDim: CGFloat) -> (pixels: [UInt8], w: Int, h: Int) {
    let scale = min(1, maxDim / CGFloat(max(image.width, image.height)))
    let w = max(1, Int(CGFloat(image.width) * scale))
    let h = max(1, Int(CGFloat(image.height) * scale))
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    return (Array(UnsafeBufferPointer(start: buf, count: w * h * 4)), w, h)
}

let args = CommandLine.arguments
guard args.count >= 2, let img = loadCGImage(args[1]) else {
    print("ERR load"); exit(1)
}
let doOCR = args.contains("--ocr")
let (px, w, h) = rgbaBuffer(img, maxDim: 600)

// 背景色 = 四角像素中位数近似（取左上角区域平均）
func sampleBG(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    var r = 0, g = 0, b = 0, n = 0
    for dy in 0..<8 { for dx in 0..<8 {
        let i = ((y * 8 + dy) * w + (x * 8 + dx)) * 4
        guard i + 2 < px.count else { continue }
        r += Int(px[i]); g += Int(px[i+1]); b += Int(px[i+2]); n += 1
    }}
    return (r / n, g / n, b / n)
}
let corners = [sampleBG(0, 0), sampleBG(w / 32, 0), sampleBG(0, h / 32), sampleBG(w / 32, h / 32)]
var br = 0, bg = 0, bb = 0
for c in corners { br += c.0; bg += c.1; bb += c.2 }
let bgc = (br / 4, bg / 4, bb / 4)

let cols = 12, rows = 8
var grid = [Double](repeating: 0, count: cols * rows)
var inkCount = 0, totalCount = 0
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let dr = abs(Int(px[i]) - bgc.0), dg = abs(Int(px[i+1]) - bgc.1), db = abs(Int(px[i+2]) - bgc.2)
        let isBg = dr < 14 && dg < 14 && db < 14
        totalCount += 1
        if !isBg {
            inkCount += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            let gc = min(cols - 1, x * cols / w), gr = min(rows - 1, y * rows / h)
            grid[gr * cols + gc] += 1
        }
    }
}
let cellTotal = Double(totalCount) / Double(cols * rows)
print("SIZE \(img.width)x\(img.height) INK \(String(format: "%.1f", Double(inkCount) / Double(totalCount) * 100))%")
print("BBOX x[\(minX)..\(maxX)] y[\(minY)..\(maxY)]  (\(String(format: "%.0f", Double(minX)/Double(w)*100))%-\(String(format: "%.0f", Double(maxX)/Double(w)*100))% 宽)")
var out = "GRID%\n    "
for c in 0..<cols { out += String(format: "%5d", c) }
print(out)
for r in 0..<rows {
    var line = String(format: "r%d ", r)
    for c in 0..<cols {
        line += String(format: "%5.0f", grid[r * cols + c] / cellTotal * 100)
    }
    print(line)
}
// 每列合计（横向密度剖面）
var colSum = ""
for c in 0..<cols {
    let s = (0..<rows).map { grid[$0 * cols + c] }.reduce(0, +)
    colSum += String(format: "%5.0f", s / (cellTotal * Double(rows)) * 100)
}
print("COLSUM\(colSum)")

if doOCR {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    try? handler.perform([request])
    let observations = request.results ?? []
    var lines: [(text: String, box: CGRect)] = []
    for obs in observations {
        guard let cand = obs.topCandidates(1).first else { continue }
        let t = cand.string.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { lines.append((t, obs.boundingBox)) }
    }
    print("OCR \(lines.count) lines:")
    for l in lines.prefix(150) {
        // Vision 坐标系原点在左下，转为顶部百分比
        let topPct = (1 - l.box.maxY) * 100
        print(String(format: "  y%04.0f x%02.0f-%02.0f | %@", topPct, l.box.minX * 100, l.box.maxX * 100, l.text))
    }
}
