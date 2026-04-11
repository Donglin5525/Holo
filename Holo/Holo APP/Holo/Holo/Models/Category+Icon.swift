//
//  Category+Icon.swift
//  Holo
//
//  分类图标扩展 - 提供分类图标的统一渲染方法
//

import SwiftUI

// MARK: - Category Icon View Builder

/// 获取分类图标
/// - Parameters:
///   - category: 分类对象
///   - size: 图标尺寸
/// - Returns: 图标视图
@ViewBuilder
func transactionCategoryIcon(_ category: Category, size: CGFloat) -> some View {
    let name = category.icon

    if name.hasPrefix("icon_") {
        // 兼容：用户自定义分类仍使用旧 icon_ 名称，回退到 tag.fill
        Image(systemName: "tag.fill")
            .font(.system(size: size * 0.6, weight: .medium))
            .foregroundColor(category.swiftUIColor)
    } else {
        Image(systemName: name)
            .font(.system(size: size * 0.6, weight: .medium))
            .foregroundColor(category.swiftUIColor)
    }
}
