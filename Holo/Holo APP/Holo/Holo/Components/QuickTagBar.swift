//
//  QuickTagBar.swift
//  Holo
//
//  智能快捷标签栏
//  根据当前选中科目，展示历史金额和名称标签
//  点击标签自动填充到记账表单
//

import SwiftUI
import UIKit

// MARK: - Quick Tag Bar

/// 智能快捷标签栏（纯展示组件）
/// 数据由父视图传入，不持有标签状态
struct QuickTagBar: View {

    /// 标签数据（由父视图提供）
    let tags: [QuickTagItem]

    /// 点击标签回调
    let onTagTap: (_ value: String, _ kind: QuickTagKind) -> Void

    // MARK: - Body

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.sm) {
                    ForEach(tags) { tag in
                        QuickTagChip(item: tag) {
                            onTagTap(tag.value, tag.kind)
                        }
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
            }
            .frame(height: 38)
            .background(Color.transactionQuickTagBarBackground)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.holoBorder.opacity(0.55))
                    .frame(height: 0.5)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 0.5)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

extension Color {
    static var transactionKeypadTrayBackground: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.145, green: 0.145, blue: 0.155, alpha: 1)
                : UIColor.secondarySystemBackground
        })
    }

    static var transactionQuickTagBarBackground: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.185, green: 0.185, blue: 0.20, alpha: 1)
                : UIColor(red: 0.94, green: 0.94, blue: 0.965, alpha: 1)
        })
    }

    static var transactionQuickTagChipBackground: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
                : UIColor.white
        })
    }
}

// MARK: - Quick Tag Chip

/// 快捷标签胶囊视图
struct QuickTagChip: View {

    let item: QuickTagItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if case .amount = item.kind {
                    Image(systemName: "yensign")
                        .font(.system(size: 10, weight: .medium))
                }
                Text(item.value)
                    .font(.holoLabel)
                    .lineLimit(1)
            }
            .foregroundColor(.holoTextPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.transactionQuickTagChipBackground)
                    .overlay(
                        Capsule()
                            .stroke(Color.holoBorder.opacity(0.9), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()
        QuickTagBar(tags: []) { _, _ in }
    }
}
