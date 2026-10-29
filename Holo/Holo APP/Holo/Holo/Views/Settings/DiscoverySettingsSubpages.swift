//
//  DiscoverySettingsSubpages.swift
//  Holo
//
//  「一个发现」设置子页的下挂两页（对齐原型 discoverySettings → scope / cloud）：
//  · DiscoveryScopeView 使用范围——当前允许理解的记录类型（只读；修改范围需关闭后重新
//    开启并选择，DiscoveryService 暂无 updateAllowedDomains，见协议缺口 TODO ①）
//  · DiscoveryProcessingNoteView 自动处理如何进行——数据怎么用、怎么停（原设置主子页
//    平铺五条处理说明收进此页，2026-10-28 挑刺整改）
//
//  两页由 DiscoverySettingsView 经 NavigationLink 闭包形式压栈，页本身不自带
//  NavigationStack（栈中栈卡死坑）。
//

import SwiftUI

// MARK: - 使用范围（只读展示）

struct DiscoveryScopeView: View {

    /// 当前允许范围（本机设置真源快照，进入时由父页传入）
    let allowedDomains: Set<DiscoverySourceDomain>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("可以理解哪些记录。")
                        .holoText(.sectionTitle)
                        .foregroundStyle(Color.holoToolText)
                    Text("范围在开启时选择；想更改，先关闭再重新开启，已生成的发现会清除。")
                        .holoText(.supporting)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, HoloSpacing.lg)

                HoloSettingsSection {
                    ForEach(Array(DiscoveryDomainMeta.all.enumerated()), id: \.element.id) { index, meta in
                        if index > 0 { HoloSettingsDivider() }
                        domainRow(meta)
                    }
                }

                Text(scopeNote)
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HoloSpacing.lg + HoloSpacing.md)
            }
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoToolBackground.ignoresSafeArea())
        .navigationTitle("使用范围")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var scopeNote: String {
        "健康与财务记录不参与；已设为「不参与 AI」的想法始终排除。"
    }

    private func domainRow(_ meta: DiscoveryDomainMeta) -> some View {
        let allowed = allowedDomains.contains(meta.domain)
        return HoloSettingsRow(icon: meta.icon, title: meta.title, subtitle: meta.subtitle) {
            Image(systemName: allowed ? "checkmark" : "minus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(allowed ? Color.holoPrimary : Color.holoToolTextSecondary.opacity(0.5))
        }
        .accessibilityIdentifier("settings.discovery.domains.\(meta.domain.rawValue)")
        .accessibilityLabel(Text("允许使用\(meta.title)"))
        .accessibilityValue(Text(allowed ? "已允许" : "未允许"))
    }
}

// MARK: - 自动处理如何进行

struct DiscoveryProcessingNoteView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("自动理解，也由你选择。")
                        .holoText(.sectionTitle)
                        .foregroundStyle(Color.holoToolText)
                    Text("开启后，Holo 会在有新记录时自动把允许范围内的相关片段交给 AI 理解。下面是它具体怎么做、怎么停。")
                        .holoText(.supporting)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, HoloSpacing.lg)

                HoloSettingsSection {
                    HoloSettingsRow(
                        icon: "cloud",
                        title: "理解发生在云端",
                        subtitle: "相关片段会经 Holo 的服务器交给第三方 AI 分析，不是只在手机本地处理。"
                    )
                    HoloSettingsDivider()
                    HoloSettingsRow(
                        icon: "line.3.horizontal.decrease.circle",
                        title: "只取允许的材料",
                        subtitle: "只读取你勾选范围内的想法、任务、习惯；不读健康与财务，不读长期记忆，也不会往记忆里写。"
                    )
                    HoloSettingsDivider()
                    HoloSettingsRow(
                        icon: "checkmark.shield",
                        title: "每条发现都带依据",
                        subtitle: "记录不够或分析不可靠时不会呈现；呈现的都能点开看到来源记录。"
                    )
                    HoloSettingsDivider()
                    HoloSettingsRow(
                        icon: "bell.slash",
                        title: "不保证每天都有",
                        subtitle: "只在有值得留意的变化时出现；不发通知。"
                    )
                    HoloSettingsDivider()
                    HoloSettingsRow(
                        icon: "stop.circle",
                        title: "随时可以关",
                        subtitle: "关闭会停止新的分析并删除已生成的发现。正在进行的分析会尽快停止，迟到的结果不会被采用。"
                    )
                }
            }
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoToolBackground.ignoresSafeArea())
        .navigationTitle("自动处理如何进行")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
