//
//  GoalWorkshopOptionsCard.swift
//  Holo
//
//  目标共创·路径卡（方案任务 5）：2–3 条实质不同的路径，含理由与代价
//

import SwiftUI

struct GoalWorkshopOptionsCard: View {
    let options: [GoalRouteOption]
    let recommendedOptionID: String?
    let assistantText: String?
    let isBusy: Bool
    let onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            if let assistantText, !assistantText.isEmpty {
                Text(assistantText)
                    .font(.subheadline)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            Text("有\(options.count > 1 ? "几条" : "一条")走得通的路，代价各不相同：")
                .font(.headline)

            ForEach(options) { option in
                routeRow(option)
            }

            if let recommendedOptionID,
               let recommended = options.first(where: { $0.id == recommendedOptionID }) {
                Button {
                    onChoose(recommended.id)
                } label: {
                    Text("听你的，按「\(recommended.title)」来")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HoloActionStyle(role: .primary))
                .disabled(isBusy)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private func routeRow(_ option: GoalRouteOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: HoloSpacing.sm) {
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if option.id == recommendedOptionID {
                    Text("推荐")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Color.holoToolAction)
                        .background(Color.holoToolAction.opacity(0.1), in: Capsule())
                }
                }
                Spacer()
                Button("选这条") { onChoose(option.id) }
                    .font(.subheadline)
                    .frame(minWidth: 44, minHeight: 44)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isBusy)
            }
            detail("适合", value: option.fit)
            detail("投入", value: option.effort)
            detail("代价", value: option.tradeoff)
            Text(option.reason)
                .font(.footnote)
                .foregroundStyle(Color.holoToolTextSecondary)
        }
        .padding(12)
        .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private func detail(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Text(title).holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
            Text(value).holoText(.supporting).foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
