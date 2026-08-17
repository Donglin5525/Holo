//
//  AboutView.swift
//  Holo
//
//  「关于 Holo」页面
//  展示 App 图标、版本号与法律文档入口
//

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showPrivacyPolicy = false
    @State private var showTermsOfUse = false
    @State private var copiedDeviceId = false

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "版本 \(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: HoloSpacing.lg) {
                appHeader
                deviceSection
                legalSection
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            UIPasteboard.general.string = HoloBackendDeviceIdentity.shared.deviceId
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
                    Text(copiedDeviceId ? "已复制" : "设备号")
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
                    title: "隐私政策",
                    subtitle: "了解我们如何保护你的数据"
                )
            }

            Button {
                showTermsOfUse = true
            } label: {
                settingsRowContent(
                    icon: "doc.text",
                    iconColor: .holoInfo,
                    title: "用户协议",
                    subtitle: "服务条款与使用规范"
                )
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
