//
//  ChatLogView.swift
//  Holo
//
//  大模型调用日志查看页面
//  展示每次 LLM 调用的请求和响应，支持一键复制
//

import SwiftUI

struct ChatLogView: View {

    let log: LLMLog

    @Environment(\.dismiss) private var dismiss
    @State private var copiedSection: String? = nil

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 自定义导航栏
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 32, height: 32)
                            .background(Color.holoTextSecondary.opacity(0.1))
                            .cornerRadius(16)
                    }

                    Spacer()

                    Text("查看日志")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Color.clear
                        .frame(width: 32, height: 32)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(0..<log.calls.count, id: \.self) { index in
                            callSection(log.calls[index], index: index)
                        }

                        // 底部留白，避免被浮窗遮挡
                        Color.clear.frame(height: 60)
                    }
                    .padding(16)
                }
            }

            // 浮动复制按钮（叠层，不占布局空间）
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        copyAll()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: copiedSection == "all" ? "checkmark" : "doc.on.doc")
                            Text(copiedSection == "all" ? "已复制" : "复制全部")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(copiedSection == "all" ? Color.green : Color.holoPrimary)
                        .cornerRadius(20)
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .swipeBackToDismiss { dismiss() }
        .navigationBarHidden(true)
    }

    // MARK: - Call Section

    @ViewBuilder
    private func callSection(_ call: LLMCallLog, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: call.type == "intent_recognition" ? "brain" : "bubble.left.and.bubble.right")
                    .foregroundColor(.holoPrimary)
                Text(callTitle(for: call))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text(call.model)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }

            CardDivider()

            // 请求消息
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("请求内容")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                    Spacer()
                    copyButton(
                        text: formatCallRequest(call),
                        sectionId: "request_\(index)"
                    )
                }

                ForEach(0..<call.requestMessages.count, id: \.self) { msgIndex in
                    messageRow(call.requestMessages[msgIndex])
                }
            }

            CardDivider()

            // 响应内容
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("响应内容")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                    Spacer()
                    copyButton(
                        text: call.responseText,
                        sectionId: "response_\(index)"
                    )
                }

                Text(call.responseText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(.holoTextPrimary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.holoCardBackground)
                    .cornerRadius(8)
            }
        }
        .padding(14)
        .background(Color.holoCardBackground)
        .cornerRadius(12)
    }

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(_ msg: ChatMessageDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                roleBadge(msg.role)
                Text(msg.role)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }
            Text(msg.content)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(nil)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoBackground)
        .cornerRadius(8)
    }

    // MARK: - Role Badge

    @ViewBuilder
    private func roleBadge(_ role: String) -> some View {
        switch role {
        case "system":
            Image(systemName: "gearshape")
                .font(.system(size: 10))
                .foregroundColor(.orange)
        case "user":
            Image(systemName: "person")
                .font(.system(size: 10))
                .foregroundColor(.blue)
        default:
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundColor(.holoPrimary)
        }
    }

    // MARK: - Copy Button

    @ViewBuilder
    private func copyButton(text: String, sectionId: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            copiedSection = sectionId
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedSection == sectionId { copiedSection = nil }
            }
        } label: {
            if copiedSection == sectionId {
                Text("已复制")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
            } else {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundColor(.holoPrimary)
            }
        }
    }

    // MARK: - Helpers

    private func callTitle(for call: LLMCallLog) -> String {
        call.type == "intent_recognition" ? "意图识别" : "对话回复"
    }

    private func formatCallRequest(_ call: LLMCallLog) -> String {
        call.requestMessages.map { msg in
            "[\(msg.role)]\n\(msg.content)"
        }.joined(separator: "\n\n")
    }

    private func copyAll() {
        let fullText = log.calls.map { call in
            let header = "=== \(callTitle(for: call)) (模型: \(call.model)) ==="
            let request = call.requestMessages.map { "[\($0.role)]\n\($0.content)" }.joined(separator: "\n\n")
            return "\(header)\n\n--- 请求 ---\n\(request)\n\n--- 响应 ---\n\(call.responseText)"
        }.joined(separator: "\n\n")

        UIPasteboard.general.string = fullText
        copiedSection = "all"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedSection == "all" { copiedSection = nil }
        }
    }
}
