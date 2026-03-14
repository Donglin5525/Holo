//
//  ExpandedCalendarView.swift
//  Holo
//
//  下拉展开的月历网格 — 仅支持左右滑动切换月份
//

import SwiftUI

struct ExpandedCalendarView: View {
    @ObservedObject var calendarState: CalendarState
    
    @State private var swipeOffset: CGFloat = 0
    
    /// 月历网格（含上下月补位）
    private var gridDates: [Date] {
        CalendarGridGenerator.generateGrid(for: calendarState.currentMonth)
    }
    
    /// 网格行数
    private var rowCount: Int { gridDates.count / 7 }
    
    var body: some View {
        VStack(spacing: 8) {
            // 月份标题（无左右箭头，仅展示）
            Text(CalendarDateFormatter.monthTitle(for: calendarState.currentMonth))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
            
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
            
            // 月历网格（用 VStack+HStack 替代 LazyVGrid 以避免掉帧）
            VStack(spacing: 2) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in
                            let idx = row * 7 + col
                            if idx < gridDates.count {
                                let day = gridDates[idx]
                                DayCellView(
                                    date: day,
                                    summary: calendarState.dailySummaries[day.startOfDay],
                                    isSelected: day.isSameDay(as: calendarState.selectedDate),
                                    isCurrentMonth: day.isSameMonth(as: calendarState.currentMonth),
                                    style: .calendar,
                                    onTap: { calendarState.selectDate(day) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .offset(x: swipeOffset)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { swipeOffset = $0.translation.width * 0.3 }
                    .onEnded { v in
                        if v.translation.width < -40 { performMonthSwipe(forward: true) }
                        else if v.translation.width > 40 { performMonthSwipe(forward: false) }
                        else { withAnimation(.spring(response: 0.3)) { swipeOffset = 0 } }
                    }
            )
        }
        .padding(.bottom, 4)
    }
    
    /// 两阶段月切换动画
    private func performMonthSwipe(forward: Bool) {
        let slide: CGFloat = forward ? -UIScreen.main.bounds.width * 0.3 : UIScreen.main.bounds.width * 0.3
        withAnimation(.easeOut(duration: 0.15)) { swipeOffset = slide }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if forward { calendarState.goToNextMonth() }
            else { calendarState.goToPreviousMonth() }
            swipeOffset = -slide
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipeOffset = 0 }
        }
    }
}
