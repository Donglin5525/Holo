//
//  HoloIssueKicker.swift
//  Holo
//
//  刊头（2026-11-23 审美七项 P4）：一行字距拉开的「第 N 周 · 小雪」，
//  放在「我的积累」主标题上方。周数按 ISO 8601（周一为一周开始），节气见 HoloSolarTerm。
//  跨午夜不需要实时刷新，页面出现时计算即可。
//

import SwiftUI

struct HoloIssueKicker: View {
    let date: Date

    @ScaledMetric(relativeTo: .caption2) private var size = HoloIssueKickerMetrics.fontSize

    /// 周数用 ISO 8601 日历，与系统「周一为一周开始」一致
    private static let isoCalendar = Calendar(identifier: .iso8601)

    private var week: Int {
        HoloIssueKicker.isoCalendar.component(.weekOfYear, from: date)
    }

    private var term: HoloSolarTerm {
        HoloSolarTerm.current(on: date, calendar: .current)
    }

    var body: some View {
        (Text("第 \(week) 周") + Text(verbatim: " · ") + Text(term.name))
            .font(.system(size: size, weight: .semibold))
            .tracking(HoloIssueKickerMetrics.tracking)
            .foregroundStyle(Color.holoToolTextSecondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("第 \(week) 周，\(term.name)"))
    }
}

/// 刊头的局部排版尺寸。
enum HoloIssueKickerMetrics {
    static let fontSize: CGFloat = 11
    static let tracking: CGFloat = 2.2
}
