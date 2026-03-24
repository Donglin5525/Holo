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

    // MARK: - Body

    var body: some View {
        VStack(spacing: HoloSpacing.xl) {
            // 图标
            ZStack {
                Circle()
                    .fill(Color.holoPrimary.opacity(0.15))
                    .frame(width: 100, height: 100)

                Image(systemName: "heart.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundColor(.holoPrimary)
            }

            // 标题和说明
            VStack(spacing: HoloSpacing.sm) {
                Text("健康数据")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                Text("Holo 需要读取您的健康数据来展示步数、睡眠和站立时长")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)
            }

            // 数据类型说明
            VStack(spacing: HoloSpacing.md) {
                permissionRow(icon: "figure.walk", title: "步数", description: "每日行走步数")
                permissionRow(icon: "bed.double.fill", title: "睡眠", description: "睡眠时长分析")
                permissionRow(icon: "figure.stand", title: "站立", description: "每日站立时长")
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.lg)

            Spacer()

            // 按钮
            VStack(spacing: HoloSpacing.sm) {
                Button(action: onAuthorize) {
                    Text("授权访问")
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
    }

    // MARK: - Helper Views

    private func permissionRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.holoPrimary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(description)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
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