//
//  DailyKanbanEntryButton.swift
//  Holo
//
//  首页中心今日看板入口按钮
//  显示今日进度环 + 简要摘要，替代原 VoiceAssistantButton
//

import SwiftUI

struct DailyKanbanEntryButton: View {

    let action: () -> Void

    @ObservedObject private var todoRepo = TodoRepository.shared
    @ObservedObject private var habitRepo = HabitRepository.shared

    @State private var isAnimating = false

    private var kanbanProgress: (completed: Int, total: Int) {
        todoRepo.getDailyKanbanProgress()
    }

    private var habitProgress: (completed: Int, total: Int) {
        habitRepo.getTodayCheckInProgress()
    }

    private var overallPercent: Double {
        let kTotal = Double(kanbanProgress.total)
        let hTotal = Double(habitProgress.total)
        let total = kTotal + hTotal
        guard total > 0 else { return 0 }
        let done = Double(kanbanProgress.completed) + Double(habitProgress.completed)
        return done / total
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                outerRing(size: 320, opacity: 0.05)
                outerRing(size: 256, opacity: 0.1)
                mainButton
            }
            .frame(width: 192, height: 192)

            Text("今日看板")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .allowsHitTesting(false)
        }
    }

    private func outerRing(size: CGFloat, opacity: Double) -> some View {
        Circle()
            .stroke(Color.holoPrimary.opacity(opacity), lineWidth: 1)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }

    private var mainButton: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.holoPrimaryLight, .holoPrimary, .holoPrimaryDark],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.4), Color.white.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.8)

                progressContent
            }
        }
        .frame(width: 192, height: 192)
        .contentShape(Circle())
        .shadow(color: .holoPrimary.opacity(0.3), radius: 30)
        .scaleEffect(isAnimating ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isAnimating)
        .onAppear { isAnimating = true }
    }

    private var progressContent: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 6)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: overallPercent)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.6, dampingFraction: 0.7), value: overallPercent)

                Text("\(Int(overallPercent * 100))")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                + Text("%")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }

            HStack(spacing: 6) {
                labelItem(count: habitProgress.completed, total: habitProgress.total, icon: "checkmark.circle")
                labelItem(count: kanbanProgress.completed, total: kanbanProgress.total, icon: "checklist")
            }
        }
    }

    private func labelItem(count: Int, total: Int, icon: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text("\(count)/\(total)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
        }
        .foregroundColor(.white.opacity(0.8))
    }
}

#Preview {
    ZStack {
        Color.holoBackground.ignoresSafeArea()
        DailyKanbanEntryButton { }
    }
}
