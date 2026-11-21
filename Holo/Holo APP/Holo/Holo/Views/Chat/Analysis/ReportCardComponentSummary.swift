//
//  ReportCardComponentSummary.swift
//  Holo
//
//  对话结果卡里的组件摘要（2026-11-20 报告改版 B 期）：
//  只取「一眼看出好不好」的两样——进度（或数字卡）+ 关联事项状态标签（≤4 个），
//  细节留给详情页。没有组件时不渲染，卡片保持 A 期的纯文字形态。
//

import SwiftUI

struct ReportCardComponentSummary: View {
    let components: [HoloReportComponent]

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 10) {
                if let progress {
                    compactProgress(progress)
                } else if let tiles {
                    ReportKPITilesView(tiles: Array(tiles.tiles.prefix(3)))
                }
                if !habitRows.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(Array(habitRows.enumerated()), id: \.offset) { _, row in
                            HStack {
                                Text(row.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(.holoTextPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if let status = row.statusLabel {
                                    ReportStatusChip(text: status, tone: row.tone ?? .neutral)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.holoTextSecondary.opacity(0.05)))
                        }
                    }
                }
            }
        }
    }

    private var hasContent: Bool {
        progress != nil || tiles != nil || !habitRows.isEmpty
    }

    private var progress: HoloReportComponent.Progress? {
        components.lazy.compactMap { component -> HoloReportComponent.Progress? in
            if case .progress(let p) = component.payload { return p }
            return nil
        }.first
    }

    private var tiles: HoloReportComponent.KPITiles? {
        components.lazy.compactMap { component -> HoloReportComponent.KPITiles? in
            if case .kpiTiles(let p) = component.payload, !p.tiles.isEmpty { return p }
            return nil
        }.first
    }

    private var habitRows: [HoloReportComponent.HabitStrip.Row] {
        let rows = components.flatMap { component -> [HoloReportComponent.HabitStrip.Row] in
            if case .habitStrip(let p) = component.payload { return p.rows }
            return []
        }
        return Array(rows.prefix(4))
    }

    private func compactProgress(_ progress: HoloReportComponent.Progress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let current = progress.current {
                    Text("当前 ")
                        .font(.system(size: 11.5))
                        .foregroundColor(.holoTextSecondary)
                    + Text(ReportProgressView.format(current))
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundColor(.holoTextPrimary)
                    + Text(progress.unit.map { " \($0)" } ?? "")
                        .font(.system(size: 11.5))
                        .foregroundColor(.holoTextSecondary)
                } else {
                    Text(progress.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
                ReportStatusChip(text: progress.statusLabel, tone: progress.tone ?? .neutral)
            }
            if progress.fraction != nil || progress.timeFraction != nil {
                ReportProgressBar(fraction: progress.fraction, timeFraction: progress.timeFraction,
                                  isStale: progress.isStale == true, height: 8)
                HStack {
                    if let fraction = progress.fraction {
                        Text("进度 \(ReportProgressView.percent(fraction))")
                    }
                    Spacer()
                    if let time = progress.timeFraction {
                        Text("▍时间已过 \(ReportProgressView.percent(time))")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundColor(.holoTextSecondary)
            }
        }
    }
}
