//
//  HabitLampView.swift
//  Holo
//
//  习惯完成「A 点亮」（2026-11-23 审美七项 P1）：打卡型好习惯已记录的按钮
//  是一盏习惯色的灯（RadialGradient 灯体 + 白色灯芯，无外发光阴影）。
//  当天首次完成时灯芯放大点亮、习惯色光晕扩散淡出（≤1.6s 后消失，
//  属完成瞬间的动效反馈，不留常驻光晕）；此后灯芯以固定周期轻微呼吸，
//  呼吸只做透明度起伏。
//
//  触感（4.8）：回执触感已由 HabitActionCoordinator 对「好习惯首次完成 +
//  来源是习惯今天页」的打卡延后，由本视图在灯最亮那一刻（≈0.25s）播
//  HapticManager.soft()；数值行没有灯，触感保持回执即时档。
//
//  降级：allowsMotion == false（完成动效开关关闭 / 系统减弱动态效果）
//  不点亮、不呼吸、不震动，外观切换由调用方按 reducedFade 淡变；
//  低电量模式不呼吸；行滚出屏幕由 LazyVStack 回收，天然不呼吸。
//

import SwiftUI

/// 灯体局部排版尺寸（30pt 基准灯的派生比例；命中区域由调用方按钮提供）
private enum HabitLampMetrics {
    /// 基准灯体直径（今天页普通行）
    static let baseDiameter: CGFloat = 30
    /// 基准灯芯直径
    static let baseWick: CGFloat = 7
    /// 基准点亮光晕直径
    static let baseHalo: CGFloat = 58
    /// 灯芯点亮起始缩放（弹到 1.0 的过程中由弹簧自带过冲）
    static let igniteFrom: CGFloat = 0.4
    /// 光晕亮度峰值时刻（自点亮起，秒）
    static let haloPeakTime: TimeInterval = 0.48
    /// 光晕缩放峰值 / 终态
    static let haloPeakScale: CGFloat = 1.3
    static let haloEndScale: CGFloat = 1.8
    /// 光晕峰值透明度
    static let haloPeakOpacity: Double = 1.0
    /// 静止灯芯透明度（深色上限 0.85，避免刺眼）
    static let staticWickOpacity: Double = 0.9
    static let staticWickOpacityDark: Double = 0.85
    /// 呼吸透明度区间（深色同幅度、上限压到 0.85）
    static let breathLow: Double = 0.7
    static let breathHigh: Double = 1.0
    static let breathLowDark: Double = 0.6
    static let breathHighDark: Double = 0.85
    /// 灯体中心与白色的混合比例（深色更收敛）
    static let mixFraction: Double = 0.55
    static let mixFractionDark: Double = 0.35
}

/// 习惯灯：静止态 + 首次点亮动画 + 呼吸。纯装饰，不参与命中与无障碍。
struct HabitLampView: View {

    let color: Color
    /// 非空 = 正在播放一次「首次点亮」（导演在动画窗口内下发、到期清空）。
    /// 首次完成的胶囊→灯切换属于「挂载即带令牌」，同样播放；
    /// 窗口外滚动回收重挂只见 nil，显示静止灯不重播。
    let ignitionToken: UUID?
    let allowsMotion: Bool
    /// 可见灯体直径（主角大卡用更大的灯；不改调用方的命中区域）
    var lampDiameter: CGFloat = HabitLampMetrics.baseDiameter

    @Environment(\.colorScheme) private var scheme
    /// 正在播放点亮动画的令牌（nil = 静止）
    @State private var playingToken: UUID?
    /// 点亮动画的三个状态量，用普通 SwiftUI 动画驱动。首版用 KeyframeAnimator，
    /// 在「胶囊换灯、插入即起播」的场景下实测不推进，换成状态动画后逐帧核对按预期推进。
    @State private var wickScale: CGFloat = HabitLampMetrics.igniteFrom
    @State private var haloScale: CGFloat = HabitLampMetrics.igniteFrom
    @State private var haloOpacity: Double = 0

    private var isDark: Bool { scheme == .dark }

    private var haloDiameter: CGFloat {
        lampDiameter * HabitLampMetrics.baseHalo / HabitLampMetrics.baseDiameter
    }

    private var wickDiameter: CGFloat {
        lampDiameter * HabitLampMetrics.baseWick / HabitLampMetrics.baseDiameter
    }

    private var mixFraction: Double {
        isDark ? HabitLampMetrics.mixFractionDark : HabitLampMetrics.mixFraction
    }

    private var staticWickOpacity: Double {
        isDark ? HabitLampMetrics.staticWickOpacityDark : HabitLampMetrics.staticWickOpacity
    }

    /// 低电量模式不呼吸：常驻动画换电量
    private var allowsBreathing: Bool {
        allowsMotion && playingToken == nil
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: Body

    var body: some View {
        Group {
            if playingToken != nil, allowsMotion {
                igniteLamp
            } else {
                restingLamp
            }
        }
        .task(id: ignitionToken) {
            await beginIgnition()
        }
        .task(id: playingToken) {
            await endIgnitionWhenSettled()
        }
        .accessibilityHidden(true)
    }

    /// 点亮中的灯：光晕在灯体后面扩散淡出，灯芯从小放大到最亮
    private var igniteLamp: some View {
        ZStack {
            halo(scale: haloScale, opacity: haloOpacity)
            lampBody
            wick(scale: wickScale, opacity: staticWickOpacity)
        }
        .onAppear { playIgnition() }
    }

    /// 灯芯 0.3 秒弹到最亮；光晕 0.48 秒亮到峰值，再用余下时间放大淡出
    private func playIgnition() {
        withAnimation(HoloAnimation.snappy) { wickScale = 1 }
        withAnimation(HoloAnimation.lampHaloRise) {
            haloOpacity = HabitLampMetrics.haloPeakOpacity
            haloScale = HabitLampMetrics.haloPeakScale
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(HabitLampMetrics.haloPeakTime))
            withAnimation(HoloAnimation.lampHaloFade) {
                haloOpacity = 0
                haloScale = HabitLampMetrics.haloEndScale
            }
        }
    }

    /// 静止的灯：无光晕；灯芯呼吸或固定透明度
    private var restingLamp: some View {
        ZStack {
            lampBody
            if allowsBreathing {
                breathingWick
            } else {
                wick(scale: 1, opacity: staticWickOpacity)
            }
        }
    }

    // MARK: 部件

    private var lampBody: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.holoMixed(with: .white, fraction: mixFraction), color],
                    center: .center,
                    startRadius: 0,
                    endRadius: lampDiameter / 2
                )
            )
            .frame(width: lampDiameter, height: lampDiameter)
    }

    private func halo(scale: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.35), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: haloDiameter / 2
                )
            )
            .frame(width: haloDiameter, height: haloDiameter)
            .scaleEffect(scale)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func wick(scale: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: wickDiameter, height: wickDiameter)
            .scaleEffect(scale)
            .opacity(opacity)
            .accessibilityHidden(true)
    }

    /// 呼吸：只做灯芯透明度起伏（禁止 shadow / 外发光），每相半个周期
    private var breathingWick: some View {
        PhaseAnimator(HabitLampBreathPhase.allCases) { phase in
            wick(scale: 1, opacity: breathOpacity(phase))
        } animation: { _ in
            .easeInOut(duration: HoloAnimation.lampBreathPeriod / 2)
        }
    }

    private func breathOpacity(_ phase: HabitLampBreathPhase) -> Double {
        let low = isDark ? HabitLampMetrics.breathLowDark : HabitLampMetrics.breathLow
        let high = isDark ? HabitLampMetrics.breathHighDark : HabitLampMetrics.breathHigh
        return phase == .dim ? low : high
    }

    // MARK: 点亮时序

    /// 非空点亮令牌到达（挂载即带 = 首次完成的胶囊→灯切换，或令牌变化 = 新点亮）
    /// 且动效允许 → 进入播放；灯最亮那一刻轻震一次。（视图卸载时任务自动取消，不会补震）
    /// 令牌由导演在动画窗口结束时清空，所以「挂载时令牌非空」就是「正在播」。
    @MainActor
    private func beginIgnition() async {
        guard let token = ignitionToken, allowsMotion else { return }
        // 先无动画复位到起始态，再切换到点亮视图，由它的 onAppear 起播
        wickScale = HabitLampMetrics.igniteFrom
        haloScale = HabitLampMetrics.igniteFrom
        haloOpacity = 0
        playingToken = token
        do { try await Task.sleep(for: .seconds(HoloAnimation.lightFlightDelay)) } catch { return }
        HapticManager.soft()
    }

    /// 收尾独立于外部令牌（令牌清空只影响上一个小任务），保证动画时长走完、
    /// 结束后回到静止灯并允许呼吸
    @MainActor
    private func endIgnitionWhenSettled() async {
        guard let token = playingToken else { return }
        do { try await Task.sleep(for: .seconds(HoloAnimation.lampHaloDuration)) } catch { return }
        if playingToken == token { playingToken = nil }
    }
}

/// 呼吸相位
private enum HabitLampBreathPhase: CaseIterable {
    case dim
    case bright
}
