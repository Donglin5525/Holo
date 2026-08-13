//
//  KanbanProgressHero.swift
//  Holo
//
//  看板顶部进度汇总卡片
//

import SwiftUI

struct KanbanProgressHero: View {

    @ObservedObject var todoRepo: TodoRepository
    @ObservedObject var habitRepo: HabitRepository
    @ObservedObject var healthRepo: HealthRepository
    let userName: String
    @ObservedObject private var displaySettings = HabitStatsDisplaySettings.shared

    /// 今日支出：nil = 加载中/失败，统一显示占位符，避免误导成「¥0=没花钱」
    @State private var todayExpense: Decimal? = nil
    @State private var hasLoadedExpense: Bool = false

    private var taskProgress: (completed: Int, total: Int) {
        todoRepo.getDailyKanbanProgress()
    }

    private var habitProgress: (completed: Int, total: Int) {
        let visibleIds = displaySettings.dashboardVisibleHabitIds
        return habitRepo.getTodayCheckInProgress(
            visibleHabitIds: visibleIds.isEmpty ? nil : visibleIds
        )
    }

    private var overallPercent: Double {
        let total = Double(taskProgress.total + habitProgress.total)
        guard total > 0 else { return 0 }
        return Double(taskProgress.completed + habitProgress.completed) / total
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HoloRadius.xl)
                .fill(
                    LinearGradient(
                        colors: [.holoPrimary, .holoPrimaryDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .holoPrimary.opacity(0.25), radius: 16, y: 8)

            VStack(spacing: 14) {
                HStack(spacing: 16) {
                    progressRing
                    progressInfo
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                }

                progressBar

                HStack(spacing: 0) {
                    statItem(value: habitProgressText, label: "打卡")
                    statItem(value: taskProgressText, label: "待办")
                    statItem(value: sleepText, label: "睡眠")
                    statItem(value: expenseText, label: "今日支出").frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .task {
            await loadTodayExpense()
        }
    }

    private var progressRing: some View {
        Color.clear
            .frame(width: 64, height: 64)
            .overlay {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 5)

                    Circle()
                        .trim(from: 0, to: overallPercent)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: overallPercent)

                    Text("\(Int(overallPercent * 100))%")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
    }

    private var progressInfo: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(greetingMessage)
                .font(.holoCaption)
                .foregroundColor(.white.opacity(0.7))
            Text(progressMessage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Text(goalContributionMessage)
                .font(.holoTinyLabel)
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.white)
                    .frame(width: geo.size.width * overallPercent, height: 4)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: overallPercent)
            }
        }
        .frame(height: 4)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.holoTinyLabel)
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Computed Values

    private var greetingMessage: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 6 { return "夜深了" }
        if hour < 12 { return "早上好，\(displayName)" }
        if hour < 18 { return "下午好，\(displayName)" }
        return "晚上好，\(displayName)"
    }

    private var displayName: String {
        UserDisplayNameSettings.normalizedDisplayName(userName)
            ?? UserDisplayNameSettings.fallbackDisplayName
    }

    private var progressMessage: String {
        let pct = Int(overallPercent * 100)
        if pct == 100 { return "全部完成！" }
        if pct >= 75 { return "就快完成了，加油！" }
        if pct >= 50 { return "已过半，继续保持" }
        if pct > 0 { return "迈出了第一步" }
        return "开始美好的一天"
    }

    /// 目标贡献文案：今天做的事有多少关联着目标
    private var goalContributionMessage: String {
        let hasGoals = !GoalRepository.shared.activeGoalsForAI(limit: 1).isEmpty
        if !hasGoals {
            return "设个目标，让每天的忙碌有方向 →"
        }
        let c = TodoRepository.shared.getTodayGoalContribution()
        let total = c.taskCount + c.habitCount
        if total == 0 {
            let anyProgress = taskProgress.completed + habitProgress.completed
            return anyProgress == 0
                ? "开始今天的第一件事，或为你的目标迈一步"
                : "今天还没有行动落在目标上"
        }
        return "\(total)件事在为目标添砖加瓦"
    }

    private var habitProgressText: String {
        "\(habitProgress.completed)/\(habitProgress.total)"
    }

    private var taskProgressText: String {
        "\(taskProgress.completed)/\(taskProgress.total)"
    }

    private var sleepText: String {
        let hours = healthRepo.todaySleep
        return String(format: "%.1fh", hours)
    }

    private var expenseText: String {
        guard hasLoadedExpense, let todayExpense else { return "--" }
        return NumberFormatter.currency.string(from: NSDecimalNumber(decimal: todayExpense)) ?? "¥0"
    }

    /// 拉取今日支出总额（与 KanbanBudgetSection 同一数据源：今日 0 点 ~ 次日 0 点的支出交易）
    private func loadTodayExpense() async {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date()
        do {
            let transactions = try await FinanceRepository.shared.getTransactions(from: start, to: end)
            todayExpense = transactions
                .filter { $0.transactionType == .expense }
                .reduce(Decimal.zero) { $0 + ($1.amount as Decimal) }
        } catch {
            todayExpense = nil
        }
        hasLoadedExpense = true
    }
}
