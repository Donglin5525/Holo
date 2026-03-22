//
//  HabitRankingCard.swift
//  Holo
//
//  习惯排行榜卡片组件
//  显示 TOP 5 完成率最高的习惯
//

import SwiftUI

// MARK: - HabitRankingCard

/// 习惯排行榜卡片
struct HabitRankingCard: View {
    let ranking: [HabitRankingItem]

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            HStack {
                Text("习惯排行榜")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text("TOP 5")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.holoBackground)
                    .clipShape(Capsule())
            }

            if ranking.isEmpty {
                emptyView
            } else {
                rankingList
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 排行榜列表

    private var rankingList: some View {
        VStack(spacing: HoloSpacing.sm) {
            ForEach(ranking.indices, id: \.self) { index in
                let item = ranking[index]
                rankingRow(rank: index + 1, item: item)
            }
        }
    }

    // MARK: - 排行榜行

    private func rankingRow(rank: Int, item: HabitRankingItem) -> some View {
        HStack(spacing: HoloSpacing.md) {
            // 排名
            Text("\(rank)")
                .font(.holoCaption)
                .foregroundColor(rank <= 3 ? medalColor(for: rank) : .holoTextSecondary)
                .frame(width: 24)

            // 图标
            Image(systemName: item.icon)
                .font(.system(size: 20))
                .foregroundColor(item.habitColor)
                .frame(width: 32, height: 32)
                .background(item.habitColor.opacity(0.15))
                .clipShape(Circle())

            // 名称和连续天数
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)

                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.holoPrimary)

                    Text("\(item.streak) 天")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }

            Spacer()

            // 完成率
            Text(String(format: "%.0f%%", item.completionRate))
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
        }
        .padding(.vertical, HoloSpacing.xs)
    }

    private func medalColor(for rank: Int) -> Color {
        switch rank {
        case 1: return .holoChart1  // 金色
        case 2: return .holoChart2  // 银色
        case 3: return .holoChart3  // 铜色
        default: return .holoTextSecondary
        }
    }

    // MARK: - 空状态

    private var emptyView: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "trophy")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无习惯数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }
}
