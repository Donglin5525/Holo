//
//  AboutView.swift
//  Holo
//
//  「关于 Holo」页面
//  展示 App 图标、版本号与法律文档入口
//  2026-10-25 设置页规整：原一级页「重看新手引导/重看新人笔记」收编至此
//

import SwiftUI
#if canImport(UIKit)
#else
import AppKit
#endif

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showPrivacyPolicy = false
    @State private var showTermsOfUse = false
    @State private var copiedDeviceId = false

    /// 重看首页导览：关于页是 sheet 叠 sheet 的第二层，由调用方负责先关掉两层弹层再触发
    var onReplayCoachTour: (() -> Void)? = nil
    /// 重看新人笔记（跳转预置欢迎笔记）：同上，两层 dismiss 后深链跳转
    var onReplayWelcomeNote: (() -> Void)? = nil

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return String(localized: "版本 \(version) (\(build))")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: HoloSpacing.lg) {
                appHeader
                deviceSection
                legalSection
                replaySection
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoBackground)
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // sheet 自带 NavigationStack 且无系统返回键，没有关闭钮用户就退不出去
            // （2026-10-17 设计走查实锤：只能靠重启 App 脱身）；对齐 §8.8 左上关闭惯例
            ToolbarItem(placement: HoloToolbarPlacement.topBarLeading) {
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
                Text("关于 Holo")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
            }
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            LegalDocumentSheet(documentType: .privacyPolicy)
        }
        .sheet(isPresented: $showTermsOfUse) {
            LegalDocumentSheet(documentType: .termsOfUse)
        }
    }

    // MARK: - App 信息头部

    private var appHeader: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.holoPrimary)
                .frame(width: 96, height: 96)
                .background(
                    Circle()
                        .fill(Color.holoPrimary.opacity(0.1))
                )

            Text("Holo")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.holoTextPrimary)

            Text(String(localized: "你的人生数据库"))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Text(appVersionText)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.lg)
    }

    // MARK: - 设备信息

    /// 设备号用于反馈问题时定位账号（客服/测试期权益调整），点击整行复制
    private var deviceSection: some View {
        Button {
            #if canImport(UIKit)
            UIPasteboard.general.string = HoloBackendDeviceIdentity.shared.deviceId
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(HoloBackendDeviceIdentity.shared.deviceId, forType: .string)
            #endif
            copiedDeviceId = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copiedDeviceId = false
            }
        } label: {
            HStack(spacing: HoloSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.holoPrimary.opacity(0.1))
                        .frame(width: 40, height: 40)

                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 16))
                        .foregroundColor(.holoPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(copiedDeviceId ? String(localized: "已复制") : String(localized: "设备号"))
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(HoloBackendDeviceIdentity.shared.deviceId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Image(systemName: copiedDeviceId ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(copiedDeviceId ? .holoPrimary : .holoTextSecondary)
            }
            .padding(.vertical, HoloSpacing.sm)
            .padding(.horizontal, HoloSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoCardBackground)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 法律与隐私

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("法律与隐私")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            Button {
                showPrivacyPolicy = true
            } label: {
                settingsRowContent(
                    icon: "shield.checkered",
                    iconColor: .holoPrimary,
                    title: String(localized: "隐私政策"),
                    subtitle: String(localized: "了解我们如何保护你的数据")
                )
            }

            Button {
                showTermsOfUse = true
            } label: {
                settingsRowContent(
                    icon: "doc.text",
                    iconColor: .holoInfo,
                    title: String(localized: "用户协议"),
                    subtitle: String(localized: "服务条款与使用规范")
                )
            }
        }
    }

    // MARK: - 重看引导（2026-10-25 从设置一级页收编至此）

    /// 点击后先关关于 sheet，等收起动画结束再交调用方关设置页并触发跳转
    private var replaySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onReplayCoachTour?()
                }
            } label: {
                settingsRowContent(
                    icon: "sparkles",
                    iconColor: .holoPurple,
                    title: String(localized: "重看新手引导"),
                    subtitle: String(localized: "三步回顾首页的功能入口")
                )
            }

            // 预置欢迎笔记被删后入口自动隐藏，不复活
            if WelcomeNoteSeed.isNoteAlive() {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        onReplayWelcomeNote?()
                    }
                } label: {
                    settingsRowContent(
                        icon: "book",
                        iconColor: .holoPrimary,
                        title: String(localized: "重看新人笔记"),
                        subtitle: String(localized: "产品理念与功能速览")
                    )
                }
            }
        }
    }

    // MARK: - 行视图（与 SettingsView settingsRow 视觉风格保持一致）

    private func settingsRowContent(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.1))
                    .frame(width: 40, height: 40)

                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(subtitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.holoTextSecondary)
        }
        .padding(.vertical, HoloSpacing.sm)
        .padding(.horizontal, HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoCardBackground)
        )
    }
}
