//
//  ThoughtTagManagementView.swift
//  Holo
//
//  P1 标签治理页（方案 §4.2）：「我的标签 / AI 建议」双分组
//  AI 建议动作：确认采用 / 改名后采用 / 合并到已有 / 全局删除（复用既有 Repository 能力）
//  批量动作先展示受影响想法数；删除前二次确认
//

import SwiftUI

struct ThoughtTagManagementView: View {

    private enum Segment: String, CaseIterable {
        case mine = "我的标签"
        case aiSuggested = "AI 建议"
    }

    @State private var segment: Segment = .mine
    @State private var recognizedNames: [String] = []
    @State private var unrecognizedAINames: [String] = []
    @State private var assignmentCounts: [String: Int] = [:]
    @State private var recognizedKeys: Set<String> = []

    /// 待执行改名/合并的标签（弹输入框）
    @State private var renameTarget: String? = nil
    @State private var renameText: String = ""
    /// 待删除标签（先展示受影响数，二次确认）
    @State private var deleteTarget: String? = nil
    @State private var deleteAffectedCount: Int = 0
    @State private var notice: String? = nil

    @Environment(\.dismiss) private var dismiss

    private let repository = ThoughtRepository()
    private let service = ThoughtOrganizationService()

    var body: some View {
        NavigationStack {
            List {
                Picker("分组", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { seg in
                        Text(seg.rawValue).tag(seg)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    let names = segment == .mine ? recognizedNames : unrecognizedAINames
                    if names.isEmpty {
                        Text(segment == .mine ? "还没有你确认过的标签" : "暂无待处理的 AI 建议标签")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }
                    ForEach(names, id: \.self) { name in
                        tagRow(name)
                    }
                } footer: {
                    Text(segment == .mine
                         ? "你手动创建、正文 # 或确认过的标签，是 AI 优先复用的词表。"
                         : "仅来自 AI 建议、尚未被你认可的标签；确认后才会进入你的标签库。")
                }
            }
            .navigationTitle("标签治理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { loadData() }
            .alert("重命名标签", isPresented: renameBinding) {
                TextField("新标签名", text: $renameText)
                Button("确认") { applyRename() }
                Button("取消", role: .cancel) { renameTarget = nil }
            } message: {
                Text("把 #\(ThoughtTagNormalizer.displayName(renameTarget ?? "")) 改名为（与已有标签同名即为合并）")
            }
            .alert("删除标签", isPresented: deleteBinding) {
                Button("删除", role: .destructive) { applyDelete() }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("将影响 \(deleteAffectedCount) 条想法的标签关联；原文与手动标签不受影响，AI 也不会立即再建回。")
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
        let count = assignmentCounts[ThoughtTagNormalizer.key(name)] ?? 0
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(display)")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Text(count > 0 ? "\(count) 条想法" : "未使用")
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
                Button {
                    renameTarget = name
                    renameText = display
                } label: {
                    Label(segment == .mine ? "改名" : "改名后采用", systemImage: "pencil")
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
        }
    }

    // MARK: - 动作

    private func confirmAdopt(_ name: String) {
        let converted = (try? repository.confirmAITagAssignments(tagName: name)) ?? 0
        ThoughtClassificationFeedbackStore.log(
            .confirm, thoughtId: UUID(), tagName: name,
            wasRecognizedTag: false
        )
        notice = "已采用 #\(ThoughtTagNormalizer.displayName(name))（\(converted) 条）"
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
            notice = outcome == .merged ? "已合并到 #\(ThoughtTagNormalizer.displayName(newName))" : "已改名 #\(ThoughtTagNormalizer.displayName(newName))"
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = "改名失败：\(error.localizedDescription)"
        }
        loadData()
    }

    private func mergeInto(_ name: String, target: String) {
        do {
            _ = try service.renameTagEverywhere(from: name, to: target)
            ThoughtClassificationFeedbackStore.log(.merge, thoughtId: UUID(), tagName: target)
            notice = "已合并到 #\(ThoughtTagNormalizer.displayName(target))"
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = "合并失败：\(error.localizedDescription)"
        }
        loadData()
    }

    private func applyDelete() {
        guard let name = deleteTarget else { return }
        deleteTarget = nil
        let result = service.deleteTagEverywhere(name: name)
        ThoughtClassificationFeedbackStore.log(.deleteGlobal, thoughtId: UUID(), tagName: name)
        notice = "已删除 #\(ThoughtTagNormalizer.displayName(name))（影响 \(result?.removedAssignmentCount ?? 0) 条）"
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
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }
}
