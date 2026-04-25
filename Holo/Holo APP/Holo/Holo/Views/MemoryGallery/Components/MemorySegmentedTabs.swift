//
//  MemorySegmentedTabs.swift
//  Holo
//
//  记忆长廊顶部 Tab 切换器
//  回放 / 地图 / 明细
//

import SwiftUI

/// 记忆长廊 Tab 类型
enum MemoryGalleryTab: String, CaseIterable {
    case replay = "回放"
    case map = "地图"
    case detail = "明细"
}

/// 分段 Tab 切换器
struct MemorySegmentedTabs: View {

    @Binding var selectedTab: MemoryGalleryTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MemoryGalleryTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .background(Color.holoGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        .padding(.horizontal, HoloSpacing.lg)
    }

    private func tabButton(_ tab: MemoryGalleryTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            Text(tab.rawValue)
                .font(.holoCaption)
                .foregroundColor(selectedTab == tab ? .white : .holoTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm / 2)
                        .fill(selectedTab == tab ? Color.holoPrimary : Color.clear)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
