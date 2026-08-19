//
//  MemoryAttributionBadge.swift
//  Holo
//
//  记忆引用署名：AI 回答气泡下方的持久署名行。
//  「引用了你 N 条记忆」可展开查看具体记忆内容，并点入单条记忆详情——
//  让记忆的使用可见、可核对。
//

import SwiftUI

struct MemoryAttributionBadge: View {
    let count: Int
    let memoryIDs: [String]

    @State private var isExpanded = false
    @State private var records: [HoloMemoryRecord] = []
    @State private var selectedRecord: HoloMemoryRecord?

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
                    if records.isEmpty {
                        Text("记忆可能已被删除或归档")
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary.opacity(0.7))
                    } else {
                        ForEach(records) { record in
                            attributionRow(record)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.holoDivider.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .sheet(item: $selectedRecord) { record in
            NavigationStack {
                HoloMemoryRecordDetailView(record: record, onChange: { change in
                    if case .removed(let id) = change {
                        records.removeAll { $0.id == id }
                    }
                })
            }
        }
        .task(id: memoryIDs) {
            guard records.isEmpty, !memoryIDs.isEmpty else { return }
            await loadRecords()
        }
    }

    private func attributionRow(_ record: HoloMemoryRecord) -> some View {
        Button {
            selectedRecord = record
        } label: {
            HStack(alignment: .top, spacing: 4) {
                Text("· \(record.displaySummary)")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.holoTextPlaceholder)
                    .padding(.top, 2)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadRecords() async {
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else { return }
        var loaded: [HoloMemoryRecord] = []
        for id in memoryIDs.prefix(8) {
            if let record = try? await repository.fetch(id: id) {
                loaded.append(record)
            }
        }
        records = loaded
    }
}
