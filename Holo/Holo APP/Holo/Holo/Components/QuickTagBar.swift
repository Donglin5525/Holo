//
//  QuickTagBar.swift
//  Holo
//
//  智能快捷标签栏
//  根据当前选中科目，展示历史金额和名称标签
//  点击标签自动填充到记账表单
//

import SwiftUI

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
            VStack(spacing: 0) {
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
                .frame(height: 44)
            }
            .padding(.vertical, HoloSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
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
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.holoGlassBackground)
                    .overlay(
                        Capsule()
                            .stroke(Color.holoBorder, lineWidth: 1)
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
