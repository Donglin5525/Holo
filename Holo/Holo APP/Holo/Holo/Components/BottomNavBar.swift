//
//  BottomNavBar.swift
//  Holo
//
//  底部导航栏组件
//  包含个人、中央AI按钮、记忆长廊三个入口
//

import SwiftUI

/// 底部导航栏
/// 设计特点：
/// - 毛玻璃背景的浮动导航栏
/// - 左右两个文字按钮（个人、记忆长廊）
/// - 中央凸起的 AI 助手按钮
struct BottomNavBar: View {
    
    // MARK: - Properties

    /// 当前选中的标签
    @Binding var selectedTab: TabItem

    /// 个人按钮点击回调
    var onProfileTap: (() -> Void)? = nil

    /// 记忆长廊按钮点击回调
    var onMemoryTap: (() -> Void)? = nil

    /// 中心按钮点击回调（Holo One 快捷动作）
    var onCenterTap: (() -> Void)? = nil
    
    /// 导航项枚举
    enum TabItem: String, CaseIterable {
        case profile = "个人"
        case ai = "AI"
        case memory = "记忆长廊"
    }
    
    // MARK: - Body
    
    var body: some View {
        HStack(spacing: 0) {
            // 左侧 - 个人按钮
            navButton(
                icon: "person.fill",
                title: "个人",
                isSelected: selectedTab == .profile
            ) {
                if let onProfileTap {
                    onProfileTap()
                } else {
                    selectedTab = .profile
                }
            }
            .frame(maxWidth: .infinity)

            // 中央 - AI 按钮（凸起）
            centerAIButton

            // 右侧 - 记忆长廊按钮
            navButton(
                icon: "book.fill",
                title: "记忆长廊",
                isSelected: selectedTab == .memory
            ) {
                if let onMemoryTap {
                    onMemoryTap()
                } else {
                    selectedTab = .memory
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.xl)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.xl)
                        .stroke(Color.holoBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 15, x: 0, y: 5)
        )
        .padding(.horizontal, HoloSpacing.lg)
    }
    
    // MARK: - 子视图
    
    /// 普通导航按钮
    private func navButton(
        icon: String,
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
                
                Text(title)
                    .font(.holoTinyLabel)
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
            }
        }
    }
    
    /// 中央 AI 按钮
    private var centerAIButton: some View {
        Button {
            if let onCenterTap {
                onCenterTap()
            } else {
                selectedTab = .ai
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    // 橙色圆形背景
                    Circle()
                        .fill(Color.holoPrimary)
                        .frame(width: 56, height: 56)
                        .shadow(color: .holoPrimary.opacity(0.3), radius: 20, x: 0, y: 0)

                    // AI 图标
                    Image(systemName: "sparkles")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white)
                }

                // 小黄点指示器：仅在首页时显示
                Circle()
                    .fill(selectedTab == .ai ? Color.holoChart8 : .clear)
                    .frame(width: 6, height: 6)
            }
        }
        .offset(y: -24)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.holoBackground
            .ignoresSafeArea()
        
        VStack {
            Spacer()
            BottomNavBar(selectedTab: .constant(.ai))
        }
    }
}