//
//  ReportEmptyStateView.swift
//  Holo
//
//  报告 Tab 空态 = 能力橱窗：无已完成报告且无生成中任务时展示。
//  新用户第一次进 AI 页即完成能力教育（治「能力不可见」）。
//

import SwiftUI

struct ReportEmptyStateView: View {
    var onLaunch: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                Text("Holo 能为你写的报告")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundColor(.holoTextPrimary)
                    .padding(.top, 14)

                Text("报告会随使用越来越厚——它记下的每一步，\n都会成为下一份报告的证据。")
                    .font(.system(size: 12.5))
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                capabilityCard(
                    icon: "sparkles",
                    tint: .holoPrimary,
                    title: "深度分析",
                    subtitle: "把你的财务、习惯、任务、想法放在一起看，找出单看一处发现不了的规律。"
                )

                capabilityCard(
                    icon: "play.rectangle.fill",
                    tint: .indigo,
                    title: "周期回放",
                    subtitle: "每周 / 每月一次对账：说好的事做了没、计划偏了多少，数据说了算。"
                )

                // 示例摘录：让「报告长什么样」可感知
                VStack(alignment: .leading, spacing: 7) {
                    Text("报告长这样（示例）")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .tracking(1)

                    Text("「连续三周晚间支出上扬，与加班周期高度吻合；运动日夜间外卖频次是非运动日的 2.4 倍。」")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.35))
                        .lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(Color.holoCardBackground, in: RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                        .stroke(Color.holoDivider.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )

                Button {
                    onLaunch()
                } label: {
                    Text("去对话发起我的第一份分析")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.holoPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                Text("会帮你打开分析场景目录，选一个场景即可发起")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary.opacity(0.9))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
    }

    private func capabilityCard(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(.holoTextPrimary)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.holoCardBackground, in: RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .stroke(Color.holoDivider.opacity(0.5), lineWidth: 0.8)
        )
    }
}
