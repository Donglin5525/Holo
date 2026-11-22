//
//  MemoryAlmanacGallerySamples.swift
//  Holo
//
//  图表验收样板页（-HoloChartGallery -HoloChartGalleryTab=9）的「年鉴」样板（样板 0 为「我的积累」紧凑版）：
//  合成数据、不写业务库。覆盖满年 / 选中某天 / 新用户（最惨稀疏态）/ 往年 / 分享图。
//

import SwiftUI

struct MemoryAlmanacGallerySamples: View {
    @State private var selectedDate: Date?

    private static let calendar = Calendar.current
    private static let today = date(2026, 11, 21)

    /// 无头走查：-HoloAlmanacSample=N 只显示第 N 个样板（模拟器命令行无法滚动长页）
    private static let only: Int? = ProcessInfo.processInfo.arguments
        .first { $0.hasPrefix("-HoloAlmanacSample=") }
        .flatMap { $0.split(separator: "=").last.flatMap { Int($0) } }

    private func shows(_ index: Int) -> Bool { Self.only == nil || Self.only == index }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if shows(0) { full }
            if shows(1) { newUser }
            if shows(2) { past }
            if shows(3) { share }
            if shows(4) { taskRhythm }
        }
        .onAppear {
            // 样板 0 预选 11 月 18 日，直接看到选中态
            if Self.only == 0 { selectedDate = Self.date(2026, 11, 18) }
        }
    }

    @ViewBuilder private var full: some View {
            caption("满年 · 2026-11-21")
            MemoryAlmanacCard(
                almanac: Self.fullYear, earliestYear: 2025, selectedDate: selectedDate,
                onSelectDate: { selectedDate = $0 }, onChangeYear: { _ in }, onShare: {},
                showsHero: false, onOpenDay: { _ in }
            )
    }

    @ViewBuilder private var newUser: some View {
            caption("新用户 · 11 月 19 日开始")
            MemoryAlmanacCard(
                almanac: Self.newUser, earliestYear: 2026, selectedDate: nil,
                onSelectDate: { _ in }, onChangeYear: { _ in }, onShare: {}
            )
    }

    @ViewBuilder private var past: some View {
            caption("往年 · 2025")
            MemoryAlmanacCard(
                almanac: Self.pastYear, earliestYear: 2025, selectedDate: nil,
                onSelectDate: { _ in }, onChangeYear: { _ in }
            )
    }

    @ViewBuilder private var share: some View {
            caption("分享图 · 1080×1920 等比缩小")
            MemoryAlmanacShareCard(almanac: Self.fullYear)
                .scaleEffect(0.8, anchor: .topLeading)
                .frame(width: MemoryAlmanacShareCard.canvasSize.width * 0.8,
                       height: MemoryAlmanacShareCard.canvasSize.height * 0.8, alignment: .topLeading)
    }

    /// 任务「完成节奏」近 12 周：HoloHeatmap.dots
    @ViewBuilder private var taskRhythm: some View {
            caption("任务 · 完成节奏 · 近 12 周（.dots）")
            HoloHeatmap(days: Self.taskDays, weekdayLabels: ["一", "", "三", "", "五", "", ""], style: .dots)
                .padding(HoloSpacing.md)
                .holoSurface(.independent)
    }

    private static let taskDays: [HoloHeatmapDay] = {
        let now = calendar.startOfDay(for: Date())
        let weekStart = now.startOfWeek
        let start = weekStart.addingWeeks(-11)
        let counts = sampleCounts(year: calendar.component(.year, from: start), through: now)
            .merging(sampleCounts(year: calendar.component(.year, from: now), through: now)) { a, _ in a }
        return (0..<84).map { offset in
            let day = start.addingDays(offset).startOfDay
            return HoloHeatmapDay(date: day, count: (counts[day] ?? 0) / 2, isFuture: day > now)
        }
    }()

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).font(.caption).foregroundStyle(Color.holoToolTextSecondary)
    }

    // MARK: - 合成数据（确定性伪随机：春节、八月出行两段空档）

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    private static func sampleCounts(year: Int, through end: Date) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        var day = date(year, 1, 1)
        while day <= end {
            let comps = calendar.dateComponents([.month, .day, .weekday], from: day)
            let month = comps.month ?? 1, dom = comps.day ?? 1, weekday = comps.weekday ?? 2
            var chance = (weekday == 1 || weekday == 7) ? 72 : 86
            if month == 2 && (13...22).contains(dom) { chance = 12 }
            if month == 8 && (3...12).contains(dom) { chance = 8 }
            let seed = (year * 10_000 + month * 100 + dom) &* 2_654_435_761
            let roll = Int(UInt32(truncatingIfNeeded: seed) % 100)
            if roll < chance { counts[day] = 1 + Int(UInt32(truncatingIfNeeded: seed >> 7) % 9) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return counts
    }

    static let fullYear = MemoryAlmanacBuilder.build(
        year: 2026, dayCounts: sampleCounts(year: 2026, through: today),
        today: today, firstRecordDate: date(2025, 3, 1)
    )
    static let newUser = MemoryAlmanacBuilder.build(
        year: 2026, dayCounts: [date(2026, 11, 19): 2, date(2026, 11, 20): 1, date(2026, 11, 21): 3],
        today: today, firstRecordDate: date(2026, 11, 19)
    )
    static let pastYear = MemoryAlmanacBuilder.build(
        year: 2025, dayCounts: sampleCounts(year: 2025, through: date(2025, 12, 31)),
        today: today, firstRecordDate: date(2025, 3, 1)
    )
}
