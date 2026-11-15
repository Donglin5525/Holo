import Foundation
import CoreGraphics

// MARK: - CSS 贝塞尔求解器

/// 单调 cubic-bezier(1, y1, x2, 1) 的精确求解器（WebKit UnitBezier 同型实现）。
///
/// CSS 动画的曲线是「先解 x 得参数，再取 y」；直接拿时间进度当曲线值会错过关键帧
/// 交接点（暖光规格 §4.3 明令禁止）。Newton 迭代为主，二分兜底。
struct UnitBezier {
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double

    init(x1: Double, y1: Double, x2: Double, y2: Double) {
        precondition(x1 >= 0 && x2 <= 1, "CSS 贝塞尔控制点 x 必须落在 [0, 1]")
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        // 多项式系数：B(t) = ((ax·t + bx)·t + cx)·t
        cx = 3 * x1
        bx = 3 * (x2 - x1) - cx
        ax = 1 - cx - bx
        cy = 3 * y1
        by = 3 * (y2 - y1) - cy
        ay = 1 - cy - by
    }

    private let ax, bx, cx, ay, by, cy: Double

    /// 曲线在参数 t 的分量值。
    private func sample(t: Double) -> (x: Double, y: Double) {
        let xt = ((ax * t + bx) * t + cx) * t
        let yt = ((ay * t + by) * t + cy) * t
        return (xt, yt)
    }

    private func sampleDerivativeX(t: Double) -> Double {
        (3 * ax * t + 2 * bx) * t + cx
    }

    /// 给定进度 x ∈ [0, 1]，解出曲线 y 值。端点直接返回，保证 0 → 0、1 → 1。
    func value(atX x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        // Newton 迭代
        var t = x
        for _ in 0..<8 {
            let dx = sampleDerivativeX(t: t)
            if dx < 1e-6 { break }
            let error = sample(t: t).x - x
            if abs(error) < 1e-7 { return sample(t: t).y }
            t -= error / dx
        }
        // 二分兜底
        var low = 0.0
        var high = 1.0
        t = x
        while high - low > 1e-7 {
            let current = sample(t: t).x
            if abs(current - x) < 1e-7 { break }
            if current < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sample(t: t).y
    }
}

/// 「一束暖光」用到的两条 CSS 缓动曲线（暖光规格 §4.2 时间线表）。
enum WarmLightEasing {
    /// CSS `ease-out` = cubic-bezier(0, 0, 0.58, 1)：驱动光层位移、缩放、亮度与合成层淡出。
    static let easeOut = UnitBezier(x1: 0, y1: 0, x2: 0.58, y2: 1)
    /// CSS `ease-in-out` = cubic-bezier(0.42, 0, 0.58, 1)：驱动出发/抵达两组文案的透明度段。
    static let easeInOut = UnitBezier(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
}

// MARK: - 时间线

/// 「一束暖光」某一时刻的全部可视参数（暖光规格 §4.1–4.3 的纯函数化，无副作用）。
struct WarmLightFrame: Equatable {
    /// 渐变层自身透明度：0.18 → 1（独立于 stop 内的 alpha）。
    var glowAlpha: Double
    /// 光层缩放：0.74 → 1（围绕扩展框中心）。
    var glowScale: Double
    /// 光层整体位移（画布坐标系，pt）：(-0.16Gw, +0.13Gh) → 0。
    var glowOffset: CGSize
    /// 出发组文案透明度：1 → 0。
    var departureAlpha: Double
    /// 抵达组文案透明度：0 → 1。
    var arrivalAlpha: Double
    /// 暖光合成层（底板+光+文案）整体透明度：主段恒 1，尾段 1 → 0。
    var compositeAlpha: Double
}

/// 暖光时间线。正常：1450ms 主段 + 210ms 淡出；系统「减少动态」：850ms 光形定态，
/// 亮度改走 easeOut 的抵达段百分比关键点，随后同样 210ms 淡出。
struct WarmLightTimeline {
    let reduceMotion: Bool

    init(reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
    }

    var mainDuration: TimeInterval {
        reduceMotion ? HoloAnimation.warmLightReducedMainDuration : HoloAnimation.warmLightMainDuration
    }

    var fadeDuration: TimeInterval { HoloAnimation.warmLightFadeDuration }

    /// 过场整段时长；此后合成层完全透明，由会话移除遮罩。
    var totalDuration: TimeInterval { mainDuration + fadeDuration }

    /// 主段结束（合成层开始淡出、结果页开始露出）的时刻，即交接提交点。
    var handoffElapsed: TimeInterval { mainDuration }

    /// 光层绘制框相对画布四边各扩 20%（CSS `inset: -20%`），即 1.4 倍。
    static let extendedBoxFactor: CGFloat = 1.4
    /// 初态位移：扩展框宽的 -16%、高的 +13%。
    static let initialOffsetFactor = CGSize(width: -0.16, height: 0.13)
    /// 初态缩放与亮度。
    static let initialScale: Double = 0.74
    static let initialGlowAlpha: Double = 0.18

    /// 取 elapsed（秒，单调时钟域）时刻的整帧参数。
    func frame(at elapsed: TimeInterval, canvas: CGSize) -> WarmLightFrame {
        let e = Swift.max(0, elapsed)
        let m = mainDuration

        let glowScale: Double
        let glowAlpha: Double
        let glowOffset: CGSize
        if reduceMotion {
            // 光形固定终态位置与大小，只让亮度走 30%–67% 的 easeOut 段（HTML .is-gentle ::before）。
            glowScale = 1
            glowOffset = .zero
            glowAlpha = segmentProgress(at: e, from: 0.30 * m, to: 0.67 * m, easing: WarmLightEasing.easeOut)
        } else {
            let progress = WarmLightEasing.easeOut.value(atX: Swift.min(1, e / m))
            glowScale = Self.initialScale + (1 - Self.initialScale) * progress
            glowAlpha = Self.initialGlowAlpha + (1 - Self.initialGlowAlpha) * progress
            let extendedWidth = Double(canvas.width * Self.extendedBoxFactor)
            let extendedHeight = Double(canvas.height * Self.extendedBoxFactor)
            glowOffset = CGSize(width: Double(Self.initialOffsetFactor.width) * extendedWidth * (1 - progress),
                                height: Double(Self.initialOffsetFactor.height) * extendedHeight * (1 - progress))
        }

        // 出发文案：主段 12% 前保持 1，12%–34% 淡出到 0；抵达文案：30% 前保持 0，30%–67% 淡入到 1。
        let departure = 1 - segmentProgress(at: e, from: 0.12 * m, to: 0.34 * m, easing: WarmLightEasing.easeInOut)
        let arrival = segmentProgress(at: e, from: 0.30 * m, to: 0.67 * m, easing: WarmLightEasing.easeInOut)

        // 合成层：主段内恒 1，主段后 210ms ease-out 淡出。
        let composite: Double
        if e <= m {
            composite = 1
        } else {
            let fade = WarmLightEasing.easeOut.value(atX: Swift.min(1, (e - m) / fadeDuration))
            composite = 1 - fade
        }

        return WarmLightFrame(glowAlpha: glowAlpha,
                              glowScale: glowScale,
                              glowOffset: glowOffset,
                              departureAlpha: departure,
                              arrivalAlpha: arrival,
                              compositeAlpha: composite)
    }

    /// [from, to] 区间内的 0→1 曲线进度；区间外按端点截断。
    private func segmentProgress(at elapsed: Double, from: Double, to: Double, easing: UnitBezier) -> Double {
        guard elapsed > from, to > from else { return elapsed <= from ? 0 : 1 }
        let local = (elapsed - from) / (to - from)
        if local >= 1 { return 1 }
        return easing.value(atX: local)
    }
}

// MARK: - 光晕调色板

/// 一个渐变 stop：直通 RGBA（0–1），CSS 语义。
struct WarmLightGradientStop: Equatable {
    var position: Double
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

/// 暖光椭圆渐变的颜色（暖光规格 §4.1，同浅深两套）。
///
/// CSS 原型：`radial-gradient(ellipse at 47% 45%, #FFCF858F, #E99A573B 38%, transparent 70%)`。
/// CSS 渐变按**预乘 alpha** 插值，SwiftUI/CG 是直通插值——直接搬色标中间色会偏暗，
/// 因此先在预乘空间密集采样再转回直通色喂给原生渐变。
enum WarmLightGlowPalette {
    /// 原型三个颜色 stop（`#RRGGBBAA` 换算到 0–1；transparent = rgba(0,0,0,0)）。
    static let cssStops: [WarmLightGradientStop] = [
        WarmLightGradientStop(position: 0.00, red: 255.0 / 255.0, green: 207.0 / 255.0, blue: 133.0 / 255.0, alpha: 143.0 / 255.0),
        WarmLightGradientStop(position: 0.38, red: 233.0 / 255.0, green: 154.0 / 255.0, blue: 87.0 / 255.0, alpha: 59.0 / 255.0),
        WarmLightGradientStop(position: 0.70, red: 0, green: 0, blue: 0, alpha: 0),
    ]

    /// 在预乘空间按 CSS 语义插值得到的密集色标（原生渐变直通插值近似 CSS 曲线）。
    ///
    /// - Parameter samplesPerSegment: 每个 CSS stop 区间的采样数（含首端点）。
    static func denseStops(samplesPerSegment: Int = 24) -> [WarmLightGradientStop] {
        precondition(samplesPerSegment >= 1)
        var result: [WarmLightGradientStop] = []
        for (start, end) in zip(cssStops, cssStops.dropFirst()) {
            let segmentCount = max(1, samplesPerSegment)
            let isLastSegment = end.position == cssStops.last?.position
            // 最后一个区间把末端点也算进来；中间区间避免与下一段首点重复。
            let upper = isLastSegment ? segmentCount : segmentCount - 1
            for step in 0...upper {
                let t = Double(step) / Double(segmentCount)
                let position = start.position + (end.position - start.position) * t
                // 预乘 alpha 插值，再除回直通色。
                let a0 = start.alpha, a1 = end.alpha
                let alpha = a0 + (a1 - a0) * t
                func premix(_ c0: Double, _ c1: Double) -> Double {
                    let premultiplied = c0 * a0 + (c1 * a1 - c0 * a0) * t
                    return alpha > 1e-6 ? premultiplied / alpha : 0
                }
                result.append(WarmLightGradientStop(position: position,
                                                     red: premix(start.red, end.red),
                                                     green: premix(start.green, end.green),
                                                     blue: premix(start.blue, end.blue),
                                                     alpha: alpha))
            }
        }
        return result
    }
}
