//
//  FeatureButton.swift
//  Holo
//
//  功能入口按钮组件
//  用于首页五角形布局的功能快捷入口（任务、财务、健康、观点、习惯）
//

import SwiftUI

/// 功能入口按钮配置
/// - 遵循 Identifiable 以支持 ForEach 遍历和拖拽排序
/// - 遵循 Equatable 以支持数组查找和比较
struct FeatureButtonConfig: Identifiable, Equatable {
    let id: String             // 唯一标识符，用于拖拽排序和持久化
    let icon: String           // SF Symbol 图标名称
    let title: String          // 显示标题
    let color: Color           // 图标颜色（预留扩展）
    
    /// Equatable 实现：基于 id 判断相等
    static func == (lhs: FeatureButtonConfig, rhs: FeatureButtonConfig) -> Bool {
        lhs.id == rhs.id
    }
}

/// 功能入口按钮内容视图（不含交互）
/// 用于支持外部自定义手势（如长按拖拽）
struct FeatureButtonContent: View {
    
    // MARK: - Properties
    
    /// 按钮配置
    let config: FeatureButtonConfig
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 4) {
            // 图标容器
            iconContainer
            
            // 标题文字
            titleText
        }
    }
    
    // MARK: - 子视图
    
    /// 图标容器
    private var iconContainer: some View {
        ZStack {
            // 毛玻璃背景 + 色染叠层
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(.ultraThinMaterial)
                .frame(width: 56, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.lg)
                        .fill(config.color.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.lg)
                        .stroke(Color.holoBorder, lineWidth: 1)
                )

            // 图标
            Image(systemName: config.icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(config.color)
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

/// 功能入口按钮（带点击交互）
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
            FeatureButtonContent(config: config)
        }
    }
}

// MARK: - 预设配置

extension FeatureButtonConfig {
    /// 任务按钮配置
    static let task = FeatureButtonConfig(
        id: "task",
        icon: "checklist",
        title: "任务",
        color: .holoPrimary
    )
    
    /// 财务按钮配置
    static let finance = FeatureButtonConfig(
        id: "finance",
        icon: "wallet.pass",
        title: "财务",
        color: .holoSuccess
    )
    
    /// 健康按钮配置
    static let health = FeatureButtonConfig(
        id: "health",
        icon: "heart.fill",
        title: "健康",
        color: .holoInfo
    )
    
    /// 观点/想法按钮配置
    static let thoughts = FeatureButtonConfig(
        id: "thoughts",
        icon: "lightbulb.fill",
        title: "观点",
        color: .holoPurple
    )
    
    /// 习惯按钮配置 - 圆形打勾图标，与 SVG 设计风格一致
    static let habit = FeatureButtonConfig(
        id: "habit",
        icon: "checkmark.circle",
        title: "习惯",
        color: .holoInfo
    )

    /// 默认的五个功能按钮配置（按五角形布局顺序）
    static let defaultItems: [FeatureButtonConfig] = [
        .task, .finance, .habit, .health, .thoughts
    ]
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