import SwiftUI

// 语义色 Color.warmLightPaper / warmLightInk / warmLightAccent 由资产目录
// 自动生成符号（GeneratedAssetSymbols）提供，深浅色走资产变体，不在手写扩展里重复。

// MARK: - 暖光过场叶子视图

/// 「一束暖光」过场：底板 + 椭圆光晕 + 出发/抵达两组日期文案的合成层。
///
/// 只收只读参数（内容快照、时间线、elapsed 闭包），不持有会话状态、不发交互事件；
/// 开始、取消、交接提交与收尾统一由漫步会话控制（暖光规格 §4.3）。
/// 整层对辅助功能隐藏，播放期间对命中区域形成遮罩。
struct MemoryWarmLightTransition: View {
    /// 一组日期文案。摘句只挂在抵达组；出发组只有标签、年份与日期。
    struct StampContent: Equatable {
        /// 「今天」或「出发」；抵达组固定「想起那一天」。
        var label: String
        /// 如「2026 年」，等宽数字。
        var yearText: String
        /// 如「5 月 21 日」。
        var dateText: String
        /// 同一抵达日的原文摘句，保持语义完整；无想法目标时为 nil。
        var excerpt: String?
    }

    let departure: StampContent
    let arrival: StampContent
    let timeline: WarmLightTimeline
    /// 单调时钟域内的已播放秒数；Debug 对拍注入固定值冻结静帧。
    let elapsed: () -> TimeInterval

    var body: some View {
        TimelineView(.animation) { _ in
            GeometryReader { proxy in
                let frame = timeline.frame(at: elapsed(), canvas: proxy.size)
                WarmLightPlate(departure: departure,
                               arrival: arrival,
                               frame: frame,
                               canvas: proxy.size)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 合成层

/// 底板、光晕与两组文案叠成的单层；先裁切到画布，再按合成透明度整体淡出，
/// 露出宿主已排版好的抵达页（暖光规格 §4.1 图层顺序）。
private struct WarmLightPlate: View {
    let departure: MemoryWarmLightTransition.StampContent
    let arrival: MemoryWarmLightTransition.StampContent
    let frame: WarmLightFrame
    let canvas: CGSize

    var body: some View {
        // 图层（底→顶）：纸底板 → 超尺寸椭圆光晕 → 两组日期文案。
        // 光晕是画布 1.4 倍大，必须挂在 .background 里：background 不参与布局尺寸且默认居中，
        // 否则会把 ZStack 撑大、经 GeometryReader 左上锚定后整体画面偏移（P0 对拍实抓）。
        ZStack {
            WarmLightStamp(content: departure, alpha: frame.departureAlpha)
            WarmLightStamp(content: arrival, alpha: frame.arrivalAlpha)
        }
        .background {
            WarmLightGlowCanvas(stops: WarmLightGlowPalette.denseStops())
                .frame(width: canvas.width * WarmLightTimeline.extendedBoxFactor,
                       height: canvas.height * WarmLightTimeline.extendedBoxFactor)
                .scaleEffect(frame.glowScale, anchor: .center)
                .offset(x: frame.glowOffset.width, y: frame.glowOffset.height)
                .opacity(frame.glowAlpha)
        }
        .background {
            Color.warmLightPaper
        }
        .compositingGroup()
        .clipped()
        .opacity(frame.compositeAlpha)
    }
}

// MARK: - 椭圆光晕

/// 椭圆径向渐变。CSS `farthest-corner` 的半径按暖光规格换算为
/// `√2 × (0.53·Gw, 0.55·Gh)`，先归一化到单位圆再由上下文变换拉成椭圆。
private struct WarmLightGlowCanvas: View {
    let stops: [WarmLightGradientStop]

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: 0.47 * size.width, y: 0.45 * size.height)
            let radiusWidth = 2.0.squareRoot() * 0.53 * size.width
            let radiusHeight = 2.0.squareRoot() * 0.55 * size.height
            var transformed = context
            transformed.translateBy(x: center.x, y: center.y)
            transformed.scaleBy(x: radiusWidth, y: radiusHeight)
            let gradient = Gradient(stops: stops.map { stop in
                Gradient.Stop(color: Color(.sRGB,
                                            red: stop.red,
                                            green: stop.green,
                                            blue: stop.blue,
                                            opacity: stop.alpha),
                              location: stop.position)
            })
            transformed.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                             with: .radialGradient(gradient,
                                                   center: .zero,
                                                   startRadius: 0,
                                                   endRadius: 1))
        }
    }
}

// MARK: - 日期文案组

/// 一组居中文案：28×1 细线（0.65）→ 标签 → 年份 → 日期 → 可选摘句。
/// 排版与原型 `.motion-stamp` 对齐：列内 4pt，线下额外 5pt，摘句额外上距 8pt。
private struct WarmLightStamp: View {
    let content: MemoryWarmLightTransition.StampContent
    let alpha: Double

    /// 日期字号：CSS clamp(1.9rem, 8vw, 2.7rem) 在 393pt 视口的值，随动态字体缩放。
    @ScaledMetric(relativeTo: .title) private var dateSize: CGFloat = 31.44
    @ScaledMetric(relativeTo: .body) private var excerptSize: CGFloat = 15.2
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var yearSize: CGFloat = 13

    var body: some View {
        VStack(spacing: 4) {
            Rectangle()
                .fill(Color.warmLightAccent)
                .frame(width: 28, height: 1)
                .opacity(0.65)
                .padding(.bottom, 5)
            Text(content.label)
                .font(.system(size: labelSize, weight: .semibold))
                .tracking(0.84)
                .foregroundStyle(Color.warmLightAccent)
            Text(content.yearText)
                .font(.system(size: yearSize))
                .monospacedDigit()
                .foregroundStyle(Color.warmLightAccent)
            Text(content.dateText)
                .font(.system(size: dateSize, weight: .semibold, design: .serif))
                .tracking(-0.07 * dateSize)
                .foregroundStyle(Color.warmLightInk)
                .lineLimit(1)
                // 不用 fixedSize：衬线 CJK 回退字形的理想宽度与实际字形宽度不一致，
                // fixedSize 会钉住错误宽度让整行向右溢出（P0 对拍 bbox 实测：标签 184✓ 日期 243✗）。
            if let excerpt = content.excerpt {
                Text(excerpt)
                    .font(.system(size: excerptSize, weight: .semibold, design: .serif))
                    .lineSpacing(excerptSize * 0.25)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: excerptMaxWidth)
                    .padding(.top, 8)
                    .foregroundStyle(Color.warmLightInk)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .opacity(alpha)
    }

    /// CSS `max-width: 24ch`：衬线数字 advance ≈ 0.5em，即 12em。
    private var excerptMaxWidth: CGFloat { excerptSize * 12 }
}
