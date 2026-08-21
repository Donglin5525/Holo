//
//  MemoryNavbarTabs.swift
//  Holo
//
//  记忆长廊页级 tab（L1 轻头部）：并入标题栏右侧的灰底小分段，
//  替代原满宽橙色大分段——视觉减重并省一整行。
//

import SwiftUI

/// 记忆长廊 Tab 类型
enum MemoryGalleryTab: String, CaseIterable {
    case calendar = "日历"
    case insight = "洞察"
}

/// 标题栏右侧小分段（灰底滑块，iOS 系统样式）
struct MemoryNavbarTabs: View {

    @Binding var selectedTab: MemoryGalleryTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MemoryGalleryTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.holoNestedCardBackground.opacity(0.66)))
        .overlay(Capsule().stroke(Color.holoBorder.opacity(0.42), lineWidth: 1))
    }

    private func tabButton(_ tab: MemoryGalleryTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            withAnimation(HoloAnimation.quick) {
                selectedTab = tab
            }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
                .padding(.horizontal, 13)
                .frame(height: 26)
                .background(
                    Capsule().fill(isSelected ? Color.holoCardBackground : Color.clear)
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.holoPrimary.opacity(0.14) : Color.clear, lineWidth: 1)
                )
                // 命中区向外扩到 32pt 高（视觉仍是 24pt 胶囊），高频操作不点空
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("\(tab.rawValue)视图")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
