//
//  DataGapHintCard.swift
//  Holo
//
//  Agent 分析结果的「可能遗漏数据」提示卡片。
//  根据 complexity 自动选择三种交互形态：
//  - single：单组同类商品 → 按钮确认（都算上/不算/部分算）
//  - mixed：多组不同商品 → 纯对话提示（引导用户回复）
//  - 部分算展开后 → 逐条勾选
//

import SwiftUI

struct DataGapHintCard: View {
    let hints: [HoloRenderedDataGapHint]
    var onRecalculate: (([String]) -> Void)? = nil

    @State private var resolvedHints: Set<String> = []   // 已处理的 hint description
    @State private var showSelectionFor: String? = nil   // 当前展开逐条勾选的 hint description
    @State private var selectedExcerpts: Set<String> = [] // 逐条勾选选中的

    var body: some View {
        let visible = hints.filter { !resolvedHints.contains($0.description) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(visible) { hint in
                    hintView(hint)
                }
            }
        }
    }

    @ViewBuilder
    private func hintView(_ hint: HoloRenderedDataGapHint) -> some View {
        if hint.complexity == "single" {
            singleHintView(hint)
        } else {
            mixedHintView(hint)
        }
    }

    // MARK: - 形态二：单组确认按钮

    private func singleHintView(_ hint: HoloRenderedDataGapHint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.orange)
                Text(hint.description)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.holoTextPrimary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showSelectionFor == hint.description {
                // 形态三：逐条勾选
                selectionView(hint)
            } else {
                // 形态二：三个按钮
                HStack(spacing: 8) {
                    Button {
                        onRecalculate?(hint.suggestedKeywords)
                        resolvedHints.insert(hint.description)
                    } label: {
                        Text("都算上")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.holoPrimary)
                            .clipShape(Capsule())
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSelectionFor = hint.description
                        }
                    } label: {
                        Text("部分算")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.holoPrimary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    Button {
                        resolvedHints.insert(hint.description)
                    } label: {
                        Text("不用了")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 形态三：逐条勾选

    private func selectionView(_ hint: HoloRenderedDataGapHint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(hint.sampleExcerpts.prefix(10), id: \.self) { excerpt in
                Button {
                    if selectedExcerpts.contains(excerpt) {
                        selectedExcerpts.remove(excerpt)
                    } else {
                        selectedExcerpts.insert(excerpt)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selectedExcerpts.contains(excerpt) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14))
                            .foregroundColor(selectedExcerpts.contains(excerpt) ? .holoPrimary : .holoTextSecondary)
                        Text(excerpt)
                            .font(.system(size: 11.5))
                            .foregroundColor(.holoTextPrimary.opacity(0.8))
                            .lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Button {
                    // 把选中的 excerpt 里包含的关键词提取出来重算
                    // 简化处理：从选中的条目里提取关键词，回退到全部 suggestedKeywords
                    let keywords = selectedExcerpts.isEmpty ? hint.suggestedKeywords : extractKeywords(from: selectedExcerpts, fallback: hint.suggestedKeywords)
                    onRecalculate?(keywords)
                    resolvedHints.insert(hint.description)
                } label: {
                    Text("确认并重算")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.holoPrimary)
                        .clipShape(Capsule())
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSelectionFor = nil
                        selectedExcerpts.removeAll()
                    }
                } label: {
                    Text("返回")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 形态一：纯对话提示

    private func mixedHintView(_ hint: HoloRenderedDataGapHint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.orange)
                Text(hint.description)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.holoTextPrimary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !hint.sampleExcerpts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(hint.sampleExcerpts.prefix(5), id: \.self) { excerpt in
                        Text("· \(excerpt)")
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary.opacity(0.85))
                            .lineLimit(2)
                    }
                }
                .padding(.leading, 18)
            }

            Text("回复告诉我怎么处理，比如「都算上」「只算\(hint.suggestedKeywords.first ?? "")」，或补充其他品牌。")
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary.opacity(0.7))
                .padding(.leading, 18)
        }
        .padding(12)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 辅助

    /// 从用户选中的条目里提取关键词。简单实现：检查每条 excerpt 是否包含 suggestedKeywords 中的词。
    private func extractKeywords(from selected: Set<String>, fallback: [String]) -> [String] {
        var matched: Set<String> = []
        for excerpt in selected {
            for keyword in fallback where excerpt.localizedCaseInsensitiveContains(keyword) {
                matched.insert(keyword)
            }
        }
        return matched.isEmpty ? fallback : Array(matched)
    }
}
