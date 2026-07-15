//
//  PersonalMemorySettingsView.swift
//  Holo
//
//  用户管理 Holo 记忆方式的统一入口。
//

import SwiftUI

struct PersonalMemorySettingsView: View {
    @ObservedObject private var memorySettings = HoloMemorySettings.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.xl) {
                memoryControlsSection
                memoryManagementSection
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .navigationTitle("我的记忆")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var memoryControlsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            sectionTitle("Holo 如何记住你", icon: "brain.head.profile")

            VStack(spacing: 0) {
                memoryToggleRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "自动形成记忆",
                    subtitle: memorySettings.automaticMemoryEnabled
                        ? "从你的数据变化中整理值得记住的内容"
                        : "关闭后不再形成新记忆",
                    isOn: $memorySettings.automaticMemoryEnabled
                )

                Divider()
                    .padding(.leading, 56)

                memoryToggleRow(
                    icon: "text.bubble",
                    title: "记忆辅助回答",
                    subtitle: memorySettings.memoryAssistedAnsweringEnabled
                        ? "HoloAI 会结合已记住的信息理解你"
                        : "关闭后回答不会读取已有记忆",
                    isOn: $memorySettings.memoryAssistedAnsweringEnabled
                )
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))

            Text("关闭开关不会删除已有记忆，你仍可随时查看或管理。")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private var memoryManagementSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            sectionTitle("记忆内容", icon: "list.bullet.rectangle")

            NavigationLink {
                HoloMemoryCenterView()
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.holoPrimary.opacity(0.1))
                            .frame(width: 40, height: 40)

                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.holoPrimary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("记忆管理")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("查看、纠正或删除 Holo 记住的内容")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoTextSecondary.opacity(0.5))
                }
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
            .buttonStyle(.plain)

            Text("普通记忆可随你的 iCloud 在设备间同步；健康相关记忆只保存在本机。")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.holoPrimary)
            Text(title)
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)
        }
    }

    private func memoryToggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.holoPrimary.opacity(0.1))
                    .frame(width: 40, height: 40)

                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.holoPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer(minLength: HoloSpacing.sm)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.holoPrimary)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 12)
    }
}

#Preview {
    NavigationStack {
        PersonalMemorySettingsView()
    }
}
