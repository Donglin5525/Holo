//
//  MemoryGalleryFindDateModel.swift
//  Holo
//
//  「找日期」面板的共享模型（暖光规格 §2「找日期与打开漫步」）：
//  - 长廊顶栏按钮与日历页共用的同一展示宿主：日期选择 / 随机漫步两个面板状态互斥
//  - 漫步会话挂在模型上：面板关合不丢本轮已看集合；长廊会话结束才清空
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class MemoryGalleryFindDateModel: ObservableObject {
    enum Mode {
        case calendar
        case walk
    }

    @Published var isPresented = false
    @Published private(set) var mode: Mode = .calendar

    let walkSession = MemoryRandomWalkSession()

    /// 顶栏「找日期」：保留长廊当前位置，面板跟随当前阅读章节月份。
    func open() {
        mode = .calendar
        isPresented = true
    }

    /// 面板内切到随机漫步：就地把面板从日期选择器切到漫步，不叠第二层 sheet。
    func switchToWalk() {
        mode = .walk
        if walkSession.phase == .idle {
            walkSession.start()
        }
    }

    /// 回到日期选择（漫步关闭时若仍在面板内）。
    func switchToCalendar() {
        mode = .calendar
    }

    func dismiss() {
        walkSession.close()
        isPresented = false
        mode = .calendar
    }

    /// 长廊会话结束（页面消失）：清本轮集合。
    func endGallerySession() {
        isPresented = false
        mode = .calendar
        walkSession.resetSession()
    }
}

/// 「找日期」面板：年月切换、周一至周日、有记录标记、回到最近、随机漫步行。
struct MemoryGalleryFindDateSheet: View {
    @ObservedObject var model: MemoryGalleryFindDateModel
    let calendar: Calendar
    /// 当前聚焦日（选择器高亮）。
    let focusedDate: Date
    /// 某日记录数（已载入窗口内；nil = 无记录或未载入）。
    let recordCount: (Date) -> Int?
    /// 面板跨月时让宿主补拉该月数据。
    let ensureData: (Date) -> Void
    /// 点某天：回到长廊该天并收起面板。
    let onSelectDay: (Date) -> Void
    /// 回到最近有记录的日子（今天无记录时往前找）。
    let onBackToLatest: () -> Void
    /// 漫步里点开一条原记录（详情弹层/想法深链由宿主决定）。
    let onOpenEvent: (CalendarEvent) -> Void

    @State private var monthAnchor: Date?
    @State private var showYearMenu = false

    private var displayedMonth: Date {
        monthAnchor ?? focusedDate
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.mode == .walk {
                MemoryRandomWalkView(
                    session: model.walkSession,
                    calendar: calendar,
                    onClose: { model.dismiss() },
                    onOpenInGallery: { day in
                        onSelectDay(day)
                    },
                    onOpenEvent: onOpenEvent
                )
            } else {
                calendarPanel
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if monthAnchor == nil { monthAnchor = focusedDate }
        }
    }

    // MARK: - 日期选择面板

    private var calendarPanel: some View {
        VStack(spacing: 12) {
            monthHeader
            weekdayHeader
            dayGrid
            Divider().padding(.horizontal, 20)
            backToLatestRow
            randomWalkRow
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("memoryGallery.findDate.prevMonth")
            Spacer()
            Button {
                showYearMenu.toggle()
            } label: {
                Text(monthTitle)
                    .font(.headline)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("memoryGallery.findDate.title")
            .popover(isPresented: $showYearMenu) {
                yearMenu
            }
            Spacer()
            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("memoryGallery.findDate.nextMonth")
        }
        .padding(.horizontal, 12)
    }

    private var monthTitle: String {
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        return String(format: "%d 年 %d 月", comps.year ?? 0, comps.month ?? 0)
    }

    private var yearMenu: some View {
        VStack(spacing: 4) {
            ForEach(availableYears, id: \.self) { year in
                Button("\(String(year)) 年") {
                    if let anchor = calendar.date(bySetting: .year, value: year, of: displayedMonth) {
                        monthAnchor = calendar.startOfDay(for: anchor)
                        ensureData(monthAnchor ?? displayedMonth)
                    }
                    showYearMenu = false
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .frame(minWidth: 120)
        .presentationCompactAdaptation(.popover)
    }

    private var availableYears: [Int] {
        let thisYear = calendar.component(.year, from: Date())
        return stride(from: thisYear, through: thisYear - 6, by: -1).map { $0 }
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            monthAnchor = next
            ensureData(next)
        }
    }

    private var weekdayHeader: some View {
        // 周一首（与 CalendarRangeBuilder 同约定）
        let symbols = calendar.veryShortWeekdaySymbols
        let mondayFirst = (0..<7).map { symbols[($0 + 1) % 7] }
        return HStack {
            ForEach(mondayFirst, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
    }

    private var dayGrid: some View {
        let days = monthDays
        let startOfWeekdayIndex = { () -> Int in
            let weekday = calendar.component(.weekday, from: days.first ?? displayedMonth)
            return (weekday - 1 + 6) % 7
        }()
        let today = calendar.startOfDay(for: Date())
        let focused = calendar.startOfDay(for: focusedDate)

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
            ForEach(0..<startOfWeekdayIndex, id: \.self) { _ in
                Color.clear.frame(height: 42)
            }
            ForEach(days, id: \.self) { day in
                let startOfDay = calendar.startOfDay(for: day)
                let isFuture = startOfDay > today
                let count = recordCount(startOfDay)
                Button {
                    onSelectDay(startOfDay)
                } label: {
                    VStack(spacing: 3) {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(isFuture ? Color.secondary.opacity(0.4) : .primary)
                        Circle()
                            .fill(isFuture ? Color.clear : (count != nil ? Color.holoPrimary : Color.clear))
                            .frame(width: 4.5, height: 4.5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background {
                        if startOfDay == focused {
                            Circle()
                                .fill(Color.holoPrimary.opacity(0.14))
                                .frame(width: 36, height: 36)
                        } else if startOfDay == today {
                            Circle()
                                .strokeBorder(Color.holoPrimary.opacity(0.5), lineWidth: 1)
                                .frame(width: 34, height: 34)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isFuture)
                .accessibilityLabel(startOfDay == today ? "今天" : "")
            }
        }
        .padding(.horizontal, 20)
    }

    private var monthDays: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth) else { return [] }
        var days: [Date] = []
        var cursor = interval.start
        while cursor < interval.end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    private var backToLatestRow: some View {
        Button {
            onBackToLatest()
        } label: {
            HStack {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.subheadline)
                    .foregroundStyle(Color.holoPrimary)
                Text("回到最近")
                    .font(.subheadline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("memoryGallery.findDate.backToLatest")
    }

    /// 随机漫步行（§2：36×36 图标容器、12pt 图文间距、≥62pt 行高）。
    private var randomWalkRow: some View {
        Button {
            model.switchToWalk()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.holoPrimary.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "sparkles")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.holoPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("随机漫步")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("去一个有记录的旧日")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("memoryGallery.randomWalk")
    }
}
