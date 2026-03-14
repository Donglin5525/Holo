//
//  PopupCalendarSheet.swift
//  Holo
//
//  从底部弹出的月历抽屉 — 由日历 icon 触发
//  布局：月份导航 + 月历网格 + AI 建议占位区
//

import SwiftUI

// MARK: - PopupCalendarSheet

/// 底部抽屉式月历弹窗
/// 用户点击右上角日历 icon 时呈现
struct PopupCalendarSheet: View {
    @ObservedObject var calendarState: CalendarState
    
    /// 关闭弹窗的环境方法
    @Environment(\.dismiss) var dismiss
    
    /// 滑动偏移
    @State private var swipeOffset: CGFloat = 0
    
    /// 是否显示年月选择器
    @State private var showMonthYearPicker: Bool = false
    
    /// 网格日期
    private var gridDates: [Date] {
        CalendarGridGenerator.generateGrid(for: calendarState.currentMonth)
    }
    private var rowCount: Int { gridDates.count / 7 }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部拖拽指示条
            dragIndicator
            
            // 月份导航（含左右箭头，因为弹窗中用户期望精确导航）
            monthNavigationBar
            
            // 星期标题
            weekdayHeader
            
            // 月历网格
            calendarGrid
            
            // 上滑提示（仅在半屏时可见，引导用户展开查看 AI 区域）
            swipeUpHint
            
            // 分割线
            Divider()
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.sm)
            
            // AI 建议占位区
            aiPlaceholder
            
            Spacer(minLength: 16)
        }
        .padding(.top, 8)
        .background(Color.holoBackground)
        // 自定义高度：确保月历完整显示（~480pt 足够放下 6 行网格 + 导航 + 星期行）
        // large 可查看 AI 占位区
        .presentationDetents([.height(480), .large])
        .presentationDragIndicator(.hidden)
        // 年月快速选择器弹窗
        .sheet(isPresented: $showMonthYearPicker) {
            let cal = Calendar.current
            let year = cal.component(.year, from: calendarState.currentMonth)
            let month = cal.component(.month, from: calendarState.currentMonth)
            MonthYearPickerView(
                currentYear: year,
                currentMonth: month,
                onConfirm: { y, m in
                    calendarState.jumpToMonth(year: y, month: m)
                    showMonthYearPicker = false
                },
                onCancel: { showMonthYearPicker = false }
            )
            .presentationDetents([.height(320)])
            .presentationDragIndicator(.hidden)
        }
    }
    
    /// 上滑提示：告知用户可以继续向上滑动
    private var swipeUpHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .medium))
            Text("上滑查看 AI 洞察")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(.holoTextSecondary.opacity(0.5))
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }
    
    // MARK: - 子视图
    
    /// 顶部小横条（拖拽指示器）
    private var dragIndicator: some View {
        Capsule()
            .fill(Color.holoTextSecondary.opacity(0.3))
            .frame(width: 36, height: 4)
            .padding(.top, 8)
            .padding(.bottom, 12)
    }
    
    /// 月份导航栏（左箭头 + 标题 + 右箭头 + 今天按钮）
    private var monthNavigationBar: some View {
        HStack {
            Button { calendarState.goToPreviousMonth() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: 32)
            }
            
            Spacer()
            
            // 月份标题 — 点击弹出年月选择器
            Button { showMonthYearPicker = true } label: {
                HStack(spacing: 4) {
                    Text(CalendarDateFormatter.monthTitle(for: calendarState.currentMonth))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            Spacer()
            
            Button { calendarState.goToNextMonth() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: 32)
            }
            
            // 「今天」快捷按钮 — 非当天时高亮显示
            Button {
                calendarState.goToToday()
                dismiss()
            } label: {
                Text("今天")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(calendarState.selectedDate.isToday ? .holoTextSecondary : .holoPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(calendarState.selectedDate.isToday
                                  ? Color.holoBackground
                                  : Color.holoPrimary.opacity(0.1))
                    )
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.bottom, 8)
    }
    
    /// 星期标题行
    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(CalendarDateFormatter.weekdaySymbols, id: \.self) { sym in
                Text(sym)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.bottom, 6)
    }
    
    /// 月历网格
    private var calendarGrid: some View {
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
                                onTap: {
                                    calendarState.selectDate(day)
                                    dismiss()
                                },
                                onLongPress: {
                                    // 长按记账：先关闭弹窗，再触发快速记账
                                    dismiss()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        calendarState.longPressDate = day
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .offset(x: swipeOffset)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { swipeOffset = $0.translation.width * 0.3 }
                .onEnded { v in
                    if v.translation.width < -40 { performSwipe(forward: true) }
                    else if v.translation.width > 40 { performSwipe(forward: false) }
                    else { withAnimation(.spring(response: 0.3)) { swipeOffset = 0 } }
                }
        )
    }
    
    /// AI 建议占位区
    private var aiPlaceholder: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                
                Text("AI 洞察")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                
                Spacer()
            }
            
            VStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.holoPrimary.opacity(0.4))
                
                Text("AI 消费洞察即将上线")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.holoPrimary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.holoPrimary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    )
            )
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.md)
    }
    
    /// 月切换动画
    private func performSwipe(forward: Bool) {
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
