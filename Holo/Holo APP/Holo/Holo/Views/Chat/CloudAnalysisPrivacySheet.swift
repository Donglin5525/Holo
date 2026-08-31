//
//  CloudAnalysisPrivacySheet.swift
//  Holo
//
//  云端异步分析（二期 M2b）——首次启用前的隐私说明（仅出现一次）。
//  文案口径经两轮对抗性审查定稿（设计稿 2026-08-30）：
//  - 承诺范围限定「本次分析上传的数据」，不做全局否定式承诺（长期记忆在存）；
//  - 「结束即删除」由后端真实销毁行为背书（任务完成主动清除密文，7 天兜底）；
//  - 结果去向明确「只保存在这台设备」。
//

import SwiftUI

struct CloudAnalysisPrivacySheet: View {
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                Text("这次分析的数据怎么处理")
                    .font(.system(size: 17, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("为了让你锁屏、离开 App 后分析也能完成，Holo 会把本次分析所需的数据（如任务、账目、习惯、想法记录）**加密上传到云端**完成分析。")
                } icon: {
                    Image(systemName: "icloud.and.arrow.up").font(.system(size: 13)).foregroundColor(.holoTextSecondary)
                }
                Label {
                    Text("这些数据**仅用于这一次分析**——分析结束或失败后立即删除，云端不会保留。")
                } icon: {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundColor(.holoTextSecondary)
                }
                Label {
                    Text("**分析结果只保存在你的设备上**，不会在云端留存副本。")
                } icon: {
                    Image(systemName: "iphone").font(.system(size: 13)).foregroundColor(.holoTextSecondary)
                }
                Label {
                    Text("Holo 不会出售你的数据，也不用于广告。")
                } icon: {
                    Image(systemName: "hand.raised").font(.system(size: 13)).foregroundColor(.holoTextSecondary)
                }
            }
            .font(.system(size: 14))
            .foregroundColor(.holoTextPrimary)

            Text("本次分析仍按原方式在本机进行，确认后从下一次分析开始启用云端模式。")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)

            Button {
                onConfirm()
            } label: {
                Text("知道了，下次开始用云端分析")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.holoPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        // 撑满 sheet 容器（medium detent），内容顶部对齐，避免容器露毛玻璃底
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.holoCardBackground)
        // 容器底色与内容同色，杜绝上下安全区露出系统材质
        .presentationBackground(Color.holoCardBackground)
    }
}
