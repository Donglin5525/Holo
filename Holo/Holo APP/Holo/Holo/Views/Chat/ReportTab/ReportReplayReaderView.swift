//
//  ReportReplayReaderView.swift
//  Holo
//
//  周期回放的全屏阅读版：报告 Tab 档案行进入。
//  内容复用聊天流的 PeriodReplayChatCard（不新造版式），外层只包全屏容器与返回栏。
//

import SwiftUI

struct ReportReplayReaderView: View {
    let message: ChatMessageViewData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    PeriodReplayChatCard(message: message)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
        }
        .background(Color.holoBackground.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoTextSecondary.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            Spacer()

            Text("周期回放")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 与左侧按钮对称的占位，保证标题真正居中
            Color.clear
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
