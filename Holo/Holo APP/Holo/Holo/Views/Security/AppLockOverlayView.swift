//
//  AppLockOverlayView.swift
//  Holo
//
//  应用锁覆盖层
//  锁定态：图标 + 解锁按钮（onAppear 自动发起一次验证）
//  遮罩态：仅 App 标识（后台快照保护，不泄露页面内容）
//  同时挂在两处：HoloApp 根部 ZStack（冷启动防闪现）与 AppLockManager 的系统级窗口（盖住浮层）
//

import SwiftUI

struct AppLockOverlayView: View {

    @ObservedObject private var manager = AppLockManager.shared

    var body: some View {
        ZStack {
            // 不透明底色：遮罩/锁屏都必须完全盖住下层内容
            Color.holoToolBackground.ignoresSafeArea()

            if manager.isLocked {
                lockedContent
            } else {
                shieldContent
            }
        }
        .onAppear {
            manager.lockScreenDidAppear()
        }
        // 锁定期隔断 VoiceOver 对下层内容的朗读
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - 锁定态

    private var lockedContent: some View {
        VStack(spacing: HoloSpacing.lg) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.holoPrimary.opacity(0.1))
                    .frame(width: 88, height: 88)

                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(.holoPrimary)
            }

            Text("Holo 已锁定")
                .font(.holoHeading)
                .foregroundColor(.holoToolText)

            Text(manager.unlockHint)
                .font(.holoBody)
                .foregroundColor(.holoToolTextSecondary)

            Spacer()

            Button {
                manager.attemptUnlock()
            } label: {
                Group {
                    if manager.isEvaluating {
                        ProgressView()
                            .tint(.holoToolOnAction)
                    } else {
                        HStack(spacing: HoloSpacing.sm) {
                            Image(systemName: "faceid")
                            Text("解锁")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
            }
            .buttonStyle(HoloActionStyle(role: .primary))
            .disabled(manager.isEvaluating)
            .padding(.horizontal, HoloSpacing.xl)
            .accessibilityLabel(String(localized: "解锁 Holo"))
        }
        .padding(.bottom, 80)
    }

    // MARK: - 遮罩态（后台快照）

    private var shieldContent: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44, weight: .medium))
                .foregroundColor(.holoToolTextSecondary)
            Text("Holo")
                .font(.holoHeading)
                .foregroundColor(.holoToolTextSecondary)
        }
    }
}
