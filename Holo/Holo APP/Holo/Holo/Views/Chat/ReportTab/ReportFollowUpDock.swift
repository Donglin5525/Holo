//
//  ReportFollowUpDock.swift
//  Holo
//
//  报告详情页的「报告内追问」UI：
//  · ReportFollowUpDock —— 底部常驻区（输入条 / 生成中 / 失败重试三态）
//  · ReportFollowUpRecordsSection —— 正文尾部的追问记录区块
//    （血统挂载的子报告列表 + 生成中卡片）
//

import SwiftUI

// MARK: - 底部追问 Dock

struct ReportFollowUpDock: View {
    @ObservedObject var controller: ReportFollowUpController

    var body: some View {
        VStack(spacing: 7) {
            switch controller.phase {
            case .idle:
                inputDock
            case .running:
                runningDock
            case .failed(let message):
                failedDock(message)
            }
        }
        .padding(.horizontal, 23)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    // MARK: 输入态

    private var inputDock: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                TextField("就这份报告继续问…", text: $controller.draftText, axis: .vertical)
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1...3)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color.holoBackground.opacity(0.9), in: Capsule())
                    .overlay(
                        Capsule().stroke(Color.holoBorder.opacity(0.6), lineWidth: 0.8)
                    )
                    .onSubmit { controller.sendDraft() }

                Button {
                    controller.sendDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            canSend ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.3),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送追问")
            }

            quotaNote
        }
    }

    /// 额度说明行：发送前讲清成本；额度用尽时换成恢复提示。
    @ViewBuilder
    private var quotaNote: some View {
        if let remaining = controller.quotaRemaining, remaining <= 0 {
            Text("深度洞察额度已用完，恢复后可继续追问；普通对话不受影响")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.holoError)
        } else {
            Text(quotaNoteText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.holoTextSecondary.opacity(0.9))
        }
    }

    private var quotaNoteText: String {
        if let remaining = controller.quotaRemaining {
            return "追问会生成一份新报告挂在本报告下 · 消耗深度洞察额度（本周剩 \(remaining) 次）"
        }
        return "追问会生成一份新报告挂在本报告下 · 消耗深度洞察额度"
    }

    private var canSend: Bool {
        !controller.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: 生成中

    private var runningDock: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.85)

            VStack(alignment: .leading, spacing: 2) {
                Text("追问生成中")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                Text(runningDetailText)
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                controller.cancelRunning()
            } label: {
                Text("取消")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.holoBackground.opacity(0.9), in: Capsule())
                    .overlay(
                        Capsule().stroke(Color.holoBorder.opacity(0.6), lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消追问")
        }
    }

    /// 生成中副文案：优先用消息快照自带的 Agent 状态（与聊天卡同源），
    /// 快照未就绪时用问题本身兜底，不虚构进度。
    private var runningDetailText: String {
        if let message = controller.runningMessage {
            return HoloAgentChatStatusPresenter.display(from: message.content).title
        }
        return "完成后出现在上面的「追问记录」里"
    }

    // MARK: 失败重试

    private func failedDock(_ message: String) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.holoError)
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.holoError.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    controller.retryLast(text: controller.draftText)
                } label: {
                    Text("重试")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.holoPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("原样重试这次追问")
            }
        }
    }
}

// MARK: - 追问记录区块

struct ReportFollowUpRecordsSection: View {
    typealias ReportArchiveDTO = ChatMessageRepository.ReportArchiveDTO

    @ObservedObject var controller: ReportFollowUpController
    /// 条目点击 → 打开子报告详情（由路由层转消息快照）
    var onOpen: (ReportArchiveDTO) -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                Text("追问记录")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                if !controller.followUps.isEmpty {
                    Text("\(controller.followUps.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.holoBackground.opacity(0.9), in: Capsule())
                }
                Spacer(minLength: 8)
                Text("就这份报告问过的问题")
                    .font(.system(size: 10.5))
                    .foregroundColor(.holoTextSecondary.opacity(0.8))
            }

            if controller.phase == .running {
                runningCard
            }

            ForEach(controller.followUps) { entry in
                recordRow(entry)
            }

            if controller.followUps.isEmpty && controller.phase != .running {
                Text("还没有追问，在下面输入框直接问")
                    .font(.system(size: 11.5))
                    .foregroundColor(.holoTextSecondary.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .stroke(Color.holoBorder.opacity(0.55), lineWidth: 0.8)
        )
    }

    // MARK: 生成中卡

    private var runningCard: some View {
        HStack(spacing: 9) {
            ProgressView()
                .scaleEffect(0.75)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.runningQuestion ?? "正在追查")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.holoPrimaryDark)
                    .lineLimit(2)
                Text(runningDetailText)
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(Color.holoPrimary.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private var runningDetailText: String {
        if let message = controller.runningMessage {
            let status = HoloAgentChatStatusPresenter.display(from: message.content)
            return status.detail.isEmpty ? "正在翻证据，通常 1 分钟内出结果" : status.detail
        }
        return "正在翻证据，通常 1 分钟内出结果"
    }

    // MARK: 记录条目

    private func recordRow(_ entry: ReportArchiveDTO) -> some View {
        Button {
            onOpen(entry)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let relation = entry.followUpRelationLabel {
                        Text(relation)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color.holoFollowUpTint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.holoFollowUpTint.opacity(0.14), in: Capsule())
                    }

                    Text(Self.dateFormatter.string(from: entry.timestamp))
                        .font(.system(size: 10.5))
                        .foregroundColor(.holoTextSecondary.opacity(0.85))

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                }

                Text(entry.question ?? entry.title ?? "一次追问")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary = entry.summary {
                    HStack(alignment: .top, spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.holoPrimary.opacity(0.45))
                            .frame(width: 2.5)
                        Text(summary)
                            .font(.system(size: 11.5))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 2.5) {
                    Text("看这份追问报告")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.holoPrimary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(Color.holoBackground.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .stroke(Color.holoBorder.opacity(0.5), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开这份追问生成的报告")
    }
}
