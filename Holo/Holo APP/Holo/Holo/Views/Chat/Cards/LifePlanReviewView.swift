//
//  LifePlanReviewView.swift
//  Holo
//
//  计划确认页（fullScreenCover，仿 GoalDraftReviewView）：
//  优先结果勾选（建目标）→ 行动卡逐项勾选/拒绝（拒绝可选原因标签）→ 确认写回（可撤销）。
//

import SwiftUI

struct LifePlanReviewView: View {
    let snapshot: LifePlanSnapshot
    let onConfirm: (LifePlanConfirmSelection) -> Void
    let onCancel: () -> Void

    struct LifePlanConfirmSelection {
        var planID: UUID
        var selectedPriorityIDs: Set<UUID>
        var selectedActionIDs: Set<UUID>
        var rejections: [(actionID: UUID, reasonTag: String?, freeText: String?)]
    }

    @State private var selectedPriorityIDs: Set<UUID> = []
    @State private var selectedActionIDs: Set<UUID> = []
    @State private var rejections: [UUID: String] = [:]
    @State private var rejectingAction: LifePlanActionSnapshot?
    @State private var rejectionFreeText = ""

    private static let rejectionTags: [(raw: String, label: String)] = [
        ("no_need", "不需要"),
        ("no_time", "时间不够"),
        ("dislike_style", "不喜欢这个方式"),
        ("distrust", "证据不够有说服力")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    introCard
                    prioritiesCard
                    actionsCard
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle("确认本周重点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认落库", action: confirm)
                        .font(.system(size: 15, weight: .semibold))
                        .disabled(selectedPriorityIDs.isEmpty && selectedActionIDs.isEmpty)
                }
            }
            .sheet(item: $rejectingAction) { action in
                rejectionSheet(action)
                    .presentationDetents([.medium])
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Text("勾选你认可的项：优先结果会建为目标，行动卡会创建对应的任务或习惯。你决定接受哪些——不勾的就是拒绝，拒绝会帮我下次做得更好。")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoDivider.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var prioritiesCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            sectionHeader("优先结果", subtitle: "勾选后创建为目标")
            ForEach(snapshot.priorities) { priority in
                Button {
                    toggleSelection(&selectedPriorityIDs, priority.id)
                } label: {
                    HStack(alignment: .top, spacing: HoloSpacing.sm) {
                        Image(systemName: selectedPriorityIDs.contains(priority.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedPriorityIDs.contains(priority.id) ? .holoPrimary : .holoTextSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(priority.outcome)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoTextPrimary)
                                .multilineTextAlignment(.leading)
                            Text(priority.whyNow)
                                .font(.holoLabel)
                                .foregroundColor(.holoTextSecondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoDivider.opacity(0.5)))
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            sectionHeader("行动卡", subtitle: "任务 / 习惯；左滑或点「拒绝」告诉我原因")
            ForEach(snapshot.actions.filter { $0.status == "proposed" }) { action in
                actionRow(action)
            }
            if snapshot.actions.filter({ $0.status == "proposed" }).isEmpty {
                Text("本计划已无待确认行动")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoDivider.opacity(0.5)))
    }

    private func actionRow(_ action: LifePlanActionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Button {
                toggleSelection(&selectedActionIDs, action.id)
            } label: {
                HStack(alignment: .top, spacing: HoloSpacing.sm) {
                    Image(systemName: selectedActionIDs.contains(action.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selectedActionIDs.contains(action.id) ? .holoPrimary : .holoTextSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: action.type == "habit" ? "arrow.triangle.2.circlepath" : "checkmark.square")
                                .font(.system(size: 11))
                                .foregroundColor(.holoTextSecondary)
                            Text(action.payload.displayTitle)
                                .font(.system(size: 14))
                                .foregroundColor(.holoTextPrimary)
                                .multilineTextAlignment(.leading)
                        }
                        if let benefit = action.expectedBenefit, !benefit.isEmpty {
                            Text(benefit)
                                .font(.holoLabel)
                                .foregroundColor(.holoTextSecondary)
                        }
                        if let tradeoff = action.tradeoff, !tradeoff.isEmpty {
                            Text(tradeoff)
                                .font(.holoLabel)
                                .foregroundColor(.holoChart2)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            HStack {
                if let tag = rejections[action.id] {
                    Text("已拒绝：\(Self.rejectionTags.first { $0.raw == tag }?.label ?? tag)")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
                Button("拒绝") {
                    rejectionFreeText = ""
                    rejectingAction = action
                }
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func rejectionSheet(_ action: LifePlanActionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("「\(action.payload.displayTitle)」不要的原因？")
                .font(.system(size: 15, weight: .semibold))
            ForEach(Self.rejectionTags, id: \.raw) { tag in
                Button {
                    rejections[action.id] = tag.raw
                    selectedActionIDs.remove(action.id)
                    rejectingAction = nil
                } label: {
                    HStack {
                        Text(tag.label)
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        if rejections[action.id] == tag.raw {
                            Image(systemName: "checkmark")
                                .foregroundColor(.holoPrimary)
                        }
                    }
                    .padding(HoloSpacing.sm)
                    .background(Color.holoDivider.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .buttonStyle(.plain)
            }
            TextField("补充一句（可选）", text: $rejectionFreeText)
                .font(.system(size: 14))
                .padding(HoloSpacing.sm)
                .background(Color.holoDivider.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .padding(HoloSpacing.lg)
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
            Text(subtitle)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private func toggleSelection(_ set: inout Set<UUID>, _ id: UUID) {
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
            rejections[id] = nil
        }
    }

    private func confirm() {
        let rejectionList: [(actionID: UUID, reasonTag: String?, freeText: String?)] = rejections
            .filter { $0.value.isEmpty == false || rejectingRecorded($0.key) }
            .map { (actionID: $0.key, reasonTag: $0.value, freeText: nil) }
        onConfirm(LifePlanConfirmSelection(
            planID: snapshot.id,
            selectedPriorityIDs: selectedPriorityIDs,
            selectedActionIDs: selectedActionIDs,
            rejections: rejectionList
        ))
    }

    private func rejectingRecorded(_ id: UUID) -> Bool {
        rejections[id] != nil
    }
}
