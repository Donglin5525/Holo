//
//  MemoryAttributionBadge.swift
//  Holo
//
//  记忆引用署名：AI 回答气泡下方的持久署名行。
//  「引用了你 N 条记忆」可展开查看具体记忆内容——让记忆的使用可见、可核对。
//

import SwiftUI

struct MemoryAttributionBadge: View {
    let count: Int
    let memoryIDs: [String]

    @State private var isExpanded = false
    @State private var summaries: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "brain.head.profile")
                        .font(.system(size: 10))
                    Text(isExpanded ? "收起引用" : "引用了你 \(count) 条记忆")
                        .font(.system(size: 11))
                }
                .foregroundColor(.holoTextSecondary.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("本条回答引用了 \(count) 条已记住的信息")

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if summaries.isEmpty {
                        Text("记忆可能已被删除或归档")
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary.opacity(0.7))
                    } else {
                        ForEach(summaries, id: \.self) { summary in
                            Text("· \(summary)")
                                .font(.system(size: 11))
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.holoDivider.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .task(id: memoryIDs) {
            guard summaries.isEmpty, !memoryIDs.isEmpty else { return }
            await loadSummaries()
        }
    }

    private func loadSummaries() async {
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else { return }
        var loaded: [String] = []
        for id in memoryIDs.prefix(8) {
            if let record = try? await repository.fetch(id: id) {
                loaded.append(record.displaySummary)
            }
        }
        summaries = loaded
    }
}
