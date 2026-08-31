//
//  CoachMark.swift
//  Holo
//
//  通用聚光灯导览组件：全屏半透明遮罩 + 挖洞高亮目标区域 + 说明卡片。
//  目标视图通过 .coachMarkTarget(id) 上报自身全局 frame，导览按步骤依次聚焦。
//  交互：点遮罩任意处前进一步，右上角「跳过」直接结束；完成与跳过均回调 onFinish。
//

import SwiftUI

// MARK: - 布局计算（纯函数，供单元测试）

/// 说明卡片定位规则：
/// 下方放得下优先（视觉动线在下方）；下方放不下改放上方（贴洞上方向上生长）；
/// 两边都放不下兜底贴洞下方——卡片延伸到屏底压住 home indicator 区域，好过向上侵入状态栏。
enum CoachMarkLayout {

    /// 顶部安全距离：状态栏 + 灵动岛
    static let topSafeInset: CGFloat = 60
    /// 卡片与洞的间距
    static let gap: CGFloat = 16
    /// 卡片距屏幕底的允许余量
    static let bottomMargin: CGFloat = 8

    /// 按文案长度估算卡片高度（定位是贴边生长，估算值只用于「选哪边」，误差几十点无碍）
    static func estimatedCardHeight(message: String, cardWidth: CGFloat) -> CGFloat {
        let textWidth = cardWidth - 2 * 20 // 卡片内边距 HoloSpacing.lg
        let charsPerLine = max(Int(textWidth / 16), 6) // holoBody 中文字符近似宽 16
        let lines = ceil(Double(message.count) / Double(charsPerLine))
        return 24 + 8 + CGFloat(lines) * 23 + 16 + 36 + 2 * 20 + 24
    }

    /// 卡片贴容器顶（洞下方）还是贴容器底（洞上方）
    static func cardAlignment(hole: CGRect, screenSize: CGSize, estimatedHeight: CGFloat) -> Alignment {
        let fitsBelow = hole.maxY + gap + estimatedHeight <= screenSize.height - bottomMargin
        let fitsAbove = estimatedHeight <= hole.minY - gap - topSafeInset
        return (fitsBelow || !fitsAbove) ? .top : .bottom
    }
}

// MARK: - 目标区域上报

/// 收集子树内所有 .coachMarkTarget(id) 上报的全局 frame
struct CoachMarkTargetFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// 把当前视图注册为导览高亮目标（导览进行中按 id 取其全局 frame 挖洞）
    func coachMarkTarget(_ id: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: CoachMarkTargetFramesKey.self, value: [id: geo.frame(in: .global)])
            }
        )
    }
}

// MARK: - 步骤定义

/// 导览单步：聚焦 targetID 对应的目标区域，展示标题与说明
struct CoachMarkStep: Identifiable, Equatable {
    /// 与 .coachMarkTarget(id) 对应的目标标识
    let targetID: String
    let title: String
    let message: String
    /// 洞相对目标 frame 的外扩边距
    var padding: CGFloat = 10
    /// 洞圆角
    var cornerRadius: CGFloat = 22

    var id: String { targetID }
}

// MARK: - 挂载修饰器

extension View {
    /// 在当前视图上挂聚光灯导览层（自动收集子树内 .coachMarkTarget 上报的 frame）
    func coachMarkTour(isPresented: Bool, steps: [CoachMarkStep], onFinish: @escaping () -> Void) -> some View {
        modifier(CoachMarkTourModifier(isPresented: isPresented, steps: steps, onFinish: onFinish))
    }
}

/// 收集目标 frame 并按需叠加导览层。
/// State 放在修饰器里：frame 更新只重算 overlay，不触发宿主视图重渲染。
private struct CoachMarkTourModifier: ViewModifier {

    let isPresented: Bool
    let steps: [CoachMarkStep]
    let onFinish: () -> Void

    @State private var frames: [String: CGRect] = [:]

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(CoachMarkTargetFramesKey.self) { frames = $0 }
            .overlay {
                if isPresented {
                    CoachMarkOverlay(steps: steps, targetFrames: frames, onFinish: onFinish)
                        .transition(.opacity)
                }
            }
    }
}

// MARK: - 导览视图

/// 聚光灯导览层。frames 为全局坐标，内部按本层实际全局原点换算后再使用。
struct CoachMarkOverlay: View {

    let steps: [CoachMarkStep]
    let targetFrames: [String: CGRect]
    let onFinish: () -> Void

    @State private var currentIndex: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var step: CoachMarkStep? {
        guard steps.indices.contains(currentIndex) else { return nil }
        return steps[currentIndex]
    }

    private var isLastStep: Bool {
        currentIndex == steps.count - 1
    }

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if let step,
                   let globalFrame = targetFrames[step.targetID] {
                    let hole = holeRect(for: step, target: globalFrame.offsetBy(dx: -origin.x, dy: -origin.y))

                    scrim(hole: hole)
                    holeBorder(hole: hole)
                    tooltip(step: step, hole: hole, screenSize: geo.size)
                    skipButton(screenSize: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .onAppear { currentIndex = 0 }
    }

    // MARK: - 布局计算

    /// 目标 frame 外扩 padding 得到洞区域
    private func holeRect(for step: CoachMarkStep, target: CGRect) -> CGRect {
        target.insetBy(dx: -step.padding, dy: -step.padding)
    }

    // MARK: - 遮罩与高亮

    /// 全屏遮罩：destinationOut 在合成组内把洞区域从白色遮罩中挖掉
    private func scrim(hole: CGRect) -> some View {
        Color.black.opacity(0.55)
            .mask {
                ZStack {
                    Color.white
                    CoachHoleShape(rect: hole, cornerRadius: step?.cornerRadius ?? 22)
                        .fill(Color.black)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .ignoresSafeArea()
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: hole)
    }

    /// 洞边缘白色描边，让高亮区域在浅色内容上也清晰
    private func holeBorder(hole: CGRect) -> some View {
        CoachHoleShape(rect: hole, cornerRadius: step?.cornerRadius ?? 22)
            .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
            .shadow(color: .black.opacity(0.25), radius: 4)
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: hole)
    }

    // MARK: - 说明卡片

    /// 说明卡片：按 CoachMarkLayout.cardAlignment 选边后贴边生长，
    /// 长文案卡片不会溢出盖住高亮目标。
    private func tooltip(step: CoachMarkStep, hole: CGRect, screenSize: CGSize) -> some View {
        let cardWidth: CGFloat = min(screenSize.width - 48, 320)
        let estimated = CoachMarkLayout.estimatedCardHeight(message: step.message, cardWidth: cardWidth)
        let alignment = CoachMarkLayout.cardAlignment(hole: hole, screenSize: screenSize, estimatedHeight: estimated)
        let useBelow = alignment == .top

        return card(step: step)
            .frame(width: cardWidth, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(.top, useBelow ? hole.maxY + CoachMarkLayout.gap : 0)
            .padding(.bottom, useBelow ? 0 : screenSize.height - hole.minY + CoachMarkLayout.gap)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: step)
    }

    private func card(step: CoachMarkStep) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text(step.title)
                .font(.holoTitle)
                .foregroundColor(.white)

            Text(step.message)
                .font(.holoBody)
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: HoloSpacing.sm) {
                // 步骤圆点
                HStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { index in
                        Circle()
                            .fill(Color.white.opacity(index == currentIndex ? 1 : 0.35))
                            .frame(width: 6, height: 6)
                    }
                }

                Spacer()

                Button(action: { advance() }) {
                    Text(isLastStep ? "开始使用" : "下一步")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(Color.holoPrimary)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLastStep ? "开始使用" : "下一步")
            }
        }
        .padding(HoloSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.lg)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)
        )
    }

    // MARK: - 跳过按钮

    private func skipButton(screenSize: CGSize) -> some View {
        Button(action: onFinish) {
            Text("跳过")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color.white.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .position(x: screenSize.width - 52, y: 76)
        .accessibilityLabel("跳过导览")
    }

    // MARK: - 步骤推进

    private func advance() {
        if isLastStep {
            onFinish()
        } else {
            withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86)) {
                currentIndex += 1
            }
        }
    }
}

// MARK: - 可动画洞形状

/// 挖洞矩形。实现 animatableData 让洞在步骤切换时平滑移动到下一个目标。
private struct CoachHoleShape: Shape {

    var rect: CGRect
    let cornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(rect.minX, rect.minY),
                AnimatablePair(rect.width, rect.height)
            )
        }
        set {
            rect = CGRect(x: newValue.first.first, y: newValue.first.second,
                          width: newValue.second.first, height: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: self.rect, cornerRadius: cornerRadius, style: .continuous)
    }
}

// MARK: - Preview

#Preview("聚光灯导览") {
    ZStack {
        Color.holoBackground.ignoresSafeArea()

        VStack {
            Text("页面内容")
                .font(.holoHeading)
                .coachMarkTarget("preview.target")
                .padding(.top, 120)

            Spacer()
        }
    }
    .coachMarkTour(
        isPresented: true,
        steps: [
            CoachMarkStep(
                targetID: "preview.target",
                title: "示例步骤",
                message: "这是说明文案，可以换行两到三行，讲清楚这个区域是做什么的。"
            )
        ],
        onFinish: {}
    )
}
