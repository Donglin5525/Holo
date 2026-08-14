//
//  ContentReportSheet.swift
//  Holo
//
//  AI 内容举报面板（App Store Guideline 1.2）
//  选择举报原因 + 可选补充说明 → 提交到后端 POST /v1/reports。
//

import SwiftUI

struct ContentReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let message: ChatMessageViewData
    let service: HoloContentReportService

    @State private var selectedReason: ContentReportReason = .inappropriate
    @State private var detail: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSucceed = false

    @MainActor
    init(
        message: ChatMessageViewData,
        service: HoloContentReportService? = nil
    ) {
        self.message = message
        self.service = service ?? .shared
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if didSucceed {
                successView
            } else {
                ScrollView {
                    formView
                }
            }
        }
        .background(Color.holoBackground)
        .interactiveDismissDisabled(isSubmitting)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("举报 AI 内容")
                .font(.headline)
                .foregroundColor(.holoTextPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.holoTextSecondary)
            }
            .disabled(isSubmitting)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Form

    private var formView: some View {
        VStack(alignment: .leading, spacing: 16) {
            reportedContentView

            Text("你举报的内容将由我们审核。除非必要，我们不会以该内容再次训练模型。")
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(ContentReportReason.allCases) { reason in
                    reasonRow(reason)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("补充说明（可选）")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                TextEditor(text: $detail)
                    .font(.system(size: 15))
                    .frame(height: 88)
                    .padding(8)
                    .background(Color.holoDivider.opacity(0.4))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.holoDivider, lineWidth: 1)
                    )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundColor(.holoError)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                submit()
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("提交举报")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .buttonStyle(.plain)
            .background(isSubmitting ? Color.holoPrimary.opacity(0.6) : Color.holoPrimary)
            .foregroundColor(.white)
            .cornerRadius(12)
            .disabled(isSubmitting)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var reportedContentView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("举报内容")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoTextSecondary)

            Text(message.content.isEmpty ? "（内容为空）" : message.content)
                .font(.system(size: 15))
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(Color.holoDivider.opacity(0.3))
                .cornerRadius(10)
        }
    }

    private func reasonRow(_ reason: ContentReportReason) -> some View {
        Button {
            selectedReason = reason
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedReason == reason
                    ? "largecircle.fill.circle"
                    : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(.holoPrimary)

                Text(reason.label)
                    .font(.system(size: 15))
                    .foregroundColor(.holoTextPrimary)

                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color.holoDivider.opacity(0.3))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.holoSuccess)

            Text("感谢反馈，我们会处理")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.holoTextPrimary)

            Button {
                dismiss()
            } label: {
                Text("完成")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(.plain)
            .background(Color.holoPrimary)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    // MARK: - Actions

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil

        let snapshot = message.content.isEmpty ? nil : message.content
        let messageId = message.id.uuidString

        Task {
            do {
                try await service.submit(
                    messageId: messageId,
                    reason: selectedReason,
                    detail: detail,
                    contentSnapshot: snapshot
                )
                didSucceed = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}
