//
//  HealthPermissionView.swift
//  Holo
//
//  健康权限引导视图
//  引导用户授权 HealthKit 数据访问
//

import SwiftUI

// MARK: - HealthPermissionView

/// 健康权限引导视图
struct HealthPermissionView: View {
    let onAuthorize: () -> Void
    let onDismiss: () -> Void

    private let heroTextMaxWidth: CGFloat = 330
    private let permissionCardWidth: CGFloat = 248
    private let permissionIconColumnWidth: CGFloat = 56

    // MARK: - Body

    var body: some View {
        VStack(alignment: .center, spacing: HoloSpacing.xl) {
            heroContent
            permissionCard

            Spacer()

            // 按钮
            VStack(spacing: HoloSpacing.sm) {
                Button(action: onAuthorize) {
                    Text("授权 Apple Health")
                        .font(.holoBody)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.holoPrimary)
                        .cornerRadius(HoloRadius.md)
                }

                Button(action: onDismiss) {
                    Text("稍后再说")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .padding(HoloSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Helper Views

    private var heroContent: some View {
        VStack(alignment: .center, spacing: HoloSpacing.xl) {
            ZStack {
                RoundedRectangle(cornerRadius: HoloRadius.xl)
                    .fill(Color.holoTextPrimary)
                    .frame(width: 100, height: 100)

                Image(systemName: "apple.logo")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundColor(.holoCardBackground)
            }

            VStack(alignment: .center, spacing: HoloSpacing.sm) {
                Text("连接 Apple Health")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text("HOLO 只读取你的健康数据，用于展示三环进度和生成生活洞察；不会写入 Apple Health，也不会上传原始健康记录。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: heroTextMaxWidth, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            permissionRow(icon: "figure.walk", title: "步数", description: "生成日间活动环")
            permissionRow(icon: "bed.double.fill", title: "睡眠", description: "生成恢复状态和效率洞察")
            permissionRow(icon: "figure.stand", title: "站立", description: "识别久坐和提醒节奏")
        }
        .padding(HoloSpacing.md)
        .frame(width: permissionCardWidth, alignment: .leading)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    private func permissionRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.holoPrimary)
                .frame(width: permissionIconColumnWidth, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(description)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#Preview {
    HealthPermissionView(
        onAuthorize: {},
        onDismiss: {}
    )
    .background(Color.holoBackground)
}
