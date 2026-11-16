import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import os.log

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
    /// 传入非 nil 的会话请求 ID 时走 Core Animation Render-Server 直驱（120Hz 零主线程开销）；
    /// 为 nil 时走静态帧（供 WarmLightFrameRenderTests / ImageRenderer 逐帧对拍）。
    var animationID: UUID? = nil

    var body: some View {
        Group {
            if let animationID {
                #if canImport(UIKit)
                WarmLightCoreAnimationView(
                    animationID: animationID,
                    departure: departure,
                    arrival: arrival,
                    timeline: timeline,
                    initialElapsed: elapsed()
                )
                #else
                TimelineViewContent(departure: departure,
                                    arrival: arrival,
                                    timeline: timeline,
                                    elapsed: elapsed,
                                    usePeriodic: true)
                #endif
            } else {
                GeometryReader { proxy in
                    WarmLightPlate(departure: departure,
                                   arrival: arrival,
                                   frame: timeline.frame(at: elapsed(), canvas: proxy.size),
                                   canvas: proxy.size)
                }
                .accessibilityHidden(true)
            }
        }
    }
}

#if canImport(UIKit)
/// 1:1 复刻原型 CSS 关键帧的 Core Animation 实现：
/// - 全部动画提交到 Render Server（GPU 120Hz 原生合成，主线程零每帧重绘）
/// - 径向渐变预渲染一次为 CGImage，动画期间只改 opacity 与 transform
/// - 严格对齐 CSS cubic-bezier(0,0,0.58,1) / (0.42,0,0.58,1) 与 0/12/30/34/67/100% 关键帧
private struct WarmLightCoreAnimationView: UIViewRepresentable {
    let animationID: UUID
    let departure: MemoryWarmLightTransition.StampContent
    let arrival: MemoryWarmLightTransition.StampContent
    let timeline: WarmLightTimeline
    let initialElapsed: TimeInterval

    func makeUIView(context: Context) -> WarmLightHostUIView {
        let view = WarmLightHostUIView()
        view.configure(animationID: animationID,
                       departure: departure,
                       arrival: arrival,
                       timeline: timeline,
                       initialElapsed: initialElapsed)
        return view
    }

    func updateUIView(_ uiView: WarmLightHostUIView, context: Context) {
        uiView.configure(animationID: animationID,
                       departure: departure,
                       arrival: arrival,
                       timeline: timeline,
                       initialElapsed: initialElapsed)
    }
}

private final class WarmLightHostUIView: UIView {
    private static let logger = Logger(subsystem: "com.holo.app", category: "RandomWalk")

    private let glowLayer = CALayer()
    private let departureView = WarmLightStampUIView()
    private let arrivalView = WarmLightStampUIView()

    private var currentAnimationID: UUID?
    private var currentReduceMotion: Bool?
    private var pendingInitialElapsed: TimeInterval = 0
    private var lastRenderedGlowSize: CGSize = .zero
    private var hasStartedAnimation = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = UIColor(Color.warmLightPaper)
        departureView.accessibilityElementsHidden = true

        layer.addSublayer(glowLayer)
        addSubview(departureView)
        addSubview(arrivalView)

        departureView.translatesAutoresizingMaskIntoConstraints = false
        arrivalView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            departureView.leadingAnchor.constraint(equalTo: leadingAnchor),
            departureView.trailingAnchor.constraint(equalTo: trailingAnchor),
            departureView.topAnchor.constraint(equalTo: topAnchor),
            departureView.bottomAnchor.constraint(equalTo: bottomAnchor),
            arrivalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            arrivalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            arrivalView.topAnchor.constraint(equalTo: topAnchor),
            arrivalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(animationID: UUID,
                   departure: MemoryWarmLightTransition.StampContent,
                   arrival: MemoryWarmLightTransition.StampContent,
                   timeline: WarmLightTimeline,
                   initialElapsed: TimeInterval) {
        let needsRestart = currentAnimationID != animationID || currentReduceMotion != timeline.reduceMotion
        if needsRestart {
            currentAnimationID = animationID
            currentReduceMotion = timeline.reduceMotion
            pendingInitialElapsed = initialElapsed
            hasStartedAnimation = false
            departureView.update(content: departure)
            arrivalView.update(content: arrival)
            setNeedsLayout()
        }
        startAnimationIfReady(timeline: timeline, initialElapsed: pendingInitialElapsed)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let gw = bounds.width * WarmLightTimeline.extendedBoxFactor
        let gh = bounds.height * WarmLightTimeline.extendedBoxFactor
        let targetSize = CGSize(width: gw, height: gh)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.bounds = CGRect(origin: .zero, size: targetSize)
        glowLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        if lastRenderedGlowSize != targetSize {
            lastRenderedGlowSize = targetSize
            glowLayer.contents = Self.renderGlowImage(size: targetSize, scale: traitCollection.displayScale)
        }
        CATransaction.commit()

        if !hasStartedAnimation, let reduceMotion = currentReduceMotion {
            startAnimationIfReady(timeline: WarmLightTimeline(reduceMotion: reduceMotion),
                                  initialElapsed: pendingInitialElapsed)
        }
    }

    private func startAnimationIfReady(timeline: WarmLightTimeline, initialElapsed: TimeInterval) {
        guard !hasStartedAnimation, bounds.width > 0, bounds.height > 0 else { return }
        hasStartedAnimation = true

        let main = timeline.mainDuration
        let fade = timeline.fadeDuration
        let gw = bounds.width * WarmLightTimeline.extendedBoxFactor
        let gh = bounds.height * WarmLightTimeline.extendedBoxFactor

        let easeOut = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
        let easeInOut = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
        let linear = CAMediaTimingFunction(name: .linear)

        let t0 = layer.convertTime(CACurrentMediaTime(), from: nil) - max(0, initialElapsed)
        Self.logger.notice("[RW] CA start req=\(self.currentAnimationID?.uuidString.prefix(8) ?? "nil", privacy: .public) size=\(Int(self.bounds.width), privacy: .public)x\(Int(self.bounds.height), privacy: .public) main=\(main, privacy: .public) fade=\(fade, privacy: .public) initE=\(initialElapsed, privacy: .public)")

        glowLayer.removeAllAnimations()
        departureView.layer.removeAllAnimations()
        arrivalView.layer.removeAllAnimations()
        layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 1. 光晕层（warm-memory-light）
        if timeline.reduceMotion {
            glowLayer.transform = CATransform3DIdentity
            let glowOpacity = CAKeyframeAnimation(keyPath: "opacity")
            glowOpacity.values = [0.0, 0.0, 1.0, 1.0]
            glowOpacity.keyTimes = [0.0, 0.30, 0.67, 1.0]
            glowOpacity.timingFunctions = [linear, easeOut, linear]
            glowOpacity.duration = main
            glowOpacity.beginTime = t0
            glowOpacity.fillMode = .both
            glowOpacity.isRemovedOnCompletion = false
            glowLayer.add(glowOpacity, forKey: "warmLightGlowOpacity")
        } else {
            let tx = Double(WarmLightTimeline.initialOffsetFactor.width) * Double(gw)
            let ty = Double(WarmLightTimeline.initialOffsetFactor.height) * Double(gh)
            var startTransform = CATransform3DMakeTranslation(tx, ty, 0)
            startTransform = CATransform3DScale(startTransform,
                                                WarmLightTimeline.initialScale,
                                                WarmLightTimeline.initialScale,
                                                1)

            let glowTransform = CABasicAnimation(keyPath: "transform")
            glowTransform.fromValue = NSValue(caTransform3D: startTransform)
            glowTransform.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            glowTransform.duration = main
            glowTransform.timingFunction = easeOut
            glowTransform.beginTime = t0
            glowTransform.fillMode = .both
            glowTransform.isRemovedOnCompletion = false

            let glowOpacity = CABasicAnimation(keyPath: "opacity")
            glowOpacity.fromValue = WarmLightTimeline.initialGlowAlpha
            glowOpacity.toValue = 1.0
            glowOpacity.duration = main
            glowOpacity.timingFunction = easeOut
            glowOpacity.beginTime = t0
            glowOpacity.fillMode = .both
            glowOpacity.isRemovedOnCompletion = false

            glowLayer.add(glowTransform, forKey: "warmLightGlowTransform")
            glowLayer.add(glowOpacity, forKey: "warmLightGlowOpacity")
        }

        // 2. 出发文案（light-depart：0-12% 恒 1，12-34% ease-in-out 淡出）
        let departAnim = CAKeyframeAnimation(keyPath: "opacity")
        departAnim.values = [1.0, 1.0, 0.0, 0.0]
        departAnim.keyTimes = [0.0, 0.12, 0.34, 1.0]
        departAnim.timingFunctions = [linear, easeInOut, linear]
        departAnim.duration = main
        departAnim.beginTime = t0
        departAnim.fillMode = .both
        departAnim.isRemovedOnCompletion = false
        departureView.layer.add(departAnim, forKey: "warmLightDepart")

        // 3. 抵达文案（light-arrive：0-30% 恒 0，30-67% ease-in-out 淡入）
        let arriveAnim = CAKeyframeAnimation(keyPath: "opacity")
        arriveAnim.values = [0.0, 0.0, 1.0, 1.0]
        arriveAnim.keyTimes = [0.0, 0.30, 0.67, 1.0]
        arriveAnim.timingFunctions = [linear, easeInOut, linear]
        arriveAnim.duration = main
        arriveAnim.beginTime = t0
        arriveAnim.fillMode = .both
        arriveAnim.isRemovedOnCompletion = false
        arrivalView.layer.add(arriveAnim, forKey: "warmLightArrive")

        // 4. 整层交接淡出（is-landing：1450ms 起 210ms ease-out 淡出）
        let landingFade = CABasicAnimation(keyPath: "opacity")
        landingFade.fromValue = 1.0
        landingFade.toValue = 0.0
        landingFade.duration = fade
        landingFade.timingFunction = easeOut
        landingFade.beginTime = t0 + main
        landingFade.fillMode = .both
        landingFade.isRemovedOnCompletion = false
        layer.add(landingFade, forKey: "warmLightLandingFade")

        CATransaction.commit()
    }

    private static func renderGlowImage(size: CGSize, scale: CGFloat) -> CGImage? {
        let effectiveScale = max(1, scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = effectiveScale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            let stops = WarmLightGlowPalette.denseStops()
            let colors = stops.map {
                CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
            } as CFArray
            let locations = stops.map { CGFloat($0.position) }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else {
                return
            }
            let rx = 2.0.squareRoot() * 0.53 * size.width
            let ry = 2.0.squareRoot() * 0.55 * size.height
            let center = CGPoint(x: 0.47 * size.width, y: 0.45 * size.height)
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: 1.0, y: ry / max(1, rx))
            ctx.drawRadialGradient(gradient,
                                   startCenter: .zero,
                                   startRadius: 0,
                                   endCenter: .zero,
                                   endRadius: rx,
                                   options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
        return image.cgImage
    }
}

private final class WarmLightStampUIView: UIView {
    private let stack = UIStackView()
    private let hairline = UIView()
    private let labelView = UILabel()
    private let yearView = UILabel()
    private let dateView = UILabel()
    private let excerptView = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        hairline.backgroundColor = UIColor(Color.warmLightAccent).withAlphaComponent(0.65)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hairline.widthAnchor.constraint(equalToConstant: 28),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])

        labelView.textAlignment = .center
        yearView.textAlignment = .center
        dateView.textAlignment = .center
        dateView.numberOfLines = 1
        excerptView.textAlignment = .center
        excerptView.numberOfLines = 2
        excerptView.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(hairline)
        stack.setCustomSpacing(9, after: hairline)
        stack.addArrangedSubview(labelView)
        stack.addArrangedSubview(yearView)
        stack.addArrangedSubview(dateView)
        stack.setCustomSpacing(12, after: dateView)
        stack.addArrangedSubview(excerptView)

        let excerptSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: 15.2)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            excerptView.widthAnchor.constraint(lessThanOrEqualToConstant: excerptSize * 12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(content: MemoryWarmLightTransition.StampContent) {
        let labelSize = UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 12)
        let yearSize = UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 13)
        let dateSize = UIFontMetrics(forTextStyle: .title1).scaledValue(for: 31.44)
        let excerptSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: 15.2)

        let accent = UIColor(Color.warmLightAccent)
        let ink = UIColor(Color.warmLightInk)

        labelView.attributedText = NSAttributedString(
            string: content.label,
            attributes: [
                .font: UIFont.systemFont(ofSize: labelSize, weight: .semibold),
                .foregroundColor: accent,
                .kern: 0.84,
            ]
        )

        yearView.font = UIFont.monospacedDigitSystemFont(ofSize: yearSize, weight: .regular)
        yearView.textColor = accent
        yearView.text = content.yearText

        let dateFont = Self.serifFont(size: dateSize, weight: .semibold)
        dateView.attributedText = NSAttributedString(
            string: content.dateText,
            attributes: [
                .font: dateFont,
                .foregroundColor: ink,
                .kern: -0.07 * dateSize,
            ]
        )

        if let excerpt = content.excerpt {
            excerptView.isHidden = false
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = excerptSize * 0.25
            excerptView.attributedText = NSAttributedString(
                string: excerpt,
                attributes: [
                    .font: Self.serifFont(size: excerptSize, weight: .semibold),
                    .foregroundColor: ink,
                    .paragraphStyle: paragraph,
                ]
            )
        } else {
            excerptView.isHidden = true
            excerptView.attributedText = nil
        }
    }

    private static func serifFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}
#endif

private final class WarmLightTickProbe {
    var count = 0
    var lastLogElapsed: TimeInterval = -1
}

/// schedule 选择器：.animation（帧驱动）与 .periodic（墙钟周期）类型不同，走分支。
private struct TimelineViewContent: View {
    let departure: MemoryWarmLightTransition.StampContent
    let arrival: MemoryWarmLightTransition.StampContent
    let timeline: WarmLightTimeline
    let elapsed: () -> TimeInterval
    let usePeriodic: Bool

    @State private var probe = WarmLightTickProbe()
    private static let logger = Logger(subsystem: "com.holo.app", category: "RandomWalk")

    var body: some View {
        let plate = GeometryReader { proxy in
            let e = elapsed()
            let frame = timeline.frame(at: e, canvas: proxy.size)
            let _ = logTickIfNeeded(elapsed: e, canvas: proxy.size, frame: frame)
            WarmLightPlate(departure: departure,
                           arrival: arrival,
                           frame: frame,
                           canvas: proxy.size)
        }
        Group {
            if usePeriodic {
                TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { _ in plate }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in plate }
            }
        }
        .onAppear {
            Self.logger.notice("[RW] WarmLight onAppear usePeriodic=\(usePeriodic, privacy: .public) reduceMotion=\(timeline.reduceMotion, privacy: .public)")
        }
        .onDisappear {
            Self.logger.notice("[RW] WarmLight onDisappear totalTicks=\(probe.count, privacy: .public)")
        }
    }

    private func logTickIfNeeded(elapsed: TimeInterval, canvas: CGSize, frame: WarmLightFrame) {
        probe.count += 1
        let c = probe.count
        if c <= 3 || elapsed - probe.lastLogElapsed >= 0.3 {
            probe.lastLogElapsed = elapsed
            Self.logger.notice("[RW] tick#\(c, privacy: .public) e=\(String(format: "%.3f", elapsed), privacy: .public) size=\(Int(canvas.width), privacy: .public)x\(Int(canvas.height), privacy: .public) comp=\(String(format: "%.2f", frame.compositeAlpha), privacy: .public) glowA=\(String(format: "%.2f", frame.glowAlpha), privacy: .public) depA=\(String(format: "%.2f", frame.departureAlpha), privacy: .public) arrA=\(String(format: "%.2f", frame.arrivalAlpha), privacy: .public)")
        }
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
            // 渐变只栅格化一次（ShapeStyle 层），动画帧只改 scale/offset/opacity 三个
            // GPU 变换——此前 Canvas 每帧重录 51 色标渐变，真机 120Hz 下卡成幻灯片
            //（11-15 东林实报「动画很卡/没加载出来」根因）。
            WarmLightGlowLayer(canvas: canvas)
                .scaleEffect(frame.glowScale, anchor: .center)
                .offset(x: frame.glowOffset.width, y: frame.glowOffset.height)
                .opacity(frame.glowAlpha)
        }
        .background {
            Color.warmLightPaper
        }
        .compositingGroup()
        .clipped()
        .contentShape(Rectangle())
        .opacity(frame.compositeAlpha)
    }
}

// MARK: - 椭圆光晕

/// 椭圆径向渐变（静态层）。规格同前：椭圆心在扩展框 (0.47Gw, 0.45Gh)，
/// 半轴 √2×(0.53Gw, 0.55Gh)。实现＝单位圆径向渐变（RadialGradient ShapeStyle，
/// 只栅格化一次）＋非等比 scaleEffect 拉成椭圆，动画帧零重绘。
private struct WarmLightGlowLayer: View {
    let canvas: CGSize

    /// 圆渐变的边长：直径取水平半轴的两倍；垂直方向由 scaleEffect 压到 0.55Gh/0.53Gw。
    private var squareSide: CGFloat { 2.0.squareRoot() * 1.06 * canvas.width * WarmLightTimeline.extendedBoxFactor }
    private var yAxisRatio: CGFloat {
        let gw = canvas.width * WarmLightTimeline.extendedBoxFactor
        let gh = canvas.height * WarmLightTimeline.extendedBoxFactor
        return gh / gw * 0.55 / 0.53
    }

    var body: some View {
        let gw = canvas.width * WarmLightTimeline.extendedBoxFactor
        let gh = canvas.height * WarmLightTimeline.extendedBoxFactor
        let side = squareSide
        RadialGradient(
            gradient: Gradient(stops: WarmLightGlowPalette.denseStops().map { stop in
                Gradient.Stop(color: Color(.sRGB,
                                           red: stop.red,
                                           green: stop.green,
                                           blue: stop.blue,
                                           opacity: stop.alpha),
                              location: stop.position)
            }),
            center: .center,
            startRadius: 0,
            endRadius: side / 2
        )
        .frame(width: side, height: side)
        .scaleEffect(x: 1, y: yAxisRatio, anchor: .center)
        // 椭圆心定位到扩展框 (0.47Gw, 0.45Gh)：锚点居中后偏移即中心点。
        .offset(x: 0.47 * gw - side / 2,
                y: 0.45 * gh - side / 2)
        .frame(width: gw, height: gh, alignment: .topLeading)
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
