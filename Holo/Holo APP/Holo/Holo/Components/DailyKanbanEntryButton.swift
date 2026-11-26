//
//  DailyKanbanEntryButton.swift
//  Holo
//
//  首页中心「今天」入口按钮
//
//  球体视觉保持原版：数据驱动三环轨道（总进度/习惯/任务）+ 中心呼吸光点，布局不动。
//  新版增量（todayCommandCenterEnabled + viewModel 注入）只有一处：
//  球体正下方显示「今天」标题与状态摘要（偏浅灰小字，位置由东林拍板 2026-09-14），
//  不把摘要压进球体中央。
//
//  持续动画由 TimelineView 以绝对时间为相位驱动（东林 2026-10-06 拍板：光球永转、
//  不受系统减少动态效果约束）——角度只由时间戳决定，暂停恢复/页面遮挡/门控翻转
//  都从当前时刻继续，不存在「转一半跳回起点」的相位重置。
//

import SwiftUI

struct DailyKanbanEntryButton: View {

    @AppStorage(HoloMotionRollout.interactionKey) private var motionEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.holoMotionSurfaceIsActive) private var surfaceActive

    let action: () -> Void
    /// 新版统一 ViewModel（HomeView 持有唯一实例；注入后才显示下方标题+摘要）。
    var todayViewModel: HoloTodayViewModel? = nil

    @ObservedObject private var todoRepo = TodoRepository.shared
    @ObservedObject private var habitRepo = HabitRepository.shared
    @ObservedObject private var displaySettings = HabitStatsDisplaySettings.shared
    @ObservedObject private var homeTemplate = HomeTemplateManager.shared

    @State private var animatedOverall: Double = 0
    @State private var animatedHabit: Double = 0
    @State private var animatedTask: Double = 0

    // MARK: - 进度缓存

    /// 缓存进度值，避免动画驱动的 body 重渲染触发重复 Core Data 查询
    @State private var cachedTaskPercent: Double = 0
    @State private var cachedHabitPercent: Double = 0
    @State private var cachedOverallPercent: Double = 0

    /// 统一刷新三环进度（仅在数据变更时调用，而非每次 body 求值）
    private func refreshProgress() {
        let t = todoRepo.getDailyKanbanProgress()
        // 显式全部关闭（configured 标记）→ 看板进度归零，不回退成「显示全部」
        let h: (completed: Int, total: Int)
        if let visibleIds = displaySettings.effectiveDashboardVisibleIds(), visibleIds.isEmpty {
            h = (0, 0)
        } else {
            let visibleIds = displaySettings.dashboardVisibleHabitIds
            let visibleSet = Set(visibleIds)
            // 过期白名单（习惯 UUID 重建后）一个都匹配不上时回退全部，防止看板进度莫名归零
            let effectiveIds: [UUID]? = visibleIds.isEmpty
                ? nil
                : (habitRepo.activeHabits.contains { visibleSet.contains($0.id) } ? visibleIds : nil)
            h = habitRepo.getTodayCheckInProgress(visibleHabitIds: effectiveIds)
        }
        cachedTaskPercent = t.total > 0 ? Double(t.completed) / Double(t.total) : 0
        cachedHabitPercent = h.total > 0 ? Double(h.completed) / Double(h.total) : 0
        let overall = Double(t.total + h.total)
        cachedOverallPercent = overall > 0 ? Double(t.completed + h.completed) / overall : 0
    }

    /// 是否显示下方「今天」标题与摘要（新版增量；球体两种形态完全一致）。
    private var showsCaption: Bool {
        HoloTodayRolloutPolicy.isEnabled && todayViewModel != nil
    }

    /// 持续运转的门：动效开关开启、首页可见、App 前台。减少动态效果不停转（2026-10-06 拍板）。
    private var ambientMotionActive: Bool {
        motionEnabled && surfaceActive && scenePhase == .active
    }

    // MARK: - Body

    var body: some View {
        Group {
            switch homeTemplate.currentStyle {
            case .classic:
                sphere
            case .sundial:
                sundialCenterpiece
            case .moonPhase:
                moonPhaseCenterpiece
            }
        }
        .buttonStyle(HoloPressStyle())
        .onAppear {
            refreshProgress()
            animatedOverall = cachedOverallPercent
            animatedHabit = cachedHabitPercent
            animatedTask = cachedTaskPercent
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoDataDidChange)) { _ in
            refreshProgress()
        }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
            refreshProgress()
        }
        .onChange(of: displaySettings.dashboardVisibleHabitIds) { _, _ in
            refreshProgress()
        }
        // activeHabits 由 HomeView.task 异步 setup 加载，onAppear 时仍为空；
        // 监听 count 变化，确保加载完成后能补刷新一次习惯进度
        .onChange(of: habitRepo.activeHabits.count) { _, _ in
            refreshProgress()
        }
        .onChange(of: cachedOverallPercent) { _, newValue in
            withAnimation(reduceMotion || !motionEnabled ? nil : .spring(response: 0.8, dampingFraction: 0.7)) {
                animatedOverall = newValue
            }
        }
        .onChange(of: cachedHabitPercent) { _, newValue in
            withAnimation(reduceMotion || !motionEnabled ? nil : .spring(response: 0.8, dampingFraction: 0.7)) {
                animatedHabit = newValue
            }
        }
        .onChange(of: cachedTaskPercent) { _, newValue in
            withAnimation(reduceMotion || !motionEnabled ? nil : .spring(response: 0.8, dampingFraction: 0.7)) {
                animatedTask = newValue
            }
        }
    }

    // MARK: - 球体（原版布局：三环轨道 + 中心呼吸光点）

    private var sphere: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !ambientMotionActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                // 外环（320pt）— 缓慢旋转
                Circle()
                    .stroke(
                        Color.holoPrimary.opacity(0.08),
                        style: StrokeStyle(lineWidth: 0.5, dash: [4, 8])
                    )
                    .frame(width: 320, height: 320)
                    .rotationEffect(.degrees(Self.orbitAngle(t, period: 90) * 0.3))
                    .allowsHitTesting(false)

                // 外环（256pt）— 较快旋转
                Circle()
                    .stroke(
                        Color.holoPrimary.opacity(0.15),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 8])
                    )
                    .frame(width: 256, height: 256)
                    .rotationEffect(.degrees(Self.orbitAngle(t, period: 90) * 0.5))
                    .allowsHitTesting(false)

                mainButton(at: t)
            }
            .frame(width: 192, height: 192)
        }
    }

    /// 环绕角度只由绝对时间决定：每 period 秒一圈，相位跨任何中断连续。
    private static func orbitAngle(_ t: Double, period: Double) -> Double {
        (t / period).truncatingRemainder(dividingBy: 1) * 360
    }

    private func mainButton(at t: Double) -> some View {
        let ring1 = Self.orbitAngle(t, period: 90)
        let ring2 = -Self.orbitAngle(t, period: 60)
        let ring3 = Self.orbitAngle(t, period: 45)
        // 呼吸沿用原参数：中心光点 0.6↔1.0、整体 1↔1.03，周期 4s 正弦往返
        let centerPulse = 0.8 + 0.2 * sin(2 * .pi * t / 4)
        let breathScale = 1.015 + 0.015 * sin(2 * .pi * t / 4)
        return Button(action: action) {
            ZStack {
                // 渐变填充
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.holoPrimaryLight, .holoPrimary, .holoPrimaryDark],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // 外环（104pt，原 80 放大 30%）— 总体进度（素四终稿：细金丝降调）
                progressOrbit(size: 104, progress: animatedOverall, opacity: 0.55, lineWidth: 3.5, rotation: ring1)

                // 中环（75pt，原 58 放大 30%）— 习惯进度
                progressOrbit(size: 75, progress: animatedHabit, opacity: 0.38, lineWidth: 2.8, rotation: ring2)

                // 内环（49pt，原 38 放大 30%）— 任务进度
                progressOrbit(size: 49, progress: animatedTask, opacity: 0.26, lineWidth: 2.2, rotation: ring3)

                // 中心呼吸光点
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.6), Color.white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 10
                        )
                    )
                    .frame(width: 20, height: 20)
                    .scaleEffect(centerPulse)

                // 状态铭文：沿球内下弧逐字排布（素四终稿，弧 r=72）
                ArcInscriptionText(text: captionText)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 192, height: 192)
        .contentShape(Circle())
        .shadow(color: .holoPrimary.opacity(0.3), radius: 30)
        .scaleEffect(breathScale)
        .accessibilityLabel(Text("今天，\(captionText)，按钮"))
    }

    private var captionText: String {
        guard let vm = todayViewModel else {
            return String(localized: "查看今天")
        }
        if case .ready(let snapshot) = vm.state {
            if snapshot.primaryFocus?.severity == .risk {
                return String(localized: "1 件事需要关注")
            }
            let agendaCount = snapshot.agenda.count
            if agendaCount > 0 {
                return String(localized: "今天有\(agendaCount)项安排")
            }
            if snapshot.primaryFocus != nil {
                return String(localized: "1 件事值得推进")
            }
            return String(localized: "今天暂无紧急事项")
        }
        if vm.lastSnapshot != nil {
            return String(localized: "查看今天")
        }
        return String(localized: "正在整理今天")
    }

    // MARK: - 数据驱动三环

    /// 进度轨道（素四终稿：细金丝，无末端光点）
    private func progressOrbit(
        size: CGFloat, progress: Double,
        opacity: Double, lineWidth: CGFloat,
        rotation: Double
    ) -> some View {
        ZStack {
            // 底层轨道
            Circle()
                .stroke(Color.white.opacity(opacity * 0.15), lineWidth: lineWidth)
                .frame(width: size, height: size)

            // 进度弧
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.white.opacity(opacity), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))

            // 末端光点
            let tipAngle = (-90 + progress * 360) * .pi / 180
            let tipRadius = size / 2
            Circle()
                .fill(Color.white.opacity(opacity))
                .frame(width: lineWidth + 2, height: lineWidth + 2)
                .blur(radius: 1)
                .offset(x: tipRadius * cos(tipAngle), y: tipRadius * sin(tipAngle))
        }
        .rotationEffect(.degrees(rotation))
    }
}

/// 弧形铭文：文字沿下弧逐字排布，字顶朝圆心（素四终稿「今天有 3 项安排」形态）。
/// 弧半径 72pt（三环 104 外、球缘 88 内的安全环带），字号 10.5。
private struct ArcInscriptionText: View {
    let text: String
    var radius: CGFloat = 72
    var fontSize: CGFloat = 10.5

    var body: some View {
        let chars = Array(text)
        // 每字弧向步进（度）：字宽+字距 ≈ 13pt / 72pt 半径 ≈ 10.4°
        let step: Double = 10.4
        let n = Double(chars.count)
        return ZStack {
            ForEach(0..<chars.count, id: \.self) { index in
                let theta = (Double(index) - (n - 1) / 2) * step
                let rad = theta * .pi / 180
                Text(String(chars[index]))
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .rotationEffect(.degrees(-theta))
                    .offset(
                        x: radius * sin(rad),
                        y: radius * cos(rad)
                    )
            }
        }
        .lineLimit(1)
        .accessibilityHidden(true) // 摘要语义已并入球体按钮 accessibility label
    }
}

// MARK: - 首页高审美模板中心件（2026-11-24：方案 ② 日晷时间针 & 方案 ④ 盈亏月相）

extension DailyKanbanEntryButton {

    // MARK: 方案 ② · 纸本星象 · 日晷时间针

    private var sundialCenterpiece: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !ambientMotionActive)) { timeline in
            let now = timeline.date
            let t = now.timeIntervalSinceReferenceDate
            let outerRotate = Self.orbitAngle(t, period: 120)
            let tipBreath = 0.72 + 0.28 * sin(2 * .pi * t / 4.2)
            let dialHalo = 0.85 + 0.15 * sin(2 * .pi * t / 5.5)
            // 实时日晷指针角：按 24 小时昼夜弧平滑推进（正午 12:00 指顶，06:00 偏左，18:00 偏右）
            let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
            let hourFloat = Double(comps.hour ?? 12) + Double(comps.minute ?? 0) / 60.0 + Double(comps.second ?? 0) / 3600.0
            let handDegrees = ((hourFloat - 12.0) / 12.0) * 150.0

            VStack(spacing: 10) {
                Button(action: action) {
                    ZStack {
                        sundialPaperHalo(halo: dialHalo)
                        sundialDashedRing(rotation: outerRotate)
                        sundialDialTicks()
                        // 外进度弧：任务（渐变暖墨）
                        editorialGradientArc(
                            size: 162,
                            progress: animatedTask,
                            trackOpacity: 0.08,
                            colors: [Color.holoAlmanacInk.opacity(0.20), Color.holoAlmanacInk.opacity(0.78)],
                            tipColor: Color.holoAlmanacInk,
                            lineWidth: 1.8,
                            tipGlow: false
                        )
                        // 内进度弧：习惯（渐进朱砂橙 + 微光尾点）
                        editorialGradientArc(
                            size: 138,
                            progress: animatedHabit,
                            trackOpacity: 0.07,
                            colors: [Color.holoPrimaryLight.opacity(0.45), Color.holoPrimary],
                            tipColor: Color.holoPrimary,
                            lineWidth: 2.2,
                            tipGlow: true,
                            tipPulse: tipBreath
                        )
                        sundialDialFace()
                        sundialHand(degrees: handDegrees, breath: tipBreath)
                        sundialCenterAxis()
                    }
                    .frame(width: 196, height: 196)
                    .contentShape(Circle())
                }
                .accessibilityLabel(Text("今天，\(captionText)，按钮"))

                editorialBelowCaption
            }
        }
    }

    // MARK: 方案 ② 图层函数（按视觉图层拆小类型检查单元，修饰符/顺序/数值与原实现一致）

    /// 极柔纸面底光晕（236pt 径向渐变）
    private func sundialPaperHalo(halo: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.holoPrimary.opacity(0.08 * halo),
                        Color.holoAlmanacInk.opacity(0.03),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 24,
                    endRadius: 118
                )
            )
            .frame(width: 236, height: 236)
            .allowsHitTesting(false)
    }

    /// 外虚线天象环（216pt，120s 缓慢匀速旋转）
    private func sundialDashedRing(rotation: Double) -> some View {
        Circle()
            .stroke(
                Color.holoAlmanacInk.opacity(0.14),
                style: StrokeStyle(lineWidth: 0.75, dash: [2, 6])
            )
            .frame(width: 216, height: 216)
            .rotationEffect(.degrees(rotation))
            .allowsHitTesting(false)
    }

    /// 60 枚精密表盘刻度（Canvas 零开销绘制；角度统一 CGFloat，避免 Double/CGFloat 混算拖慢类型检查）
    private func sundialDialTicks() -> some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outerR: CGFloat = 95
            for i in 0..<60 {
                let angle = CGFloat(i) * 6.0 * .pi / 180.0
                let isCardinal = i % 15 == 0
                let isHour = i % 5 == 0
                let len: CGFloat = isCardinal ? 7.5 : (isHour ? 4.5 : 2.2)
                let p1 = CGPoint(x: center.x + (outerR - len) * cos(angle), y: center.y + (outerR - len) * sin(angle))
                let p2 = CGPoint(x: center.x + outerR * cos(angle), y: center.y + outerR * sin(angle))
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                ctx.stroke(
                    path,
                    with: .color(Color.holoAlmanacInk.opacity(isCardinal ? 0.36 : (isHour ? 0.22 : 0.11))),
                    lineWidth: isCardinal ? 1.1 : 0.65
                )
            }
        }
        .frame(width: 196, height: 196)
        .allowsHitTesting(false)
    }

    /// 中央陶瓷/纸质微凸盘面（108pt + 描边 overlay + 阴影，零文字纯留白）
    private func sundialDialFace() -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.holoCardBackground,
                        Color.holoPaper
                    ],
                    center: UnitPoint(x: 0.38, y: 0.32),
                    startRadius: 4,
                    endRadius: 62
                )
            )
            .frame(width: 108, height: 108)
            .overlay(
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.65), Color.holoAlmanacInk.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.85
                    )
            )
            .shadow(color: Color.holoAlmanacInk.opacity(0.08), radius: 12, x: 0, y: 5)
    }

    /// 精工日晷时间针（胶囊 + 两个圆点，随当下真实时刻平滑指向）
    private func sundialHand(degrees: Double, breath: Double) -> some View {
        ZStack {
            // 指针主体（细锥形 + 尾平衡针）
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.holoAlmanacInk, Color.holoAlmanacInk.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1.7, height: 42)
                .offset(y: -14)
                .shadow(color: Color.holoAlmanacInk.opacity(0.22), radius: 2, x: 1, y: 2)

            // 针尖朱砂微光点（4.2s 呼吸）
            Circle()
                .fill(Color.holoPrimary.opacity(0.32 * breath))
                .frame(width: 11, height: 11)
                .blur(radius: 2.5)
                .offset(y: -35)

            Circle()
                .fill(Color.holoPrimary)
                .frame(width: 4.5, height: 4.5)
                .offset(y: -35)
        }
        .rotationEffect(.degrees(degrees))
        .allowsHitTesting(false)
    }

    /// 中心表轴（双层同心圆）
    private func sundialCenterAxis() -> some View {
        ZStack {
            Circle()
                .fill(Color.holoAlmanacInk)
                .frame(width: 7.5, height: 7.5)
            Circle()
                .fill(Color.holoPaper)
                .frame(width: 2.5, height: 2.5)
        }
    }

    // MARK: 方案 ④ · 盈亏月相 · 晨昏切面

    private var moonPhaseCenterpiece: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !ambientMotionActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let starOrbit1 = Self.orbitAngle(t, period: 95)
            let starOrbit2 = -Self.orbitAngle(t, period: 130)
            let lunarBreath = 0.82 + 0.18 * sin(2 * .pi * t / 5.0)
            let starPulse = 0.55 + 0.45 * sin(2 * .pi * t / 3.8)
            // 即使 0% 空态也呈现一弯精致细眉月，随今日总进度丝滑盈满
            let phaseProgress = max(0.14, min(1.0, animatedOverall))

            VStack(spacing: 10) {
                Button(action: action) {
                    ZStack {
                        moonPhaseHalo(breath: lunarBreath)
                        moonStarOrbitOuter(orbit: starOrbit1, pulse: starPulse)
                        moonStarOrbitInner(orbit: starOrbit2, pulse: starPulse)
                        // 外进度弧：任务（暮蓝-暖墨渐变）
                        editorialGradientArc(
                            size: 160,
                            progress: animatedTask,
                            trackOpacity: 0.08,
                            colors: [Color.holoInfo.opacity(0.22), Color.holoAlmanacInk.opacity(0.72)],
                            tipColor: Color.holoAlmanacInk,
                            lineWidth: 1.6,
                            tipGlow: false
                        )
                        // 内进度弧：习惯（暖金-朱砂渐变）
                        editorialGradientArc(
                            size: 140,
                            progress: animatedHabit,
                            trackOpacity: 0.07,
                            colors: [Color.holoPrimaryLight.opacity(0.4), Color.holoPrimary],
                            tipColor: Color.holoPrimary,
                            lineWidth: 2.0,
                            tipGlow: true,
                            tipPulse: starPulse
                        )
                        moonPhaseDial(phase: phaseProgress, breath: lunarBreath)
                    }
                    .frame(width: 196, height: 196)
                    .contentShape(Circle())
                }
                .accessibilityLabel(Text("今天，\(captionText)，按钮"))

                editorialBelowCaption
            }
        }
    }

    // MARK: 方案 ④ 图层函数（按视觉图层拆小类型检查单元，修饰符/顺序/数值与原实现一致）

    /// 柔和呼吸月晕（236pt 径向渐变光环）
    private func moonPhaseHalo(breath: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.holoPrimaryLight.opacity(0.24 * breath),
                        Color.holoInfo.opacity(0.08 * breath),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 34,
                    endRadius: 118
                )
            )
            .frame(width: 236, height: 236)
            .scaleEffect(0.98 + 0.03 * breath)
            .allowsHitTesting(false)
    }

    /// 外星轨细环 + 2 颗缓慢巡游的微光星点（外轨 212pt）
    private func moonStarOrbitOuter(orbit: Double, pulse: Double) -> some View {
        ZStack {
            Circle()
                .stroke(
                    Color.holoAlmanacInk.opacity(0.12),
                    style: StrokeStyle(lineWidth: 0.65, dash: [1.5, 7])
                )
                .frame(width: 212, height: 212)

            Circle()
                .fill(Color.holoPrimary.opacity(0.75 * pulse))
                .frame(width: 4, height: 4)
                .shadow(color: Color.holoPrimary.opacity(0.5), radius: 4)
                .offset(y: -106)
        }
        .rotationEffect(.degrees(orbit))
        .allowsHitTesting(false)
    }

    /// 内星轨细环（184pt）+ 对向巡游星点
    private func moonStarOrbitInner(orbit: Double, pulse: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Color.holoAlmanacInk.opacity(0.07), lineWidth: 0.6)
                .frame(width: 184, height: 184)

            Circle()
                .fill(Color.holoAlmanacInk.opacity(0.45 * pulse))
                .frame(width: 3, height: 3)
                .offset(y: 92)
        }
        .rotationEffect(.degrees(orbit))
        .allowsHitTesting(false)
    }

    /// 立体月相表盘（106pt，含 `.mask` + `.blendMode(.destinationOut)` + `.compositingGroup()` 月轮整段原样保留）
    private func moonPhaseDial(phase: Double, breath: Double) -> some View {
        ZStack {
            // 暗面基底（晨昏微光）
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.holoInfo.opacity(0.16),
                            Color.holoAlmanacInk.opacity(0.10)
                        ],
                        center: UnitPoint(x: 0.35, y: 0.35),
                        startRadius: 6,
                        endRadius: 56
                    )
                )
                .frame(width: 106, height: 106)
                .background(Color.holoPaper, in: Circle())

            // 盈亏亮面月轮（柔和渐变 + 几何月相遮罩）
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.holoAlmanacInk.opacity(0.92),
                                Color.holoAlmanacInk.opacity(0.78),
                                Color.holoInfo.opacity(0.85)
                            ],
                            center: UnitPoint(x: 0.65, y: 0.35),
                            startRadius: 4,
                            endRadius: 38
                        )
                    )
                    .frame(width: 58, height: 58)
                    .mask(
                        ZStack {
                            Circle()
                                .frame(width: 58, height: 58)
                            // 随完成度平滑退去的暗影圆，形成新月 → 半月 → 满月
                            Circle()
                                .frame(width: 56, height: 56)
                                .offset(x: -(10 + CGFloat(phase) * 52))
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    )

                // 月轮外极细银边
                Circle()
                    .stroke(Color.holoAlmanacInk.opacity(0.16), lineWidth: 0.7)
                    .frame(width: 58, height: 58)
            }
            .shadow(color: Color.holoAlmanacInk.opacity(0.12), radius: 8, x: 0, y: 3)

            // 12 点位朱砂经线星点
            Circle()
                .fill(Color.holoPrimary)
                .frame(width: 4, height: 4)
                .shadow(color: Color.holoPrimary.opacity(0.45 * breath), radius: 4)
                .offset(y: -41)

            // 外环高光描边
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.holoAlmanacInk.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .frame(width: 106, height: 106)
        }
        .shadow(color: Color.holoAlmanacInk.opacity(0.08), radius: 14, x: 0, y: 6)
    }

    // MARK: 公共组件：渐变进度弧 + 圆环下方静谧摘要

    private func editorialGradientArc(
        size: CGFloat,
        progress: Double,
        trackOpacity: Double,
        colors: [Color],
        tipColor: Color,
        lineWidth: CGFloat,
        tipGlow: Bool,
        tipPulse: Double = 1.0
    ) -> some View {
        let clamped = max(0, min(1, progress))
        let tipAngle = (-90 + clamped * 360) * .pi / 180
        let tipRadius = size / 2
        return ZStack {
            Circle()
                .stroke(Color.holoAlmanacInk.opacity(trackOpacity), lineWidth: 0.9)
                .frame(width: size, height: size)

            if clamped > 0.005 {
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: colors),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(max(12, clamped * 360))
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-90))

                if tipGlow {
                    Circle()
                        .fill(tipColor.opacity(0.32 * tipPulse))
                        .frame(width: lineWidth + 6, height: lineWidth + 6)
                        .blur(radius: 2.5)
                        .offset(x: tipRadius * cos(tipAngle), y: tipRadius * sin(tipAngle))
                }

                Circle()
                    .fill(tipColor)
                    .frame(width: lineWidth + 1.5, height: lineWidth + 1.5)
                    .offset(x: tipRadius * cos(tipAngle), y: tipRadius * sin(tipAngle))
            }
        }
        .allowsHitTesting(false)
    }

    /// 圆环正下方摘要：衬线「今天」+ 克制细字状态，绝不压进圆内
    private var editorialBelowCaption: some View {
        VStack(spacing: 2) {
            Text(String(localized: "今天"))
                .font(.holoEditorialSerif(size: 13, bold: false))
                .kerning(1.6)
                .foregroundStyle(Color.holoAlmanacInk.opacity(0.82))

            Text(captionText)
                .font(.system(size: 11, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(Color.holoToolTextSecondary)
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    ZStack {
        Color.holoBackground.ignoresSafeArea()
        DailyKanbanEntryButton { }
    }
}
