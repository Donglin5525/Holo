//
//  Category+Icon.swift
//  Holo
//
//  分类图标扩展 - 提供分类图标的统一渲染方法
//

import SwiftUI
import UIKit

// MARK: - Category Icon View Builder

/// 获取分类图标
/// - Parameters:
///   - category: 分类对象
///   - size: 图标尺寸
/// - Returns: 图标视图
@ViewBuilder
func transactionCategoryIcon(_ category: Category, size: CGFloat) -> some View {
    let name = category.icon
    let withNamespace = "CategoryIcons/\(name)"
    let loaded = UIImage(named: withNamespace) ?? UIImage(named: name)
    
    if let img = loaded, name.hasPrefix("icon_") {
        Image(uiImage: img)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundColor(category.swiftUIColor)
    } else {
        Image(systemName: name.hasPrefix("icon_") ? "tag.fill" : name)
            .font(.system(size: size * 0.6, weight: .medium))
            .foregroundColor(category.swiftUIColor)
    }
}
