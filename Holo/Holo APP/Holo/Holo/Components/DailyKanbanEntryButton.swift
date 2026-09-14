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

import SwiftUI

struct DailyKanbanEntryButton: View {

    let action: () -> Void
    /// 新版统一 ViewModel（HomeView 持有唯一实例；注入后才显示下方标题+摘要）。
    var todayViewModel: HoloTodayViewModel? = nil

    @ObservedObject private var todoRepo = TodoRepository.shared
    @ObservedObject private var habitRepo = HabitRepository.shared
    @ObservedObject private var displaySettings = HabitStatsDisplaySettings.shared

    @State private var isAnimating = false
    @State private var breathScale: CGFloat = 1.0
    @State private var animatedOverall: Double = 0
    @State private var animatedHabit: Double = 0
    @State private var animatedTask: Double = 0
    @State private var ringRotation1: Double = 0
    @State private var ringRotation2: Double = 0
    @State private var ringRotation3: Double = 0
    @State private var centerPulse: Double = 0.6

    // MARK: - 进度缓存

    /// 缓存进度值，避免动画驱动的 body 重渲染触发重复 Core Data 查询
    @State private var cachedTaskPercent: Double = 0
    @State private var cachedHabitPercent: Double = 0
    @State private var cachedOverallPercent: Double = 0

    /// 统一刷新三环进度（仅在数据变更时调用，而非每次 body 求值）
    private func refreshProgress() {
        let visibleIds = displaySettings.dashboardVisibleHabitIds
        let t = todoRepo.getDailyKanbanProgress()
        let h = habitRepo.getTodayCheckInProgress(
            visibleHabitIds: visibleIds.isEmpty ? nil : visibleIds
        )
        cachedTaskPercent = t.total > 0 ? Double(t.completed) / Double(t.total) : 0
        cachedHabitPercent = h.total > 0 ? Double(h.completed) / Double(h.total) : 0
        let overall = Double(t.total + h.total)
        cachedOverallPercent = overall > 0 ? Double(t.completed + h.completed) / overall : 0
    }

    /// 是否显示下方「今天」标题与摘要（新版增量；球体两种形态完全一致）。
    private var showsCaption: Bool {
        HoloTodayRolloutPolicy.isEnabled && todayViewModel != nil
    }

    // MARK: - Body

    var body: some View {
        sphere
        .onAppear {
            isAnimating = true
            refreshProgress()
            animatedOverall = cachedOverallPercent
            animatedHabit = cachedHabitPercent
            animatedTask = cachedTaskPercent
            withAnimation(.linear(duration: 90).repeatForever(autoreverses: false)) {
                ringRotation1 = 360
            }
            withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) {
                ringRotation2 = -360
            }
            withAnimation(.linear(duration: 45).repeatForever(autoreverses: false)) {
                ringRotation3 = 360
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                centerPulse = 1.0
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                breathScale = 1.03
            }
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
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                animatedOverall = newValue
            }
        }
        .onChange(of: cachedHabitPercent) { _, newValue in
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                animatedHabit = newValue
            }
        }
        .onChange(of: cachedTaskPercent) { _, newValue in
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                animatedTask = newValue
            }
        }
    }

    // MARK: - 球体（原版布局：三环轨道 + 中心呼吸光点）

    private var sphere: some View {
        ZStack {
            // 外环（320pt）— 缓慢旋转
            Circle()
                .stroke(
                    Color.holoPrimary.opacity(0.08),
                    style: StrokeStyle(lineWidth: 0.5, dash: [4, 8])
                )
                .frame(width: 320, height: 320)
                .rotationEffect(.degrees(ringRotation1 * 0.3))
                .allowsHitTesting(false)

            // 外环（256pt）— 较快旋转
            Circle()
                .stroke(
                    Color.holoPrimary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 8])
                )
                .frame(width: 256, height: 256)
                .rotationEffect(.degrees(ringRotation1 * 0.5))
                .allowsHitTesting(false)

            mainButton
        }
        .frame(width: 192, height: 192)
    }

    private var mainButton: some View {
        Button(action: action) {
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
                progressOrbit(size: 104, progress: animatedOverall, opacity: 0.55, lineWidth: 3.5, rotation: ringRotation1)

                // 中环（75pt，原 58 放大 30%）— 习惯进度
                progressOrbit(size: 75, progress: animatedHabit, opacity: 0.38, lineWidth: 2.8, rotation: ringRotation2)

                // 内环（49pt，原 38 放大 30%）— 任务进度
                progressOrbit(size: 49, progress: animatedTask, opacity: 0.26, lineWidth: 2.2, rotation: ringRotation3)

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
                return String(localized: "今天有 \(agendaCount) 项安排")
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

#Preview {
    ZStack {
        Color.holoBackground.ignoresSafeArea()
        DailyKanbanEntryButton { }
    }
}