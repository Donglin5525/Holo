//
//  HealthInsightEvidenceSheet.swift
//  Holo
//
//  健康洞察「为什么这么说」证据详情（方案 Task 8：每条生活闭环可点开查看证据）。
//  轻量展示洞察标题、摘要、建议、caveat 与引用的同源证据。
//

import SwiftUI

struct HealthInsightEvidenceSheet: View {
    let insight: GeneratedHealthInsight
    let evidence: [HealthInsightEvidence]
    /// 洞察周期徽章文案（与 HealthView 卡头同源：近 N 天 · 起日–止日），nil 时不显示徽章
    var periodBadgeText: String?
    @Environment(\.dismiss) private var dismiss

    private var referencedEvidence: [HealthInsightEvidence] {
        evidence.filter { insight.evidenceIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    // 周期徽章：与主界面洞察卡头同款（真实窗口「近 N 天 · 起日–止日」）
                    if let badgeText = periodBadgeText {
                        Text(badgeText)
                            .font(.system(.caption2, weight: .medium))
                            .foregroundColor(Color.holoToolAI)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.holoToolAI.opacity(0.10))
                            .clipShape(Capsule())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Text(insight.title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(insight.summary)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let action = insight.suggestedAction {
                        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                            Text("一个可以试试的小动作")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextPrimary)
                            Text(action)
                                .font(.holoLabel)
                                .foregroundColor(.holoChart1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let caveat = insight.caveat {
                        Text(caveat)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }

                    if !referencedEvidence.isEmpty {
                        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                            Text("为什么这么说")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextPrimary)

                            ForEach(referencedEvidence) { ev in
                                if ev.metricKey == "habit.record.note" {
                                    NoteEvidenceCard(evidence: ev)
                                } else {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ev.title)
                                            .font(.holoLabel)
                                            .foregroundColor(.holoTextPrimary)
                                        Text(ev.detail)
                                            .font(.holoTinyLabel)
                                            .foregroundColor(.holoTextSecondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(HoloSpacing.sm)
                                    .background(Color.holoCardBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                                }
                            }
                        }
                    }

                    Text("本内容由 AI 基于健康数据分析生成，仅供参考，不构成医疗诊断或专业建议。如有健康问题，请咨询专业医生。")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(HoloSpacing.md)
            }
            .navigationTitle("为什么这么说")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .holoSheetShell()
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

/// 打卡备注证据卡（metricKey == habit.record.note）：
/// 原话全文展示不截断（引文样式），来源行说明这是当时打卡记下的备注。
private struct NoteEvidenceCard: View {
    let evidence: HealthInsightEvidence

    /// 主体名从证据 id 派生：id 形如 `habit-note-yyyyMMdd-习惯名`，
    /// 去掉前缀 habit-note- 后再去掉前 9 个字符（8 位日期 + 1 个「-」），
    /// 与习惯名自身含不含「-」无关
    private var habitName: String? {
        guard let prefixRange = evidence.id.range(of: "habit-note-") else { return nil }
        let remainder = String(evidence.id[prefixRange.upperBound...])
        guard remainder.count > 9 else { return nil }
        let name = String(remainder.dropFirst(9))
        return name.isEmpty ? nil : name
    }

    /// 标题行：本地化日期 + 主体名；occurredAt 缺失或派生失败时兜底显示证据原 title
    private var titleText: String {
        guard let occurredAt = evidence.occurredAt, let name = habitName else {
            return evidence.title
        }
        return "\(Self.noteDayFormatter.string(from: occurredAt)) \(name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleText)
                .font(.holoLabel)
                .foregroundColor(.holoTextPrimary)

            // 引文块：竖引线 + 弯引号包裹的备注原话，不截断、不做展开交互
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.holoTextSecondary.opacity(0.25))
                    .frame(width: 2)

                // 备注原话是动态内容，用 verbatim 避免被当作本地化 key 查表/提取
                Text(verbatim: "“\(evidence.detail)”")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("当时打卡时记下的备注")
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.sm)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    /// 标题日期：App 语言（SeedLanguage）的 MMMd，与 HealthDateNavigator 同源做法
    private static let noteDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = noteLocale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static var noteLocale: Locale {
        switch SeedLanguage.current {
        case .simplifiedChinese: return Locale(identifier: "zh_CN")
        case .traditionalChinese: return Locale(identifier: "zh_TW")
        case .english: return Locale(identifier: "en_US")
        }
    }
}
