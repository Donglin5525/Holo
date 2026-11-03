//
//  TaskListHeroSection.swift
//  Holo
//
//  任务首页 Hero 今日仪表（文字状态头 / 常规进度卡 / 庆祝卡）——
//  2026-10-24 随真机主线程栈溢出排险从 TaskListView 拆出（纯搬移，界面/行为零变化）。
//

import SwiftUI

struct TaskListHeroSection: View {

    let tasks: [TodoTask]
    let todayProgress: (completed: Int, total: Int)
    let overdueCount: Int
    @Binding var heroAppeared: Bool

    /// 完成协调层（G1 完成契约：撤回窗口 / confirm / 撤回统一走它）
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared

    /// 正在完成中的任务 ID（来自完成协调层的全局撤回状态）
    private var pendingCompletionTaskId: UUID? { completionCoordinator.pending?.taskID }

    var body: some View {
        let ratio: CGFloat = heroProgress.total > 0
            ? CGFloat(heroProgress.completed) / CGFloat(heroProgress.total)
            : 0

        Group {
            if HoloTaskMotionRolloutPolicy.isEnabled {
                // Holo 文字状态头：不使用百分比、圆环和进度条。
                paperHeroCard
            } else if isHeroAllDone {
                heroCelebrateCard(total: heroProgress.total)
            } else {
                heroRegularCard(ratio: ratio)
            }
        }
        .opacity(heroAppeared ? 1 : 0)
        .offset(y: heroAppeared ? 0 : 14)
        .padding(.top, HoloSpacing.md)
        .animation(HoloAnimation.grounded, value: isHeroAllDone)
    }

    /// 撤回窗口期间乐观计数：正在完成中的今日任务直接计入完成数
    private var heroProgress: (completed: Int, total: Int) {
        var progress = todayProgress
        if let pendingId = pendingCompletionTaskId,
           let task = tasks.first(where: { $0.id == pendingId }),
           !task.completed, task.isDueToday {
            progress.completed += 1
        }
        return progress
    }

    private var isHeroAllDone: Bool {
        heroProgress.total > 0 && heroProgress.completed >= heroProgress.total
            && pendingCompletionTaskId == nil
    }

    /// Holo 状态头：保留不依赖进度条的文字反馈。
    @ViewBuilder
    private var paperHeroCard: some View {
        if isHeroAllDone {
            TaskPaperHeaderCard(
                title: String(localized: "今天的计划已完成"),
                subtitle: celebrateSubtitle(total: heroProgress.total),
                countBadge: String(localized: "已清零")
            )
        } else {
            let remaining = max(0, heroProgress.total - heroProgress.completed)
            TaskPaperHeaderCard(
                title: String(localized: "今天，先推进重要的事"),
                subtitle: paperHeroSubtitle,
                countBadge: remaining > 0 ? String(localized: "\(remaining) 项待办") : nil
            )
        }
    }

    /// 纸页头副行：日期 + 待办/过期状态文字化（保留信息，去掉比例表达）
    private var paperHeroSubtitle: String {
        var parts: [String] = []
        let remaining = heroProgress.total - heroProgress.completed
        if heroProgress.total > 0 {
            parts.append(remaining > 0
                         ? String(localized: "还有 \(remaining) 项可以推进")
                         : String(localized: "今日任务已清零"))
        }
        if overdueCount > 0 {
            parts.append(String(localized: "\(overdueCount) 项已过期"))
        }
        let status = parts.isEmpty ? String(localized: "还没有安排今天的任务") : parts.joined(separator: " · ")
        return "\(heroDateString) · \(status)"
    }

    /// 常规态：日期行 + 大数字进度 + 环形进度 + 渐变条 + 过期警示
    private func heroRegularCard(ratio: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heroDateString)
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.lg) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("今日进度")
                        .font(.system(size: 12.5))
                        .foregroundColor(.holoTextSecondary)

                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(heroProgress.completed)")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .foregroundColor(.holoPrimary)
                        Text("/")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                        Text("\(heroProgress.total)")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                    }

                    HStack(spacing: 10) {
                        if heroProgress.total > 0 {
                            Text("还剩 ") + Text("\(heroProgress.total - heroProgress.completed)")
                                .foregroundColor(.holoPrimary)
                                .fontWeight(.bold)
                                + Text(" 项")
                        } else {
                            Text("今天暂无到期任务")
                        }

                        if overdueCount > 0 {
                            Text("\(overdueCount) 项已过期")
                                .foregroundColor(.holoToolError)
                                .fontWeight(.semibold)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                }

                Spacer(minLength: 0)

                heroRing(ratio: ratio)
            }

            heroProgressBar(ratio: ratio)
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.holoCardBackground)
                // 左上暖色光晕（与习惯页进度头同源的暖调）
                LinearGradient(
                    colors: [Color.holoPrimary.opacity(0.07), .clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.14), lineWidth: 1)
        )
    }

    /// 环形进度（品牌橙渐变描边）
    private func heroRing(ratio: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(Color.holoPrimary.opacity(0.10), lineWidth: 7)

            Circle()
                .trim(from: 0, to: ratio)
                .stroke(
                    AngularGradient(
                        colors: [.holoPrimary, .holoPrimaryDark],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text("\(Int((ratio * 100).rounded()))%")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundColor(.holoPrimary)
        }
        .frame(width: 72, height: 72)
        .animation(.easeOut(duration: 0.5), value: ratio)
    }

    private func heroProgressBar(ratio: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.holoBorder)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.holoPrimary, .holoPrimaryDark],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(height: 6)
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.5), value: ratio)
    }

    private var heroDateString: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return formatter.string(from: Date()) + " · " + String(localized: "今天")
    }

    /// 庆祝态：今日清零，整块变品牌橙渐变（与习惯页「今天全部点亮」同一语言）
    private func heroCelebrateCard(total: Int) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: 1)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("今天全部完成")
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundColor(.white)
                    Text("✨")
                        .font(.system(size: 16))
                }

                Text(celebrateSubtitle(total: total))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.88))
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.holoPrimary, .holoPrimaryDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .shadow(color: Color.holoPrimary.opacity(0.32), radius: 14, x: 0, y: 6)
    }

    /// 庆祝卡副行：有次日任务时预告明天；其余时段用不绑定时间的普适句（深夜除外，改致意休息）
    private func celebrateSubtitle(total: Int) -> String {
        let tomorrowCount = tasks.filter { $0.isDueTomorrow && !$0.completed }.count
        if tomorrowCount > 0 {
            return String(localized: "共 \(total) 项全部清零 · 明天还有 \(tomorrowCount) 项等着你")
        }
        if DayPeriod.current() == .lateNight {
            return String(localized: "共 \(total) 项任务全部清零 · 夜深了，早点休息")
        }
        return String(localized: "共 \(total) 项任务全部清零 · 今天剩下的时间都是你的")
    }
}
