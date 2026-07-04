//
//  WeeklyGridView.swift
//  Holo
//
//  周历网格视图（P2）：7 列 × 24h 时间轴，事件按 timestamp 定位
//

import SwiftUI

struct WeeklyGridView: View {
    let weekStart: Date                      // 周一首
    let eventsByDay: [Date: [CalendarEvent]]
    let onSelect: (CalendarEvent) -> Void

    private let hourHeight: CGFloat = 44

    var body: some View {
        ScrollView(showsIndicators: false) {
            HStack(alignment: .top, spacing: 4) {
                timeAxis
                ForEach(0..<7, id: \.self) { dayOffset in
                    dayColumn(dayOffset)
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, HoloSpacing.lg)
        }
    }

    private var timeAxis: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                Text(h % 6 == 0 ? "\(h)" : "")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 24, height: hourHeight, alignment: .topTrailing)
            }
        }
    }

    @ViewBuilder
    private func dayColumn(_ dayOffset: Int) -> some View {
        let cal = Calendar.current
        if let day = cal.date(byAdding: .day, value: dayOffset, to: weekStart) {
            let events = eventsByDay[cal.startOfDay(for: day)] ?? []
            ZStack(alignment: .topLeading) {
                gridBackground
                ForEach(events) { event in
                    gridEventBlock(event)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var gridBackground: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: hourHeight)
                    .overlay(
                        Rectangle().fill(Color.holoDivider).frame(height: 0.5),
                        alignment: .top
                    )
            }
        }
    }

    private func gridEventBlock(_ event: CalendarEvent) -> some View {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: event.date)
        let topOffset = CGFloat(comps.hour ?? 0) * hourHeight
            + CGFloat(comps.minute ?? 0) / 60.0 * hourHeight
        return Button {
            onSelect(event)
        } label: {
            Text(event.title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 18)
                .background(event.module.color)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 1)
        }
        .buttonStyle(.plain)
        .offset(y: topOffset)
    }
}
