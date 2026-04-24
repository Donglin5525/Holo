//
//  WeekView.swift
//  Holo
//
//  周视图 — 展示当前一周 7 天的日期与金额摘要
//  支持左右滑动切换上/下周
//

import SwiftUI

struct WeekView: View {
    @ObservedObject var calendarState: CalendarState
    
    /// 滑动偏移量（手指跟随）
    @State private var swipeOffset: CGFloat = 0
    
    /// 当前周的 7 天
    private var weekDays: [Date] {
        CalendarGridGenerator.generateWeekDays(from: calendarState.currentWeekStart)
    }
    
    var body: some View {
        VStack(spacing: 6) {
            // 星期标题行
            HStack(spacing: 0) {
                ForEach(CalendarDateFormatter.weekdaySymbols, id: \.self) { sym in
                    Text(sym)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
            
            // 日期行（带左右滑动）
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    DayCellView(
                        date: day,
                        summary: calendarState.dailySummaries[day.startOfDay],
                        isSelected: day.isSameDay(as: calendarState.selectedDate),
                        isCurrentMonth: day.isSameMonth(as: calendarState.currentMonth),
                        style: .week,
                        onTap: { calendarState.selectDate(day) }
                    )
                }
            }
            .padding(.horizontal, 4)
            .offset(x: swipeOffset)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { swipeOffset = $0.translation.width * 0.3 }
                    .onEnded { v in
                        let threshold: CGFloat = 40
                        if v.translation.width < -threshold {
                            performWeekSwipe(forward: true)
                        } else if v.translation.width > threshold {
                            performWeekSwipe(forward: false)
                        } else {
                            withAnimation(.spring(response: 0.3)) { swipeOffset = 0 }
                        }
                    }
            )
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
    
    /// 两阶段动画：快速滑出 → 更新数据 → 弹入
    private func performWeekSwipe(forward: Bool) {
        let slideOut: CGFloat = forward ? -UIScreen.main.bounds.width * 0.3 : UIScreen.main.bounds.width * 0.3
        withAnimation(.easeOut(duration: 0.15)) { swipeOffset = slideOut }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if forward { calendarState.goToNextWeek() }
            else { calendarState.goToPreviousWeek() }
            swipeOffset = -slideOut
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipeOffset = 0 }
        }
    }
}
