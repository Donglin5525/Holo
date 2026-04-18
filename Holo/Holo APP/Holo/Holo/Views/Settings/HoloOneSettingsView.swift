//
//  HoloOneSettingsView.swift
//  Holo
//
//  Holo One 设置页面
//  让用户选择底部导航栏中心按钮触发的快捷动作
//

import SwiftUI

/// Holo One 设置页面
struct HoloOneSettingsView: View {

    // MARK: - Environment

    @Environment(\.dismiss) var dismiss

    // MARK: - State

    @AppStorage("holoOneAction") private var selectedAction: HoloOneAction = .aiChat

    // MARK: - Body

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    // 说明文字
                    explanationCard

                    // 动作选项列表
                    actionOptionsSection
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("Holo One")
                        .font(.holoHeading)
                        .foregroundColor(.holoTextPrimary)
                }
            }
        }
    }

    // MARK: - 说明卡片

    private var explanationCard: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 16))
                .foregroundColor(.holoPrimary)

            Text("选择底部导航栏中心按钮的快捷动作，点击即直接执行")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 动作选项

    private var actionOptionsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("快捷动作")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            // 选项列表
            VStack(spacing: 0) {
                ForEach(HoloOneAction.allCases, id: \.self) { action in
                    actionRow(action)
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    /// 单个动作选项行
    private func actionRow(_ action: HoloOneAction) -> some View {
        Button {
            selectedAction = action
            HapticManager.light()
        } label: {
            HStack(spacing: HoloSpacing.md) {
                // 图标
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(action == selectedAction
                              ? action.iconColor.opacity(0.1)
                              : Color.holoBackground)
                        .frame(width: 40, height: 40)

                    Image(systemName: action.iconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(action == selectedAction
                                         ? action.iconColor
                                         : .holoTextSecondary)
                }

                // 文字
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayName)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(action.description)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                // 选中指示器
                if action == selectedAction {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.holoPrimary)
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Preview

#Preview {
    HoloOneSettingsView()
}
