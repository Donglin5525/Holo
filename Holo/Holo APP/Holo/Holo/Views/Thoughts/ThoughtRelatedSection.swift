//
//  ThoughtRelatedSection.swift
//  Holo
//
//  相关旧想法（2026-09-24 方案 §5.2：B 阶段首个用户可感知能力）
//
//  阅读某条想法时，用当前正文的本机向量召回 1-3 条相关的旧想法原文链接；
//  相似度低于门槛安静留空；「不相关」反馈后同版本不再重复推荐（related_feedback
//  墓碑）；不能把「语义相似」表述成「观点一致」。
//

import SwiftUI
import CoreData

// MARK: - 召回

enum ThoughtRelatedRecall {

    struct RelatedItem: Identifiable, Equatable {
        let id: UUID
        let content: String
        let createdAt: Date
        let similarity: Float
    }

    /// 本机召回：当前正文版本向量 → 索引近邻 → 排除自身/反馈墓碑/软删/归档
    /// → 校准相似度门槛 → 取回原文（截断展示）。
    static func findRelated(thoughtID: UUID,
                            content: String,
                            limit: Int = 3) async -> [RelatedItem] {
        guard ThoughtSemanticFeatureFlags.resurfacingEnabled else { return [] }
        guard let store = await ThoughtSemanticPipeline.shared.store,
              let index = await ThoughtSemanticPipeline.shared.index else { return [] }

        let hash = ThoughtEmbeddingStore.contentHash(of: content)
        guard let vector = try? await store.activeVector(thoughtID: thoughtID, contentHash: hash),
              !vector.isEmpty else { return [] }

        let dismissed = (try? await store.relatedFeedbackIDs(thoughtID: thoughtID)) ?? []
        let excluded = dismissed.union([thoughtID])
        let neighbors = (try? await index.search(
            vector: vector,
            topK: limit + excluded.count + 2,
            filter: SemanticIndexFilter(excludedIDs: excluded))) ?? []

        let (calibration, _) = ThoughtSemanticCalibration.current()
        let qualified = neighbors
            .filter { $0.similarity >= calibration.recallMinCosine }
            .prefix(limit)
        guard !qualified.isEmpty else { return [] }

        // 取回原文快照（读侧与写侧同样的值快照纪律：托管对象不跨线程）
        let wanted = qualified.map { $0.thoughtID }
        let snapshots: [UUID: (content: String, createdAt: Date)] = await MainActor.run {
            let context = CoreDataStack.shared.viewContext
            var out: [UUID: (String, Date)] = [:]
            context.performAndWait {
                let request = Thought.fetchRequest()
                request.predicate = NSPredicate(
                    format: "id IN %@ AND deletedAt == nil AND isArchived == NO", wanted)
                for thought in (try? context.fetch(request)) ?? [] {
                    if let id = thought.value(forKey: "id") as? UUID,
                       let content = thought.value(forKey: "content") as? String {
                        out[id] = (content, thought.createdAt)
                    }
                }
            }
            return out
        }
        return qualified.compactMap { neighbor in
            guard let snap = snapshots[neighbor.thoughtID] else { return nil }
            return RelatedItem(id: neighbor.thoughtID,
                               content: snap.content,
                               createdAt: snap.createdAt,
                               similarity: neighbor.similarity)
        }
    }
}

// MARK: - 展示

/// 「你之前也写过」区（编辑器阅读场景底部）。没有命中时不渲染（安静留空）。
struct ThoughtRelatedSection: View {

    let thoughtID: UUID
    let content: String
    /// 点相关旧想法跳原文（编辑器切换目标）
    var onOpenThought: ((UUID) -> Void)? = nil

    @State private var items: [ThoughtRelatedRecall.RelatedItem] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, !items.isEmpty {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Label("你之前也写过", systemImage: "sparkle.magnifyingglass")
                        .font(.holoLabel)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoAI)

                    ForEach(items) { item in
                        relatedRow(item)
                    }

                    Text("按内容相关推荐，不代表观点一致")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                }
                .padding(HoloSpacing.md)
                .background(RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color.holoAI.opacity(0.05)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "相关旧想法，共\(items.count)条"))
            }
        }
        // 编辑器以 id(thought+正文长度) 重建本视图，task 随之重跑——正文版本变化自动重召回
        .task(id: "\(thoughtID.uuidString)-\(content.count)") {
            startLoading()
        }
    }

    private func relatedRow(_ item: ThoughtRelatedRecall.RelatedItem) -> some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Button {
                onOpenThought?(item.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.content)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.createdAt.formatted(.dateTime.month().day()))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                }
            }
            .buttonStyle(.plain)

            Button {
                markUnrelated(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextPlaceholder)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "不相关"))
        }
        .padding(.vertical, 2)
    }

    private func markUnrelated(_ item: ThoughtRelatedRecall.RelatedItem) {
        Task {
            if let store = await ThoughtSemanticPipeline.shared.store {
                try? await store.recordRelatedFeedback(
                    thoughtID: thoughtID,
                    relatedID: item.id,
                    basisHash: ThoughtEmbeddingStore.contentHash(of: content))
            }
            withAnimation(HoloAnimation.quick) {
                items.removeAll { $0.id == item.id }
            }
        }
    }

    private func startLoading() {
        guard !loaded else { return }
        loaded = true
        Task {
            let result = await ThoughtRelatedRecall.findRelated(thoughtID: thoughtID, content: content)
            await MainActor.run {
                withAnimation(HoloAnimation.smooth) {
                    items = result
                }
            }
        }
    }
}

// MARK: - 相关旧想法跳原文通知

extension Notification.Name {
    /// 编辑器「你之前也写过」点某条旧想法：请求列表切换编辑器目标（object: 目标 thoughtId）
    static let thoughtRequestOpenEditor = Notification.Name("thoughtRequestOpenEditor")
}


// MARK: - 帮我想想（按需洞察 §5.1）

struct ThoughtInsightRequestDTO: Codable {
    var schemaVersion: Int = 1
    var operationId: String
    var textRevision: String
    var text: String
}

struct ThoughtInsightResponseDTO: Codable {
    struct Observation: Codable, Identifiable {
        let quote: String
        let note: String
        var id: String { quote + note }
    }
    let schemaVersion: Int
    let operationId: String
    let textRevision: String
    let observations: [Observation]?
    let perspectives: [String]?
    let nextStep: String?
}

/// 「帮我想想」入口（编辑器内，正文成形后出现）。请求只带当前笔记脱敏正文。
struct ThoughtInsightButton: View {

    let content: String
    @State private var showSheet = false

    var body: some View {
        Button {
            HapticManager.light()
            showSheet = true
        } label: {
            Label("帮我想想", systemImage: "lightbulb.max")
                .font(.holoCaption)
                .fontWeight(.semibold)
                .foregroundColor(.holoAI)
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.holoAI.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "基于这条想法请 AI 帮忙思考"))
        .sheet(isPresented: $showSheet) {
            ThoughtInsightSheet(content: content)
        }
    }
}

struct ThoughtInsightSheet: View {

    let content: String
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading
        case done
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var result: ThoughtInsightResponseDTO?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    switch phase {
                    case .loading:
                        VStack(spacing: HoloSpacing.sm) {
                            ProgressView().tint(.holoAI)
                            Text("正在基于这条想法思考…")
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, HoloSpacing.xl)

                    case .failed(let reason):
                        VStack(spacing: HoloSpacing.sm) {
                            Image(systemName: "cloud.slash")
                                .font(.system(size: 26))
                                .foregroundColor(.holoTextPlaceholder)
                            Text(reason)
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                                .multilineTextAlignment(.center)
                            if let retry = retryAction {
                                Button("重试", action: retry)
                                    .font(.holoCaption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.holoPrimary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, HoloSpacing.xl)

                    case .done:
                        if let result {
                            if let observations = result.observations, !observations.isEmpty {
                                insightSection(title: "你写过的", icon: "text.quote") {
                                    ForEach(observations) { obs in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\"\(obs.quote)\"")
                                                .font(.holoCaption)
                                                .foregroundColor(.holoTextPrimary)
                                            if !obs.note.isEmpty {
                                                Text(obs.note)
                                                    .font(.holoTinyLabel)
                                                    .foregroundColor(.holoTextSecondary)
                                            }
                                        }
                                        .padding(HoloSpacing.sm)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: HoloRadius.sm)
                                            .fill(Color.holoCardBackground))
                                    }
                                }
                            }
                            if let perspectives = result.perspectives, !perspectives.isEmpty {
                                insightSection(title: "AI 的思考（推测，请自行判断）", icon: "sparkles") {
                                    ForEach(Array(perspectives.enumerated()), id: \.offset) { _, p in
                                        Text(p)
                                            .font(.holoCaption)
                                            .foregroundColor(.holoTextPrimary)
                                            .padding(HoloSpacing.sm)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(RoundedRectangle(cornerRadius: HoloRadius.sm)
                                                .fill(Color.holoAI.opacity(0.05)))
                                    }
                                }
                            }
                            if let next = result.nextStep, !next.isEmpty {
                                Label(next, systemImage: "figure.walk")
                                    .font(.holoCaption)
                                    .foregroundColor(.holoPrimary)
                                    .padding(HoloSpacing.sm)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: HoloRadius.sm)
                                        .fill(Color.holoPrimary.opacity(0.06)))
                            }
                        }
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.xl)
            }
            .background(Color.holoBackground)
            .navigationTitle(String(localized: "帮我想想"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private var retryAction: (() -> Void)? {
        guard case .failed = phase else { return nil }
        return {
            phase = .loading
            Task { await load() }
        }
    }

    @ViewBuilder
    private func insightSection<Content: View>(title: String, icon: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Label(title, systemImage: icon)
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextSecondary)
            content()
        }
    }

    private func load() async {
        let redacted = ThoughtIndexV2Policy.redactedText(forUpload: content)
        guard !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .failed("这条想法还没有可分析的文本内容")
            return
        }
        let request = ThoughtInsightRequestDTO(
            operationId: UUID().uuidString,
            textRevision: ThoughtEmbeddingStore.contentHash(of: content),
            text: String(redacted.prefix(8_000)))
        do {
            let response = try await HoloBackendAIProvider().thoughtInsight(request)
            result = response
            phase = .done
        } catch {
            let ns = error as NSError
            if ns.code == 503 {
                phase = .failed("该能力暂不可用（服务未开放）\n保存与相关想法不受影响")
            } else if ns.code == 429 {
                phase = .failed("今日次数已用完，明天再来")
            } else {
                phase = .failed("网络或服务暂时不可用\n保存与相关想法不受影响")
            }
        }
    }
}


// MARK: - 语义搜索（C 阶段混合召回 §8.C.1）

enum SemanticSearchHelper {

    /// 语义召回：查询词脱敏 → 后端 embedding（一次最小请求）→ 本机索引 topK
    /// → 过滤有效（未删未归档）想法。离线/未索引/后端不可用返回 nil（调用方
    /// 回落纯关键词，离线搜索照常）。
    static func search(query: String, topK: Int = 20) async -> [UUID: Float]? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let index = await ThoughtSemanticPipeline.shared.index else { return nil }

        let redacted = ThoughtIndexV2Policy.redactedText(forUpload: query)
        guard !redacted.isEmpty else { return nil }
        let provider = await MainActor.run { HoloBackendAIProvider() }
        guard let vectors = try? await provider.embed(texts: [redacted]),
              let raw = vectors.first, !raw.isEmpty else { return nil }
        let vector = SemanticVectorMath.normalized(raw.map(Float.init))

        let neighbors = (try? await index.search(vector: vector, topK: topK, filter: nil)) ?? []
        guard !neighbors.isEmpty else { return [:] }

        // 有效性过滤（软删/归档不出现）
        let wanted = neighbors.map(\.thoughtID)
        let valid: Set<UUID> = await MainActor.run {
            let context = CoreDataStack.shared.viewContext
            var out = Set<UUID>()
            context.performAndWait {
                let request = Thought.fetchRequest()
                request.predicate = NSPredicate(
                    format: "id IN %@ AND deletedAt == nil AND isArchived == NO", wanted)
                for thought in (try? context.fetch(request)) ?? [] {
                    if let id = thought.value(forKey: "id") as? UUID {
                        out.insert(id)
                    }
                }
            }
            return out
        }
        var hits: [UUID: Float] = [:]
        for neighbor in neighbors where valid.contains(neighbor.thoughtID) {
            hits[neighbor.thoughtID] = neighbor.similarity
        }
        return hits
    }
}
