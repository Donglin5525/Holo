//
//  HoloMemoryInaccurateFeedbackSheet.swift
//  Holo
//
//  「不对」之后的纠正弹层（减法版原型 ⑧）：不再弹三分选择题，
//  用户只说一句哪里不对；三个快捷提示可选不强制。
//  提交映射：理解错了→.understanding、依据对不上→.evidence、
//  现在不一样了→.applicability；未选时默认 .understanding，自由文本进 reason。
//  记录路径（详情页）不带 scope，只取 reason。
//

import SwiftUI

/// 快捷提示 chip：选中时映射到知识层 markInaccurate 的 scope。
enum HoloMemoryInaccurateChip: String, CaseIterable, Identifiable {
    case understanding = "理解错了"
    case evidence = "依据对不上"
    case applicability = "现在不一样了"

    var id: String { rawValue }

    var scope: HoloKnowledgeInaccurateScope {
        switch self {
        case .understanding: return .understanding
        case .evidence: return .evidence
        case .applicability: return .applicability
        }
    }
}

struct HoloMemoryInaccurateFeedbackSheet: View {
    /// 「算了」/ 关闭。
    let onCancel: () -> Void
    /// 提交：reason 为自由文本（可为空），scope 未选 chip 时默认 .understanding。
    let onSubmit: (_ reason: String?, _ scope: HoloKnowledgeInaccurateScope) -> Void

    @State private var text = ""
    @State private var selectedChip: HoloMemoryInaccurateChip?
    @FocusState private var fieldFocused: Bool

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedChip != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color.holoToolBorder)
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 4) {
                Text("哪里不对？")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.holoToolText)
                Text("说一句就行，我来改")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .padding(.horizontal, 20)

            TextField("比如：这次是替朋友买的，我没养猫", text: $text, axis: .vertical)
                .font(.system(size: 14))
                .foregroundStyle(Color.holoToolText)
                .tint(Color.holoToolAction)
                .focused($fieldFocused)
                .lineLimit(2...4)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
                )
                .padding(.horizontal, 20)
                .padding(.top, 14)

            // 三个可选快捷 chip（不强制选；未选按理解错处理）。大字号横排放不下时自动改竖排。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(HoloMemoryInaccurateChip.allCases) { chip in
                        quickChip(chip)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(HoloMemoryInaccurateChip.allCases) { chip in
                        quickChip(chip)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            HStack(spacing: 8) {
                Button {
                    onCancel()
                } label: {
                    Text("算了")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: HoloRadius.md)
                                .strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
                        )
                }

                Button {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSubmit(trimmed.isEmpty ? nil : trimmed, (selectedChip ?? .understanding).scope)
                } label: {
                    Text("提交")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(canSubmit ? Color.holoToolOnAction : Color.holoToolTextSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            canSubmit ? Color.holoToolAction : Color.holoToolInset,
                            in: RoundedRectangle(cornerRadius: HoloRadius.md)
                        )
                }
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Text("快捷提示可不选；系统按这句话自动归类：理解错→停用并记你的纠正；依据对不上→重核来源；现在不一样了→更新范围。")
                .font(.system(size: 11))
                .foregroundStyle(Color.holoToolTextSecondary.opacity(0.85))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolBackground)
        .presentationDragIndicator(.hidden)
        .presentationDetents([.medium])
        .onAppear { fieldFocused = true }
    }

    private func quickChip(_ chip: HoloMemoryInaccurateChip) -> some View {
        let isSelected = selectedChip == chip
        return Button {
            withAnimation(HoloAnimation.quick) {
                selectedChip = isSelected ? nil : chip
            }
        } label: {
            Text(chip.rawValue)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.holoToolAction : Color.holoToolTextSecondary)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(
                    isSelected ? Color.holoToolAction.opacity(0.08) : Color.holoToolSurface,
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(isSelected ? Color.holoToolAction.opacity(0.5) : Color.holoToolBorder, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
