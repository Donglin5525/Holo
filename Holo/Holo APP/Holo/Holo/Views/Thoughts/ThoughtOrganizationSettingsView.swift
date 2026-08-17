//
//  ThoughtOrganizationSettingsView.swift
//  Holo
//
//  P1 知识树「整理设置」页（东林拍板：想法模块 AI 整理设置统一收口知识树）
//  内容：AI 自动分类开关（自系统设置迁移，一处事实源）+ 标签治理入口 + 说明文案
//  方案：docs/thoughts/plans/2026-08-16-想法智能标签端侧治理实施方案.md §4.1
//

import SwiftUI

struct ThoughtOrganizationSettingsView: View {

    @AppStorage(ThoughtAIClassificationPolicy.isEnabledKey)
    private var isThoughtAutoOrganizationEnabled: Bool = true

    @State private var showTagManagement: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $isThoughtAutoOrganizationEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI 自动分类")
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)
                            Text("保存想法后自动从已启用主题中单选分类；无法判断则进入未归类")
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                    .tint(.holoPrimary)
                } header: {
                    Text("自动整理")
                } footer: {
                    Text("关闭后新想法不再自动请求 AI，但历史标签不受影响；你仍可对单条想法点「重新整理」，或在想法列表手动批量整理。")
                }

                Section {
                    Button {
                        showTagManagement = true
                    } label: {
                        HStack {
                            Label("标签治理", systemImage: "tag")
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                } header: {
                    Text("标签库")
                } footer: {
                    Text("集中管理「我的标签」与「AI 建议标签」：确认采用、改名、合并或删除，避免标签越积越碎。")
                }

                #if DEBUG
                semanticDebugSection
                feedbackDebugSection
                #endif
            }
            .navigationTitle("整理设置")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showTagManagement) {
                ThoughtTagManagementView()
            }
            #if DEBUG
            .sheet(isPresented: $showEvaluationExport) {
                if let url = evaluationExportURL {
                    ShareSheet(items: [url])
                }
            }
            #endif
        }
    }

    // MARK: - Debug：语义候选（P2 shadow/inject/回填/评估导出，Release 不编译）

    #if DEBUG
    @AppStorage(ThoughtSemanticCandidateMode.storageKey)
    private var semanticModeRaw: String = ThoughtSemanticCandidateMode.off.rawValue

    @State private var embeddingCount: Int = 0
    @State private var backfillResult: String?
    @State private var backfillRunning = false
    @State private var showEvaluationExport = false
    @State private var evaluationExportURL: URL?

    private var semanticDebugSection: some View {
        Section {
            Picker("语义候选模式", selection: $semanticModeRaw) {
                Text("关闭").tag(ThoughtSemanticCandidateMode.off.rawValue)
                Text("影子（记录不注入）").tag(ThoughtSemanticCandidateMode.shadow.rawValue)
                Text("注入").tag(ThoughtSemanticCandidateMode.inject.rawValue)
            }

            HStack {
                Text("已缓存向量")
                Spacer()
                Text("\(embeddingCount) 条")
                    .foregroundColor(.holoTextSecondary)
            }

            Button("回填语义向量（批量，≤64 条）") {
                guard !backfillRunning else { return }
                backfillRunning = true
                Task {
                    let count = await ThoughtSemanticCandidateEngine.backfill()
                    embeddingCount = await ThoughtEmbeddingStore.shared.count()
                    backfillResult = "回填完成：\(count) 条"
                    backfillRunning = false
                }
            }
            .disabled(backfillRunning)

            if let backfillResult {
                Text(backfillResult)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Button("导出语义评估样本（40 条候选对比）") {
                Task {
                    evaluationExportURL = await SemanticEvaluationExporter.export()
                    if evaluationExportURL != nil { showEvaluationExport = true }
                }
            }
        } header: {
            Text("Debug · 语义候选（P2）")
        } footer: {
            Text("影子=计算并记录但不影响分类；注入=语义近邻标签进入分类候选。评估样本用于人工标注候选池覆盖率（Gate：提升 ≥10pp 才开注入）。")
        }
        .onAppear {
            Task {
                embeddingCount = await ThoughtEmbeddingStore.shared.count()
            }
        }
    }

    // MARK: - Debug：分类反馈（Release 不编译）

    @State private var feedbackSummary: String = ""

    private var feedbackDebugSection: some View {
        Section {
            Button("刷新反馈聚合") {
                Task {
                    let summary = await ThoughtClassificationFeedbackStore.shared.acceptanceSummary()
                    let count = await ThoughtClassificationFeedbackStore.shared.allEvents().count
                    feedbackSummary = "事件 \(count) 条 · 确认 \(summary.confirmed) · 拒绝 \(summary.rejected) · 接受率 \(String(format: "%.0f%%", summary.acceptanceRate * 100))"
                }
            }
            if !feedbackSummary.isEmpty {
                Text(feedbackSummary)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
        } header: {
            Text("Debug · 分类反馈")
        } footer: {
            Text("策略版本 \(ThoughtOrganizationPresentationPolicy.version)；本机记录，不随 iCloud 同步。")
        }
    }
    #endif
}
