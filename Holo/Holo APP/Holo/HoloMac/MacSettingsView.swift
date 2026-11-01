//
//  MacSettingsView.swift
//  HoloMac
//
//  Mac 设置中心（2026-10-26 交付缺口修复）：此前 Mac 版没有设置页，工作台齿轮
//  直开想法整理设置，「从 iCloud 重新拉取」这一数据恢复唯一入口在 Mac 上不存在。
//
//  结构对齐 iOS SettingsView 的分区形态（卡片 + 组头），内容三块：
//  - iCloud 同步（最顶部）：宿主跨平台组件 SettingsICloudSyncSection，
//    内含「立即同步 / 同步诊断 / 从 iCloud 重新拉取」——重拉即数据恢复通道；
//  - 想法整理：入口打开 ThoughtOrganizationSettingsView（原有能力原样保留）；
//  - 关于：版本号 + 数据说明（与 iPhone 共用同一 iCloud 容器）。
//

import SwiftUI

struct MacSettingsView: View {

    @Environment(\.dismiss) private var dismiss

    /// 想法整理设置（sheet 承载，与 iOS 设置页打开 ThoughtOrganizationSettingsView 同形态）
    @State private var showOrganizationSettings = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    sectionHeader(icon: "icloud.fill", title: String(localized: "iCloud 同步"))

                    // 跨平台同步区块：账号状态 / 双向同步 / 立即同步 / 同步诊断 /
                    // 从 iCloud 重新拉取（重拉 sheet 由组件内部承载）
                    SettingsICloudSyncSection(showsSectionHeader: false, requiresHoloSignIn: false)

                    sectionHeader(icon: "sparkles", title: String(localized: "想法整理"))

                    VStack(spacing: 0) {
                        navRow(
                            icon: "slider.horizontal.3",
                            iconColor: .holoAI,
                            title: String(localized: "想法整理设置"),
                            subtitle: String(localized: "整理开关 · 主题管理 · 标签管理 · AI 分析范围")
                        ) {
                            showOrganizationSettings = true
                        }
                    }
                    .background(Color.holoToolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                    .sheet(isPresented: $showOrganizationSettings) {
                        ThoughtOrganizationSettingsView()
                            .frame(minWidth: 520, minHeight: 620)
                    }

                    sectionHeader(icon: "info.circle", title: String(localized: "关于"))

                    VStack(spacing: 0) {
                        aboutRow(
                            title: String(localized: "版本"),
                            value: appVersionText)

                        Divider().padding(.leading, 56)

                        aboutRow(
                            title: String(localized: "数据"),
                            value: String(localized: "与 iPhone 版共用同一 iCloud 容器"))
                    }
                    .background(Color.holoToolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))

                    Text(String(localized: "Holo Mac 与 iPhone 通过 iCloud 私有数据库同步。同一 Apple ID 下的设备数据保持一致；本机数据损坏或版本混用时，可通过上方「从 iCloud 重新拉取」以云端为准恢复。"))
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoToolBackground)
            .navigationTitle(String(localized: "设置"))
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.navLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                    .accessibilityLabel(String(localized: "关闭"))
                }
                ToolbarItem(placement: .principal) {
                    Text(String(localized: "设置"))
                        .holoText(.sectionTitle)
                        .foregroundColor(.holoToolText)
                }
            }
            .task {
                // 与 iOS HoloApp 启动序一致：打开设置页即拉一次账号状态，
                // 账号状态行/首次恢复判断才有真实数据（Mac 启动链里没有这一步）
                guard CloudKitRuntimeAvailability.isAvailable else { return }
                await ICloudSyncStatusService.shared.warmUpAccountStatus()
            }
        }
        .frame(minWidth: 560, minHeight: 640)
    }

    // MARK: - 组件

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return String(localized: "版本 \(version) (\(build))")
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.holoPrimary)

            Text(title)
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundColor(.holoToolText)
        }
    }

    /// 导航行（对齐 iOS SettingsNavRow 形态：图标块 + 标题/副标题 + chevron）
    private func navRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(iconColor.opacity(0.1))
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(iconColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .holoText(.body)
                        .foregroundColor(.holoToolText)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary.opacity(0.5))
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("mac.settings.organizationRow")
    }

    private func aboutRow(title: String, value: String) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Text(title)
                .holoText(.body)
                .foregroundColor(.holoToolText)

            Spacer()

            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 12)
    }
}
