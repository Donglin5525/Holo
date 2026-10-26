//
//  ThoughtTagManagementView.swift
//  Holo
//
//  P1 标签治理页（方案 §4.2）：「我的标签 / AI 建议」双分组
//  AI 建议动作：确认采用 / 改名后采用 / 合并到已有 / 全局删除（复用既有 Repository 能力）
//  批量动作先展示受影响想法数；删除前二次确认
//

import SwiftUI
import CoreData

struct ThoughtTagManagementView: View {

    private enum Segment: String, CaseIterable {
        case mine
        case aiSuggested

        var displayName: String {
            switch self {
            case .mine: return String(localized: "我的标签")
            case .aiSuggested: return String(localized: "AI 建议")
            }
        }
    }

    @State private var segment: Segment = .mine
    @State private var recognizedNames: [String] = []
    @State private var unrecognizedAINames: [String] = []
    @State private var assignmentCounts: [String: Int] = [:]
    @State private var recognizedKeys: Set<String> = []
    /// 标签级 AI 排除（2026-10-21）：归一化 key → 标签实体 id；已排除的 key 集合（仅「我的标签」提供）
    @State private var aiScopeTagIDs: [String: UUID] = [:]
    @State private var excludedTagKeys: Set<String> = []
    /// 待确认开启排除的标签（弹确认，与「AI 分析范围」子页同文案）
    @State private var aiScopePending: (tagID: UUID, name: String)? = nil

    /// 待执行改名/合并的标签（弹输入框）
    @State private var renameTarget: String? = nil
    @State private var renameText: String = ""
    /// 待删除标签（先展示受影响数，二次确认）
    @State private var deleteTarget: String? = nil
    @State private var deleteAffectedCount: Int = 0
    @State private var notice: String? = nil
    /// 点行查看该标签下的想法（fullScreenCover 弹层，与主题详情同一交互模式）
    @State private var viewingTag: TagRef? = nil

    @Environment(\.dismiss) private var dismiss

    private let repository = ThoughtRepository()
    private let service = ThoughtOrganizationService()

    var body: some View {
        NavigationStack {
            List {
                Picker("分组", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { seg in
                        Text(seg.displayName).tag(seg)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    let names = segment == .mine ? recognizedNames : unrecognizedAINames
                    if names.isEmpty {
                        Text(segment == .mine ? String(localized: "还没有你确认过的标签") : String(localized: "暂无待处理的 AI 建议标签"))
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }
                    ForEach(names, id: \.self) { name in
                        tagRow(name)
                    }
                } footer: {
                    Text(segment == .mine
                         ? String(localized: "你手动创建、正文 # 或确认过的标签，是 AI 优先复用的词表。")
                         : String(localized: "仅来自 AI 建议、尚未被你认可的标签；确认后才会进入你的标签库。"))
                }
            }
            .navigationTitle("标签治理")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .holoSheetShell()
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.navTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { loadData() }
            #if canImport(UIKit)
            .fullScreenCover(item: $viewingTag) { tag in
                TagThoughtListView(tagName: tag.name)
            }
            #else
                        .sheet(item: $viewingTag) { tag in
                TagThoughtListView(tagName: tag.name)
            }
            #endif
            .alert("重命名标签", isPresented: renameBinding) {
                TextField("新标签名", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("确认") { applyRename() }
            } message: {
                Text("把 #\(ThoughtTagNormalizer.displayName(renameTarget ?? "")) 改名为（与已有标签同名即为合并）")
            }
            .alert("删除标签", isPresented: deleteBinding) {
                Button("取消", role: .cancel) { deleteTarget = nil }
                Button("删除", role: .destructive) { applyDelete() }
            } message: {
                Text("将影响 \(deleteAffectedCount) 条想法的标签关联；原文与手动标签不受影响，AI 也不会立即再建回。")
            }
            .alert("把「\(aiScopePending?.name ?? "")」留给自己？", isPresented: aiScopeBinding) {
                Button("暂不", role: .cancel) { aiScopePending = nil }
                Button("开启排除") { applyAIScopeExclusion() }
            } message: {
                Text("带「\(aiScopePending?.name ?? "")」标签的想法将退出所有 AI 处理：不归类主题、不打自动标签、不进洞察与复盘——AI 不会知道它们的存在。\n\n已有的 AI 归类会一并撤下，随时可以关闭恢复。")
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                        .padding(.horizontal, HoloSpacing.md)
                        .padding(.vertical, HoloSpacing.sm)
                        .background(Capsule().fill(Color.holoCardBackground).shadow(radius: 4))
                        .padding(.bottom, HoloSpacing.lg)
                        .task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            withAnimation { self.notice = nil }
                        }
                }
            }
        }
    }

    // MARK: - 行视图

    private func tagRow(_ name: String) -> some View {
        let display = ThoughtTagNormalizer.displayName(name)
        let key = ThoughtTagNormalizer.key(name)
        let count = assignmentCounts[key] ?? 0
        let aiExcluded = segment == .mine && excludedTagKeys.contains(key)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("#\(display)")
                        .font(.holoBody)
                        .foregroundColor(aiExcluded ? Color.holoAIShieldTint : .holoTextPrimary)
                    if aiExcluded {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.holoAIShieldTint)
                    }
                }
                Text(aiExcluded
                     ? String(localized: "\(count) 条想法 · 已排除出 AI 分析")
                     : (count > 0 ? String(localized: "\(count) 条想法") : String(localized: "未使用")))
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            Spacer()
            Menu {
                if segment == .aiSuggested {
                    Button {
                        confirmAdopt(name)
                    } label: {
                        Label("确认采用", systemImage: "checkmark")
                    }
                }
                // 标签级 AI 排除：仅「我的标签」提供（排除判定只认用户关联，AI 建议标签给了也永不生效）
                if segment == .mine, let tagID = aiScopeTagIDs[key] {
                    if aiExcluded {
                        Button {
                            setAIExcluded(tagID: tagID, excluded: false)
                        } label: {
                            Label("恢复参与 AI 分析", systemImage: "arrow.uturn.backward.circle")
                        }
                    } else {
                        Button {
                            aiScopePending = (tagID, display)
                        } label: {
                            Label("不参与 AI 分析", systemImage: "checkmark.shield")
                        }
                    }
                }
                Button {
                    renameTarget = name
                    renameText = display
                } label: {
                    Label(segment == .mine ? String(localized: "改名") : String(localized: "改名后采用"), systemImage: "pencil")
                }
                if segment == .aiSuggested, !recognizedNames.isEmpty {
                    Menu {
                        ForEach(recognizedNames, id: \.self) { target in
                            Button("#\(ThoughtTagNormalizer.displayName(target))") {
                                mergeInto(name, target: target)
                            }
                        }
                    } label: {
                        Label("合并到已有标签", systemImage: "arrow.triangle.merge")
                    }
                }
                Button(role: .destructive) {
                    deleteTarget = name
                    deleteAffectedCount = repository.countActiveAssignments(tagName: name)
                } label: {
                    Label("全局删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.holoTextSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary.opacity(0.6))
        }
        .contentShape(Rectangle())
        .onTapGesture { viewingTag = TagRef(name: name) }
    }

    // MARK: - 动作

    private func confirmAdopt(_ name: String) {
        let converted = (try? repository.confirmAITagAssignments(tagName: name)) ?? 0
        ThoughtClassificationFeedbackStore.log(
            .confirm, thoughtId: UUID(), tagName: name,
            wasRecognizedTag: false
        )
        notice = String(localized: "已采用 #\(ThoughtTagNormalizer.displayName(name))（\(converted) 条）")
        loadData()
    }

    private func applyRename() {
        guard let old = renameTarget else { return }
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !newName.isEmpty else { return }
        do {
            let outcome = try service.renameTagEverywhere(from: old, to: newName)
            let isMerge = ThoughtTagNormalizer.key(old) != ThoughtTagNormalizer.key(newName)
                && recognizedKeys.contains(ThoughtTagNormalizer.key(newName))
            ThoughtClassificationFeedbackStore.log(
                isMerge || outcome == .merged ? .merge : .rename,
                thoughtId: UUID(), tagName: newName
            )
            notice = outcome == .merged ? String(localized: "已合并到 #\(ThoughtTagNormalizer.displayName(newName))") : String(localized: "已改名 #\(ThoughtTagNormalizer.displayName(newName))")
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = String(localized: "改名失败：\(error.localizedDescription)")
        }
        loadData()
    }

    private func mergeInto(_ name: String, target: String) {
        do {
            _ = try service.renameTagEverywhere(from: name, to: target)
            ThoughtClassificationFeedbackStore.log(.merge, thoughtId: UUID(), tagName: target)
            notice = String(localized: "已合并到 #\(ThoughtTagNormalizer.displayName(target))")
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = String(localized: "合并失败：\(error.localizedDescription)")
        }
        loadData()
    }

    private func applyDelete() {
        guard let name = deleteTarget else { return }
        deleteTarget = nil
        let result = service.deleteTagEverywhere(name: name)
        ThoughtClassificationFeedbackStore.log(.deleteGlobal, thoughtId: UUID(), tagName: name)
        notice = String(localized: "已删除 #\(ThoughtTagNormalizer.displayName(name))（影响 \(result?.removedAssignmentCount ?? 0) 条）")
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        loadData()
    }

    // MARK: - 数据

    private func loadData() {
        recognizedNames = repository.fetchUserRecognizedTagNames(limit: 200)
        unrecognizedAINames = repository.fetchUnrecognizedAITagNames(limit: 200)
        recognizedKeys = Set(recognizedNames.map { ThoughtTagNormalizer.key($0) })
        var counts: [String: Int] = [:]
        for name in recognizedNames + unrecognizedAINames {
            let key = ThoughtTagNormalizer.key(name)
            if counts[key] == nil {
                counts[key] = repository.countActiveAssignments(tagName: name)
            }
        }
        assignmentCounts = counts
        // 标签级 AI 排除：key → 实体 id 与已排除集合（菜单盾牌项与名称着色用）
        let scopeTags = repository.fetchUserTagsForAIScope()
        var idsByKey: [String: UUID] = [:]
        var excluded: Set<String> = []
        for info in scopeTags {
            let key = ThoughtTagNormalizer.key(info.tag.name)
            idsByKey[key] = info.tag.id
            if info.tag.excludeFromAI { excluded.insert(key) }
        }
        aiScopeTagIDs = idsByKey
        excludedTagKeys = excluded
    }

    /// 标签级 AI 排除开关；开启走确认弹窗，关闭直接生效
    private func setAIExcluded(tagID: UUID, excluded: Bool) {
        Task {
            _ = await ThoughtAIExclusionService.shared.setTagExcluded(tagID: tagID, excluded)
            loadData()
            notice = excluded
                ? String(localized: "已退出 AI 分析，已有的 AI 归类正在撤下")
                : String(localized: "已恢复参与 AI，稍后自动归类")
        }
    }

    private func applyAIScopeExclusion() {
        guard let pending = aiScopePending else { return }
        aiScopePending = nil
        setAIExcluded(tagID: pending.tagID, excluded: true)
    }

    private var aiScopeBinding: Binding<Bool> {
        Binding(get: { aiScopePending != nil }, set: { if !$0 { aiScopePending = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }
}

/// fullScreenCover(item:) 的标签引用（String 非_identifiable 的薄包装）
private struct TagRef: Identifiable {
    let name: String
    var id: String { name }
}

/// 标签下的想法列表（标签治理页点行进入）：日期 + 正文摘要，点行进编辑器
private struct TagThoughtListView: View {
    let tagName: String
    @Environment(\.dismiss) private var dismiss
    @State private var thoughts: [Thought] = []
    @State private var selectedThoughtId: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if thoughts.isEmpty {
                    VStack(spacing: HoloSpacing.sm) {
                        Text("这个标签下还没有想法")
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(thoughts, id: \.id) { thought in
                            thoughtRow(thought)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedThoughtId = thought.id }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.holoBackground)
            .navigationTitle("#\(ThoughtTagNormalizer.displayName(tagName))")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            #if canImport(UIKit)
            .fullScreenCover(item: $selectedThoughtId) { thoughtId in
                ThoughtEditorView(editingThoughtId: thoughtId)
                    .holoContentColumn()
            }
            #else
                        .sheet(item: $selectedThoughtId) { thoughtId in
                ThoughtEditorView(editingThoughtId: thoughtId)
                    .holoContentColumn()
            }
            #endif
            .task { load() }
            .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
                load()
            }
        }
        // 全屏弹层：边缘右滑返回（fullScreenCover 无系统返回）
        .holoEdgeSwipeBack { dismiss() }
    }

    private func thoughtRow(_ thought: Thought) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(thought.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.6))
            Text(thought.content)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2)
        }
        .padding(.vertical, HoloSpacing.xs)
    }

    @MainActor
    private func load() {
        let context = CoreDataStack.shared.viewContext
        context.performAndWait {
            let request = Thought.fetchRequest()
            request.predicate = NSPredicate(format: "deletedAt == nil AND isArchived == NO")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            let all = (try? context.fetch(request)) ?? []
            let key = ThoughtTagNormalizer.key(tagName)
            thoughts = all.filter {
                ThoughtTagPresentation.matches(
                    key,
                    manualNames: $0.tagArray.map(\.name),
                    aiNames: $0.visibleAITagNames
                )
            }
        }
    }
}
