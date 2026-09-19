//
//  CategoryMoveTargetPicker.swift
//  Holo
//
//  分类删除的转移目标选择页（方案 §3.2/§3.3）。
//
//  只消费 CategoryMoveCandidate 值快照：候选资格（同类型二级、非源家族、
//  「待分类」例外）由仓库与策略层保证，本页只负责展示与点选。
//  「待分类」置顶但不预选——去处必须由用户主动决定。
//

import SwiftUI

struct CategoryMoveTargetPicker: View {
    @Environment(\.dismiss) private var dismiss

    let candidates: [CategoryMoveCandidate]
    @Binding var selection: CategoryMoveCandidate?
    /// 选定后是否联动关闭（内嵌决策页时置 false，仅回填）
    var autoDismiss = true

    private var sortedCandidates: [CategoryMoveCandidate] {
        candidates.sorted { lhs, rhs in
            let lPending = lhs.name == FinancePendingCategory.currentName
            let rPending = rhs.name == FinancePendingCategory.currentName
            if lPending != rPending { return lPending }
            let lParent = lhs.parentName ?? ""
            let rParent = rhs.parentName ?? ""
            if lParent != rParent { return lParent < rParent }
            return lhs.name < rhs.name
        }
    }

    var body: some View {
        List {
            if sortedCandidates.isEmpty {
                Text("没有可用的转移目标")
                    .foregroundColor(.holoTextSecondary)
            }
            ForEach(sortedCandidates) { candidate in
                Button {
                    selection = candidate
                    if autoDismiss { dismiss() }
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        CategoryIconBadge(
                            iconName: candidate.icon,
                            color: Color(hex: candidate.colorHex),
                            diameter: 32
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name)
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)
                            if let parentName = candidate.parentName {
                                Text(String(localized: "属于「\(parentName)」"))
                                    .font(.holoCaption)
                                    .foregroundColor(.holoTextSecondary)
                            }
                        }
                        Spacer()
                        if selection?.id == candidate.id {
                            Image(systemName: "checkmark")
                                .foregroundColor(.holoPrimary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "转移到\(candidate.name)"))
            }
        }
        .navigationTitle(String(localized: "选择目标分类"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
