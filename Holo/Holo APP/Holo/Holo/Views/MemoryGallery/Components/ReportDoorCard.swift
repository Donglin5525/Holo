//
//  ReportDoorCard.swift
//  Holo
//
//  长廊洞察 Tab 的报告门卡：显示最新一份报告，点击直达 Holo AI 页报告 Tab。
//  「一个家两个门」——档案只在报告 Tab，长廊只放这扇门（数据与档案同一条查询）。
//

import SwiftUI

struct ReportDoorCard: View {
    typealias ReportArchiveDTO = ChatMessageRepository.ReportArchiveDTO

    let entry: ReportArchiveDTO
    var onOpen: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(entry.kind == .deepAnalysis ? "深度分析" : "周期回放")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(entry.kind == .deepAnalysis ? .holoPrimary : .indigo)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(
                            (entry.kind == .deepAnalysis ? Color.holoPrimary : Color.indigo).opacity(0.10),
                            in: Capsule()
                        )

                    if entry.kind == .deepAnalysis,
                       entry.scenarioTag != .general {
                        Text(entry.scenarioTag == .replay ? "回放" : entry.scenarioTag.label)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(entry.scenarioTag.badgeColors.foreground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(entry.scenarioTag.badgeColors.background, in: Capsule())
                    }

                    Text(entry.scopeLabel ?? "自定义范围")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Text(Self.dateText(entry.timestamp))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }

                if let question = entry.question {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.holoTextSecondary.opacity(0.85))
                            .padding(.top, 1.5)
                        Text(question)
                            .font(.system(size: 11.5))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(2)
                    }
                }

                if let issue = entry.issueText {
                    Text(issue)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(entry.summary ?? entry.title ?? "本周期完成了一次报告。")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("全部报告 ›")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.holoPrimary)
            }
            .padding(13)
            .background(Color.holoCardBackground, in: RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                    .stroke(Color.holoDivider.opacity(0.5), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开 Holo AI 页的报告 Tab，查看全部报告")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
