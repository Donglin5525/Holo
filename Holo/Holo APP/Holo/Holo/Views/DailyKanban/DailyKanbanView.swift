//
//  DailyKanbanView.swift
//  Holo
//
//  今日看板主视图 — 融合财务/健康/打卡/待办/心情五大模块
//

import SwiftUI

struct DailyKanbanView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var todoRepo = TodoRepository.shared
    @ObservedObject private var habitRepo = HabitRepository.shared
    @ObservedObject private var healthRepo = HealthRepository.shared

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    headerView
                    KanbanProgressHero(
                        todoRepo: todoRepo,
                        habitRepo: habitRepo,
                        healthRepo: healthRepo
                    )
                    KanbanBudgetSection()
                    KanbanHabitSection(habitRepo: habitRepo)
                    KanbanTaskSection(todoRepo: todoRepo)
                    KanbanMoodSection()
                    KanbanHealthSection(healthRepo: healthRepo)
                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, 16)
            }
        }
        .swipeBackToDismiss { dismiss() }
        .task {
            await healthRepo.fetchTodayData()
            habitRepo.loadActiveHabits()
            todoRepo.seedDailyRitualsForToday()
        }
    }

    private var headerView: some View {
        ZStack {
            Text("今日看板")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.holoCardBackground)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.holoBorder, lineWidth: 1))
                }

                Spacer()

                Text(todayString)
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.holoPrimaryLight)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
    }

    private var todayString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 E"
        return f.string(from: Date())
    }
}

#Preview {
    DailyKanbanView()
}
