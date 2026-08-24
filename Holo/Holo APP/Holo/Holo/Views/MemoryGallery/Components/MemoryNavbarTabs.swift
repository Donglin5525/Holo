//
//  MemoryNavbarTabs.swift
//  Holo
//
//  记忆长廊页级视图开关（F 案案定稿）：标题栏右侧的迷你拨动开关，
//  左＝日历 / 右＝洞察。拨块显示当前视图图标，轨道另一端露出目标视图暗图标，
//  替代原满宽大分段与右上角小分段——宽度压到 54pt，与左侧返回键（44pt）接近等宽，
//  标题得以绝对居中。
//

import SwiftUI

/// 记忆长廊 Tab 类型
enum MemoryGalleryTab: String, CaseIterable {
    case calendar = "日历"
    case insight = "洞察"

    /// 拨块 / 轨道图标（SF Symbols，与全 App 图标风格一致）
    var iconName: String {
        switch self {
        case .calendar: return "calendar"
        case .insight: return "sparkles"
        }
    }
}

/// 标题栏右侧拨动开关：轨道 54×32，拨块 27pt 圆形橙色、承载当前视图图标
struct MemoryViewToggleSwitch: View {

    @Binding var selectedTab: MemoryGalleryTab

    /// 轨道尺寸（pt）
    private let trackSize = CGSize(width: 54, height: 32)
    /// 拨块直径（pt）
    private let knobDiameter: CGFloat = 27
    private var isInsight: Bool { selectedTab == .insight }

    var body: some View {
        Button {
            withAnimation(HoloAnimation.snappy) {
                selectedTab = isInsight ? .calendar : .insight
            }
        } label: {
            track
        }
        .buttonStyle(PlainButtonStyle())
        // 热区外扩：视觉 32pt 高，命中 40pt，高频操作不点空
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityLabel("视图开关")
        .accessibilityValue(isInsight ? "洞察" : "日历")
        .accessibilityHint("双击在日历与洞察之间切换")
    }

    // MARK: - 轨道 + 拨块

    private var track: some View {
        ZStack(alignment: .leading) {
            // 轨道两端的视图图标：目标侧露出暗图标，提示拨过去是哪里
            HStack {
                sideIcon(.calendar, visible: isInsight)
                Spacer(minLength: 0)
                sideIcon(.insight, visible: !isInsight)
            }
            .padding(.horizontal, 6)

            knob
                .offset(x: isInsight ? trackSize.width - knobDiameter - 2.5 : 2.5)
        }
        .frame(width: trackSize.width, height: trackSize.height)
        .background(
            Capsule().fill(Color.holoNestedCardBackground.opacity(0.9))
        )
        .overlay(
            Capsule().stroke(Color.holoBorder.opacity(0.42), lineWidth: 1)
        )
    }

    private var knob: some View {
        Image(systemName: selectedTab.iconName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: knobDiameter, height: knobDiameter)
            .background(Circle().fill(Color.holoPrimary))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }

    @ViewBuilder
    private func sideIcon(_ tab: MemoryGalleryTab, visible: Bool) -> some View {
        Image(systemName: tab.iconName)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.holoTextPlaceholder)
            .opacity(visible ? 1 : 0)
    }
}
