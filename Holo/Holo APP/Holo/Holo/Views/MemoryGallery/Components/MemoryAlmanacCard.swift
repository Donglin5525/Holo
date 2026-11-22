//
//  MemoryAlmanacCard.swift
//  Holo
//
//  记忆长廊 · 洞察 Tab 的「人生年鉴」卡（2026-11-21 取代 13 周活跃热力图）。
//  定稿 D：12 条目录式月度条（长度 = 当月记录天数占比）+ 点开某月展开每日刻度；
//  按住滑动选日 → 由外部展示「当天轨迹」。刻意不用圆点阵列，避免密集恐惧感。
//  方案：docs/_common/plans/2026-11-21-记忆长廊年鉴卡/01-方案.md
//

import SwiftUI

struct MemoryAlmanacCard: View {
    let almanac: MemoryAlmanacYear
    /// 可翻到的最早年份（开始记录那年）
    let earliestYear: Int
    let selectedDate: Date?
    let onSelectDate: (Date) -> Void
    let onChangeYear: (Int) -> Void
    /// 为 nil 时不显示分享按钮
    var onShare: (() -> Void)? = nil

    @State private var expandedMonth: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let currentYear = Calendar.current.component(.year, from: Date())
    private static let rowHeight: CGFloat = 22
    private static let labelWidth: CGFloat = 30
    private static let valueWidth: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            hero.padding(.top, HoloSpacing.xs)
            Text(subtitle)
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
                .monospacedDigit()
                .padding(.top, 2)
            months.padding(.top, HoloSpacing.md)
            legend.padding(.top, HoloSpacing.sm)
            Text(hint)
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
                .monospacedDigit()
                .padding(.top, HoloSpacing.xs)
        }
        .padding(HoloSpacing.md)
        .holoSurface(.independent)
        .onAppear { expandedMonth = almanac.currentMonth }
        .onChange(of: almanac.year) { _, _ in expandedMonth = almanac.currentMonth }
    }

    // MARK: - 刊头 / 大数字

    private var header: some View {
        HStack(spacing: 0) {
            Text(String(localized: "人生年鉴 · \(String(almanac.year))"))
                .font(.holoTinyLabel)
                .tracking(1.5)
                .foregroundStyle(Color.holoToolTextSecondary)
            Spacer(minLength: HoloSpacing.sm)
            iconButton("chevron.left", label: String(localized: "上一年"), enabled: almanac.year > earliestYear) {
                onChangeYear(almanac.year - 1)
            }
            iconButton("chevron.right", label: String(localized: "下一年"), enabled: almanac.year < currentYear) {
                onChangeYear(almanac.year + 1)
            }
            if let onShare {
                iconButton("square.and.arrow.up", label: String(localized: "分享年鉴"), enabled: true, action: onShare)
            }
        }
        .padding(.vertical, -12) // 44pt 热区不撑高刊头
    }

    private func iconButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(enabled ? Color.holoToolTextSecondary : Color.holoToolTextSecondary.opacity(0.3))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(almanac.recordedDays)")
                .font(.holoHeroNumber(size: 44))
                .foregroundStyle(Color.holoToolText)
            Text("天有记录")
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(String(almanac.year)) 年，\(almanac.recordedDays) 天有记录，共 \(almanac.totalCount) 件事"))
    }

    private var subtitle: String {
        let total = almanac.totalCount.formatted()
        if let start = almanac.startDate {
            return String(localized: "共 \(total) 件事 · 从 \(Self.monthDay(start)) 开始记录")
        }
        if let dayOfYear = almanac.dayOfYear {
            return String(localized: "共 \(total) 件事 · 今年第 \(dayOfYear) 天")
        }
        return String(localized: "共 \(total) 件事")
    }

    // MARK: - 月度条

    private var months: some View {
        VStack(spacing: 0) {
            ForEach(almanac.months) { month in
                monthRow(month)
                if expandedMonth == month.month {
                    MemoryAlmanacMonthTicks(
                        month: month,
                        selectedDate: selectedDate,
                        onSelectDate: onSelectDate
                    )
                    .padding(.leading, Self.labelWidth)
                    .padding(.vertical, HoloSpacing.xs)
                    .transition(.opacity)
                }
            }
        }
    }

    private func monthRow(_ month: MemoryAlmanacMonth) -> some View {
        Button {
            guard month.hasHappened else { return }
            let next = expandedMonth == month.month ? nil : month.month
            if reduceMotion { expandedMonth = next } else { withAnimation(HoloAnimation.standard) { expandedMonth = next } }
        } label: {
            HStack(spacing: 0) {
                Text(String(localized: "\(month.month)月"))
                    .font(.caption2)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .frame(width: Self.labelWidth, alignment: .leading)
                monthBar(month)
                Text(month.hasHappened ? String(localized: "\(month.recordedDays) 天") : "—")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(month.hasHappened ? 1 : 0.5))
                    .frame(width: Self.valueWidth, alignment: .trailing)
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!month.hasHappened)
        .accessibilityLabel(month.hasHappened
            ? String(localized: "\(month.month) 月，\(month.recordedDays) 天有记录")
            : String(localized: "\(month.month) 月，还没有记录"))
        .accessibilityHint(month.hasHappened ? String(localized: "展开查看每一天") : "")
    }

    private func monthBar(_ month: MemoryAlmanacMonth) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width - HoloSpacing.sm
            let fill = max(width * month.fillRatio, month.recordedDays > 0 ? 4 : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.holoAlmanacInk.opacity(0.1)).frame(width: width, height: 1)
                if month.hasHappened && fill > 0 {
                    Capsule().fill(Color.holoAlmanacInk.opacity(0.72)).frame(width: fill, height: 4)
                }
                if month.state == .current {
                    Circle().fill(Color.holoPrimary).frame(width: 6, height: 6).offset(x: max(fill - 3, 0))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - 图例 / 提示

    private var legend: some View {
        HStack(spacing: HoloSpacing.md) {
            Text("长条越长，这个月记得越多")
            if almanac.currentMonth != nil {   // 往年没有「今天」，不显示该图例
                HStack(spacing: 4) {
                    Circle().fill(Color.holoPrimary).frame(width: 6, height: 6)
                    Text("今天")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(Color.holoToolTextSecondary)
        .accessibilityHidden(true)
    }

    private var hint: String {
        if let date = selectedDate,
           let day = almanac.months.flatMap(\.days).first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) {
            return String(localized: "\(Self.monthDayWeekday(date)) · \(day.count) 件事")
        }
        return expandedMonth == nil
            ? String(localized: "点开某个月，查看每一天")
            : String(localized: "按住滑动，查看某一天")
    }

    // MARK: - 日期格式（DateFormatter + zh_CN，遵守编码约定）

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let monthDayWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter
    }()

    static func monthDay(_ date: Date) -> String { monthDayFormatter.string(from: date) }
    static func monthDayWeekday(_ date: Date) -> String { monthDayWeekdayFormatter.string(from: date) }
}

// MARK: - 展开的当月每日刻度

/// 一行加高的每日刻度：没记留空、3 档高度、今天橙色；点按或长按拖动选日
struct MemoryAlmanacMonthTicks: View {
    let month: MemoryAlmanacMonth
    let selectedDate: Date?
    let onSelectDate: (Date) -> Void

    /// 固定 31 槽，保证不同月份的「几号」上下对齐
    private static let slots = 31
    private static let tickHeights: [CGFloat] = [0, 8, 14, 20]
    private static let plotHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geometry in
                let size = CGSize(width: geometry.size.width, height: Self.plotHeight)
                ZStack {
                    Canvas { context, canvasSize in draw(in: &context, size: canvasSize) }
                    HoloScrubGestureOverlay { point in select(at: point.x, width: size.width) }
                        .accessibilityHidden(true)
                }
            }
            .frame(height: Self.plotHeight)
            axis
        }
        .padding(.horizontal, HoloSpacing.sm)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: HoloRadius.sm).fill(Color.holoAlmanacInk.opacity(0.04)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(month.month) 月每一天"))
        .accessibilityValue(selectedDate.map { MemoryAlmanacCard.monthDayWeekday($0) } ?? "")
        .accessibilityHint(String(localized: "上下轻扫切换日期"))
        .accessibilityAdjustableAction { direction in stepSelection(direction) }
    }

    private var axis: some View {
        GeometryReader { geometry in
            let pitch = geometry.size.width / CGFloat(Self.slots)
            ForEach([1, 10, 20, month.dayCount], id: \.self) { day in
                Text(verbatim: "\(day)")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .position(x: (CGFloat(day) - 0.5) * pitch, y: 5)
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let pitch = size.width / CGFloat(Self.slots)
        let base = size.height - 1
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: base))
        baseline.addLine(to: CGPoint(x: CGFloat(month.dayCount) * pitch, y: base))
        context.stroke(baseline, with: .color(Color.holoAlmanacInk.opacity(0.18)), lineWidth: 0.5)

        for (index, day) in month.days.enumerated() where day.kind == .today || (day.kind == .past && day.level > 0) {
            let isSelected = selectedDate.map { Calendar.current.isDate($0, inSameDayAs: day.date) } ?? false
            let height = day.kind == .today ? max(Self.tickHeights[day.level], 14) : Self.tickHeights[day.level]
            let x = (CGFloat(index) + 0.5) * pitch
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: base))
            tick.addLine(to: CGPoint(x: x, y: base - height))
            let color: Color = day.kind == .today ? .holoPrimary : Color.holoAlmanacInk.opacity(isSelected ? 1 : 0.6)
            context.stroke(tick, with: .color(color), style: StrokeStyle(lineWidth: isSelected ? 3 : 2.4, lineCap: .round))
        }
        // 选中但没记的日子：基线下方一个小墨点，告诉用户「选中了，这天没记」
        if let selectedDate, let index = month.days.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }),
           month.days[index].level == 0, month.days[index].kind == .past {
            let x = (CGFloat(index) + 0.5) * pitch
            context.fill(Path(ellipseIn: CGRect(x: x - 2, y: base - 5, width: 4, height: 4)), with: .color(Color.holoAlmanacInk))
        }
    }

    private func select(at x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let index = min(max(Int(x / width * CGFloat(Self.slots)), 0), Self.slots - 1)
        guard month.days.indices.contains(index), month.days[index].isSelectable else { return }
        let date = month.days[index].date
        if let selectedDate, Calendar.current.isDate(selectedDate, inSameDayAs: date) { return }
        onSelectDate(date)
    }

    private func stepSelection(_ direction: AccessibilityAdjustmentDirection) {
        let selectable = month.days.filter(\.isSelectable)
        guard !selectable.isEmpty else { return }
        let current = selectedDate.flatMap { date in selectable.firstIndex { Calendar.current.isDate($0.date, inSameDayAs: date) } }
        let next: Int
        switch direction {
        case .increment: next = min((current ?? -1) + 1, selectable.count - 1)
        case .decrement: next = max((current ?? selectable.count) - 1, 0)
        @unknown default: return
        }
        onSelectDate(selectable[next].date)
    }
}
