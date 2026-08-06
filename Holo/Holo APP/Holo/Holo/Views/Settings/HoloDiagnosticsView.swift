//
//  HoloDiagnosticsView.swift
//  Holo
//
//  诊断与反馈页：发送反馈邮件 + 查看/导出诊断日志。
//

import SwiftUI

struct HoloDiagnosticsView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var mailUnavailable = false
    @State private var logSummary: String = "正在加载…"
    @State private var logCopied = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {

                // MARK: 反馈
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("遇到问题？")
                        .font(.holoHeading)
                        .foregroundColor(.holoTextPrimary)

                    Text("发送反馈邮件给我们，我们会尽快跟进。邮件会自动附带设备信息，便于定位问题。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Button {
                    let sent = HoloFeedbackMailer.presentMail(includeDiagnosticLog: true)
                    if !sent {
                        mailUnavailable = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("发送反馈邮件")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 14)
                    .padding(.horizontal, HoloSpacing.lg)
                    .frame(maxWidth: .infinity)
                    .background(Color.holoPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .alert("未配置邮件账户", isPresented: $mailUnavailable) {
                    Button("复制邮箱地址") {
                        UIPasteboard.general.string = HoloFeedbackMailer.recipient
                    }
                    Button("好的", role: .cancel) {}
                } message: {
                    Text("你的设备未配置邮件账户。可复制邮箱地址 \(HoloFeedbackMailer.recipient) 通过其他方式发送反馈。")
                }

                // MARK: 诊断日志
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    HStack {
                        Text("诊断日志")
                            .font(.holoHeading)
                            .foregroundColor(.holoTextPrimary)

                        Spacer()

                        Button {
                            UIPasteboard.general.string = logSummary
                            logCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { logCopied = false }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: logCopied ? "checkmark" : "doc.on.doc")
                                Text(logCopied ? "已复制" : "复制")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.holoPrimary)
                        }
                    }

                    Text("系统自动记录的崩溃、卡顿、CPU 异常等信息。MetricKit 每天批量交付一次，当日数据可能需要次日才出现。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    ScrollView {
                        Text(logSummary)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.holoTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                    .padding(HoloSpacing.md)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoBackground)
        .navigationTitle("诊断与反馈")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .task {
            loadLogSummary()
        }
    }

    private func loadLogSummary() {
        if let export = HoloDiagnosticLogger.shared.exportAllLogs() {
            logSummary = export.summary
        } else {
            logSummary = "（暂无诊断日志）"
        }
    }
}
