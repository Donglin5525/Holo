//
//  HoloQuotaNoticeCard.swift
//  Holo
//
//  名额说明弹窗（信用卡还款提醒免费 3 张满额时，自定义替代系统 alert）
//  设计语言：居中卡片 + 压暗遮罩 + 三区排版（状态标题 / 两条出路 / 操作），
//  圆角 HoloRadius.xl（弹窗档）、单一强调色（品牌橙主按钮）、
//  Plus 淡金仅出路 B 图标底一处（emblemGoldGradient 18%）。
//  出路行是纯信息行不可点；升级由用户主动选择后才进付费墙。
//

import SwiftUI

// MARK: - 卡片本体

struct HoloQuotaNoticeCard: View {

    let onUpgrade: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部区：状态式标题（直接回答「为什么开关弹回来了」）+ 规则说明
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("免费名额已用满")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.holoTextPrimary)
                    .lineLimit(1)
                Text("免费版最多同时开 3 张卡的还款提醒，你的 3 个名额都已开启。")
                    .holoText(.supporting)
                    .foregroundStyle(Color.holoTextSecondary)
            }

            // 内容区：升级路径一行（Plus 淡金图标底，全弹窗唯一金色）
            VStack(spacing: HoloSpacing.sm) {
                QuotaPathRow(
                    icon: "crown",
                    iconBackground: AnyShapeStyle(HoloPlusTheme.emblemGoldGradient.opacity(0.18)),
                    iconForeground: HoloPlusTheme.emblemBadgeText,
                    title: "升级后不限张数",
                    subtitle: "开通后会自动打开这张卡的提醒"
                )
            }
            .padding(.top, HoloSpacing.md)

            // 操作区：唯一主按钮 + 次要文字钮（一个弹层一个主操作 + 一个关闭）
            VStack(spacing: HoloSpacing.xs) {
                Button {
                    HapticManager.light()
                    onUpgrade()
                } label: {
                    Text("升级 Holo Plus")
                        .holoText(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.holoToolOnAction)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(Color.holoToolAction))
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoloPressStyle())
                .accessibilityIdentifier("holo.quotaNotice.upgrade")

                Button {
                    HapticManager.light()
                    onDismiss()
                } label: {
                    Text("知道了")
                        .holoText(.body)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoloPressStyle())
                .accessibilityIdentifier("holo.quotaNotice.dismiss")
            }
            .padding(.top, HoloSpacing.md)
        }
        .padding(HoloSpacing.page)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.xl, style: .continuous)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.xl, style: .continuous)
                .strokeBorder(Color.holoDivider.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: HoloShadow.card, radius: 18, y: 8)
        .frame(maxWidth: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("holo.quotaNotice.card")
    }
}

/// 出路行：28×28 圆角图标底 + 主/副文字（同构骨架，左对齐，纯信息不可点）
private struct QuotaPathRow: View {

    let icon: String
    let iconBackground: AnyShapeStyle
    let iconForeground: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: HoloSpacing.md) {
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .fill(iconBackground)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(iconForeground)
                )

            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text(title)
                    .holoText(.supporting)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.holoTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 挂载修饰符（两个入口共用）

struct HoloQuotaNoticeModifier: ViewModifier {

    @Binding var isPresented: Bool
    let onUpgrade: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture {
                            HapticManager.light()
                            dismiss()
                        }
                        .transition(.opacity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityHidden(true)

                    HoloQuotaNoticeCard(
                        onUpgrade: {
                            dismiss()
                            onUpgrade()
                        },
                        onDismiss: { dismiss() }
                    )
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                }
            }
        }
        .animation(HoloAnimation.snappy, value: isPresented)
        .onChange(of: isPresented) { _, shown in
            if shown { HapticManager.warning() }
        }
    }

    private func dismiss() {
        withAnimation(HoloAnimation.quick) {
            isPresented = false
        }
    }
}

extension View {
    /// 满额说明弹窗：遮罩点击 = 知道了；升级回调里自行调 requirePlus（付费墙会全屏盖上来）
    func holoQuotaNotice(isPresented: Binding<Bool>, onUpgrade: @escaping () -> Void) -> some View {
        modifier(HoloQuotaNoticeModifier(isPresented: isPresented, onUpgrade: onUpgrade))
    }
}
