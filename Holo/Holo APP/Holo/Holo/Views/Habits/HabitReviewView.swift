//
//  HabitReviewView.swift
//  Holo
//
//  回顾 · 整体首页（V2 §6）：一个月份、两个覆盖摘要、一份结果列表。
//  不默认钻入单习惯、不内嵌图表、无旧全局报表入口；
//  点一行进入该习惯的回顾（继承月份，容器路由承载）。
//

import SwiftUI

struct HabitReviewView: View {

    @ObservedObject var model: HabitModuleViewModel
    /// 点某习惯行 → 单习惯回顾
    var onOpenSingle: (UUID) -> Void

    // MARK: 弹层状态

    @State private var showMonthPicker = false
    @State private var showMetricInfo = false

    private var snapshot: HabitReviewOverviewSnapshot? { model.reviewOverview }

    private var isCurrentMonth: Bool {
        let calendar = Calendar.current
        let current = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return calendar.isDate(model.overviewMonth, equalTo: current, toGranularity: .month)
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HoloSpacing.sm) {
                if model.reviewLoadFailed {
                    loadFailedState
                } else if let snapshot {
                    monthNav
                    scopeLine
                    if !isCurrentMonth {
                        backToCurrentMonth
                    }
                    summaryCards(snapshot)

                    if model.visibleIdsForReview == [] {
                        allHiddenState
                    } else if snapshot.rows.isEmpty {
                        monthEmptyState
                    } else {
                        resultList(snapshot)
                    }
                } else if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.xs)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showMonthPicker) { monthPicker }
        .sheet(isPresented: $showMetricInfo) { metricInfo }
    }

    // MARK: 月份导航

    private var canGoNextMonth: Bool { !isCurrentMonth }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("yyyy年M月")
        return formatter.string(from: model.overviewMonth)
    }

    private var monthNav: some View {
        HStack {
            Button {
                moveMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoToolText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "上一个月")))

            Spacer()

            Button {
                showMonthPicker = true
            } label: {
                Text(monthTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.holoToolText)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("habit.review.monthTitle")

            Spacer()

            Button {
                moveMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(canGoNextMonth ? .holoToolText : .holoToolTextSecondary.opacity(0.35))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNextMonth)
            .accessibilityLabel(Text(String(localized: "下一个月")))
        }
    }

    private func moveMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: model.overviewMonth) else { return }
        model.setOverviewMonth(next)
    }

    // MARK: 范围行（截至X日 · 全部习惯/已选N项 + 口径说明入口）

    private var scopeLine: some View {
        HStack(spacing: 4) {
            Text(cutoffText)
            Text("·")
            Text(scopeText)
                .foregroundColor(.holoToolText)
        }
        .font(.system(size: 11))
        .foregroundColor(.holoToolTextSecondary)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            Button {
                showMetricInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary.opacity(0.7))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "查看统计口径")))
        }
        .padding(.bottom, 6)
    }

    /// 本月截止今天；过去月是完整月份
    private var cutoffText: String {
        if isCurrentMonth {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.setLocalizedDateFormatFromTemplate("M月d日")
            return String(localized: "截至\(formatter.string(from: Date()))")
        }
        return String(localized: "完整月份")
    }

    private var scopeText: String {
        // 用投影快照算好的数量；直接插值 visibleIdsForReview（[UUID]）会打出 ID 串
        if let count = snapshot?.visibleCount {
            return String(localized: "已选 \(count) 项")
        }
        return String(localized: "全部习惯")
    }

    private var backToCurrentMonth: some View {
        Button {
            model.setOverviewMonth(Date())
        } label: {
            Text(String(localized: "回到本月"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoPrimary)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .padding(.top, -6)
        .frame(maxWidth: .infinity)
    }

    // MARK: 两个覆盖摘要

    private func summaryCards(_ snapshot: HabitReviewOverviewSnapshot) -> some View {
        HStack(spacing: 0) {
            summaryCell(
                value: "\(snapshot.activeRecordDays)",
                unit: String(localized: "天"),
                title: String(localized: "有记录的日子"))
            Rectangle().fill(Color.holoToolBorder.opacity(0.5)).frame(width: 0.5, height: 44)
            summaryCell(
                value: "\(snapshot.recordedHabitCount)",
                unit: String(localized: "项"),
                title: String(localized: "留下记录的习惯"))
        }
        .padding(.vertical, 18)
        .overlay(alignment: .top) { separator }
        .overlay(alignment: .bottom) { separator }
    }

    private func summaryCell(value: String, unit: String, title: String) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .medium).monospacedDigit())
                    .foregroundColor(.holoToolText)
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
            }
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var separator: some View {
        Rectangle().fill(Color.holoToolBorder.opacity(0.5)).frame(height: 0.5)
    }

    // MARK: 结果列表

    private func resultList(_ snapshot: HabitReviewOverviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "每个习惯的积累"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.holoToolTextSecondary)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ForEach(snapshot.rows) { row in
                reviewRow(row)
            }

            Text(String(localized: "暂停与归档保留历史。这里统计的是留下的记录。"))
                .font(.system(size: 10))
                .foregroundColor(.holoToolTextSecondary.opacity(0.8))
                .padding(.top, 14)
        }
    }

    private func reviewRow(_ row: HabitReviewRowSnapshot) -> some View {
        Button {
            onOpenSingle(row.id)
        } label: {
            HStack(spacing: 12) {
                rowIcon(row)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(row.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.holoToolText)
                            .lineLimit(1)
                        if row.lifecycle != .active {
                            Text(row.lifecycle == .paused
                                 ? String(localized: "当前已暂停")
                                 : String(localized: "当前已归档"))
                                .font(.system(size: 10))
                                .foregroundColor(.holoToolTextSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.holoToolBorder.opacity(0.7)))
                        }
                    }
                    Text(row.resultText)
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary.opacity(0.6))
            }
            .padding(.vertical, 12)
            .frame(minHeight: 68)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { separator }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("habit.review.row.\(row.id)")
        .accessibilityLabel(Text("\(row.name)，\(row.resultText)"))
    }

    private func rowIcon(_ row: HabitReviewRowSnapshot) -> some View {
        let color = Color(hex: row.colorHex)
        return row.iconImage(size: 18)
            .foregroundColor(color)
            .frame(width: 37, height: 37)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.opacity(0.12)))
    }

    // MARK: 空状态与失败态

    private var allHiddenState: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "eye.slash")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(.holoPrimary.opacity(0.7))
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 17).fill(Color.holoToolInset))
            Text(String(localized: "你关闭了所有展示项"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.holoToolText)
            Text(String(localized: "记录依然保留，可以调整回顾的展示范围。"))
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var monthEmptyState: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "calendar")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(.holoPrimary.opacity(0.7))
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 17).fill(Color.holoToolInset))
            Text(String(localized: "这个月还没有记录"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.holoToolText)
            Text(String(localized: "可以切换月份，或从今天开始记录。"))
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
            Button {
                model.selectedTab = .today
            } label: {
                Text(String(localized: "去今天记录"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Color.holoToolAction))
            }
            .buttonStyle(HoloPressStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var loadFailedState: some View {
        VStack(spacing: HoloSpacing.md) {
            Text(String(localized: "加载没有成功"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.holoToolText)
            Text(String(localized: "记录保持原样，请重试。"))
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
            Button {
                model.refresh()
            } label: {
                Text(String(localized: "重试"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Color.holoToolAction))
            }
            .buttonStyle(HoloPressStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: 月份选择弹层（本月 + 前 5 个月）

    private var monthPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "选择月份"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.holoToolText)
                .padding(.bottom, 4)
            Text(String(localized: "进入单习惯会继承这一个月。"))
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
                .padding(.bottom, 10)

            ForEach(availableMonths, id: \.self) { month in
                Button {
                    model.setOverviewMonth(month)
                    showMonthPicker = false
                } label: {
                    HStack {
                        Text(monthText(month))
                            .font(.system(size: 14))
                            .foregroundColor(.holoToolText)
                        Spacer()
                        if Calendar.current.isDate(month, equalTo: model.overviewMonth, toGranularity: .month) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.holoPrimary)
                        }
                    }
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) { separator }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.md)
        .presentationDetents([.height(430)])
    }

    private var availableMonths: [Date] {
        let calendar = Calendar.current
        let current = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return (0..<6).compactMap {
            calendar.date(byAdding: .month, value: -$0, to: current)
        }
    }

    private func monthText(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("yyyy年M月")
        return formatter.string(from: month)
    }

    // MARK: 口径说明弹层

    private var metricInfo: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text(String(localized: "这些数字代表什么"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.holoToolText)
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "有记录的日子：所选习惯在这个月留下过记录的不同日期。同一天记录多个习惯，也只算一天。"))
                Text(String(localized: "留下记录的习惯：这个月有记录的不同习惯，同一习惯多条记录仍算一项。"))
                Text(String(localized: "这些是记录覆盖，不是目标达成率。隐藏展示项后，摘要与列表一起改变范围。"))
            }
            .font(.system(size: 12))
            .foregroundColor(.holoToolTextSecondary)
            .lineSpacing(4)
            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.lg)
        .presentationDetents([.height(330)])
    }
}
