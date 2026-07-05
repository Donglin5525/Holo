//
//  MemorySegmentedTabs.swift
//  Holo
//
//  记忆长廊顶部 Tab 切换器
//  洞察 / 明细
//

import SwiftUI

/// 记忆长廊 Tab 类型
enum MemoryGalleryTab: String, CaseIterable {
    case calendar = "日历"
    case insight = "洞察"
    case detail = "明细"
}

/// 分段 Tab 切换器
struct MemorySegmentedTabs: View {

    @Environment(\.colorScheme) private var colorScheme

    @Binding var selectedTab: MemoryGalleryTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MemoryGalleryTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .background(Color.holoGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.55), lineWidth: 1)
        )
        .padding(.horizontal, HoloSpacing.lg)
    }

    private func tabButton(_ tab: MemoryGalleryTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : unselectedTextColor)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(isSelected ? Color.holoPrimary : Color.clear)
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        .buttonStyle(PlainButtonStyle())
    }

    private var unselectedTextColor: Color {
        Color.holoTextPrimary.opacity(colorScheme == .dark ? 0.74 : 0.62)
    }
}
