//
//  FinanceSettingsView.swift
//  Holo
//
//  财务设置视图
//

import SwiftUI

struct FinanceSettingsView: View {
    let onBack: () -> Void
    @ObservedObject private var displaySettings = FinanceDisplaySettings.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            // 顶部栏
            HStack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.holoCardBackground)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
                }

                Spacer()

                Text("设置")
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, 0)
            .padding(.bottom, HoloSpacing.md)

            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.xl) {
                    // 显示设置模块
                    VStack(spacing: 0) {
                        HStack {
                            Text("显示设置")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.bottom, HoloSpacing.sm)

                        VStack(spacing: 0) {
                            FinanceDisplayToggleRow(
                                title: "本月支出",
                                icon: "arrow.down.right",
                                iconColor: .holoError,
                                isOn: $displaySettings.showMonthlyExpense
                            )

                            Divider().padding(.leading, 60)

                            FinanceDisplayToggleRow(
                                title: "本月收入",
                                icon: "arrow.up.right",
                                iconColor: .holoSuccess,
                                isOn: $displaySettings.showMonthlyIncome
                            )

                            if displaySettings.showMonthlyExpense && displaySettings.showMonthlyIncome {
                                HStack(spacing: 4) {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 11))
                                    Text("双卡并排时隐藏「今日」金额，仅单独展示时显示")
                                        .font(.system(size: 11))
                                }
                                .foregroundColor(.holoTextPlaceholder)
                                .padding(.horizontal, HoloSpacing.lg)
                                .padding(.top, HoloSpacing.xs)
                                .padding(.bottom, HoloSpacing.xs)
                            }
                        }
                        .padding(HoloSpacing.md)
                        .background(Color.holoCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
                        .padding(.horizontal, HoloSpacing.lg)
                    }

                    // 数据导入导出模块
                    ImportExportView()

                    // 分类管理模块
                    VStack(spacing: 0) {
                        HStack {
                            Text("账户管理")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.bottom, HoloSpacing.sm)

                        NavigationLink {
                            AccountListView()
                        } label: {
                            HStack {
                                Image(systemName: "wallet.pass.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.holoPrimary)
                                    .frame(width: 44, height: 44)
                                    .background(Color.holoPrimary.opacity(0.1))
                                    .clipShape(Circle())

                                Text("账户")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextPrimary)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.holoTextSecondary)
                            }
                            .padding(HoloSpacing.md)
                            .background(Color.holoCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                            .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, HoloSpacing.lg)
                    }

                    // 分类管理模块
                    VStack(spacing: 0) {
                        HStack {
                            Text("分类管理")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.bottom, HoloSpacing.sm)

                        NavigationLink {
                            CategoryManagementView()
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.holoPrimary)
                                    .frame(width: 44, height: 44)
                                    .background(Color.holoPrimary.opacity(0.1))
                                    .clipShape(Circle())

                                Text("分类")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextPrimary)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.holoTextSecondary)
                            }
                            .padding(HoloSpacing.md)
                            .background(Color.holoCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                            .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, HoloSpacing.lg)
                    }
                }
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
        }
        .background(Color.holoBackground)
        }
    }
}

// MARK: - 显示设置 Toggle 行

struct FinanceDisplayToggleRow: View {
    let title: String
    let icon: String
    let iconColor: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(iconColor)
                .frame(width: 36, height: 36)
                .background(iconColor.opacity(0.1))
                .clipShape(Circle())

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.holoPrimary)
        }
        .padding(.vertical, HoloSpacing.sm)
    }
}
