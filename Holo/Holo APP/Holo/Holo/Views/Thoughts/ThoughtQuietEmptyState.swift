//
//  ThoughtQuietEmptyState.swift
//  Holo
//
//  想法列表的空态（2026-11-23 审美七项 P5）：一句话留白，不放图标与描边胶囊。
//  空态按语境区分：搜索/筛选无结果保留原文案只引导换关键词/换范围；
//  真·零想法才给「记一条想法」入口（右下 FAB 是本屏唯一橙主行动，链接退为墨色）。
//

import SwiftUI

/// 想法列表空态（ThoughtListView 专用，从列表文件拆出守住行数闸门）
struct ThoughtQuietEmptyState: View {
    /// 搜索框有关键词
    let isSearching: Bool
    /// 命中标签 / 筛选 / 主题范围（非搜索）
    let isFiltering: Bool
    /// 记一条想法入口（仅真·零想法分支显示）
    let onRecord: () -> Void
    /// 首次 iCloud 同步未完成时显示恢复提示
    let showsRestoreHint: Bool

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            if isSearching {
                HoloQuietEmptyState(
                    line: "没有找到相关想法",
                    byline: Self.byline(String(localized: "换个关键词试试")),
                    topSpacing: .flexible
                )
            } else if isFiltering {
                HoloQuietEmptyState(
                    line: "该范围内暂无想法",
                    byline: Self.byline(String(localized: "换个范围，或清空筛选再看看")),
                    topSpacing: .flexible
                )
            } else {
                HoloQuietEmptyState(
                    line: "念头来得快，\n走得也快。",
                    byline: "— 抓住一个",
                    actionTitle: "记一条想法",
                    actionStyle: .ink,
                    action: onRecord,
                    actionIdentifier: "thoughtEmptyCta",
                    topSpacing: .flexible
                )
            }

            if showsRestoreHint {
                Text("正在从 iCloud 恢复数据，稍等片刻就会显示")
                    .font(ThoughtLayout.secondary)
                    .foregroundColor(.holoInfo)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    /// 搜索/筛选分支的副句：caption 为已本地化的原文案，前缀「— 」走词条表的通用「— %@」键
    private static func byline(_ caption: String) -> LocalizedStringKey {
        LocalizedStringKey("— \(caption)")
    }
}
