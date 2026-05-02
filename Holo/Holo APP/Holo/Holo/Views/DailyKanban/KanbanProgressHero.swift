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

    private var taskProgress: (completed: Int, total: Int) {
        todoRepo.getDailyKanbanProgress()
    }

    private var habitProgress: (completed: Int, total: Int) {
        habitRepo.getTodayCheckInProgress()
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
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 5)
                .frame(width: 64, height: 64)

            Circle()
                .trim(from: 0, to: overallPercent)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 64, height: 64)
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.7), value: overallPercent)

            Text("\(Int(overallPercent * 100))%")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.white)
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
        if hour < 12 { return "早上好，东林" }
        if hour < 18 { return "下午好，东林" }
        return "晚上好，东林"
    }

    private var progressMessage: String {
        let pct = Int(overallPercent * 100)
        if pct == 100 { return "全部完成！" }
        if pct >= 75 { return "就快完成了，加油！" }
        if pct >= 50 { return "已过半，继续保持" }
        if pct > 0 { return "迈出了第一步" }
        return "开始美好的一天"
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
        "¥--"
    }
}
