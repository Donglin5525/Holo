//
//  DiscoveryCapsuleView.swift
//  Holo
//
//  「一个发现」常驻行胶囊（01 §1）：与 QuickActionBar 其余胶囊同排同规格，
//  仅在 presentationState == .available 时渲染；未看=淡橙轻品牌色、已看=普通样式。
//  无数字、无红点、无闪烁、无催看；其余状态（含 disabled 占位）一律不渲染。
//

import SwiftUI

struct DiscoveryCapsuleView: View {

    let state: DiscoveryPresentationState
    let onTap: () -> Void

    var body: some View {
        // 只有有效发现才有胶囊；disabled/preparing/waiting/stale 等一律不渲染占位
        if case .available(_, let viewed) = state {
            capsule(viewed: viewed)
        }
    }

    // MARK: - 胶囊

    private func capsule(viewed: Bool) -> some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12))
                Text("一个发现")
                    .font(.system(size: 13))
            }
            .foregroundColor(foregroundColor(viewed: viewed))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background(viewed: viewed))
            .cornerRadius(16)
            // 与 QuickActionBar 同规矩：横向滚动时不被父级压缩
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityIdentifier("chat.discovery.capsule")
        .accessibilityLabel(Text(viewed ? "一个发现" : "一个发现，有新内容"))
        .accessibilityHint(Text("打开这条发现的阅读面板"))
    }

    /// 未看=淡橙轻品牌底（亮暗模式都用品牌橙低透明，避免深色下出实心亮块）；
    /// 已看=与常驻行其他胶囊完全一致的普通样式
    private func background(viewed: Bool) -> Color {
        viewed ? Color.holoPrimary.opacity(0.1) : Color.holoPrimary.opacity(0.22)
    }

    private func foregroundColor(viewed: Bool) -> Color {
        viewed
            ? .holoPrimary
            : Color.holoDynamic(
                light: UIColor(red: 234/255, green: 88/255, blue: 12/255, alpha: 1),   // holoPrimaryDark
                dark: UIColor(red: 254/255, green: 215/255, blue: 170/255, alpha: 1)   // holoPrimaryLight
            )
    }
}

// #Preview 已临时禁用（Xcode 26.2 隔离协议混淆崩溃规避，恢复见实施进度.md）
