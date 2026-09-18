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
        VStack(alignment: .leading, spacing: 12) {
            if let assistantText, !assistantText.isEmpty {
                Text(assistantText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func routeRow(_ option: GoalRouteOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                if option.id == recommendedOptionID {
                    Text("推荐")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                Spacer()
                Button("选这条") { onChoose(option.id) }
                    .font(.subheadline)
                    .disabled(isBusy)
            }
            LabeledContent {
                Text(option.fit)
                    .foregroundStyle(.secondary)
            } label: {
                Text("适合").font(.footnote)
            }
            LabeledContent {
                Text(option.effort)
                    .foregroundStyle(.secondary)
            } label: {
                Text("投入").font(.footnote)
            }
            LabeledContent {
                Text(option.tradeoff)
                    .foregroundStyle(.secondary)
            } label: {
                Text("代价").font(.footnote)
            }
            Text(option.reason)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
