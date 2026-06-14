//
//  CategoryIconBadge.swift
//  Holo
//
//  统一分类图标徽章：圆形底色 + 图标，单一占比常量。
//  替代散落于各调用点的 ZStack { Circle + icon } 硬编码（占比曾低至 30%）。
//

import SwiftUI

struct CategoryIconBadge: View {
    let iconName: String
    let color: Color
    let diameter: CGFloat
    var isSelected: Bool = false

    /// 图标占圆形直径的比例（替代原 size*0.6 的 ~30% 占比）
    static let iconRatio: CGFloat = 0.58
    /// 默认底色透明度（统一，替代散落的 0.1/0.12/0.15）
    static let backgroundOpacity: Double = 0.12
    /// 选中态底色透明度
    static let selectedBackgroundOpacity: Double = 0.25

    var body: some View {
        Circle()
            .fill(color.opacity(isSelected ? Self.selectedBackgroundOpacity : Self.backgroundOpacity))
            .frame(width: diameter, height: diameter)
            .overlay {
                categoryIconGlyph(resolvedIconName,
                                  size: diameter * Self.iconRatio,
                                  color: color)
            }
            .overlay {
                if isSelected {
                    Circle()
                        .stroke(color, lineWidth: max(2, diameter * 0.05))
                }
            }
    }

    /// 兼容旧 `icon_` 前缀自定义分类（回退 tag.fill），与原 transactionCategoryIcon 行为一致
    private var resolvedIconName: String {
        iconName.hasPrefix("icon_") ? "tag.fill" : iconName
    }

    init(iconName: String, color: Color, diameter: CGFloat, isSelected: Bool = false) {
        self.iconName = iconName
        self.color = color
        self.diameter = diameter
        self.isSelected = isSelected
    }

    init(category: Category, diameter: CGFloat, isSelected: Bool = false) {
        self.init(iconName: category.icon,
                  color: category.swiftUIColor,
                  diameter: diameter,
                  isSelected: isSelected)
    }
}

#Preview {
    VStack(spacing: 20) {
        CategoryIconBadge(iconName: "fork.knife", color: .blue, diameter: 64)
        CategoryIconBadge(iconName: "airplane.departure", color: .green, diameter: 48, isSelected: true)
        CategoryIconBadge(iconName: "house.lodge.fill", color: .indigo, diameter: 40)
    }
    .padding()
}
