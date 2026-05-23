//
//  InsightFeedbackSheet.swift
//  Holo
//
//  洞察卡片反馈 Sheet
//  两维反馈：准确性（准/不准）+ 价值感（有用/没用）
//  选"不准"必须选择原因
//

import SwiftUI

struct InsightFeedbackSheet: View {

    let insightId: UUID
    let cardId: String?
    let cardType: MemoryInsightCardType
    let moduleHint: String?

    @State private var accuracyRating: AccuracyRating?
    @State private var valueRating: ValueRating?
    @State private var reasonType: FeedbackReasonType?
    @State private var userCorrection: String = ""
    @State private var showReasonPicker: Bool = false
    @State private var isSubmitting: Bool = false

    @Environment(\.dismiss) private var dismiss

    private let repository = MemoryInsightRepository()

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    // 准确性
                    accuracySection

                    // 价值感
                    valueSection

                    // 不准原因（仅在选了 inaccurate 时展示）
                    if accuracyRating == .inaccurate {
                        reasonSection
                    }

                    // 用户补充说明
                    correctionSection
                }
                .padding(HoloSpacing.lg)
            }
            .navigationTitle("反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") { submitFeedback() }
                        .disabled(!canSubmit || isSubmitting)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Accuracy

    private var accuracySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("准确性")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                feedbackChip(
                    title: "准",
                    icon: "checkmark.circle",
                    isSelected: accuracyRating == .accurate
                ) { accuracyRating = .accurate }

                feedbackChip(
                    title: "不准",
                    icon: "xmark.circle",
                    isSelected: accuracyRating == .inaccurate
                ) {
                    accuracyRating = .inaccurate
                    showReasonPicker = true
                }
            }
        }
    }

    // MARK: - Value

    private var valueSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("价值感")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                feedbackChip(
                    title: "有用",
                    icon: "hand.thumbsup",
                    isSelected: valueRating == .useful
                ) { valueRating = .useful }

                feedbackChip(
                    title: "没用",
                    icon: "hand.thumbsdown",
                    isSelected: valueRating == .notUseful
                ) { valueRating = .notUseful }
            }
        }
    }

    // MARK: - Reason

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("不准原因")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: HoloSpacing.xs) {
                ForEach(FeedbackReasonType.allCases, id: \.self) { reason in
                    reasonChip(reason: reason)
                }
            }
        }
    }

    private func reasonChip(reason: FeedbackReasonType) -> some View {
        Button {
            reasonType = reason
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: reasonType == reason ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(reasonType == reason ? .holoPrimary : .holoTextPlaceholder)

                Text(reason.displayName)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)

                Spacer()
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(reasonType == reason ? Color.holoPrimary.opacity(0.08) : Color.holoGlassBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(reasonType == reason ? Color.holoPrimary.opacity(0.3) : Color.holoBorder.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Correction

    private var correctionSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("补充说明（可选）")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            TextField("你觉得哪里有问题？", text: $userCorrection, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.holoCaption)
                .lineLimit(2...4)
                .padding(HoloSpacing.sm)
                .background(Color.holoGlassBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(Color.holoBorder.opacity(0.45), lineWidth: 1)
                )
        }
    }

    // MARK: - Components

    private func feedbackChip(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: isSelected ? "\(icon).fill" : icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.holoCaption)
            }
            .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(isSelected ? Color.holoPrimary.opacity(0.1) : Color.holoGlassBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(isSelected ? Color.holoPrimary.opacity(0.3) : Color.holoBorder.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        // 至少选一个维度
        guard accuracyRating != nil || valueRating != nil else { return false }
        // 选了"不准"必须选原因
        if accuracyRating == .inaccurate && reasonType == nil { return false }
        return true
    }

    private func submitFeedback() {
        isSubmitting = true

        let module = deriveModule()
        let correction = userCorrection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : userCorrection.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try repository.saveFeedback(
                insightId: insightId,
                cardId: cardId,
                accuracyRating: accuracyRating,
                valueRating: valueRating,
                reasonType: reasonType,
                module: module,
                patternType: nil,
                userCorrection: correction
            )

            // dataWrong 单独记录到 debug 日志
            if reasonType == .dataWrong {
                MemoryInsightDebugLogService.shared.logDataWrong(
                    insightId: insightId,
                    cardId: cardId,
                    userCorrection: correction,
                    module: module
                )
            }

            dismiss()
        } catch {
            // 反馈失败不影响用户体验，静默处理
            dismiss()
        }
    }

    /// 从 cardType 推导 module 字符串
    private func deriveModule() -> String? {
        switch cardType {
        case .habit: return "habit"
        case .finance: return "finance"
        case .task: return "task"
        case .thought: return "thought"
        case .milestone: return "milestone"
        case .crossDomain: return "crossDomain"
        case .overview: return moduleHint
        case .anomaly: return moduleHint
        }
    }
}
