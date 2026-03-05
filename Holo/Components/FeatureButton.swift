//
//  FeatureButton.swift
//  Holo
//
//  功能入口按钮组件
//  用于首页四角的功能快捷入口（任务、财务、健康、观点）
//

import SwiftUI

/// 功能入口按钮配置
struct FeatureButtonConfig {
    let icon: String           // SF Symbol 图标名称
    let title: String          // 显示标题
    let color: Color           // 图标颜色（预留扩展）
}

/// 功能入口按钮
/// 设计特点：
/// - 毛玻璃背景
/// - 圆角矩形按钮
/// - 图标 + 文字标签
/// - 阴影效果
struct FeatureButton: View {
    
    // MARK: - Properties
    
    /// 按钮配置
    let config: FeatureButtonConfig
    
    /// 点击回调
    let action: () -> Void
    
    // MARK: - Body
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // 图标容器
                iconContainer
                
                // 标题文字
                titleText
            }
        }
    }
    
    // MARK: - 子视图
    
    /// 图标容器
    private var iconContainer: some View {
        ZStack {
            // 毛玻璃背景
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(.ultraThinMaterial)
                .frame(width: 56, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.lg)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            
            // 图标
            Image(systemName: config.icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.holoTextPrimary)
        }
        .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 10)
    }
    
    /// 标题文字
    private var titleText: some View {
        Text(config.title)
            .font(.holoLabel)
            .foregroundColor(.holoTextPrimary.opacity(0.7))
    }
}

// MARK: - 预设配置

extension FeatureButtonConfig {
    /// 任务按钮配置
    static let task = FeatureButtonConfig(
        icon: "checklist",
        title: "任务",
        color: .holoPrimary
    )
    
    /// 财务按钮配置
    static let finance = FeatureButtonConfig(
        icon: "wallet.pass",
        title: "财务",
        color: .holoSuccess
    )
    
    /// 健康按钮配置
    static let health = FeatureButtonConfig(
        icon: "heart.fill",
        title: "健康",
        color: .holoInfo
    )
    
    /// 观点/想法按钮配置
    static let thoughts = FeatureButtonConfig(
        icon: "lightbulb.fill",
        title: "观点",
        color: .holoPurple
    )
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.holoBackground
            .ignoresSafeArea()
        
        HStack(spacing: 40) {
            FeatureButton(config: .task) {
                print("Task tapped")
            }
            
            FeatureButton(config: .finance) {
                print("Finance tapped")
            }
        }
    }
}