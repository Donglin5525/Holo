//
//  DailyKanbanEntryButton.swift
//  Holo
//
//  首页中心今日看板入口按钮
//  数据驱动三环轨道：总进度 / 习惯 / 任务，不同速度旋转 + 中心呼吸光点
//

import SwiftUI

struct DailyKanbanEntryButton: View {

    let action: () -> Void

    @ObservedObject private var todoRepo = TodoRepository.shared
    @ObservedObject private var habitRepo = HabitRepository.shared

    @State private var isAnimating = false
    @State private var animatedOverall: Double = 0
    @State private var animatedHabit: Double = 0
    @State private var animatedTask: Double = 0
    @State private var ringRotation1: Double = 0
    @State private var ringRotation2: Double = 0
    @State private var ringRotation3: Double = 0
    @State private var centerPulse: Double = 0.6

    // MARK: - 进度计算

    private var taskPercent: Double {
        let p = todoRepo.getDailyKanbanProgress()
        guard p.total > 0 else { return 0 }
        return Double(p.completed) / Double(p.total)
    }

    private var habitPercent: Double {
        let p = habitRepo.getTodayCheckInProgress()
        guard p.total > 0 else { return 0 }
        return Double(p.completed) / Double(p.total)
    }

    private var overallPercent: Double {
        let t = todoRepo.getDailyKanbanProgress()
        let h = habitRepo.getTodayCheckInProgress()
        let total = Double(t.total + h.total)
        guard total > 0 else { return 0 }
        return Double(t.completed + h.completed) / total
    }

    // MARK: - Body

    var body: some View {
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

            // 主按钮
            mainButton
        }
        .frame(width: 192, height: 192)
        .onAppear {
            isAnimating = true
            animatedOverall = overallPercent
            animatedHabit = habitPercent
            animatedTask = taskPercent
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
        }
        .onChange(of: overallPercent) { _, newValue in
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                animatedOverall = newValue
            }
        }
        .onChange(of: habitPercent) { _, newValue in
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                animatedHabit = newValue
            }
        }
        .onChange(of: taskPercent) { _, newValue in
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                animatedTask = newValue
            }
        }
    }

    // MARK: - 数据驱动三环

    /// 带末端光点的进度轨道
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

    // MARK: - 主按钮

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

                // 高光叠加
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.4), Color.white.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.8)

                // 外环（80pt）— 总体进度
                progressOrbit(size: 80, progress: animatedOverall, opacity: 0.9, lineWidth: 5, rotation: ringRotation1)

                // 中环（58pt）— 习惯进度
                progressOrbit(size: 58, progress: animatedHabit, opacity: 0.6, lineWidth: 4, rotation: ringRotation2)

                // 内环（38pt）— 任务进度
                progressOrbit(size: 38, progress: animatedTask, opacity: 0.4, lineWidth: 3, rotation: ringRotation3)

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
            }
        }
        .frame(width: 192, height: 192)
        .contentShape(Circle())
        .shadow(color: .holoPrimary.opacity(0.3), radius: 30)
        .scaleEffect(isAnimating ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isAnimating)
    }
}

#Preview {
    ZStack {
        Color.holoBackground.ignoresSafeArea()
        DailyKanbanEntryButton { }
    }
}
