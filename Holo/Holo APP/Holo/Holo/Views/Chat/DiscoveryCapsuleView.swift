//
//  DiscoveryCapsuleView.swift
//  Holo
//
//  「一个发现」常驻行胶囊（01 §1）：与 QuickActionBar 其余胶囊同排同规格，
//  开启后常驻，可查看本机整理进度；有未读云端观察时用轻品牌色。
//

import SwiftUI
import Combine

struct DiscoveryCapsuleView: View {

    let state: DiscoveryPresentationState
    let onTap: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(DiscoverySettings.enabledKey) private var isEnabled = false
    @ObservedObject private var consent = HoloAIDataProcessingConsent.shared

    var body: some View {
        if isEnabled && consent.isGranted {
            // 亮起语义=「今天有一条待看的卡」（state 由 LocalService.refresh 驱动），
            // 列表里另有待确认条目不再触发淡橙（设计检查 #10：旧轮询导致常亮）。
            capsule(viewed: !hasUnreadFinding)
        }
    }

    private var hasUnreadFinding: Bool {
        if case .available(_, viewed: false) = state { return true }
        return false
    }

    // MARK: - 胶囊

    private func capsule(viewed: Bool) -> some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12))
                Text("一个发现")
                    .font(.system(size: 13))
                if !viewed {
                    Circle().fill(Color.holoToolAction).frame(width: 6, height: 6)
                }
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
        .accessibilityLabel(Text(viewed ? "一个发现" : "一个发现，今天有一条"))
        .accessibilityHint(Text("查看记录里的规律和整理状态"))
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
